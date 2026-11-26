import AppKit
import SwiftUI
import WebKit

/// The mail document never navigates inside its WebView. Only a deliberate
/// click on a web link may leave the message, through the system browser.
enum MailHTMLNavigationDecision: Equatable {
    case allowInitialDocument
    case openExternally(URL)
    case cancel

    static func decide(url: URL?, navigationType: WKNavigationType,
                       isMainFrame: Bool, initialDocumentPending: Bool) -> Self {
        guard isMainFrame, let url else { return .cancel }
        if initialDocumentPending, navigationType == .other, url.absoluteString == "about:blank" {
            return .allowInitialDocument
        }
        guard navigationType == .linkActivated,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, !host.isEmpty, host != ".",
              parts.user == nil, parts.password == nil else { return .cancel }
        return .openExternally(url)
    }
}

// MARK: - Mail HTML View

/// 邮件正文渲染：用 `WKWebView` 展示 HTML 正文，无 HTML 时回退纯文本。
///
/// 安全约束（邮件正文内容不可信）：
/// - 禁用 JavaScript（`allowsContentJavaScript = false`）；
/// - 注入 CSP `default-src 'none'`，仅放行内联样式、`data:` 与当前邮件的 CID 图片，
///   远程图片与跟踪像素不会发起任何请求；
/// - `loadHTMLString(_:baseURL:)` 不传 baseURL，相对地址同样无法加载。
/// - 禁止正文内导航；用户主动点击的 HTTP(S) 链接在系统浏览器打开。
struct MailHTMLView: NSViewRepresentable {
    /// 服务器返回的 HTML 正文（可为空）。
    let html: String?
    /// 纯文本正文（无 HTML 时回退展示）。
    let text: String?
    var inlineImages: MailInlineImageSource? = nil
    var findQuery = ""
    var findRequest = UUID()
    var findBackwards = false
    var onFindResult: (@MainActor (Bool) -> Void)? = nil
    @AppStorage(ReadingTypography.preferenceKey) private var readingPointSize = ReadingTypography.defaultSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = .nonPersistent()
        if !WKWebView.handlesURLScheme("cid") { configuration.setURLSchemeHandler(context.coordinator.inlineHandler, forURLScheme: "cid") }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Keep transparent mail content on the same light paper as the host
        // card, including while WebKit is loading in a dark app appearance.
        webView.underPageBackgroundColor = .white
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Zoom also respects fixed inline font sizes. A size change must not reload the mail.
        let zoom = Double(ReadingTypography(pointSize: readingPointSize).pointSize) / Double(ReadingTypography.defaultSize)
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        let document = Self.document(html: html, text: text)
        context.coordinator.load(document: document, in: webView, inlineImages: inlineImages)
        context.coordinator.find(findQuery, request: findRequest, backwards: findBackwards, in: webView, onResult: onFindResult)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil; webView.stopLoading(); coordinator.inlineHandler.invalidate()
        coordinator.invalidateFind()
    }

    // MARK: - Coordinator

    /// Keep the blank-document permit until this load commits. A stale policy
    /// callback from the previous message must not consume the new load's permit.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let openExternal: @MainActor (URL) -> Void
        var rendered: String?
        var initialDocumentPending = false
        var currentNavigation: WKNavigation?
        let inlineHandler = MailInlineImageHandler()
        private var sourceID: UUID?
        private var sourceRevision: UUID?
        private var findGeneration = UUID()
        private var query = ""
        private var findRequest: UUID?
        private var backwards = false
        private weak var findView: WKWebView?
        private var onFind: (@MainActor (Bool) -> Void)?

        init(openExternal: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
            self.openExternal = openExternal
        }

        func load(document: String, in webView: WKWebView, inlineImages: MailInlineImageSource? = nil) {
            guard rendered != document || sourceID != inlineImages?.id || sourceRevision != inlineImages?.revision else { return }
            rendered = document
            findGeneration = UUID(); findRequest = nil
            sourceID = inlineImages?.id; sourceRevision = inlineImages?.revision
            webView.stopLoading()
            inlineHandler.invalidate(); inlineHandler.replaceSource(inlineImages)
            initialDocumentPending = true
            currentNavigation = webView.loadHTMLString(document, baseURL: nil)
        }

        func invalidateFind() { findGeneration = UUID(); onFind = nil; findView = nil }

        func find(_ value: String, request: UUID, backwards: Bool, in view: WKWebView, onResult: (@MainActor (Bool) -> Void)?) {
            guard query != value || findRequest != request else { return }
            if value.isEmpty && query.isEmpty { findRequest = request; return }
            query = String(value.prefix(4096)); findRequest = request; self.backwards = backwards
            onFind = onResult; findView = view
            if currentNavigation == nil { executeFind() }
        }

        private func executeFind() {
            guard let view = findView else { return }
            let generation = findGeneration, expected = findRequest
            let configuration = WKFindConfiguration(); configuration.backwards = backwards
            configuration.caseSensitive = false; configuration.wraps = true
            view.find(query, configuration: configuration) { [weak self] result in
                guard let self, self.findGeneration == generation, self.findRequest == expected else { return }
                self.onFind?(result.matchFound)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? navigationAction.sourceFrame.isMainFrame
            let decision = MailHTMLNavigationDecision.decide(url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                isMainFrame: isMainFrame, initialDocumentPending: initialDocumentPending)
            return policy(for: decision)
        }

        func policy(for decision: MailHTMLNavigationDecision) -> WKNavigationActionPolicy {
            switch decision {
            case .allowInitialDocument:
                return .allow
            case .openExternally(let url):
                openExternal(url)
                return .cancel
            case .cancel:
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let navigation, navigation === currentNavigation else { return }
            initialDocumentPending = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation, navigation === currentNavigation else { return }
            initialDocumentPending = false
            currentNavigation = nil
            executeFind()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            guard let navigation, navigation === currentNavigation else { return }
            initialDocumentPending = false
            currentNavigation = nil
        }
    }

    // MARK: - Document

    /// 组装可渲染文档：CSP + 基础排版样式置于最前，正文整体嵌入 body。
    /// 邮件自带的 `<html>/<head>/<body>` 标签会被 HTML 解析器合并忽略，
    /// 其 `<style>` 仍生效，但受限的 CSP 保证不会外联任何资源。
    static func document(html: String?, text: String?) -> String {
        let head = """
        <meta http-equiv="Content-Security-Policy" \
        content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; \
        font-src data:; media-src 'none'; object-src 'none'; frame-src 'none'; \
        base-uri 'none'; form-action 'none';">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html, body { background: transparent; }
        body {
            margin: 0; padding: 14px 16px;
            color: #202124;
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size: \(ReadingTypography.defaultSize)px; line-height: 1.55;
            word-break: break-word; overflow-wrap: anywhere;
            -webkit-text-size-adjust: 100%;
        }
        img { max-width: 100%; height: auto; }
        table { max-width: 100%; }
        pre { white-space: pre-wrap; word-break: break-word;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        blockquote { margin: 0 0 0 12px; padding-left: 10px; border-left: 2px solid rgba(127,127,127,0.35); }
        </style>
        """

        let content: String
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = html
        } else if let text, !text.isEmpty {
            // 兜底：无 HTML 部件、但文本内容其实是 HTML 源码时按 HTML 渲染。
            // 覆盖两类情况：发送端把整段 HTML 塞进 text/plain 部件；以及修复前
            // 已按原始 HTML 文本入库的缓存正文（无需重新下载即可正常显示）。
            // 信任级别与上面的 html 分支一致：同源、CSP 限制、JS 禁用。
            content = Self.looksLikeHTML(text) ? text : "<pre>\(escape(text))</pre>"
        } else {
            content = ""
        }
        return "<!DOCTYPE html><html><head>\(head)</head><body>\(content)</body></html>"
    }

    /// 判定字符串是否为 HTML 文档源码（保守：需以 `<` 开头且含明确的文档/结构标签）。
    private static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(2000).lowercased()
        let trimmed = head.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        guard trimmed.hasPrefix("<") else { return false }
        return ["<!doctype", "<html", "<head", "<body", "<div", "<table", "<meta", "<style"]
            .contains { trimmed.contains($0) }
    }

    /// 纯文本转义为安全 HTML。
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
