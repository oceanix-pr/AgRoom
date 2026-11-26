import SwiftUI
import AppKit
import WebKit
import AgRoomCore
import Combine

// MARK: - WebView Representable

struct WebViewRepresentable: NSViewRepresentable {
    let tab: BrowserTabModel

    func makeNSView(context: Context) -> WKWebView {
        tab.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

enum BrowserKnowledgeSaveResult {
    case saved(KnowledgeItem)
    case empty
    case discarded
}

/// Keep extraction and its eventual write in the space and tab that started the action.
@MainActor
enum BrowserKnowledgeSaveOperation {
    static func run(
        originSpace: AppSpace,
        source: String,
        isCurrent: () -> Bool,
        title: () async -> String,
        body: () async -> String,
        service: (AppSpace) -> KnowledgeService?
    ) async throws -> BrowserKnowledgeSaveResult {
        guard isCurrent(), !Task.isCancelled else { return .discarded }
        let pageTitle = await title()
        guard isCurrent(), !Task.isCancelled else { return .discarded }
        let bodyText = await body()
        guard isCurrent(), !Task.isCancelled else { return .discarded }
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }

        let item = KnowledgeItem(
            title: pageTitle.isEmpty ? L.string("browser.untitled") : String(pageTitle.prefix(120)),
            content: "Source: \(source)\n\n" + bodyText,
            kind: .document,
            tags: ["web"]
        )
        guard let knowledge = service(originSpace) else { throw SpaceSearchError.unavailable }
        try await knowledge.save(item)
        return .saved(item)
    }
}

// MARK: - Browser View

/// 内置浏览器：多标签、持久化存储（登录态跨启动保留）、HTTP 警示、正文一键存为知识条目。
/// 标签管理在 BrowserService：与调度 Agent 浏览器工具共用同一批标签与登录会话
public struct BrowserView: View {
    let hub: Hub
    private let space: AppSpace

    /// 当前空间的浏览器服务（标签与登录态按空间隔离；空间切换时本视图按 .id 重建）
    @ObservedObject private var service: BrowserService
    @State private var tabObservation: AnyCancellable?
    @State private var tabRevision = 0
    @State private var extractMessage: String?
    @State private var saveTask: Task<Void, Never>?

    public init(hub: Hub) {
        let space = hub.spaceStore.current
        self.hub = hub
        self.space = space
        _service = ObservedObject(wrappedValue: BrowserService.forSpace(space))
    }

    private var activeTab: BrowserTabModel? {
        service.activeTab
    }

    public var body: some View {
        let _ = tabRevision
        VStack(spacing: 0) {
            tabBar
            Divider()
            navigationBar
            if let tab = activeTab, tab.currentScheme == "http" {
                httpWarning
            }
            if let message = extractMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
            if let tab = activeTab {
                WebViewRepresentable(tab: tab)
                    // 切换标签必须换视图身份：makeNSView 每身份只调一次，
                    // 不加 .id 会一直显示旧标签的 WKWebView
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L.string("browser.empty"),
                    systemImage: "globe",
                    description: Text(L.string("browser.empty.desc"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footerNote
        }
        .onAppear {
            if service.tabs.isEmpty {
                _ = service.addTab()
            }
        }
        .onReceive(service.$tabs) { tabs in
            tabObservation = Publishers.MergeMany(tabs.map { $0.objectWillChange }).sink {
                Task { @MainActor in tabRevision &+= 1 }
            }
        }
        .onDisappear { saveTask?.cancel(); tabObservation = nil }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(service.tabs) { tab in
                        tabChip(tab)
                            .modifier(BrowserSleepAction(service: service, tab: tab))
                    }
                    SleepingTabButtons(service: service)
                }
            }
            Button(action: { _ = service.addTab() }) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(L.string("browser.new_tab"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func tabChip(_ tab: BrowserTabModel) -> some View {
        let isActive = tab.id == service.activeTabId
        return HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            }
            Text(tab.title.isEmpty ? L.string("browser.new_tab") : tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: { service.closeTab(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { service.activeTabId = tab.id }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button(action: { activeTab?.webView.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(activeTab?.canGoBack != true)

            Button(action: { activeTab?.webView.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(activeTab?.canGoForward != true)

            Button(action: {
                guard let tab = activeTab else { return }
                if tab.isLoading {
                    tab.webView.stopLoading()
                } else {
                    tab.webView.reload()
                }
            }) {
                Image(systemName: activeTab?.isLoading == true ? "xmark" : "arrow.clockwise")
            }
            .disabled(activeTab == nil)

            addressField
            Toggle(isOn: $service.followsAgent) {
                Image(systemName: "cursorarrow.rays")
            }
            .toggleStyle(.button)
            .help(L.string("browser.follow_agent"))

            // 自适应缩放：按页面内容宽度缩放到当前视口（老系统固定宽页面专用）
            Button(action: { activeTab?.fitToWidth() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(activeTab == nil)
            .help(L.string("browser.zoom_fit.help"))

            // 兼容模式（IE11 UA）：老系统专用，开启后域名记忆；现代站点勿开（会白屏）
            Button(action: { activeTab?.toggleLegacyMode() }) {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundColor(activeTab?.isLegacyMode == true ? .orange : .secondary)
            }
            .disabled(activeTab == nil)
            .help(L.string("browser.legacy_mode.help"))

            Button(action: savePageAsKnowledge) {
                Label(L.string("browser.save_knowledge"), systemImage: "square.and.arrow.down")
            }
            .disabled(activeTab == nil || saveTask != nil)
            .help(L.string("browser.save_knowledge.help"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var addressField: some View {
        Group {
            if let tab = activeTab {
                TextField("https://...", text: Binding(
                    get: { tab.urlText },
                    set: { tab.urlText = $0 }
                )) {
                    tab.load(tab.urlText)
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            } else {
                TextField("https://...", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
            }
        }
    }

    private var httpWarning: some View {
        Label(L.string("browser.http_warning"), systemImage: "lock.open")
            .font(.caption)
            .foregroundColor(.orange)
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }

    private var footerNote: some View {
        Text(L.format("browser.storage_note", L.dispatcherName()))
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }

    // MARK: - Actions

    /// 抽取当前页正文（document.body.innerText）存为知识条目
    private func savePageAsKnowledge() {
        guard let tab = activeTab, saveTask == nil else { return }
        let originSpace = space
        let originURL = tab.webView.url?.absoluteString ?? tab.urlText
        extractMessage = nil
        tab.operationCount += 1
        saveTask = Task {
            defer { tab.operationCount -= 1; saveTask = nil }
            do {
                let result = try await BrowserKnowledgeSaveOperation.run(
                    originSpace: originSpace,
                    source: originURL,
                    isCurrent: {
                        hub.spaceStore.current == originSpace &&
                        service.activeTabId == tab.id &&
                        (tab.webView.url?.absoluteString ?? tab.urlText) == originURL
                    },
                    title: { await evaluateString(tab, script: "document.title") ?? tab.title },
                    body: { await evaluateString(tab, script: "document.body.innerText") ?? "" },
                    service: { hub.makeKnowledgeService(for: $0) }
                )
                switch result {
                case .saved(let item):
                    extractMessage = L.string("browser.saved") + " · \(item.title)"
                case .empty:
                    extractMessage = L.string("browser.extract_empty")
                case .discarded:
                    break
                }
            } catch is CancellationError {
                // Leaving the tab or space cancels the in-flight extraction.
            } catch {
                extractMessage = L.errorDescription(error)
            }
        }
    }

    /// 执行 JS 并取字符串结果（主线程安全桥接）
    private func evaluateString(_ tab: BrowserTabModel, script: String) async -> String? {
        await withCheckedContinuation { continuation in
            tab.webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }
}


struct BrowserSleepAction: ViewModifier {
    @ObservedObject var service: BrowserService
    let tab: BrowserTabModel
    @State private var request: BrowserService.SleepRequest?

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(L.string("browser.sleep")) { request = service.sleepRequest(for: tab) }
                .disabled(service.sleepRequest(for: tab) == nil)
        }
        .alert(L.string("browser.sleep"), isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
               presenting: request) { candidate in
            Button(L.string("browser.sleep"), role: .destructive) { service.sleep(candidate) }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { _ in Text(L.string("browser.sleep.warning")) }
    }
}

struct SleepingTabButtons: View {
    @ObservedObject var service: BrowserService

    var body: some View {
        ForEach(service.sleepingTabs) { tab in
            Button { service.wake(tab.id) } label: {
                Label(tab.title.isEmpty ? tab.url.host ?? tab.url.absoluteString : tab.title, systemImage: "moon.zzz")
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(L.string("browser.wake"))
            .contextMenu {
                Button(L.string("browser.wake")) { service.wake(tab.id) }
                Button(L.string("common.close")) { service.closeSleepingTab(tab.id) }
            }
        }
    }
}
