import Foundation
import GRDB
import Observation
import Testing
import SwiftUI
import AppKit
@testable import AgRoomCore
@testable import AgRoomUI

/// 帮助页与菜单跳转：跨层跳转通道、导航项与三语文案覆盖
@Suite("App navigation and help")
@MainActor
struct AppNavigationTests {
    @Test("Composer slash suggestions never reinterpret ordinary message text")
    func composerSlashQueries() {
        let titles: [AppMenuCommand: String] = [
            .newChat: "New chat",
            .search: "Search",
            .taskCenter: "任务中心",
            .artifactLibrary: "Artifact library"
        ]
        let title: (AppMenuCommand) -> String = { titles[$0] ?? "" }
        #expect(ComposerSlashCommandSuggestions.matches("/", title: title)
            == [.newChat, .search, .taskCenter, .artifactLibrary])
        #expect(ComposerSlashCommandSuggestions.matches("/new", title: title) == [.newChat])
        #expect(ComposerSlashCommandSuggestions.matches("/任务", title: title) == [.taskCenter])
        for ordinaryText in ["Please use /search", "https://example.com/a", "/search more", "/search\nmore"] {
            #expect(ComposerSlashCommandSuggestions.matches(ordinaryText, title: title).isEmpty)
        }
    }

    @Test("未挂载空间来源时跳转被挂起，挂载后补发且只发一次")
    func pendingRouteIsDeliveredOnce() async throws {
        let navigation = AppNavigation()
        var received: [ProductRoute] = []
        let token = NotificationCenter.default.addObserver(
            forName: ProductRoute.notification, object: nil, queue: nil
        ) { notification in
            if let route = notification.object as? ProductRoute { received.append(route) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // 空间来源未注册：窗口未挂载，通知没有订阅者，路由必须保留
        navigation.open(page: .help)
        #expect(received.isEmpty)

        navigation.deliverPendingIfNeeded(space: .work)
        #expect(received.count == 1)
        let route = try #require(received.first)
        #expect(route.page == HubNavItem.help.rawValue)
        #expect(route.space == .work)

        // 已补发：重复挂载不再重放（否则每次切页都会被拽回帮助页）
        navigation.deliverPendingIfNeeded(space: .work)
        #expect(received.count == 1)
    }

    @Test("跳转被消费后清除挂起状态，重复点击不会留下多余路由")
    func deliveredRouteIsCleared() async throws {
        let navigation = AppNavigation()
        var received: [ProductRoute] = []
        let token = NotificationCenter.default.addObserver(
            forName: ProductRoute.notification, object: nil, queue: nil
        ) { notification in
            if let route = notification.object as? ProductRoute { received.append(route) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        navigation.open(page: .settings)
        navigation.deliverPendingIfNeeded(space: .personal)
        let route = try #require(received.first)
        navigation.markDelivered(route)

        // 挂起已清除：窗口重新挂载时不应再次切到设置页
        navigation.deliverPendingIfNeeded(space: .personal)
        #expect(received.count == 1)
    }

    @Test("帮助页是侧栏可见的独立导航项")
    func helpNavItem() async throws {
        #expect(HubNavItem.help.rawValue == "help")
        #expect(HubNavItem.help.labelKey == "nav.help")
        #expect(HubNavItem.help.isVisibleInSidebar)
        #expect(HubNavItem.allCases.contains(.help))
    }

    @Test("三语资源都提供 nav.help 与全部 help.* 文案")
    func helpLocalizationCoverage() throws {
        let resources = Self.resourcesDirectory
        let expected = Self.helpKeys
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let url = resources.appendingPathComponent("\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: url, encoding: .utf8)
            let keys = Self.keys(in: contents)
            #expect(keys.contains("nav.help"), "\(language) 缺少 nav.help")
            for key in expected {
                #expect(keys.contains(key), "\(language) 缺少 \(key)")
            }
        }
    }

    @Test("Help categories render independently in all three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_HELP_SNAPSHOT_DIR"] != nil))
    func helpCategoryRendering() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGROOM_HELP_SNAPSHOT_DIR"])
        let oldLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = oldLanguage }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for category in HelpCategory.allCases {
                let dark = category == .privacy || category == .shortcuts
                let width = language == .english ? 1000.0 : 900.0
                let host = NSHostingView(rootView: HelpContentView(initialCategory: category, onOpen: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 950),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(70))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("help-\(category.rawValue)-\(language.rawValue).png"))
            }
        }
    }

    // MARK: - 资源定位

    /// 从测试文件位置回溯到 `Sources/AgRoomUI/Resources`
    private static var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgRoomCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AgRoom
            .appendingPathComponent("Sources/AgRoomUI/Resources")
    }

    /// 帮助页用到的全部文案键（与 HelpView 一一对应）
    private static var helpKeys: [String] {
        var keys = [
            "nav.help", "help.open_settings", "help.categories",
            "help.quickstart", "help.tour", "help.shortcuts", "help.privacy", "help.faq"
        ]
        for index in 1...4 {
            keys.append("help.quickstart.\(index).title")
            keys.append("help.quickstart.\(index).desc")
        }
        for page in HubNavItem.allCases where page.isVisibleInSidebar && page != .help {
            keys.append("help.tour.\(page.rawValue)")
        }
        keys += [
            "help.shortcut.settings", "help.shortcut.sidebar", "help.shortcut.newchat",
            "help.shortcut.hotkey", "help.shortcut.save", "help.shortcut.files"
        ]
        keys += [
            "help.privacy.local", "help.privacy.spaces",
            "help.privacy.keychain", "help.privacy.endpoint"
        ]
        for name in ["model", "files", "skills", "data"] {
            keys.append("help.faq.\(name).title")
            keys.append("help.faq.\(name).desc")
        }
        return keys
    }

    /// 取出 `.strings` 中的键名（忽略注释与空行）
    private static func keys(in contents: String) -> Set<String> {
        var result: Set<String> = []
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let end = trimmed.range(of: "\" =") else { continue }
            result.insert(String(trimmed[trimmed.index(after: trimmed.startIndex)..<end.lowerBound]))
        }
        return result
    }
}

@Suite("Sidebar navigation host", .serialized)
@MainActor
struct SidebarNavigationHostTests {
    @Test("Sidebar preference restores both collapsed and expanded states after recreation")
    func sidebarPreferenceSurvivesRecreation() throws {
        let suite = "SidebarNavigationHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = AppStorage(wrappedValue: false, SidebarVisibilityPreference.collapsedKey, store: defaults)
        let visibility = SidebarVisibilityPreference.binding(preference.projectedValue)
        #expect(visibility.wrappedValue == .all)
        #expect(defaults.object(forKey: SidebarVisibilityPreference.collapsedKey) == nil)

        for expected in [NavigationSplitViewVisibility.detailOnly, .all] {
            SidebarVisibilityAction.toggle(visibility)
            let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
            let reopenedPreference = AppStorage(wrappedValue: false, SidebarVisibilityPreference.collapsedKey, store: reopenedDefaults)
            let reopenedVisibility = SidebarVisibilityPreference.binding(reopenedPreference.projectedValue)
            #expect(reopenedVisibility.wrappedValue == expected)
            #expect(reopenedDefaults.bool(forKey: SidebarVisibilityPreference.collapsedKey) == (expected == .detailOnly))
            reopenedVisibility.wrappedValue = .automatic
            #expect(reopenedVisibility.wrappedValue == expected)
        }
    }

    @Observable final class State {
        var visibility: NavigationSplitViewVisibility = .all
        var selection: HubNavItem = .chat
    }

    private final class Views {
        var detail: NSTextField?
        var rail: NSView?
        var detailBuilds = 0
    }

    private struct DetailField: NSViewRepresentable {
        let views: Views
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(string: "Unsent draft")
            views.detail = field
            views.detailBuilds += 1
            return field
        }
        func updateNSView(_ nsView: NSTextField, context: Context) {}
    }

    private struct RailMarker: NSViewRepresentable {
        let views: Views
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            views.rail = view
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private struct ResizableColumns: View {
        @State private var width = 340.0
        let key: String
        let direction: Double
        let views: Views

        var body: some View {
            HStack(spacing: 0) {
                Color.clear.frame(width: direction > 0 ? width : nil)
                SplitDivider(columnWidth: $width, range: 260...460, persistKey: key, direction: direction)
                RailMarker(views: views)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: direction < 0 ? width : nil)
            }
        }
    }

    private final class DividerTestHost<Content: View>: NSHostingView<Content> {
        // Deliver the test's mouse-down even when another app is in front.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func sendDividerEvent(_ type: NSEvent.EventType, x: CGFloat, to window: NSWindow) async throws {
        let time = ProcessInfo.processInfo.systemUptime
        let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 80),
            modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil,
            eventNumber: Int(time * 1000), clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(24))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @Test("A moving divider tracks the pointer and saves the release position", arguments: [1.0, -1.0])
    func dividerTracksPointer(direction: Double) async throws {
        let key = "SplitDividerTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let views = Views()
        let host = DividerTestHost(rootView: ResizableColumns(key: key, direction: direction, views: views))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(window, phase: { "split layout" }) { (views.rail?.frame.width ?? 0) > 0 }
        let rightPane = try #require(views.rail)
        func dividerX() -> CGFloat { rightPane.convert(.zero, to: nil).x - SplitWidths.dividerWidth / 2 }
        let startX = dividerX()
        func send(_ type: NSEvent.EventType, offset: CGFloat) async throws {
            // Start inside the wider hit area, just beside the painted line.
            try await sendDividerEvent(type, x: startX + 2 + offset, to: window)
        }

        try await send(.mouseMoved, offset: 0)
        try await send(.leftMouseDown, offset: 0)
        for offset in [1.0, 16, 32, 32, 180, -160, 70, 70] {
            try await send(.leftMouseDragged, offset: offset)
            let expectedWidth = min(max(340 + offset * direction, 260), 460)
            #expect(abs(dividerX() - (startX + (expectedWidth - 340) * direction)) < 0.5)
            #expect(UserDefaults.standard.object(forKey: key) == nil)
        }
        // The mouse may move between the last drag callback and the release.
        try await send(.leftMouseUp, offset: 75)
        #expect(abs(dividerX() - (startX + 75)) < 0.5)
        #expect(SplitColumnWidth.snapshot(key: key, defaultValue: 340, range: 260...460) == 340 + 75 * direction)
    }

    private struct ChatColumnsHost: View {
        @State private var sessionWidth = 220.0
        @State private var panelWidth = 300.0
        let key: String
        let docked: Bool
        let views: Views
        private let markdown = String(repeating: "A long answer wraps across the conversation pane. ", count: 180)
            + "\n\n| Model | Estimate |\n| --- | ---: |\n| Example | 1.50 |"

        var body: some View {
            ChatSplitLayout(sessionWidth: $sessionWidth, panelWidth: $panelWidth, sessionWidthKey: key,
                            panelWidthKey: key + ".panel", panelMode: docked ? .docked : .closed) {
                RailMarker(views: views).frame(maxWidth: .infinity, maxHeight: .infinity)
            } conversation: {
                VStack(spacing: 0) {
                    ScrollView { MarkdownView(text: markdown, documentID: "divider") }
                        .modifier(ChatTranscriptViewport())
                    DetailField(views: views).frame(height: 28)
                }
            } panel: {
                Color.clear
            }
        }
    }

    @Test("Chat columns track the drag while long Markdown keeps its width until release", arguments: [false, true])
    func chatDefersTranscriptReflow(docked: Bool) async throws {
        let key = "ChatSplitLayoutTests.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let views = Views()
        let host = DividerTestHost(rootView: ChatColumnsHost(key: key, docked: docked, views: views))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func prose(in view: NSView) -> SelectableTextView? {
            if let text = view as? SelectableTextView, text.string.hasPrefix("A long answer") { return text }
            for child in view.subviews {
                if let found = prose(in: child) { return found }
            }
            return nil
        }
        try await settle(window, phase: { "chat Markdown" }) { (prose(in: host)?.bounds.width ?? 0) > 200 }
        let text = try #require(prose(in: host)), sidebar = try #require(views.rail), draft = try #require(views.detail)
        let initialWidth = text.bounds.width
        let composerWidth = draft.bounds.width
        let startX = sidebar.convert(NSPoint(x: sidebar.bounds.maxX, y: 0), to: nil).x + SplitWidths.dividerWidth / 2
        try await sendDividerEvent(.mouseMoved, x: startX, to: window)
        try await sendDividerEvent(.leftMouseDown, x: startX, to: window)
        for offset: CGFloat in [8, 24, 48, 96, 32, -20, 54] {
            try await sendDividerEvent(.leftMouseDragged, x: startX + offset, to: window)
            #expect(abs(sidebar.bounds.width - (220 + offset)) < 1)
            #expect(abs(draft.bounds.width - (composerWidth - offset)) < 1)
            #expect(text.bounds.width == initialWidth)
            #expect(UserDefaults.standard.object(forKey: key) == nil)
        }
        try await sendDividerEvent(.leftMouseUp, x: startX + 62, to: window)
        #expect(abs(text.bounds.width - (initialWidth - 62)) < 1)
        #expect(UserDefaults.standard.double(forKey: key) == 282)
        #expect(prose(in: host) === text && views.detail === draft && draft.stringValue == "Unsent draft")
    }

    @Test("A saved divider position retains subpoint adjustments")
    func dividerRestoresFractionalWidth() {
        let key = "SplitDividerTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        SplitColumnWidth.persist(340, key: key, range: 260...460)
        SplitColumnWidth.persist(340.5, key: key, range: 260...460)
        #expect(SplitColumnWidth.snapshot(key: key, defaultValue: 340, range: 260...460) == 340.5)
    }

    private struct Host: View {
        let state: State
        let views: Views
        let store: SpaceStore
        var reduceMotion = false

        var body: some View {
            SidebarNavigationLayout(
                columnVisibility: Binding(get: { state.visibility }, set: { state.visibility = $0 }),
                sidebarWidths: (140, 160, 220),
                reduceMotion: reduceMotion
            ) {
                VStack { SpaceSwitcher(spaceStore: store); Text("Expanded navigation"); Spacer() }
            } compactSidebar: {
                CompactSidebar(spaceStore: store, selection: state.selection, pendingTeamApprovals: 12) { state.selection = $0 }
                    .background(RailMarker(views: views))
            } detail: {
                DetailField(views: views).padding(16)
            }
            .frame(minWidth: 1120, minHeight: 640)
        }
    }

    @Test("Sidebar transitions continuously while retaining detail, draft and toolbar", arguments: [false, true])
    func toolbarCollapsePreservesNavigationAndDetail(reduceMotion: Bool) async throws {
        let state = State(), views = Views()
        let store = SpaceStore(space: .work, databaseQueue: try DatabaseQueue())
        let host = NSHostingController(rootView: Host(state: state, views: views, store: store, reduceMotion: reduceMotion))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.close() }
        // SwiftUI installs its toolbar items only after the window is ordered.
        window.makeKeyAndOrderFront(nil)

        try await settle(window, phase: { "initial layout" }) { views.detail != nil && views.rail != nil }
        let detail = try #require(views.detail)
        let rail = try #require(views.rail)
        try expectSingleSidebarButton(in: window)
        let sidebarButton = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue.contains("sidebar.visibility")
        })
        detail.stringValue = "Keep this unsent draft"
        let initialExpandedX = detail.convert(detail.bounds, to: host.view).minX

        // The NSHostingController test host does not expose SwiftUI's virtual
        // toolbar Button as an NSButton/AX action. Verify it is installed, then
        // invoke the exact action shared by that Button and the menu command.
        for width in [1120.0, 1600.0] {
            window.setContentSize(NSSize(width: width, height: 640))
            window.contentView?.layoutSubtreeIfNeeded()
            let expandedX = detail.convert(detail.bounds, to: host.view).minX
            try triggerSidebarVisibilityAction(in: window, state: state)
            let collapse = try await transitionPositions(in: window, detail: detail, relativeTo: host.view, startingAt: expandedX)
            let collapsedX = try #require(collapse.last)
            #expect(abs(expandedX - collapsedX - 96) < 1)
            expectContinuousTransition(collapse, reduceMotion: reduceMotion)
            #expect(state.visibility == .detailOnly && rail.bounds.width == 64)
            #expect(views.detail === detail && views.detailBuilds == 1)
            #expect(detail.stringValue == "Keep this unsent draft")
            #expect(window.toolbar?.items.contains(where: { $0 === sidebarButton }) == true,
                "Resizing navigation must not replace the window toolbar button")

            state.selection = .files
            try triggerSidebarVisibilityAction(in: window, state: state)
            let expansion = try await transitionPositions(in: window, detail: detail, relativeTo: host.view, startingAt: collapsedX)
            #expect(abs((expansion.last ?? 0) - expandedX) < 1)
            expectContinuousTransition(expansion, reduceMotion: reduceMotion)
            #expect(state.visibility == .all)
            #expect(views.rail === rail, "Both navigation variants stay mounted during transitions")
            #expect(views.detail === detail && views.detailBuilds == 1)
            #expect(detail.stringValue == "Keep this unsent draft")
            #expect(window.toolbar?.items.contains(where: { $0 === sidebarButton }) == true)
            state.selection = .chat
        }

        for _ in 0..<8 {
            try triggerSidebarVisibilityAction(in: window, state: state)
            try await Task.sleep(for: .milliseconds(16))
        }
        try await settle(window, phase: { "rapid repeated toggles" }) {
            state.visibility == .all && abs(detail.convert(detail.bounds, to: host.view).minX - initialExpandedX) < 1
        }
        #expect(views.detail === detail && views.detailBuilds == 1)
        #expect(detail.stringValue == "Keep this unsent draft")
        #expect(window.toolbar?.items.contains(where: { $0 === sidebarButton }) == true)

    }

    private func transitionPositions(in window: NSWindow, detail: NSView, relativeTo host: NSView,
                                     startingAt origin: CGFloat) async throws -> [CGFloat] {
        var positions = [origin]
        for _ in 0..<30 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            positions.append(detail.convert(detail.bounds, to: host).minX)
            try await Task.sleep(for: .milliseconds(16))
        }
        return positions
    }

    private func expectContinuousTransition(_ positions: [CGFloat], reduceMotion: Bool) {
        guard let start = positions.first, let end = positions.last else { return }
        let lower = min(start, end), upper = max(start, end)
        let intermediate = positions.filter { $0 > lower + 2 && $0 < upper - 2 }
        #expect(reduceMotion ? intermediate.isEmpty : intermediate.count >= 2,
            "Normal motion must have intermediate frames; Reduce Motion must switch directly")
        let direction: CGFloat = end > start ? 1 : -1
        for (previous, current) in zip(positions, positions.dropFirst()) {
            #expect((current - previous) * direction >= -1, "Navigation must not jump backwards")
            #expect(current >= lower - 1 && current <= upper + 1, "Navigation must not overshoot")
        }
    }

    private func triggerSidebarVisibilityAction(in window: NSWindow, state: State) throws {
        try expectSingleSidebarButton(in: window)
        SidebarVisibilityAction.toggle(Binding(get: { state.visibility }, set: { state.visibility = $0 }))
    }

    private func expectSingleSidebarButton(in window: NSWindow) throws {
        let toolbar = try #require(window.toolbar, "Sidebar toolbar was not installed")
        #expect(!toolbar.items.contains(where: { $0.itemIdentifier == .toggleSidebar }),
            "The system sidebar button must not appear beside the custom button")
        let buttons = toolbar.items.filter {
            $0.itemIdentifier.rawValue.contains("sidebar.visibility") || $0.label == L.string("menu.toggle_sidebar")
        }
        #expect(buttons.count == 1, "Expected exactly one custom sidebar button")
    }

    @Test("Compact navigation renders in three languages and both appearances",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_SIDEBAR_SNAPSHOT_DIR"] != nil))
    func compactNavigationRendering() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGROOM_SIDEBAR_SNAPSHOT_DIR"])
        let previousLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previousLanguage }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for dark in [false, true] {
                let store = SpaceStore(space: dark ? .personal : .work, databaseQueue: try DatabaseQueue())
                let content = HStack(spacing: 0) {
                    CompactSidebar(spaceStore: store, selection: dark ? .help : .files, pendingTeamApprovals: 12, onSelect: { _ in })
                        .frame(width: 64)
                    Divider()
                    Text(L.string("nav.files")).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: dark ? 640 : 880),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("sidebar-\(language.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func settle(_ window: NSWindow, phase: () -> String, until condition: () -> Bool) async throws {
        for _ in 0..<150 {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Sidebar layout did not settle: \(phase())")
    }

}
