import AppKit
import SwiftUI
import Testing
@preconcurrency import Network
@testable import AgRoomUI

@Suite("Markdown rich content parsing")
struct MarkdownRichParsingTests {
    @Test("LaTeX 保留反斜杠，支持四种定界符与多行块公式")
    func mathDelimiters() {
        let source = #"前 $\frac{a_1}{b}$ 后 \(x^2\)"# + "\n\n$$\n\\sum_{i=1}^{n} i\n$$\n\n" + #"\[\sqrt{x}\]"#
        let document = MarkdownParser.parse(source)
        let math = MarkdownResourcePlan.keys(in: document.blocks).compactMap { key -> MarkdownMath? in
            if case .math(let value) = key { return value }; return nil
        }
        #expect(math.map(\.source) == [#"\frac{a_1}{b}"#, "x^2", #"\sum_{i=1}^{n} i"#, #"\sqrt{x}"#])
        #expect(math.map(\.display) == [false, false, true, true])
        #expect(document.plainText.contains(#"\frac{a_1}{b}"#))
        #expect(MarkdownParser.parse("QQ$$\nx\n$$").plainText == "QQx")
        #expect(document.blocks[1].content == .math(MarkdownMath(source: #"\sum_{i=1}^{n} i"#, display: true)))
    }

    @Test("货币、转义、代码与未闭合定界符不发起公式渲染")
    func literalDelimiters() {
        let samples = [#"价格 $5 和 $10。"#, #"\$x$"#, #"`$x$`"#, "```latex\n$x$\n```", #"\(unfinished"#, "$unfinished", "$$\nunclosed"]
        for source in samples {
            #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse(source).blocks).isEmpty)
        }
        #expect(MarkdownParser.parse(#"\(unfinished"#).plainText == #"\(unfinished"#)
        #expect(MarkdownParser.parse(#"**前** $a$ &amp; $b$"#).plainText == "前 a & b")
    }

    @Test("公式嵌入强调、表格与多行引用，源码范围保持 UTF-8 原始偏移")
    func mathContainers() throws {
        let source = "---\r\nname: math\r\n---\r\n**中文 $x_1$**\r\n\r\n> $$\n> \\frac{1}{2}\n> $$\n\nA | B\n--- | ---\n$x$ | $y$"
        let document = MarkdownParser.parse(source, strippingFrontmatter: true)
        let keys = MarkdownResourcePlan.keys(in: document.blocks)
        #expect(keys.contains(.math(MarkdownMath(source: #"\frac{1}{2}"#, display: true))))
        #expect(keys.contains(.math(MarkdownMath(source: "y", display: false))))
        guard case .paragraph(let nodes) = document.blocks[0].content, case .strong(let children) = nodes[0].content else { Issue.record("应保留强调容器"); return }
        let math = try #require(children.first { if case .math = $0.content { return true }; return false })
        let range = try #require(math.sourceRange)
        #expect(String(decoding: Array(source.utf8)[range], as: UTF8.self) == "$x_1$")
        #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse("> $$\n>x\n>$$").blocks) == [.math(MarkdownMath(source: "x", display: true))])
        for list in ["- $$\n  x_1\n  $$", "1. $$\n   x_1\n   $$"] {
            let blocks = MarkdownParser.parse(list).blocks
            guard case .list(_, let items) = blocks.first?.content,
                  case .math(let value) = items.first?.blocks.first?.content else { Issue.record("多行公式必须保持列表归属"); continue }
            #expect(value.source == "x_1")
        }
    }

    @Test("未闭合 Mermaid 围栏保持代码；闭合后才调度图表")
    func mermaidClosure() {
        let source = "```mermaid\ngraph LR\nA --> B\n"
        #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse(source).blocks).isEmpty)
        #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse(source + "```").blocks).count == 1)
        #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse("~~~mermaid\ngraph LR\nA-->B\n~~~").blocks).count == 1)
        #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse("> ```mermaid\n> graph LR\n> A-->B\n> ```").blocks).count == 1)
        #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse("- ```mermaid\n  graph LR\n  A-->B\n  ```").blocks).count == 1)
    }

    @Test("图片保留引用目标和替代文字，不猜测未完成的地址")
    func imageReferences() {
        let source = "![示意][image]\n\n[image]: images/test.png"
        let document = MarkdownParser.parse(source)
        #expect(MarkdownResourcePlan.keys(in: document.blocks) == [.image("images/test.png")])
        #expect(document.plainText == "示意")
        #expect(MarkdownResourcePlan.keys(in: MarkdownParser.parse("![示意](https://example.com/").blocks).isEmpty)
    }
}

@Suite("Markdown resource boundaries", .serialized)
struct MarkdownResourceBoundaryTests {
    @Test("远程图片使用无凭据请求；检查重定向、MIME、响应长度与取消")
    func remoteImages() async throws {
        let server = try LoopbackMarkdownImageServer()
        let base = try await server.start()
        defer { server.stop() }
        let loader = MarkdownImageLoader()
        #expect(try await loader.load(base + "/image", context: MarkdownSourceContext()) == server.body)
        #expect(try await loader.load(base + "/redirect", context: MarkdownSourceContext()) == server.body)
        for path in ["/insecure-redirect", "/large", "/text"] {
            await #expect(throws: (any Error).self) { try await loader.load(base + path, context: MarkdownSourceContext()) }
        }
        let task = Task { try await loader.load(base + "/slow", context: MarkdownSourceContext()) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test("相对路径按文档目录解析；拒绝穿越、符号链接、另一空间和不安全网络地址")
    func sourceResolution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let personal = root.appendingPathComponent("personal")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("escape"), withDestinationURL: personal)
        let context = MarkdownSourceContext(spaceID: "work", baseURL: work, allowedRoots: [root], forbiddenRoots: [personal])
        #expect(try context.resolveImage("a%20b.png") == work.appendingPathComponent("a b.png"))
        #expect(throws: (any Error).self) { try context.resolveImage("../../outside.png") }
        #expect(throws: (any Error).self) { try context.resolveImage("escape/secret.png") }
        for source in ["http://example.com/a.png", "https://user:password@example.com/a.png", "javascript:alert(1)", "data:image/png;base64,AA=="] {
            #expect(throws: (any Error).self) { try context.resolveImage(source) }
        }
        #expect(try context.resolveImage("https://example.com/a.png").scheme == "https")
        #expect(try context.resolveImage("http://127.0.0.1/a.png").host == "127.0.0.1")
        #expect(throws: (any Error).self) { try MarkdownSourceContext().resolveImage("relative.png") }
    }

    @MainActor @Test("图片到达时创建新附件，重新测量高度并提供文本复制替代")
    func localImageAndAttachment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent("image.png"))
        let model = MarkdownRenderModel()
        await model.update("前 ![替代文字](image.png) 后", documentID: "image-test", streaming: false,
                           context: MarkdownSourceContext(spaceID: "work", baseURL: root, allowedRoots: [root]))
        let resource = try #require(model.resources[.image("image.png")])
        let attachmentView = SelectableTextView.make(attributed: resource.attachment(maxWidth: 160, maxHeight: 100))
        #expect(attachmentView.heightForWidth(60) < attachmentView.heightForWidth(200))
        guard case .prose(let prose) = model.segments.first else { Issue.record("行内图片保持段落布局"); return }
        let text = SelectableTextView.make(prose: prose)
        #expect(text.heightForWidth(300) >= 80)
        text.setSelectedRange(NSRange(location: 0, length: prose.attributedString.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(text.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "前 替代文字 后")
        // 同一文档换空间，原先解码结果不能沿用。
        await model.update("前 ![替代文字](image.png) 后", documentID: "image-test", streaming: false,
                           context: MarkdownSourceContext(spaceID: "personal", baseURL: root))
        #expect(model.resources.isEmpty)
        #expect(model.failedResources.contains(.image("image.png")))
        let context = MarkdownSourceContext(spaceID: "work", baseURL: root, allowedRoots: [root])
        await model.update("![稍后到达](later.png)", documentID: "retry", streaming: false, context: context)
        #expect(model.failedResources.contains(.image("later.png")))
        try data.write(to: root.appendingPathComponent("later.png"))
        await model.update("![稍后到达](later.png)", documentID: "retry", streaming: false, context: context, retryRevision: 1)
        #expect(model.resources[.image("later.png")] != nil)
        #expect(model.failedResources.isEmpty)
    }

    @Test("不接受伪图片与过大文件")
    func boundedImages() async throws {
        #expect(throws: (any Error).self) { try MarkdownImageLoader.decode(Data("<svg></svg>".utf8)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: UInt64(MarkdownImageLoader.maximumBytes + 1))
        try handle.close()
        await #expect(throws: (any Error).self) {
            try await MarkdownImageLoader().load("large.png", context: MarkdownSourceContext(baseURL: root, allowedRoots: [root]))
        }
    }
}

private final class LoopbackMarkdownImageServer: @unchecked Sendable {
    let body = Data([1, 2, 3, 4])
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Markdown image HTTP fixture")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        let body = body
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let response: String
                var content = Data()
                if request.lowercased().contains("cookie:") || request.lowercased().contains("authorization:") {
                    response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n"
                } else {
                    switch path {
                    case "/redirect": response = "HTTP/1.1 302 Found\r\nLocation: /image\r\nContent-Length: 0\r\n"
                    case "/insecure-redirect": response = "HTTP/1.1 302 Found\r\nLocation: http://example.com/image\r\nContent-Length: 0\r\n"
                    case "/large": response = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 99999999\r\n"
                    case "/text": response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 0\r\n"
                    default:
                        response = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\n"
                        content = body
                    }
                }
                let payload = Data((response + "Connection: close\r\n\r\n").utf8) + content
                let send: @Sendable () -> Void = {
                    connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
                }
                if path == "/slow" { queue.asyncAfter(deadline: .now() + 1, execute: send) }
                else { send() }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(listener.port!.rawValue)")
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

@MainActor @Suite("Offline formula and Mermaid rendering", .serialized)
struct MarkdownOfflineRenderingTests {
    @Test("复用离线宿主后短公式恢复自然尺寸，失败后的下一项可正常渲染")
    func reusedHostClearsPreviousOutput() async throws {
        let renderer = MarkdownWebRenderer(reusingHost: true)
        defer { renderer.close() }
        let short = MarkdownResourceKey.math(.init(source: "x", display: false))
        let a = try await renderer.render(short, dark: false)
        let wide = try await renderer.render(.math(.init(source: "a+b+c+d+e+f+g+h", display: true)), dark: false)
        let b = try await renderer.render(short, dark: false)
        #expect(wide.image.size.width > b.image.size.width)
        #expect(a.image.size == b.image.size && a.descent == b.descent)
        await #expect(throws: (any Error).self) {
            try await renderer.render(.math(.init(source: #"\invalidAgRoomMacro"#, display: false)), dark: false)
        }
        let dark = try await renderer.render(short, dark: true)
        #expect(dark.image.size == a.image.size)
    }
    @Test("长图随对话宽度伸缩，超过原生宽度也不受缩略图上限约束")
    func adaptivePortraitDiagram() async throws {
        let diagram = "flowchart TD\n" + (0..<14).map { "N\($0)[步骤 \($0)] --> N\($0 + 1)" }.joined(separator: "\n")
        let resource = try await MarkdownWebRenderer().render(.mermaid(diagram), dark: false)
        #expect(resource.vectorPDF != nil)
        #expect(resource.vectorImage?.representations.contains { $0 is NSPDFImageRep } == true)
        for width in [320.0, 980.0, 1_400.0] {
            let host = NSHostingView(rootView: ScrollView {
                MarkdownRichBlock(resource: resource, failed: false, source: diagram, language: "mermaid").padding(16)
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            func images(_ view: NSView) -> [NSImageView] {
                if let image = view as? NSImageView { return [image] }
                return view.subviews.flatMap(images)
            }
            let image = try #require(images(host).first)
            #expect(abs(image.frame.width - (width - 32)) < 1)
            #expect(image.frame.height > 400)
            #expect(abs(image.frame.height / image.frame.width - resource.image.size.height / resource.image.size.width) < 0.01)
        }
    }

    @Test("放大画布支持宽度适配、实际比例、缩放和拖动平移")
    func zoomCanvasSizingAndPanning() async throws {
        let image = NSImage(size: NSSize(width: 800, height: 2_400))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let viewport = CGSize(width: 640, height: 480)
        #expect(MarkdownPreviewZoom.fitWidth.scale(content: image.size, viewport: viewport) == 0.8)
        #expect(MarkdownPreviewZoom.fitWindow.scale(content: image.size, viewport: viewport) == 0.2)
        #expect(MarkdownPreviewZoom.actual(2).scale(content: image.size, viewport: viewport) == 2)
        let host = NSHostingView(rootView: MarkdownZoomCanvas(image: image, scale: 1, onZoom: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func scrollViews(_ view: NSView) -> [MarkdownZoomScrollView] {
            if let scroll = view as? MarkdownZoomScrollView { return [scroll] }
            return view.subviews.flatMap(scrollViews)
        }
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let scroll = try #require(scrollViews(host).first)
        let drawing = try #require(scroll.documentView?.subviews.first as? NSImageView)
        #expect(drawing.frame.size == image.size)
        #expect(scroll.contentView.bounds.origin.y == 0)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 200), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 150, y: 300), modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        drawing.mouseDown(with: down)
        drawing.mouseDragged(with: drag)
        drawing.mouseUp(with: drag)
        #expect(scroll.contentView.bounds.origin.y > 0)
        let focusedY = scroll.contentView.bounds.midY / drawing.frame.height
        host.rootView = MarkdownZoomCanvas(image: image, scale: 2, onZoom: { _ in })
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(drawing.frame.width == 1_600)
        #expect(drawing.frame.height == 4_800)
        #expect(abs(scroll.contentView.bounds.midY / drawing.frame.height - focusedY) < 0.001)
    }

    @Test("图表放大窗口默认按宽度显示，调整窗口宽度后保持适配")
    func vectorPreviewFitsViewport() async throws {
        for dark in [false, true] {
            let resource = try await MarkdownWebRenderer().render(.mermaid(Self.approvalSequence), dark: dark)
            let host = NSHostingView(rootView: MarkdownResourcePreview(resource: resource, name: "Mermaid", initiallyFitsWidth: true)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            func scrollViews(_ view: NSView) -> [MarkdownZoomScrollView] {
                if let scroll = view as? MarkdownZoomScrollView { return [scroll] }
                return view.subviews.flatMap(scrollViews)
            }
            for width in [1_000.0, 1_240.0] {
                window.setContentSize(NSSize(width: width, height: 720))
                for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
                let scroll = try #require(scrollViews(host).first)
                let image = try #require(scroll.documentView?.subviews.first as? NSImageView)
                #expect(abs(image.frame.width - scroll.contentView.bounds.width) < 1)
                #expect(abs(scroll.contentView.bounds.origin.y) < 1)
                #expect(abs(image.frame.height / image.frame.width - resource.image.size.height / resource.image.size.width) < 0.01)
            }
            if let directory = ProcessInfo.processInfo.environment["AGROOM_MARKDOWN_SNAPSHOT_DIR"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let preview = NSImage(size: host.bounds.size)
                preview.lockFocus()
                (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
                host.bounds.fill()
                if let cg = bitmap.cgImage { NSImage(cgImage: cg, size: host.bounds.size).draw(in: host.bounds, from: .zero, operation: .sourceOver, fraction: 1) }
                preview.unlockFocus()
                let tiff = try #require(preview.tiffRepresentation)
                let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("diagram-zoom-\(dark ? "dark" : "light").png"))
            }
            let scroll = try #require(scrollViews(host).first)
            let image = try #require(scroll.documentView?.subviews.first as? NSImageView)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 180))
            let readingPosition = scroll.contentView.bounds.minY / image.frame.height
            window.setContentSize(NSSize(width: 1_000, height: 720))
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            #expect(abs(scroll.contentView.bounds.minY / image.frame.height - readingPosition) < 0.001)
        }
    }

    private static let narrowingFlow = """
    flowchart TD
        Base["父会话模式上限"]
        Base --> G1["守护进程 · 后台<br/>任务范围内自动批准 = false<br/>后台不新增免确认入口"]
        Base --> G2["子代理<br/>restricted(to: 父模式)<br/>只能收窄，不能提权"]
        Base --> G3["定时任务 · 无人值守<br/>readOnly.v1 代码内工具白名单<br/>需确认即失败关闭"]
        Base --> G4["team_write<br/>归 workspaceMutation<br/>过模式后走任务板逐次批准"]
        Base --> G5["运行 / 挂起 / 等待确认期间<br/>禁止切换模式<br/>保证同一轮同一能力上限"]
        classDef narrow fill:#fff3e0,stroke:#e67e22,color:#7e4a00;
        class Base fill:#e8f4ff,stroke:#2471a3,color:#154360;
        class G1,G2,G3,G4,G5 narrow;
    """
    private static let approvalSequence = """
    sequenceDiagram
        autonumber
        participant L as LLM
        participant P as PermissionPolicy
        participant A as AutoReview
        participant U as 用户
        participant E as 执行器 Sandbox
        participant T as 审计

        L->>P: 工具名 + 已解析参数
        P->>P: 能力分类 → 模式闸门
        alt deny
            P-->>L: toolResult 直接拒绝
            P-->>T: mode_denied
        else 需要人工确认
            P->>A: 硬确认？ / 免确认？ / 规则匹配？
            A-->>P: 未命中，落回普通确认
            P->>U: 确认卡
            U-->>P: 批准（本轮 / 持久）
            P->>P: 二次校验同一份参数 + FileAreaPolicy
            P->>E: 执行
            E-->>L: 结果
            P-->>T: 人工批准记录
        else 免确认或规则命中
            P->>E: 用已解析的可执行 + argv 执行
            E-->>L: 结果
            P-->>T: 规则命中记录
        end
    """

    @Test("截图中的权限时序图可渲染")
    func screenshotSequence() async throws {
        _ = NSApplication.shared
        let resource = try await MarkdownWebRenderer().render(.mermaid(Self.approvalSequence), dark: false)
        #expect(resource.image.size.height > 100)
        #expect(resource.pixelCount <= MarkdownWebRenderer.maximumSnapshotPixels)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_MARKDOWN_SNAPSHOT_DIR"],
           let tiff = resource.image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("approval-sequence.png"))
        }
    }

    @Test("原生宿主中的多个图表从空模型开始异步加载")
    func multipleDiagramsMounted() async throws {
        let diagrams = ["graph LR\nA[权限分类] --> B[模式闸门]", "graph LR\nA[规则匹配] --> B[确认卡]", Self.narrowingFlow, Self.approvalSequence]
        let source = diagrams.enumerated().map { index, diagram in
            "## 图 \(index + 1)\n\n```mermaid\n" + diagram + "\n```"
        }.joined(separator: "\n\n")
        let model = MarkdownRenderModel()
        let host = NSHostingView(rootView: MarkdownView(text: source, documentID: "multiple-charts", model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1_000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && model.resources.count + model.failedResources.count < 4 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.failedResources.isEmpty)
        #expect(model.resources.count == 4)
        #expect(model.resources.values.reduce(0) { $0 + $1.pixelCount } <= 16_000_000)
        #expect(model.resources.values.allSatisfy { $0.pixelCount <= MarkdownWebRenderer.maximumSnapshotPixels })
        if let directory = ProcessInfo.processInfo.environment["AGROOM_MARKDOWN_SNAPSHOT_DIR"] {
            for (index, diagram) in diagrams.enumerated() {
                let resource = try #require(model.resources[.mermaid(diagram + "\n")])
                let preview = NSImage(size: resource.image.size)
                preview.lockFocus()
                NSColor.white.setFill()
                let rect = NSRect(origin: .zero, size: resource.image.size)
                rect.fill()
                resource.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                preview.unlockFocus()
                let tiff = try #require(preview.tiffRepresentation)
                let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("approval-chart-\(index + 1).png"))
            }
        }
    }

    @Test("兼容内联样式笔误时不改动合法 class、classDef 或引号内正文")
    func styleCompatibilityBoundaries() {
        let source = "graph TD\nA[测试]\nclass A fill:#fff,stroke:#000;"
        #expect(MarkdownWebRenderer.compatibleMermaidSource(source).hasSuffix("style A fill:#fff,stroke:#000;"))
        for source in ["graph TD\nclass A narrow;\nclassDef narrow fill:#fff;", "graph TD\nA[\"多行正文\nclass A fill:#fff;\n\"]", "sequenceDiagram\nNote over A: class A fill:#fff;"] {
            #expect(MarkdownWebRenderer.compatibleMermaidSource(source) == source)
        }
    }

    @Test("富内容在窄宽宿主与深浅色下保持行内布局和末段高度")
    func hostedRichContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 64, height: 36))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 64, height: 36), xRadius: 6, yRadius: 6).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("figure.png"))
        let context = MarkdownSourceContext(spaceID: "work", baseURL: root, allowedRoots: [root])
        let source = #"正文中的 $\frac{1}{2}+x^2$ 与后面的文字保持同段。"#
            + "\n\n行内图片 ![标记](figure.png) 与文字。\n\n![示例图片](figure.png)\n\n$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$\n\n"
            + "```mermaid\ngraph LR\nA[输入] --> B[处理]\nB --> C[输出]\n```\n\n"
            + "名称 | 公式\n--- | ---\n示例 | $x^2$\n\n最后一段保持完整显示。"
        for dark in [false, true] {
            let model = MarkdownRenderModel()
            await model.update(source, documentID: "rich-host", streaming: false, context: context, dark: dark)
            #expect(model.failedResources.isEmpty)
            #expect(model.resources.count == 5)
            for width in [320.0, 700.0] {
                let host = NSHostingView(rootView: MarkdownView(text: source, documentID: "rich-host", sourceContext: context, model: model)
                    .padding(16).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                func textViews(_ view: NSView) -> [SelectableTextView] {
                    if let text = view as? SelectableTextView { return [text] }
                    return view.subviews.flatMap(textViews)
                }
                var views: [SelectableTextView] = []
                for _ in 0..<100 {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    views = textViews(host)
                    if views.contains(where: { $0.string.contains("最后一段") }) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(views.contains(where: { $0.string.contains("最后一段") }))
                #expect(host.fittingSize.height < 600)
                window.setContentSize(NSSize(width: width, height: ceil(host.fittingSize.height)))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                for view in views {
                    #expect(view.frame.height >= view.heightForWidth(view.frame.width) - 0.5)
                }
                if let directory = ProcessInfo.processInfo.environment["AGROOM_MARKDOWN_SNAPSHOT_DIR"],
                   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let preview = NSImage(size: host.bounds.size)
                    preview.lockFocus()
                    (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
                    host.bounds.fill()
                    if let cg = bitmap.cgImage { NSImage(cgImage: cg, size: host.bounds.size).draw(in: host.bounds, from: .zero, operation: .sourceOver, fraction: 1) }
                    preview.unlockFocus()
                    let tiff = try #require(preview.tiffRepresentation)
                    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("host-rich-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test("真实离线引擎生成行内公式、块公式与图表的非空图片")
    func actualRendering() async throws {
        _ = NSApplication.shared
        let samples: [MarkdownResourceKey] = [
            .math(MarkdownMath(source: #"\frac{a_1}{b}+\sqrt{x}"#, display: false)),
            .math(MarkdownMath(source: #"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#, display: true)),
            .mermaid("graph LR\nA[输入] --> B[处理]\nB --> C[输出]")
        ]
        for dark in [false, true] {
            for (index, sample) in samples.enumerated() {
                let resource = try await MarkdownWebRenderer().render(sample, dark: dark)
                #expect(resource.image.size.width > 10)
                #expect(resource.image.size.height > 10)
                #expect(resource.pixelCount > 100)
                if case .math(let math) = sample, !math.display {
                    #expect(resource.descent > 0)
                    #expect(resource.descent < resource.image.size.height)
                }
                if let directory = ProcessInfo.processInfo.environment["AGROOM_MARKDOWN_SNAPSHOT_DIR"],
                   let tiff = resource.image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("rich-\(index)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test("语法错误回退，拒绝可改配置的图表指令；取消可及时收尾")
    func failuresAndCancellation() async throws {
        _ = NSApplication.shared
        for key: MarkdownResourceKey in [.math(MarkdownMath(source: #"\unknowncommand{x}"#, display: false)), .mermaid("%%{init:{securityLevel:'loose'}}%%\ngraph LR\nA-->B"), .mermaid("invalid diagram source")] {
            await #expect(throws: (any Error).self) { try await MarkdownWebRenderer().render(key, dark: false) }
        }
        let malformed = MarkdownRenderModel()
        await malformed.update("```mermaid\ninvalid diagram source\n```", documentID: "invalid-graph", streaming: false)
        #expect(malformed.resourceErrors.values.first?.messageKey == "md.resource.invalid")
        let task = Task { try await MarkdownWebRenderer().render(.mermaid("graph LR\nA --> B"), dark: false) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        let model = MarkdownRenderModel()
        let old = Task { await model.update("$x$", documentID: "old-resource", streaming: false) }
        try await Task.sleep(for: .milliseconds(10))
        old.cancel()
        await model.update("新文档", documentID: "new-resource", streaming: false)
        await old.value
        #expect(model.documentID == "new-resource")
        #expect(model.resources.isEmpty)
        #expect(model.failedResources.isEmpty)
    }
}
