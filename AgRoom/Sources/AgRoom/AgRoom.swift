import SwiftUI
import AppKit
import AgRoomUI
import AgRoomCore

// MARK: - App Delegate

/// 应用代理：菜单栏状态项常驻 + 窗口重开处理
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menuBarRobot: MenuBarRobotController?
    private weak var menuBarHub: Hub?
    var createMainWindow: (@MainActor () -> Void)?
    /// 退出确认中：避免 `applicationShouldTerminate` 重入再次弹窗。
    private var isResolvingTermination = false

    /// 主窗口只按显式标识查找，不能回落到邮件或小应用窗口。
    ///
    /// 加入邮件撰写独立窗口后，`NSApp.windows.first` 可能选中编辑器；菜单、快捷键、
    /// Dock 重开与设置入口都必须用同一个查找规则。
    private var mainWindow: NSWindow? { NSApp.agRoomMainWindow }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 外观偏好（设置页持久化；nil = 跟随系统）
        let saved = UserDefaults.standard.string(forKey: "agroom.appearance") ?? ""
        AppAppearance.apply(AppAppearance(rawValue: saved) ?? .system)
        setupStatusItem()
        setupGlobalHotkey()
        // 守护进程监督：遗留移交补拉续跑 + 完成通知刷新（后台任务接续入口）
        DaemonSupervisor.shared.start()
        // 定时任务：App 内调度，关闭窗口后仍驻留菜单栏执行
        ScheduledTaskCenter.shared.start()
        // 允许通过背景区域拖动窗口（默认标题栏下保留，拖拽体验不变）
        for window in NSApp.windows {
            window.isMovableByWindowBackground = true
        }
    }

    /// 退出前移交：仍在流式运行的对话轮写入移交文件并拉起守护进程，
    /// 只要电脑不进入休眠，任务即可执行完毕；守护进程全部完成后自动退出
    ///
    /// 加入邮件撰写窗口后还要处理两件事：把未落盘的草稿保存到各自空间，以及在有邮件
    /// 正在投递时让用户明确选择「稍后退出」或「立即退出」（投递是已发生的外部副作用）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isResolvingTermination { return .terminateLater }
        if MailComposeLifecycle.hasInFlightSends {
            isResolvingTermination = true
            presentSendInFlightAlert()
            return .terminateLater
        }
        isResolvingTermination = true
        Task { @MainActor in
            await self.finishTermination()
        }
        return .terminateLater
    }

    /// 有邮件正在投递时的退出确认。
    private func presentSendInFlightAlert() {
        let alert = NSAlert()
        alert.messageText = L.string("mail.exit.sending.title")
        alert.informativeText = L.string("mail.exit.sending.message")
        alert.addButton(withTitle: L.string("mail.exit.sending.wait"))
        alert.addButton(withTitle: L.string("mail.exit.sending.quit"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isResolvingTermination = false
                guard response == .alertSecondButtonReturn else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
                self.isResolvingTermination = true
                await self.finishTermination()
            }
        }
        if let window = mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func finishTermination() async {
        let canQuit = await AppQuitSequence.shouldQuit(
            markdown: {
                if await MarkdownDraftLifecycle.saveAll() { return true }
                return self.confirmDiscard(title: "md.draft.save_failed", message: "md.draft.exit_failed")
            },
            mail: {
                guard await MailComposeLifecycle.saveAllDrafts() else {
                    self.presentTerminationBlockedAlert(messageKey: "mail.exit.draft_failed", titleKey: "mail.compose.saveDraftFailed")
                    return false
                }
                return true
            },
            nativeApps: {
                if await NativeAppLifecycle.saveAll() { return true }
                return self.confirmDiscard(title: "apps.close.failed", message: "apps.exit.failed")
            },
            prepareNotes: {
                guard await NotesLifecycle.prepareForTermination() else {
                    self.presentTerminationBlockedAlert(messageKey: "notes.exit.failed")
                    return false
                }
                return true
            },
            handoff: { await self.performTerminationHandoff() },
            resumeNotes: { NotesLifecycle.resumeAfterCancelledExit() },
            resumeApps: { NativeAppLifecycle.resumeVisible() }
        )
        if !canQuit { isResolvingTermination = false }
        NSApp.reply(toApplicationShouldTerminate: canQuit)
    }

    private func confirmDiscard(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L.string(title)
        alert.informativeText = L.string(message)
        alert.addButton(withTitle: L.string("common.cancel"))
        alert.addButton(withTitle: L.string("apps.close.discard"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Persist only complete boundaries, then wait for a new-version Daemon
    /// to acknowledge that it can take the global lock after an older one.
    /// A local run whose result or suspension has not been saved keeps App
    /// termination pending until the user returns and it finishes safely.
    private func performTerminationHandoff() async -> Bool {
        let runs = ChatRunRegistry.shared
        guard !runs.hasUnhandoffableRunningRuns else {
            presentTerminationBlockedAlert(messageKey: "app.exit.active.message")
            return false
        }
        let handedOff = runs.handoffAllAndCancel()
        // A prior failed READY attempt may already have left a valid
        // Daemon-owned record. A later quit still needs a live successor even
        // when no local run remains to hand off in this attempt.
        if handedOff > 0 || DaemonHandoffStore.standard.hasActionableRecords || NoteBackgroundHandoff.hasRequests {
            guard await DaemonController.spawnRelayDaemon() else {
                presentTerminationBlockedAlert(messageKey: "app.exit.relay_failed.message")
                return false
            }
        }
        // The READY wait is an async boundary. Recheck local ownership before
        // allowing the App to disappear, including a run started meanwhile.
        guard !runs.hasUncertainHandoffClaims,
              !runs.hasUnhandoffableRunningRuns,
              runs.handoffableRunCount == 0 else {
            presentTerminationBlockedAlert(messageKey: "app.exit.active.message")
            return false
        }
        return true
    }

    private func presentTerminationBlockedAlert(messageKey: String, titleKey: String = "app.exit.active.title") {
        let alert = NSAlert()
        alert.messageText = L.string(titleKey)
        alert.informativeText = L.string(messageKey)
        alert.addButton(withTitle: L.string("common.ok"))
        _ = alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarRobot?.stop()
        HotkeyManager.shared.unregister()
        ScheduledTaskCenter.shared.stop()
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        HotkeyManager.shared.onToggle = { [weak self] in
            self?.toggleMainWindow()
        }
        HotkeyManager.shared.onCaptureNote = { [weak self] in
            self?.openMainWindow(page: .notes)
            AppNavigation.shared.performInCurrentSpace(.noteScreenshot)
        }
        HotkeyManager.shared.register()
    }

    /// 全局快捷键行为：主窗口可见且在前台时隐藏，否则唤起
    private func toggleMainWindow() {
        let window = mainWindow
        if NSApp.isActive, let window, window.isVisible {
            window.orderOut(nil)
            NSApp.hide(nil)
        } else {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || mainWindow?.isVisible != true || mainWindow?.isMiniaturized == true {
            showMainWindow()
        }
        for window in NSApp.windows {
            window.isMovableByWindowBackground = true
        }
        return true
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        // 所有表情共用固定宽度，双手与鼾睡标记不会挤动旁边的菜单栏项目。
        let item = NSStatusBar.system.statusItem(withLength: 28)

        let menu = NSMenu()

        let showItem = NSMenuItem(
            title: L.string("menu.show_app"),
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)

        for command in [AppMenuCommand.newChat, .search, .taskCenter, .artifactLibrary, .noteRecording, .noteScreenshot, .notePaste] {
            let entry = NSMenuItem(title: L.string(command.labelKey), action: #selector(performMenuCommand(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = command.rawValue
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let appsItem = NSMenuItem(title: L.string("nav.apps"), action: #selector(openApps), keyEquivalent: "")
        appsItem.target = self
        menu.addItem(appsItem)

        // 设置 / 帮助：唤起主窗口并切到对应功能页（与应用菜单同一入口）
        let settingsItem = NSMenuItem(
            title: L.string("nav.settings"),
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let helpItem = NSMenuItem(
            title: L.string("nav.help"),
            action: #selector(openHelp),
            keyEquivalent: ""
        )
        helpItem.target = self
        menu.addItem(helpItem)

        // 全局快捷键提示（只读展示项）
        let hintItem = NSMenuItem(title: "⌥⌘Space", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L.string("menu.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        if let button = item.button {
            let robot = MenuBarRobotController(button: button)
            menuBarRobot = robot
            menu.delegate = robot
            if let hub = menuBarHub { robot.bind(hub: hub) }
        }
    }

    func bindMenuBar(to hub: Hub) {
        menuBarHub = hub
        menuBarRobot?.bind(hub: hub)
    }

    func refreshMenuTitles() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items {
            if let raw = item.representedObject as? String, let command = AppMenuCommand(rawValue: raw) {
                item.title = L.string(command.labelKey)
            }
        }
        for (action, key) in [
            (#selector(showMainWindow), "menu.show_app"), (#selector(openApps), "nav.apps"),
            (#selector(openSettings), "nav.settings"), (#selector(openHelp), "nav.help"),
            (#selector(NSApplication.terminate(_:)), "menu.quit")
        ] {
            menu.items.first { $0.action == action }?.title = L.string(key)
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else { createMainWindow?() }
    }

    @objc private func openApps() { openMainWindow(page: .apps) }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = AppMenuCommand(rawValue: raw) else { return }
        perform(command)
    }

    func perform(_ command: AppMenuCommand) {
        guard let hub = menuBarHub else { return }
        showMainWindow()
        AppNavigation.shared.perform(command, space: hub.spaceStore.current)
    }

    /// 状态项「设置」：唤起主窗口并切到设置页
    @objc private func openSettings() {
        openMainWindow(page: .settings)
    }

    /// 状态项「帮助」：唤起主窗口并切到帮助页
    @objc private func openHelp() {
        openMainWindow(page: .help)
    }

    /// 唤起主窗口并跳转到指定功能页
    func openMainWindow(page: HubNavItem) {
        showMainWindow()
        AppNavigation.shared.open(page: page)
    }
}

// MARK: - AgRoom App

/// 主窗口查找：仅接受显式身份，关闭后由 Window scene 重建。
///
/// 撰写窗口有自己的标识，因此不会在「显示阿吉屋」「设置」等入口里被误当作主窗口。
extension NSApplication {
    var agRoomMainWindow: NSWindow? {
        windows.first { $0.identifier == AgRoomWindowIdentifier.main }
    }
}

@main
struct AgRoom: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var hub = Hub()
    @State private var languageManager = LanguageManager.shared

    var body: some Scene {
        Window(L.string("app.name"), id: "agroom.main") {
            RootView(hub: hub)
                .environment(languageManager)
                .environment(\.locale, Locale(identifier: languageManager.activeLanguageCode))
                .environment(\.layoutDirection, languageManager.layoutDirection)
                .id(languageManager.version)
                .background(MainWindowConfiguration())
                .background(MainWindowRegistration(appDelegate: appDelegate))
                .task { appDelegate.bindMenuBar(to: hub) }
        }
        // 使用全窗口统一工具栏，隐藏可见应用名，保留 Window 的语义标题。
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 760)
        .commands {
            ReadingTextCommands()
            AppMenuCommands(openPage: openMainWindow, perform: appDelegate.perform, currentSpace: { hub.spaceStore.current })
            CommandMenu(L.string("nav.apps")) {
                Button(L.string("apps.show")) { openMainWindow(page: .apps) }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L.string("nav.settings")) {
                    openMainWindow(page: .settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(L.string("nav.help")) {
                    openMainWindow(page: .help)
                }
            }
        }
    }

    /// 唤起主窗口并跳转到指定功能页
    ///
    /// 设置与帮助都集成在主窗口导航中：这里先定位主窗口，再通过
    /// `AppNavigation` 驱动页内切换；主窗口尚未挂载时跳转会被挂起，
    /// 窗口挂载后自动补发。
    private func openMainWindow(page: HubNavItem) {
        appDelegate.openMainWindow(page: page)
    }
}

private struct MainWindowRegistration: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var languageManager = LanguageManager.shared
    var body: some View {
        Color.clear.onAppear { appDelegate.createMainWindow = { openWindow(id: "agroom.main") } }
            .onChange(of: languageManager.version) { _, _ in appDelegate.refreshMenuTitles() }
    }
}

/// 按主窗口挂载配置身份与标题栏，覆盖新建窗口和根视图重建。
@MainActor
private struct MainWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView {
        WindowView()
    }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.applyConfiguration()
    }

    static func dismantleNSView(_ nsView: WindowView, coordinator: ()) {
        nsView.removeDoubleClickMonitor()
    }

    final class WindowView: NSView {
        private var doubleClickMonitor: Any?
        private var consumingDoubleClick = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            removeDoubleClickMonitor()
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyConfiguration()
        }

        func applyConfiguration() {
            guard let window else { return }
            // 主窗口显式标识：撰写窗口有自己的标识，二者不能互相误认
            if window.identifier == nil { window.identifier = AgRoomWindowIdentifier.main }
            // 根视图重建后仍隐藏可见标题；窗口标题本身保留给窗口菜单等系统入口。
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            // RootView 在整个分栏顶边画常驻细线，关闭系统分隔效果以免重复。
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }

            if doubleClickMonitor == nil {
                doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                    let handled = MainActor.assumeIsolated {
                        self?.handleTitlebarDoubleClick(event) ?? false
                    }
                    return handled ? nil : event
                }
            }
        }

        func removeDoubleClickMonitor() {
            if let doubleClickMonitor { NSEvent.removeMonitor(doubleClickMonitor) }
            doubleClickMonitor = nil
            consumingDoubleClick = false
        }

        private func handleTitlebarDoubleClick(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            if event.type == .leftMouseUp {
                guard consumingDoubleClick else { return false }
                consumingDoubleClick = false
                return true
            }
            consumingDoubleClick = false
            guard event.clickCount == 2,
                  !window.styleMask.contains(.fullScreen), window.attachedSheet == nil,
                  isTitlebarBackground(at: event.locationInWindow, in: window) else { return false }

            // 使用 AppKit 的标准缩放来保留原窗口大小；吞掉这次双击，避免系统再执行一次。
            consumingDoubleClick = true
            window.performZoom(nil)
            return true
        }

        private func isTitlebarBackground(at point: NSPoint, in window: NSWindow) -> Bool {
            guard point.y >= window.contentLayoutRect.maxY,
                  let frameView = window.contentView?.superview,
                  let hitView = frameView.hitTest(frameView.convert(point, from: nil)) else { return false }

            // SwiftUI 工具栏按钮的宿主不是 NSControl，需按实际视图范围排除。
            for item in window.toolbar?.items ?? [] {
                guard let view = item.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
                if view.convert(view.bounds, to: nil).contains(point) { return false }
            }
            // 交通灯、原生搜索框及其内部宿主保持各自的双击行为。
            var ancestor: NSView? = hitView
            while let view = ancestor {
                if view is NSControl || !view.mouseDownCanMoveWindow { return false }
                ancestor = view.superview
            }
            return true
        }
    }
}
