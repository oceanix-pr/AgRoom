import SwiftUI
import AgRoomCore
import Combine

// MARK: - Chat Browser Panel

/// 对话页右侧面板的浏览器页签：多标签条 + 紧凑导航栏（后退/前进/刷新/地址）+ 网页视图。
/// 与工具执行轨迹页签并列，两者可同时打开，页签切换互不影响。
/// 顶部 Agent 动作条：调度运行中实时显示当前工具调用（浏览网页的同时能看到 Agent 在干什么）
struct ChatBrowserPanel: View {
    /// ChatViewModel 为 @Observable：body 内直接读 liveTrace/isRunningHere 即触发视图更新
    let viewModel: ChatViewModel
    /// 本会话所属空间的浏览器服务（与独立浏览器页各自空间共用标签池）
    @ObservedObject private var service: BrowserService

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _service = ObservedObject(wrappedValue: BrowserService.forSpace(viewModel.space))
    }

    @State private var tabObservation: AnyCancellable?
    @State private var tabRevision = 0

    private var activeTab: BrowserTabModel? { service.activeTab }

    var body: some View {
        let _ = tabRevision
        VStack(spacing: 0) {
            agentActivityBar

            tabBar

            if let tab = activeTab {
                BrowserNavBar(tab: tab, followsAgent: $service.followsAgent)

                if tab.currentScheme == "http" {
                    Label(L.string("browser.http_warning"), systemImage: "lock.open")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }

                Divider()

                WebViewRepresentable(tab: tab)
                    // 切换标签必须换视图身份：makeNSView 每身份只调一次，
                    // 不加 .id 会一直显示旧标签的 WKWebView（Agent 跟随失效的根因）
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
        }
        .onReceive(service.$tabs) { tabs in
            tabObservation = Publishers.MergeMany(tabs.map { $0.objectWillChange }).sink {
                Task { @MainActor in tabRevision &+= 1 }
            }
        }
        .onDisappear { tabObservation = nil }
    }

    // MARK: Agent 动作条（实时同步调度动作）

    /// 调度运行中显示最近一次工具调用（工具名 + 参数预览），
    /// 否则显示最近一条轨迹的完成状态；无轨迹时隐藏
    private var agentActivityBar: some View {
        let trace = viewModel.liveTrace
        let running = viewModel.isRunningHere
        guard !trace.isEmpty else { return AnyView(EmptyView()) }

        let last = trace[trace.count - 1]
        let headline = running
            ? L.format("chat.browser.agent_running", localizedToolName(last.toolName))
            : L.format("chat.browser.agent_done", localizedToolName(last.toolName))
        return AnyView(
            HStack(spacing: 6) {
                if running {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: last.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(last.succeeded ? .green : .red)
                }
                Text(headline)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                if !last.argumentsPreview.isEmpty {
                    Text(last.argumentsPreview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.06))
        )
    }

    /// 工具名展示：智体调用显示昵称（与轨迹 / 参与方徽章同一套规则）
    private func localizedToolName(_ name: String) -> String {
        ChatView.localizedToolName(name, agentDisplayName: { viewModel.agentDisplayName(forToolName: $0) })
    }

    // MARK: Tab Bar（多标签）

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(service.tabs) { tab in
                        chatTabChip(tab)
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
        .padding(.vertical, 5)
    }

    private func chatTabChip(_ tab: BrowserTabModel) -> some View {
        let isActive = tab.id == service.activeTabId
        return HStack(spacing: 4) {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            }
            Text(tab.title.isEmpty ? L.string("browser.new_tab") : tab.title)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: { service.closeTab(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture { service.activeTabId = tab.id }
    }

    // MARK: Navigation Bar

    /// 独立子视图承载地址栏绑定（$tab.urlText 需要 ObservedObject 包装）
    private struct BrowserNavBar: View {
        @ObservedObject var tab: BrowserTabModel
        @Binding var followsAgent: Bool

        var body: some View {
            HStack(spacing: 8) {
                Button(action: { tab.webView.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!tab.canGoBack)

                Button(action: { tab.webView.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!tab.canGoForward)

                Button(action: {
                    if tab.isLoading {
                        tab.webView.stopLoading()
                    } else {
                        tab.webView.reload()
                    }
                }) {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }

                TextField("https://...", text: $tab.urlText) {
                    tab.load(tab.urlText)
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

                Toggle(isOn: $followsAgent) { Image(systemName: "cursorarrow.rays") }
                    .toggleStyle(.button)
                    .help(L.string("browser.follow_agent"))

                // 自适应缩放：按页面内容宽度缩放到当前视口（老系统固定宽页面专用）
                Button(action: { tab.fitToWidth() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help(L.string("browser.zoom_fit.help"))

                // 兼容模式（IE11 UA）：老系统专用，开启后域名记忆；现代站点勿开（会白屏）
                Button(action: { tab.toggleLegacyMode() }) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .foregroundColor(tab.isLegacyMode ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(L.string("browser.legacy_mode.help"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
