import AppKit
import ImageIO
import AgRoomCore

/// 值快照由入口注入；异步加载期间不查询可变的当前空间。
struct MarkdownSourceContext: Hashable, Sendable {
    var allowsRemoteMedia = true
    var spaceID = "unscoped"
    var baseURL: URL?
    var allowedRoots: [URL] = []
    var forbiddenRoots: [URL] = []

    @MainActor
    static func scoped(to space: AppSpace, baseURL: URL? = nil, additionalRoots: [URL] = []) -> Self {
        let files = FileAreaService.standard
        return Self(
            spaceID: space.rawValue, baseURL: baseURL,
            allowedRoots: [files.filesRoot] + files.defaultWriteRoots(for: space)
                + [files.defaultChatRoot(for: space)] + WorkspaceRegistry.shared.workspaces(for: space).map(\.url) + additionalRoots,
            forbiddenRoots: otherSpaceRoots(for: space)
        )
    }

    @MainActor
    static func conversation(space: AppSpace, workspace: ChatWorkspace?, dataPolicy: TaskDataPolicy = .configuredServices) -> Self {
        let workspace = workspace.flatMap { $0.space == space ? $0 : nil }
        let roots = workspace?.folderURLs ?? []
        return Self(allowsRemoteMedia: dataPolicy == .configuredServices, spaceID: space.rawValue,
                    baseURL: workspace?.url, allowedRoots: roots,
                    forbiddenRoots: otherSpaceRoots(for: space) + roots.map { $0.appendingPathComponent(".agroom-runs") })
    }

    @MainActor
    private static func otherSpaceRoots(for space: AppSpace) -> [URL] {
        let files = FileAreaService.standard
        let applicationRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgRoom")
        return AppSpace.allCases.filter { $0 != space }.flatMap {
            files.defaultWriteRoots(for: $0) + [files.defaultChatRoot(for: $0), applicationRoot.appendingPathComponent($0.rawValue)]
        }
    }

    func resolveImage(_ source: String) throws -> URL {
        guard !source.isEmpty, source.utf8.count <= 8_192 else { throw MarkdownResourceError.invalid }
        if let url = URL(string: source), let scheme = url.scheme, scheme.lowercased() != "file" {
            guard allowsRemoteMedia else { throw MarkdownResourceError.denied }
            try Self.validateRemote(url)
            return url
        }
        let url: URL
        if source.hasPrefix("file:") {
            guard let file = URL(string: source), file.isFileURL, file.host == nil || file.host == "" || file.host == "localhost" else {
                throw MarkdownResourceError.invalid
            }
            url = file
        } else if source.hasPrefix("/") {
            url = URL(fileURLWithPath: source.removingPercentEncoding ?? source)
        } else {
            guard let baseURL, baseURL.isFileURL else { throw MarkdownResourceError.invalid }
            url = baseURL.appendingPathComponent(source.removingPercentEncoding ?? source)
        }
        let resolved = Self.canonical(url)
        func contains(_ roots: [URL]) -> Bool {
            roots.contains { root in
                let path = Self.canonical(root).path
                return resolved.path == path || resolved.path.hasPrefix(path + "/")
            }
        }
        guard !contains(forbiddenRoots), contains(allowedRoots) else { throw MarkdownResourceError.denied }
        return resolved
    }

    private static func canonical(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        // Foundation 对不存在的整条路径不保证解析中间符号链接。
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { result.appendPathComponent(component) }
        return result.standardizedFileURL
    }

    static func validateRemote(_ url: URL) throws {
        guard url.host != nil, url.user == nil, url.password == nil else { throw MarkdownResourceError.denied }
        try EndpointSafety.validate(url.absoluteString)
    }
}

enum MarkdownResourceError: Error, Sendable {
    case invalid, denied, tooLarge, failed, timedOut

    var messageKey: String {
        switch self {
        case .tooLarge: "md.resource.too_large"
        case .timedOut: "md.resource.timeout"
        case .invalid: "md.resource.invalid"
        default: "md.resource.failed"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .invalid: "invalid"
        case .denied: "denied"
        case .tooLarge: "too_large"
        case .failed: "failed"
        case .timedOut: "timeout"
        }
    }
}

enum MarkdownResourceKey: Hashable {
    case image(String)
    case math(MarkdownMath)
    case mermaid(String)
}

@MainActor
struct MarkdownRenderedResource {
    let image: NSImage
    let vectorPDF: Data?
    let vectorImage: NSImage?
    var displayImage: NSImage { vectorImage ?? image }
    /// 基线距离底边的高度，用于 TextKit 行内公式。
    var descent: CGFloat = 0
    let pixelCount: Int

    init(image: NSImage, descent: CGFloat = 0, pixelCount: Int? = nil, vectorPDF: Data? = nil) {
        self.image = image
        self.vectorPDF = vectorPDF
        let vector = vectorPDF.flatMap { NSImage(data: $0) }
        vector?.size = image.size
        self.vectorImage = vector
        self.descent = descent
        if let pixelCount { self.pixelCount = pixelCount }
        else if let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.pixelCount = bitmap.width * bitmap.height
        } else { self.pixelCount = 0 }
    }

    func attachment(maxWidth: CGFloat, maxHeight: CGFloat, scale: CGFloat = 1) -> NSAttributedString {
        let size = image.size
        let ratio = min(scale, maxWidth / max(1, size.width), maxHeight / max(1, size.height))
        let attachment = MarkdownTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -descent * ratio, width: size.width * ratio, height: size.height * ratio)
        return NSAttributedString(attachment: attachment)
    }
}

@MainActor
private final class MarkdownTextAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let size = bounds.size
        guard size.width > 0, lineFrag.width.isFinite, lineFrag.width > 0 else { return bounds }
        let scale = min(1, lineFrag.width / size.width)
        return NSRect(x: bounds.origin.x, y: bounds.origin.y * scale, width: size.width * scale, height: size.height * scale)
    }
}

final class MarkdownImageSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? MarkdownSourceContext.validateRemote(url)) != nil else { completionHandler(nil); return }
        var clean = URLRequest(url: url)
        clean.timeoutInterval = 15
        completionHandler(clean)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .rejectProtectionSpace, nil)
    }
}

/// 文档私有的顺序加载器，不保留 URLSession 磁盘缓存、Cookie 或登录凭据。
actor MarkdownImageLoader {
    static let maximumBytes = 10 * 1_024 * 1_024

    func decodeImage(_ data: Data) throws -> CGImage { try Self.decode(data) }

    func load(_ source: String, context: MarkdownSourceContext) async throws -> Data {
        try Task.checkCancellation()
        let url = try context.resolveImage(source)
        if url.isFileURL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw MarkdownResourceError.invalid }
            guard (values.fileSize ?? Int.max) <= Self.maximumBytes else { throw MarkdownResourceError.tooLarge }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw MarkdownResourceError.tooLarge }
            try Task.checkCancellation()
            return data
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: MarkdownImageSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true else { throw MarkdownResourceError.invalid }
        guard response.expectedContentLength <= Self.maximumBytes else { throw MarkdownResourceError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            guard data.count < Self.maximumBytes else { throw MarkdownResourceError.tooLarge }
            data.append(byte)
        }
        return data
    }

    /// 先读像素元数据，再限尺寸解码；不让压缩炸弹分配原始整图内存。
    nonisolated static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              Double(width) * Double(height) <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_536
              ] as CFDictionary) else { throw MarkdownResourceError.invalid }
        return image
    }
}

extension NSAttributedString.Key {
    static let markdownAlternative = Self("AgRoomMarkdownAlternative")
}

struct MarkdownResourcePlan {
    private struct Page: Hashable {
        let table: Int
        let index: Int
    }

    private struct Use: Hashable {
        let key: MarkdownResourceKey
        let page: Page?
    }

    struct Table {
        let header: [[MarkdownInline]]
        let pageCount: Int
    }

    private let uses: [Use]
    let allowed: Set<MarkdownResourceKey>
    let tables: [Table]

    init(_ blocks: [MarkdownBlock], includeTableCells: Bool = true) {
        var uses: [Use] = [], seen: Set<Use> = []
        var allowed: Set<MarkdownResourceKey> = [], tables: [Table] = []
        func add(_ key: MarkdownResourceKey, on page: Page? = nil) {
            let use = Use(key: key, page: page)
            if seen.insert(use).inserted { uses.append(use) }
            if allowed.count < 64 { allowed.insert(key) }
        }
        func walk(_ nodes: [MarkdownBlock]) {
            for node in nodes {
                switch node.content {
                case .paragraph(let children):
                    if MarkdownMediaReference(children) == nil { Self.visitInline(children) { add($0) } }
                case .heading(_, let children): Self.visitInline(children) { add($0) }
                case .math(let math): add(.math(math))
                case .code(let code) where code.language.lowercased() == "mermaid" && code.isClosed: add(.mermaid(code.code))
                case .table(let table) where includeTableCells:
                    let ordinal = tables.count
                    tables.append(Table(header: table.header, pageCount: table.pageCount))
                    let columns = table.previewColumnCount, pageSize = table.rowsPerPage
                    for cell in table.header.prefix(columns) { Self.visitInline(cell) { add($0) } }
                    for (index, row) in table.rows.prefix(table.previewRowCount).enumerated() {
                        let page = Page(table: ordinal, index: index / pageSize)
                        for cell in row.prefix(columns) { Self.visitInline(cell) { add($0, on: page) } }
                    }
                case .list(_, let items): for item in items { walk(item.blocks) }
                case .quote(let children): walk(children)
                default: break
                }
            }
        }
        walk(blocks)
        self.uses = uses
        self.allowed = allowed
        self.tables = tables
    }

    func visibleKeys(tablePages: [Int: Int]) -> [MarkdownResourceKey] {
        var seen: Set<MarkdownResourceKey> = []
        return uses.compactMap { use in
            if let page = use.page, page.index != tablePages[page.table, default: 0] { return nil }
            return seen.insert(use.key).inserted ? use.key : nil
        }
    }

    static func keys(in blocks: [MarkdownBlock], includeTableCells: Bool = true) -> [MarkdownResourceKey] {
        Self(blocks, includeTableCells: includeTableCells).visibleKeys(tablePages: [:])
    }

    static func visitInline(_ nodes: [MarkdownInline], _ visit: (MarkdownResourceKey) -> Void) {
        for node in nodes {
            switch node.content {
            case .math(let math): visit(.math(math))
            case .image(let source, _, _): if let source { visit(.image(source)) }
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, _, let children):
                visitInline(children, visit)
            default: break
            }
        }
    }
}
