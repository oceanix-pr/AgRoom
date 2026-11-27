import AppKit
import Observation
import SwiftUI
import Testing
@testable import AgRoomUI

/// 原生宿主的滚动集成验证：构造长短消息混排、异步正文增高 / 收缩和可变视口的列表，
/// 检查追加消息与布局变化后跟随模式仍能把底部锚点稳定收敛到视口底部。
@MainActor
@Suite("Chat scroll host integration")
struct ChatScrollHostTests {
    @Test("追加消息后跟随到底部锚点")
    func appendedMessagesConvergeToBottom() async throws {
        let model = ChatScrollProbeModel()
        let hosting = NSHostingView(rootView: ChatScrollProbeView(model: model))
        let window = makeWindow(hosting: hosting)
        defer { window.close() }

        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.distanceFromBottom ?? .greatestFiniteMagnitude) <= 2
        }
        assertBottomMessageVisible(model)

        // 追加一批长短不一的消息：内容高度变化后仍应回到锚点附近
        model.items.append(contentsOf: Array(4...12))
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            model.snapshot.lastItemID == model.items.last
                && (model.distanceFromBottom ?? .greatestFiniteMagnitude) <= 2
        }
        assertBottomMessageVisible(model)
    }

    @Test("异步正文增高、高度收缩与视口变化后保持底部")
    func asyncLayoutChangesStayAtBottom() async throws {
        let model = ChatScrollProbeModel()
        model.items = Array(1...14)
        let hosting = NSHostingView(rootView: ChatScrollProbeView(model: model))
        let window = makeWindow(hosting: hosting)
        defer { window.close() }

        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.distanceFromBottom ?? .greatestFiniteMagnitude) <= 2
        }
        assertBottomMessageVisible(model)
        let initialContentHeight = model.snapshot.contentHeight ?? 0
        let initialViewportHeight = try #require(model.snapshot.viewportHeight)

        // 模拟 Markdown 在首轮排版后异步解码出一大段正文：高度增长后仍应贴底
        model.detailHeight = 360
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.snapshot.contentHeight ?? 0) >= initialContentHeight + 300
        }
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.distanceFromBottom ?? .greatestFiniteMagnitude) <= 2
        }
        assertBottomMessageVisible(model)

        // 模拟正文转入折叠思考区：高度骤降后偏移可能越过新底部，必须重新贴底，
        // 不能在最后一条消息下方残留空白
        model.detailHeight = 0
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.snapshot.contentHeight ?? .greatestFiniteMagnitude) <= initialContentHeight + 2
        }
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.snapshot.rawDistanceFromBottom ?? -CGFloat.greatestFiniteMagnitude) >= -2
                && (model.distanceFromBottom ?? .greatestFiniteMagnitude) <= 2
        }
        assertBottomMessageVisible(model)

        // 输入框展开 / 确认卡出现会收缩视口；跟随状态应按新视口重新贴底
        window.setContentSize(NSSize(width: 360, height: 300))
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            abs((model.snapshot.viewportHeight ?? .infinity) - (initialViewportHeight - 120)) <= 2
        }
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.distanceFromBottom ?? .greatestFiniteMagnitude) <= 2
        }
        assertBottomMessageVisible(model)

        // 视口恢复后同样保持底部
        window.setContentSize(NSSize(width: 360, height: 460))
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            abs((model.snapshot.viewportHeight ?? .infinity) - (initialViewportHeight + 40)) <= 2
        }
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.distanceFromBottom ?? .greatestFiniteMagnitude) <= 2
        }
        assertBottomMessageVisible(model)
    }

    @Test("Scrolling up during a Markdown stream preserves the reading position through final layout")
    func readingEarlierMessageDuringStream() async throws {
        let model = ChatScrollProbeModel()
        model.items = Array(1...18)
        model.markdown = "[reference][late]\n\n```swift\n" + (1...16).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let hosting = NSHostingView(rootView: ChatScrollProbeView(model: model))
        let window = makeWindow(hosting: hosting)
        defer { window.close() }
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            model.renderer.segments.contains { if case .codeBlock = $0 { true } else { false } }
                && (model.distanceFromBottom ?? .infinity) <= 2
        }
        model.readerTarget = 14
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            model.snapshot.paused && model.snapshot.readerFrame != nil
        }
        let position = try #require(model.snapshot.readerFrame?.minY)
        model.markdown += "\n```\n\n![fixture](late.png)\n\n[late]: https://example.invalid/source"
        model.streaming = false
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            model.renderer.resources.count == 1 && model.renderer.segments.contains {
                if case .prose(let prose) = $0 {
                    return prose.attributedString.length > 0 && prose.attributedString.attribute(.link, at: 0, effectiveRange: nil) != nil
                }
                return false
            }
        }
        let finalPosition = try #require(model.snapshot.readerFrame?.minY)
        #expect(abs(finalPosition - position) <= 2)
        #expect(model.snapshot.paused && (model.distanceFromBottom ?? 0) > ChatScrollState.pauseDistance)
    }

    private func makeWindow(hosting: NSHostingView<ChatScrollProbeView>) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // 与现有原生宿主测试保持一致：不激活应用、不把窗口提到前台，
        // 只用离屏布局驱动 SwiftUI 更新（前台窗口会让后续子进程测试不稳定）
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        return window
    }

    /// 跟随模式下最后一条消息应紧贴视口底部（内容底部 padding 约 16pt），
    /// 而不是停在视口上方留下空白。
    private func assertBottomMessageVisible(
        _ model: ChatScrollProbeModel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let last = model.snapshot.lastItemFrame,
              let viewport = model.snapshot.viewportFrame else {
            Issue.record("未收到最后一条消息或视口的实际布局", sourceLocation: sourceLocation)
            return
        }
        #expect(
            last.intersects(viewport),
            "最后一条消息与视口不相交：message=\(last) viewport=\(viewport)",
            sourceLocation: sourceLocation
        )
        let gap = viewport.maxY - last.maxY
        #expect(
            gap >= -2 && gap <= 32,
            "最后一条消息距视口底部 \(gap)pt，未贴底",
            sourceLocation: sourceLocation
        )
    }

    private func waitUntil(
        host: NSHostingView<ChatScrollProbeView>,
        window: NSWindow,
        timeout: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = host.rootView.model.snapshot
        try #require(condition(), "等待滚动收敛超时，内容高度 \(snapshot.contentHeight ?? -1)，视口高度 \(snapshot.viewportHeight ?? -1)，距底部 \(snapshot.rawDistanceFromBottom ?? .nan)", sourceLocation: sourceLocation)
    }
}

@MainActor
@Observable
final class ChatScrollProbeModel {
    let sessionID = UUID()
    var items: [Int] = [1, 2, 3]
    /// 最后一条消息在首轮排版后异步长出的正文高度（模拟 Markdown / 图片解析完成）
    var detailHeight: CGFloat = 0
    var distanceFromBottom: CGFloat?
    var readerTarget: Int?
    var markdown = ""
    var streaming = true
    let renderer = MarkdownRenderModel(resourceLoader: { _, _, _ in
        MarkdownRenderedResource(image: NSImage(size: .init(width: 64, height: 48)), pixelCount: 64 * 48)
    })
    /// 几何回调只写非观察态，避免布局期间写观察态触发约束循环
    @ObservationIgnored let snapshot = ChatScrollProbeSnapshot()
}

@MainActor
final class ChatScrollProbeSnapshot {
    var paused = false
    var readerFrame: CGRect?
    var lastItemID: Int?
    var lastItemFrame: CGRect?
    var viewportFrame: CGRect?
    var contentHeight: CGFloat?
    var viewportHeight: CGFloat?
    var rawDistanceFromBottom: CGFloat?
}

private struct ChatScrollProbeView: View {
    let model: ChatScrollProbeModel
    @State private var scrollState = ChatScrollState()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.items, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message \(item) " + String(repeating: "content ", count: (item % 7) * 4 + 4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if item == model.items.last, model.detailHeight > 0 {
                                Text("Late markdown body")
                                    .frame(maxWidth: .infinity, minHeight: model.detailHeight, alignment: .topLeading)
                                    .background(Color.gray.opacity(0.08))
                            }
                            if item == model.items.last, !model.markdown.isEmpty {
                                MarkdownView(text: model.markdown, streaming: model.streaming, documentID: "reply", model: model.renderer)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.gray.opacity(0.12))
                        .id(item)
                        .onGeometryChange(for: CGRect.self) { geometry in
                            geometry.frame(in: .global)
                        } action: { frame in
                            if item == model.readerTarget { model.snapshot.readerFrame = frame }
                            guard item == model.items.last else { return }
                            model.snapshot.lastItemID = item
                            model.snapshot.lastItemFrame = frame
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .padding(.bottom)
                        .id(ChatScrollState.bottomAnchorID)
                }
                .padding([.horizontal, .top])
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { frame in
                model.snapshot.viewportFrame = frame
            }
            .onAppear {
                scrollState.bindSession(model.sessionID, reset: true)
                scrollState.request(.layoutCorrection)
                scheduleFlush(proxy: proxy)
            }
            .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
                ChatScrollGeometry(
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height,
                    offsetY: geometry.contentOffset.y,
                    insetBottom: geometry.contentInsets.bottom
                )
            } action: { _, newValue in
                model.distanceFromBottom = newValue.distanceFromBottom
                model.snapshot.contentHeight = newValue.contentHeight
                model.snapshot.viewportHeight = newValue.viewportHeight
                model.snapshot.rawDistanceFromBottom = newValue.rawDistanceFromBottom
                let flush = scrollState.ingest(newValue)
                model.snapshot.paused = !scrollState.isFollowingBottom
                if model.snapshot.paused && scrollState.isUserInteracting { scrollState.endUserInteraction() }
                guard flush else { return }
                scheduleFlush(proxy: proxy)
            }
            .onChange(of: model.readerTarget) { _, item in
                guard let item else { return }
                scrollState.beginUserInteraction()
                proxy.scrollTo(item, anchor: .top)
            }
            .onChange(of: model.items.count) { _, _ in
                guard scrollState.isFollowingBottom else { return }
                scrollState.request(.newMessage)
                scheduleFlush(proxy: proxy)
            }
        }
    }

    private func scheduleFlush(proxy: ScrollViewProxy) {
        guard scrollState.beginFlush() else { return }
        let generation = scrollState.generation
        Task { @MainActor in
            scrollState.endFlush()
            guard scrollState.isCurrent(sessionID: model.sessionID, generation: generation) else { return }
            guard let request = scrollState.takePendingRequest(),
                  scrollState.canExecute(request) else { return }
            if request.isAnimated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(ChatScrollState.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(ChatScrollState.bottomAnchorID, anchor: .bottom)
            }
        }
    }
}
