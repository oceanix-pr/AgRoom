import Foundation

// MARK: - Web Search Service

/// 联网检索单条结果（标题 + 链接 + 摘要）
public struct WebSearchResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// 检索通道抽象：技能生成流水线的联网检索环节按通道组织，
/// 引擎抓取通道（DuckDuckGo HTML）为首期实现；
/// provider 原生 web_search 透传作为二期通道接入同一协议
public protocol WebSearchChannel: Sendable {
    /// 按检索词返回结果列表（内部已过滤广告/无效链接）；
    /// 任何失败返回空数组，由调用方降级，绝不抛错阻断流水线
    func search(query: String) async -> [WebSearchResult]
}

/// 搜索引擎 HTML 端点抓取通道（DuckDuckGo html 版：无 JS、结果结构稳定）。
/// 注：不直接复用 WebFetchTool——其 stripHTML 剥掉所有标签时 href 一并丢失，
/// 拿不到结果链接，故此处独立解析（链接 + 标题 + 摘要）。
public struct DuckDuckGoSearchChannel: WebSearchChannel {

    /// 进程级缓存：query → (时间, 结果)。短 TTL 失效重查，避免澄清轮重复请求
    private static let cacheTTL: TimeInterval = 600
    private static let cacheLimit = 30
    private static let perQueryLimit = 8
    private final class CacheStore: @unchecked Sendable {
        var entries: [String: (date: Date, results: [WebSearchResult])] = [:]
        let lock = NSLock()
    }
    private static let cacheStore = CacheStore()

    public init() {}

    public func search(query: String) async -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let cached = Self.cachedResults(for: trimmed) { return cached }

        // html.duckduckgo.com/html/?q= 无 JS 即可返回结果页
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return []
        }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AgRoom", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? ""
        let results = Array(Self.parseResults(from: html).prefix(Self.perQueryLimit))
        Self.storeResults(results, for: trimmed)
        return results
    }

    // MARK: - Cache

    private static func cachedResults(for query: String) -> [WebSearchResult]? {
        cacheStore.lock.lock()
        defer { cacheStore.lock.unlock() }
        guard let entry = cacheStore.entries[query],
              Date().timeIntervalSince(entry.date) < cacheTTL else { return nil }
        return entry.results
    }

    private static func storeResults(_ results: [WebSearchResult], for query: String) {
        cacheStore.lock.lock()
        defer { cacheStore.lock.unlock() }
        cacheStore.entries[query] = (Date(), results)
        if cacheStore.entries.count > cacheLimit,
           let oldest = cacheStore.entries.min(by: { $0.value.date < $1.value.date })?.key {
            cacheStore.entries.removeValue(forKey: oldest)
        }
    }

    // MARK: - HTML Parsing

    /// 解析 DDG HTML 结果页：result__a 链接（含标题）+ result__snippet 摘要按序配对。
    /// 广告（y.js 跳转）与无法解包的链接被丢弃
    static func parseResults(from html: String) -> [WebSearchResult] {
        let links = Self.matchAnchors(html, cssClass: "result__a")
        let snippets = Self.matchAnchors(html, cssClass: "result__snippet")
        var results: [WebSearchResult] = []
        for (index, link) in links.enumerated() {
            let text = Self.stripTags(link.innerText)
            guard !text.isEmpty else { continue }
            guard let url = Self.resolvedURL(from: link.href) else { continue }
            let snippetText = index < snippets.count
                ? Self.stripTags(snippets[index].innerText)
                : ""
            results.append(WebSearchResult(
                title: String(text.prefix(200)),
                url: url,
                snippet: String(snippetText.prefix(400))
            ))
        }
        return results
    }

    /// 提取所有含指定 class 的 <a> 锚点（href + 内部文本）
    private static func matchAnchors(_ html: String, cssClass: String) -> [(href: String, innerText: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\b([^>]*\bclass="[^"]*\#(cssClass)[^"]*"[^>]*)>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var anchors: [(href: String, innerText: String)] = []
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges >= 3,
                  let attrsRange = Range(match.range(at: 1), in: html),
                  let innerRange = Range(match.range(at: 2), in: html) else { continue }
            let attrs = String(html[attrsRange])
            guard let href = Self.attributeValue(named: "href", in: attrs) else { continue }
            anchors.append((href, String(html[innerRange])))
        }
        return anchors
    }

    /// 从标签属性串中取属性值（容忍单双引号与实体编码）
    private static func attributeValue(named name: String, in attrs: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        ) else { return nil }
        let range = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              match.numberOfRanges >= 3 else { return nil }
        // 组 1 = 双引号值，组 2 = 单引号值；未参与匹配的组返回 nil
        let valueRange = Range(match.range(at: 1), in: attrs)
            ?? Range(match.range(at: 2), in: attrs)
        guard let valueRange else { return nil }
        return decodeHTMLEntities(String(attrs[valueRange]))
    }

    /// DDG 结果链接形如 //duckduckgo.com/l/?uddg=<百分号编码的目标URL>&rut=…；
    /// 解包 uddg 得到真实 URL；广告走 y.js 跳转，直接丢弃
    static func resolvedURL(from href: String) -> String? {
        var value = href
        if value.hasPrefix("//") { value = "https:" + value }
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased() else { return nil }
        if host.hasSuffix("duckduckgo.com") {
            if components.path.hasPrefix("/y.js") { return nil }
            if let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                return uddg.removingPercentEncoding ?? uddg
            }
            return nil
        }
        return value
    }

    /// 去标签 + 解码常见实体 + 压缩空白（搜索结果标题/摘要用）
    static func stripTags(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = Self.decodeHTMLEntities(text)
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}

/// 检索结果的合并与归一化（多查询/多通道 → Top-N 候选）
public enum WebSearchService {

    /// URL 归一化为去重键：补协议、域名小写、去尾斜杠、
    /// 剥离常见跟踪参数（utm_* / fbclid / gclid）后取 host+path+清洗后的 query
    public static func normalizeURL(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("//") { value = "https:" + value }
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased() else { return raw }
        var path = components.path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let exactTrackingParams: Set<String> = ["fbclid", "gclid", "msclkid", "ref", "rut"]
        let kept = (components.queryItems ?? []).filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !exactTrackingParams.contains(name)
        }
        var normalized = "\(host)\(path)"
        if !kept.isEmpty {
            normalized += "?" + kept
                .map { "\($0.name)=\($0.value ?? "")" }
                .sorted()
                .joined(separator: "&")
        }
        return normalized
    }

    /// RRF（倒数排名融合）合并：每条结果得分 = Σ 1/(60+排名)，
    /// 同一 URL 在多个查询/通道命中则累加——双源命中天然升权。
    /// 按融合分排序取前 limit 条；不足不硬凑
    public static func merge(_ resultLists: [[WebSearchResult]], limit: Int = 10) -> [WebSearchResult] {
        struct Accumulator {
            var result: WebSearchResult
            var score: Double
            var firstIndex: Int
        }
        var byKey: [String: Accumulator] = [:]
        var nextIndex = 0
        for list in resultLists {
            for (rank, item) in list.enumerated() {
                let key = normalizeURL(item.url)
                let score = 1.0 / Double(60 + rank)
                if var existing = byKey[key] {
                    existing.score += score
                    byKey[key] = existing
                } else {
                    byKey[key] = Accumulator(result: item, score: score, firstIndex: nextIndex)
                    nextIndex += 1
                }
            }
        }
        return byKey.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.firstIndex < rhs.firstIndex // 分数相同保持首次出现顺序
            }
            .prefix(limit)
            .map(\.result)
    }
}
