import AppKit
import WebKit

/// 仅存在于 UI 层的离线光栅化后端；每份文档拥有自己的实例。
@MainActor
final class MarkdownWebRenderer: NSObject, WKNavigationDelegate {
    /// 实际位图像素预算，不能用 CSS 尺寸代替；Retina 会再次应用 backing scale。
    static let maximumSnapshotPixels = 2_000_000
    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<MarkdownRenderedResource, any Error>?
    private var timeout: Task<Void, Never>?
    private var key: MarkdownResourceKey?
    private var dark = false
    private var requestID: UUID?
    private enum Backend { case math, mermaid }
    private var backend: Backend?
    private let reusingHost: Bool
    private static let initialSize = NSSize(width: 1_600, height: 1_000)

    init(reusingHost: Bool = false) { self.reusingHost = reusingHost }

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: MarkdownWebRenderer.self)
        #endif
    }

    private static func asset(_ name: String, extension ext: String) throws -> String {
        guard let url = resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "Markdown")
                ?? resourceBundle.url(forResource: name, withExtension: ext) else { throw MarkdownResourceError.failed }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // 只有随应用发布的静态代码可共享；文档、公式和图片不进入静态缓存。
    private static let katex = try? asset("katex.min", extension: "js")
    private static let katexCSS = try? asset("katex.min", extension: "css")
    private static let mermaid = try? asset("mermaid.min", extension: "js")

    func render(_ key: MarkdownResourceKey, dark: Bool) async throws -> MarkdownRenderedResource {
        try Task.checkCancellation()
        guard continuation == nil else { throw MarkdownResourceError.failed }
        let script: String
        let css: String
        let backend: Backend
        switch key {
        case .math(let math):
            guard math.source.utf8.count <= 16_384 else { throw MarkdownResourceError.tooLarge }
            guard let code = Self.katex, let styles = Self.katexCSS else { throw MarkdownResourceError.failed }
            script = code; css = styles; backend = .math
        case .mermaid(let source):
            guard source.utf8.count <= 50_000 else { throw MarkdownResourceError.tooLarge }
            guard let code = Self.mermaid else { throw MarkdownResourceError.failed }
            script = code; css = ""; backend = .mermaid
        case .image: throw MarkdownResourceError.invalid
        }
        let warmView = self.backend == backend && self.dark == dark ? webView : nil
        let request = UUID()
        requestID = request
        self.key = key
        self.dark = dark
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    self?.finish(.failure(MarkdownResourceError.timedOut), request: request)
                }
                if let warmView {
                    warmView.setFrameSize(Self.initialSize)
                    draw(key, in: warmView, request: request)
                } else {
                    discardHost()
                    self.backend = backend
                    openHost(script: script, css: css, dark: dark)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), request: request) }
        }
    }

    private func openHost(script: String, css: String, dark: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(origin: .zero, size: Self.initialSize), configuration: configuration)
        view.navigationDelegate = self
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        self.webView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window
        let nonce = UUID().uuidString
        let safeScript = script.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; font-src data:; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>\(css)
        html,body { margin:0; padding:0; background:transparent; color:\(dark ? "#eeeeee" : "#222222"); }
        body { font:13px -apple-system; }
        #output { display:inline-block; padding:2px; }
        .katex-display { margin:0; }
        #baseline { display:inline-block; width:0; height:0; vertical-align:baseline; }
        </style><script nonce="\(nonce)">\(safeScript)</script></head>
        <body><div id="output"></div></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // 唯一允许的导航为本次 loadHTMLString 的空白文档。
        navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { hostFailed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { hostFailed(webView, error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { hostFailed(webView, MarkdownResourceError.failed) }

    private func hostFailed(_ view: WKWebView, _ error: any Error) {
        guard webView === view else { return }
        if let requestID { finish(.failure(error), request: requestID) } else { discardHost() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView, let key, let requestID else { return }
        draw(key, in: webView, request: requestID)
    }

    private func draw(_ key: MarkdownResourceKey, in webView: WKWebView, request: UUID) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.requestID == request else { return }
            do {
                let source: String, display: Bool, diagram: Bool
                switch key {
                case .math(let math): source = math.source; display = math.display; diagram = false
                case .mermaid(let value): source = value; display = true; diagram = true
                case .image: throw MarkdownResourceError.invalid
                }
                let actualSource = diagram ? Self.compatibleMermaidSource(source) : source
                let value = try await webView.callAsyncJavaScript(Self.renderScript, arguments: [
                    "source": actualSource, "display": display, "diagram": diagram, "dark": self.dark
                ], in: nil, contentWorld: .page)
                guard self.requestID == request else { return }
                guard let dimensions = value as? [String: Double], let width = dimensions["width"], let height = dimensions["height"],
                      width.isFinite, height.isFinite, width > 0, height > 0,
                      width <= 4_096, height <= 4_096, width * height <= 4_000_000 else { throw MarkdownResourceError.tooLarge }
                webView.setFrameSize(NSSize(width: ceil(width), height: ceil(height)))
                let config = WKSnapshotConfiguration()
                config.rect = NSRect(x: 0, y: 0, width: ceil(width), height: ceil(height))
                let rasterScale = min(2, 2_048 / width, 3_072 / height,
                                      sqrt(Double(Self.maximumSnapshotPixels) / (ceil(width) * ceil(height))))
                let pixelWidth = max(1, floor(width * rasterScale))
                // snapshotWidth 的单位是 point，WebKit 会乘上宿主屏幕的 backingScaleFactor。
                let backingScale = max(1, self.window?.backingScaleFactor ?? 1)
                config.snapshotWidth = NSNumber(value: pixelWidth / backingScale)
                let snapshot = try await webView.takeSnapshot(configuration: config)
                guard self.requestID == request else { return }
                let (image, pixels) = try Self.boundedImage(snapshot, logicalSize: config.rect.size)
                var vectorPDF: Data?
                if diagram {
                    let pdfConfiguration = WKPDFConfiguration()
                    pdfConfiguration.rect = config.rect
                    if let data = try? await webView.pdf(configuration: pdfConfiguration), data.count <= 4 * 1_024 * 1_024 {
                        vectorPDF = data
                    }
                }
                self.finish(.success(MarkdownRenderedResource(image: image, descent: dimensions["descent"] ?? 0, pixelCount: pixels, vectorPDF: vectorPDF)), request: request)
            } catch {
                let failure = error as NSError
                if failure.domain == WKError.errorDomain && failure.code == WKError.javaScriptExceptionOccurred.rawValue {
                    self.finish(.failure(MarkdownResourceError.invalid), request: request)
                } else { self.finish(.failure(error), request: request) }
            }
        }
    }

    /// 兼容模型常见的 `class Node fill:...` 笔误；源码显示 / 复制保留原样。
    /// 仅处理流程图中未被引号包围、且能确定为单节点内联样式的声明。
    static func compatibleMermaidSource(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("flowchart ") || trimmed.hasPrefix("graph "),
              let declaration = try? NSRegularExpression(pattern: #"^(\s*)class\s+([\p{L}\p{N}_-]+)\s+((?:fill|stroke|color|stroke-width|stroke-dasharray|opacity|font-size):[^\n]+)$"#) else { return source }
        var quoted = false
        return source.components(separatedBy: "\n").map { line in
            var output = line
            if !quoted, let match = declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let value = line as NSString
                output = value.substring(with: match.range(at: 1)) + "style " + value.substring(with: match.range(at: 2)) + " " + value.substring(with: match.range(at: 3))
            }
            var escaped = false
            for character in line {
                if character == "\"", !escaped { quoted.toggle() }
                if character == "\\" { escaped.toggle() } else { escaped = false }
            }
            return output
        }.joined(separator: "\n")
    }

    private static func boundedImage(_ snapshot: NSImage, logicalSize: NSSize) throws -> (NSImage, Int) {
        guard let source = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw MarkdownResourceError.failed }
        let width = Double(source.width), height = Double(source.height)
        let scale = min(1, 2_048 / width, 3_072 / height, sqrt(Double(maximumSnapshotPixels) / (width * height)))
        if scale >= 1 { return (NSImage(cgImage: source, size: logicalSize), source.width * source.height) }
        // 显示器缩放可能在异步快照期间改变，最终以实际像素再检查一次。
        let outputWidth = max(1, Int(floor(width * scale))), outputHeight = max(1, Int(floor(height * scale)))
        guard let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MarkdownResourceError.failed }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        guard let image = context.makeImage() else { throw MarkdownResourceError.failed }
        return (NSImage(cgImage: image, size: logicalSize), image.width * image.height)
    }

    private func finish(_ result: Result<MarkdownRenderedResource, any Error>, request: UUID) {
        guard requestID == request, let continuation else { return }
        requestID = nil
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        key = nil
        if case .failure = result { discardHost() }
        else if !reusingHost { discardHost() }
        continuation.resume(with: result)
    }

    func close() {
        if let requestID { finish(.failure(CancellationError()), request: requestID) }
        else { discardHost() }
    }

    private func discardHost() {
        backend = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        window?.close()
        window = nil
    }

    private static let renderScript = #"""
    const output = document.getElementById('output');
    output.replaceChildren();
    output.removeAttribute('style');
    let baseline;
    if (diagram) {
      // 图表内 frontmatter / init 指令可改变配置，因此本预览不接受这两类指令。
      if (/^\s*---/.test(source) || /%%\s*\{/.test(source)) throw new Error('Configuration directives disabled');
      mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:dark?'dark':'default',
        htmlLabels:false, maxTextSize:50000, maxEdges:500, suppressErrorRendering:true,
        flowchart:{htmlLabels:false}, secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','htmlLabels']});
      const result = await mermaid.render('diagram', source);
      output.innerHTML = result.svg;
      const svg = output.querySelector('svg');
      if (!svg) throw new Error('Missing SVG');
      svg.querySelectorAll('script,image,a').forEach(node => node.remove());
      // sequenceDiagram 的 alt/else 条件仍用 foreignObject 排版。
      // 只保留文字并重建容器，既不执行输入 HTML，也不丢失分支标签。
      for (const foreign of svg.querySelectorAll('foreignObject')) {
        const original=foreign.firstElementChild;
        const label=original?.innerText ?? foreign.textContent ?? '';
        const style=getComputedStyle(original ?? foreign);
        const clean=document.createElementNS('http://www.w3.org/1999/xhtml','div');
        clean.textContent=label;
        clean.style.font=style.font; clean.style.color=style.color;
        clean.style.whiteSpace='pre-wrap'; clean.style.textAlign='center';
        clean.style.width='100%'; clean.style.height='100%';
        clean.style.display='flex'; clean.style.alignItems='center'; clean.style.justifyContent='center';
        foreign.replaceChildren(clean);
      }
      const box = svg.viewBox.baseVal;
      if (box.width && box.height) { svg.style.width = box.width+'px'; svg.style.height = box.height+'px'; svg.style.maxWidth='none'; }
    } else {
      katex.render(source, output, {displayMode:display, throwOnError:true, trust:false,
        strict:'ignore', maxSize:20, maxExpand:1000, output:'htmlAndMathml'});
      if (!display) { baseline = document.createElement('span'); baseline.id='baseline'; output.appendChild(baseline); }
    }
    await document.fonts.ready;
    await new Promise(resolve => setTimeout(resolve, 30));
    let rect=output.getBoundingClientRect();
    if (!Number.isFinite(rect.width) || !Number.isFinite(rect.height) || rect.width<=0 || rect.height<=0) throw new Error('Invalid output size');
    let descent=baseline ? rect.bottom-baseline.getBoundingClientRect().top : 0;
    // 大型合法图表先缩放 SVG，再生成有界位图；自然尺寸超限不等于语法错误。
    const scale=Math.min(1, 4096/rect.width, 4096/rect.height, Math.sqrt(3900000/(rect.width*rect.height)));
    if (scale<1) {
      output.style.transformOrigin='top left'; output.style.transform=`scale(${scale})`;
      rect=output.getBoundingClientRect(); descent*=scale;
    }
    return {width:rect.width, height:rect.height, descent};
    """#
}
