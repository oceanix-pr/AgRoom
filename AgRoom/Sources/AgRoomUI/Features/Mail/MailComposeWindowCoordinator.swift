import AppKit
import SwiftUI
import AgRoomCore

// MARK: - Window Identifiers

/// 窗口标识：主窗口与撰写窗口必须能明确区分。
///
/// App 层此前用「第一个非 Panel 窗口」寻找主窗口；加入撰写窗口后这种推断会误选邮件
/// 编辑器，因此菜单、全局快捷键、Dock 重开与设置入口统一按标识查找。
public enum AgRoomWindowIdentifier {
    public static let main = NSUserInterfaceItemIdentifier("agroom.main")
    public static let mailCompose = NSUserInterfaceItemIdentifier("agroom.mail.compose")
}

// MARK: - Mail Compose Lifecycle (App 入口)

/// 供 App target 使用的撰写窗口生命周期入口。
///
/// App 只需在退出前了解「是否有发送在途」并落盘未保存草稿，不需要接触窗口实现细节，
/// 因此这里只暴露最小的只读状态与一个保存动作。
@MainActor
public enum MailComposeLifecycle {
    /// 是否有邮件正在发送（退出前需要处理）。
    public static var hasInFlightSends: Bool { MailSendCoordinator.shared.hasInFlightSends }

    /// 当前打开的撰写窗口数量。
    public static var openWindowCount: Int { MailComposeWindowCoordinator.shared.openWindowCount }

    /// 把所有打开的撰写窗口草稿落盘（应用退出前调用）。
    public static func saveAllDrafts() async -> Bool {
        await MailComposeWindowCoordinator.shared.saveAllDrafts()
    }
}

// MARK: - Mail Compose Window Coordinator

/// 撰写窗口协调器：创建、去重、最大化与关闭撰写窗口。
///
/// 窗口按 `(space, draftID)` 注册：同一草稿再次打开只会激活已有窗口，不同草稿可同时
/// 存在。窗口在创建时固定其空间与账号，主窗口切换空间 / 账号 / 选中邮件都不影响它们。
///
/// 本协调器是全局 UI 对象（与 `HotkeyManager` 同类），只持有窗口与其视图模型，
/// **不缓存任何空间内服务**：服务始终由窗口模型按固定空间从 `Hub` 现取现建。
@MainActor
final class MailComposeWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = MailComposeWindowCoordinator()

    private final class Entry {
        let key: String
        let window: NSWindow
        let viewModel: MailComposeViewModel
        /// 最大化前的窗口位置尺寸（nil 表示当前未最大化）。
        var restoreFrame: NSRect?
        var isClosing = false
        var isDeciding = false

        init(key: String, window: NSWindow, viewModel: MailComposeViewModel) {
            self.key = key
            self.window = window
            self.viewModel = viewModel
        }
    }

    private var entries: [String: Entry] = [:]
    private var frames: [ObjectIdentifier: Entry] = [:]

    private override init() { super.init() }

    /// 当前打开的撰写窗口数量（应用退出协调用）。
    var openWindowCount: Int { entries.count }

    /// 把所有打开的窗口草稿落盘（应用退出前调用，避免刚到期的防抖内容丢失）。
    func saveAllDrafts() async -> Bool {
        let failures = await Self.failedDrafts(in: Array(entries.values)) { entry in
            await entry.viewModel.saveDraft(silently: true)
        }
        failures.first?.window.makeKeyAndOrderFront(nil)
        return failures.isEmpty
    }

    /// 不短路：一封失败不能阻止其他窗口保存。重试读取新的窗口快照。
    static func failedDrafts<Draft>(in drafts: [Draft], save: @MainActor (Draft) async -> Bool) async -> [Draft] {
        var failures: [Draft] = []
        for draft in drafts {
            if !(await save(draft)) { failures.append(draft) }
        }
        return failures
    }

    // MARK: - Open

    /// 打开（或激活）一封草稿的撰写窗口。
    func open(
        draft: MailDraft,
        space: AppSpace,
        hub: Hub,
        fromDescription: String,
        showAIPanel: Bool
    ) {
        let key = Self.key(space: space, draftID: draft.id)
        if let entry = entries[key] {
            // 同一草稿只允许一个编辑窗口：激活已有窗口
            if showAIPanel { entry.viewModel.isAIPanelVisible = true }
            entry.window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = MailComposeViewModel(
            draft: draft,
            space: space,
            hub: hub,
            fromDescription: fromDescription,
            isAIPanelVisible: showAIPanel
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = AgRoomWindowIdentifier.mailCompose
        window.title = Self.windowTitle(kind: draft.composeKind, subject: draft.subject, attribution: viewModel.attribution)
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: MailComposeView(viewModel: viewModel))
        window.delegate = self
        if !hasVisibleFrame(window) { window.center() }

        let entry = Entry(key: key, window: window, viewModel: viewModel)
        viewModel.onRequestMaximize = { [weak self, weak window] in
            guard let self, let window else { return }
            self.toggleMaximize(window)
        }
        viewModel.onRequestClose = { [weak window] in
            window?.performClose(nil)
        }

        entries[key] = entry
        frames[ObjectIdentifier(window)] = entry

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func key(space: AppSpace, draftID: UUID) -> String {
        "\(space.rawValue)|\(draftID.uuidString)"
    }

    func refreshTitles() {
        for entry in entries.values {
            entry.window.title = Self.windowTitle(kind: entry.viewModel.composeKind, subject: entry.viewModel.subject,
                                                 attribution: entry.viewModel.attribution)
        }
    }

    private static func windowTitle(kind: MailComposeKind, subject: String, attribution: String) -> String {
        let key: String
        switch kind {
        case .new: key = "mail.compose.title"
        case .reply: key = "mail.compose.title.reply"
        case .forward: key = "mail.compose.title.forward"
        }
        let title = L.string(key)
        return subject.isEmpty ? "\(title) — \(attribution)" : "\(title): \(subject)"
    }

    // MARK: - Maximize

    /// 最大化：铺满当前屏幕可用区域（保留菜单栏与 Dock）；再次点击还原。
    func toggleMaximize(_ window: NSWindow) {
        guard let entry = frames[ObjectIdentifier(window)] else {
            window.zoom(nil)
            return
        }
        if let restore = entry.restoreFrame {
            window.setFrame(restore, display: true, animate: true)
            entry.restoreFrame = nil
        } else {
            entry.restoreFrame = window.frame
            let screen = window.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrame(visible, display: true, animate: true)
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = frames[ObjectIdentifier(sender)] else { return true }
        guard !entry.isClosing, !entry.isDeciding else { return false }
        entry.isDeciding = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let action = await entry.viewModel.prepareForClose()
            entry.isDeciding = false
            switch action {
            case .closeNow:
                self.close(entry)
            case .ask:
                self.presentCloseConfirmation(entry)
            }
        }
        return false
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = frames[ObjectIdentifier(window)] else { return }
        // 最大化状态下跟随新屏幕；否则确保窗口仍在可见范围内
        if entry.restoreFrame != nil, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrame(visible, display: true)
        } else if !hasVisibleFrame(window) {
            window.center()
        }
    }

    // MARK: - Close

    private func presentCloseConfirmation(_ entry: Entry) {
        let alert = NSAlert()
        alert.messageText = L.string("product.mail.unsaved")
        alert.informativeText = entry.viewModel.discardNote
        alert.addButton(withTitle: L.string("product.mail.saveClose"))
        alert.addButton(withTitle: L.string("product.mail.discard"))
        alert.addButton(withTitle: L.string("common.cancel"))
        let window = entry.window
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    if await entry.viewModel.saveAndClose() {
                        self.close(entry)
                    }
                    // 保存失败：保持窗口，原因已由视图模型内联展示
                case .alertSecondButtonReturn:
                    self.close(entry)
                default:
                    break
                }
            }
        }
    }

    /// 真正关闭窗口并释放登记（`close()` 不经过 `windowShouldClose`，不会再次询问）。
    private func close(_ entry: Entry) {
        entry.isClosing = true
        entries.removeValue(forKey: entry.key)
        frames.removeValue(forKey: ObjectIdentifier(entry.window))
        entry.viewModel.onWindowClosed()
        entry.window.delegate = nil
        entry.window.close()
    }

    // MARK: - Helpers

    private func hasVisibleFrame(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
    }
}
