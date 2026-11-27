import AppKit
import Observation
import SwiftUI
import Testing
@testable import AgRoomUI

/// 原生宿主的滚动集成验证：构造长短消息混排、异步正文增高 / 收缩和可变视口的列表，
/// 检查追加消息与布局变化后，滚动容器和最后一条可见消息都已到达底部。
@MainActor
@Suite("Chat scroll host integration")
struct ChatScrollHostTests {
    @Test("追加消息后跟随到底部锚点")
    func appendedMessagesConvergeToBottom() async throws {
        let model = ChatScrollProbeModel()
        let hosting = NSHostingView(rootView: ChatScrollProbeView(model: model))
        let window = makeWindow(hosting: hosting)
        defer { window.close() }

        try await waitForBottomMessage(host: hosting, window: window)

        // 追加一批长短不一的消息：内容高度变化后仍应回到锚点附近
        model.items.append(contentsOf: (4...40).map(ChatScrollProbeModel.Item.init(number:)))
        try await waitForBottomMessage(host: hosting, window: window)
    }

    @Test("异步正文增高、高度收缩与视口变化后保持底部")
    func asyncLayoutChangesStayAtBottom() async throws {
        let model = ChatScrollProbeModel()
        model.items = (1...14).map(ChatScrollProbeModel.Item.init(number:))
        let hosting = NSHostingView(rootView: ChatScrollProbeView(model: model))
        let window = makeWindow(hosting: hosting)
        defer { window.close() }

        try await waitForBottomMessage(host: hosting, window: window)
        let initialRowHeight = try #require(model.snapshot.lastItemFrame?.height)
        let initialViewportHeight = try #require(model.snapshot.viewportHeight)

        // 模拟 Markdown 在首轮排版后异步解码出一大段正文：高度增长后仍应贴底
        model.detailHeight = 360
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            (model.snapshot.lastItemFrame?.height ?? 0) >= initialRowHeight + 300
        }
        try await waitForBottomMessage(host: hosting, window: window)

        // 模拟正文转入折叠思考区：高度骤降后偏移可能越过新底部，必须重新贴底，
        // 不能在最后一条消息下方残留空白
        model.detailHeight = 0
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            guard let height = model.snapshot.lastItemFrame?.height else { return false }
            return abs(height - initialRowHeight) <= 2
        }
        try await waitForBottomMessage(host: hosting, window: window)

        // 输入框展开 / 确认卡出现会收缩视口；跟随状态应按新视口重新贴底
        window.setContentSize(NSSize(width: 360, height: 300))
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            abs((model.snapshot.viewportHeight ?? .infinity) - (initialViewportHeight - 120)) <= 2
        }
        try await waitForBottomMessage(host: hosting, window: window)

        // 视口恢复后同样保持底部
        window.setContentSize(NSSize(width: 360, height: 460))
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            abs((model.snapshot.viewportHeight ?? .infinity) - (initialViewportHeight + 40)) <= 2
        }
        try await waitForBottomMessage(host: hosting, window: window)
    }

    @Test("Scrolling up during a Markdown stream preserves the reading position through final layout")
    func readingEarlierMessageDuringStream() async throws {
        let model = ChatScrollProbeModel()
        model.items = (1...18).map(ChatScrollProbeModel.Item.init(number:))
        // A trailing result card keeps the reader outside the follow threshold
        // even while the final Markdown view replaces its streaming placeholder.
        model.detailHeight = 600
        model.markdown = "[reference][late]\n\n```swift\n" + (1...48).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let hosting = NSHostingView(rootView: ChatScrollProbeView(model: model))
        let window = makeWindow(hosting: hosting)
        defer { window.close() }
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            model.renderer.segments.contains { if case .codeBlock = $0 { true } else { false } }
                && (model.distanceFromBottom ?? .infinity) <= 2
        }
        // Keep the previous message and the start of the streaming reply on screen
        // together while the reply is being edited.
        model.readerTarget = try #require(model.items.dropLast().last?.id)
        var lastPosition: (reader: CGFloat, reply: CGFloat)?
        var stableSince = ContinuousClock.now
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            guard let reader = model.snapshot.readerFrame, let reply = model.snapshot.lastItemFrame,
                  let viewport = model.snapshot.viewportFrame else { return false }
            if lastPosition?.reader != reader.minY || lastPosition?.reply != reply.minY {
                lastPosition = (reader.minY, reply.minY)
                stableSince = .now
            }
            return model.snapshot.paused && viewport.contains(reader)
                && reply.minY >= reader.maxY - 2 && reply.minY < viewport.maxY
                && (model.distanceFromBottom ?? 0) > ChatScrollState.pauseDistance
                && stableSince.duration(to: .now) >= .milliseconds(80)
        }
        model.scrollState.endUserInteraction()
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
        try await waitUntil(host: hosting, window: window, timeout: 5) {
            guard let reader = model.snapshot.readerFrame, let reply = model.snapshot.lastItemFrame,
                  let viewport = model.snapshot.viewportFrame else { return false }
            // The reply can reflow when its image resolves. The message being read stays put.
            return abs(reader.minY - position) <= 2 && viewport.contains(reader)
                && reply.minY >= reader.maxY - 2 && reply.minY < viewport.maxY && model.snapshot.paused
                && (model.distanceFromBottom ?? 0) > ChatScrollState.pauseDistance
        }
    }

    private func makeWindow(hosting: NSHostingView<ChatScrollProbeView>) -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.orderFront(nil)
        return window
    }

    /// SwiftUI can deliver a new viewport size before the child's layout callback.
    /// Wait for both measurements, including the signed offset after a resize.
    private func waitForBottomMessage(
        host: NSHostingView<ChatScrollProbeView>,
        window: NSWindow,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let model = host.rootView.model
        let snapshot = model.snapshot
        try await waitUntil(host: host, window: window, timeout: 5, sourceLocation: sourceLocation) {
            guard snapshot.lastItemID == model.items.last?.id,
                  let last = snapshot.lastItemFrame, let viewport = snapshot.viewportFrame,
                  let contentHeight = snapshot.contentHeight, let viewportHeight = snapshot.viewportHeight,
                  let distance = snapshot.rawDistanceFromBottom else { return false }
            let gap = viewport.maxY - last.maxY
            return abs(viewport.height - viewportHeight) <= 2 && last.intersects(viewport)
                && (-2...32).contains(gap) && distance <= 2
                && (contentHeight <= viewportHeight || distance >= -2)
        }
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
            measureRows(in: host)
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = host.rootView.model.snapshot
        try #require(condition(), "等待滚动收敛超时，内容高度 \(snapshot.contentHeight ?? -1)，视口 \(String(describing: snapshot.viewportFrame))，末行 \(String(describing: snapshot.lastItemFrame))，阅读行 \(String(describing: snapshot.readerFrame))，距底部 \(snapshot.rawDistanceFromBottom ?? .nan)，暂停跟随 \(snapshot.paused)，Markdown 资源 \(host.rootView.model.renderer.resources.count)", sourceLocation: sourceLocation)
    }

    private func measureRows(in host: NSHostingView<ChatScrollProbeView>) {
        let model = host.rootView.model
        let snapshot = model.snapshot
        snapshot.viewportFrame = CGRect(origin: .zero, size: host.bounds.size)
        snapshot.readerFrame = nil
        snapshot.lastItemFrame = nil
        snapshot.lastItemID = nil
        var remaining = host.subviews
        while let view = remaining.popLast() {
            if let marker = view as? ChatScrollRowMarker.View, let id = marker.messageID {
                let rect = host.convert(marker.bounds, from: marker)
                let y = host.isFlipped ? rect.minY - host.bounds.minY : host.bounds.maxY - rect.maxY
                let frame = CGRect(x: rect.minX - host.bounds.minX, y: y, width: rect.width, height: rect.height)
                if id == model.readerTarget { snapshot.readerFrame = frame }
                if id == model.items.last?.id {
                    snapshot.lastItemID = id
                    snapshot.lastItemFrame = frame
                }
            } else {
                remaining.append(contentsOf: view.subviews)
            }
        }
    }
}

/// Read the current native layout after each update, including when the lazy stack reuses a row.
private struct ChatScrollRowMarker: NSViewRepresentable {
    final class View: NSView {
        var messageID: UUID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let id: UUID

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) { nsView.messageID = id }
}

@MainActor
@Observable
final class ChatScrollProbeModel {
    let sessionID = UUID()
    let scrollState = ChatScrollState()
    struct Item: Identifiable {
        let id = UUID()
        let number: Int
    }
    var items = (1...3).map(Item.init(number:))
    /// 最后一条消息在首轮排版后异步长出的正文高度（模拟 Markdown / 图片解析完成）
    var detailHeight: CGFloat = 0
    var distanceFromBottom: CGFloat?
    var readerTarget: UUID?
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
    var lastItemID: UUID?
    var lastItemFrame: CGRect?
    var viewportFrame: CGRect?
    var contentHeight: CGFloat?
    var viewportHeight: CGFloat?
    var rawDistanceFromBottom: CGFloat?
}

private struct ChatScrollProbeView: View {
    let model: ChatScrollProbeModel
    private var scrollState: ChatScrollState { model.scrollState }
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ChatTranscriptRows(messageCount: model.items.count) {
                    ForEach(model.items) { item in
                        let id = item.id
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message \(item.number) " + String(repeating: "content ", count: (item.number % 7) * 4 + 4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if id == model.items.last?.id, !model.markdown.isEmpty {
                                MarkdownView(text: model.markdown, streaming: model.streaming, documentID: "reply", model: model.renderer)
                            }
                            if id == model.items.last?.id, model.detailHeight > 0 {
                                Text("Late markdown body")
                                    .frame(maxWidth: .infinity, minHeight: model.detailHeight, alignment: .topLeading)
                                    .background(Color.gray.opacity(0.08))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.gray.opacity(0.12))
                        .background(ChatScrollRowMarker(id: id))
                        .id(id)
                        .onGeometryChange(for: CGRect.self) { geometry in
                            geometry.frame(in: .global)
                        } action: { frame in
                            scrollState.recordMessageFrame(frame, id: id)
                            if scrollState.hasReadingAnchor { scheduleFlush(proxy) }
                        }
                        .onDisappear {
                            scrollState.forgetMessageFrame(id)
                        }
                    }
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 24)
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onAppear {
                scrollState.bindSession(model.sessionID, reset: true)
                scrollState.request(.layoutCorrection)
                scheduleFlush(proxy)
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
                guard flush else { return }
                scheduleFlush(proxy)
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    scrollState.beginUserInteraction()
                case .animating:
                    scrollState.setAnimatingScroll(true)
                case .idle:
                    scrollState.endUserInteraction()
                    scrollState.setAnimatingScroll(false)
                    scrollState.settle()
                    scheduleFlush(proxy)
                }
            }
            .onChange(of: model.readerTarget) { _, item in
                guard let item else { return }
                scrollState.beginUserInteraction()
                scrollPosition.scrollTo(id: item, anchor: .center)
            }
            .onChange(of: model.items.count) { _, _ in
                guard scrollState.isFollowingBottom else { return }
                scrollState.request(.newMessage)
                scheduleFlush(proxy)
            }
        }
    }

    private func scheduleFlush(_ proxy: ScrollViewProxy) {
        guard scrollState.beginFlush() else { return }
        let generation = scrollState.generation
        Task { @MainActor in
            scrollState.endFlush()
            guard scrollState.isCurrent(sessionID: model.sessionID, generation: generation) else { return }
            if let target = scrollState.readingReflowTarget() {
                proxy.scrollTo(target.id, anchor: UnitPoint(x: 0, y: target.anchor))
                return
            }
            guard let request = scrollState.takePendingRequest(),
                  scrollState.canExecute(request) else { return }
            if request.isAnimated {
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }
}
