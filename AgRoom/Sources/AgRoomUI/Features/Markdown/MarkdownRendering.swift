import AppKit
import Observation
import os.signpost
import AgRoomCore

struct MarkdownBlockContext: Equatable {
    var indent: CGFloat = 0
    var quoteIndents: [CGFloat] = []
}

/// One contiguous selection, backed by the immutable outputs of its individual blocks.
@MainActor
final class MarkdownProse {
    struct Prefix {
        var count = 0
        var length = 0   // UTF-16, including the separators between matched parts
    }

    let parts: [NSAttributedString]
    private weak var previous: MarkdownProse?
    private let previousPrefix: Prefix
    private(set) lazy var attributedString = suffix(from: 0)

    init(parts: [NSAttributedString], previous: MarkdownProse? = nil, prefix: Prefix = Prefix()) {
        self.parts = parts
        self.previous = previous
        previousPrefix = prefix
    }

    func matchingPrefix(of newParts: [NSAttributedString]) -> Prefix {
        var prefix = Prefix()
        for (old, new) in zip(parts, newParts) {
            guard old === new else { break }
            prefix.length += old.length + (prefix.count == 0 ? 0 : 1)
            prefix.count += 1
        }
        return prefix
    }

    func prefix(sharedWith displayed: MarkdownProse?) -> Prefix {
        guard let displayed else { return Prefix() }
        // SwiftUI can skip revisions or remount the view. Only use a cached
        // offset when the view actually holds the corresponding old revision.
        return previous === displayed ? previousPrefix : displayed.matchingPrefix(of: parts)
    }

    func suffix(from index: Int) -> NSAttributedString {
        if index == 0, parts.count == 1 { return parts[0] }
        let text = NSMutableAttributedString()
        for i in index..<parts.count {
            if i > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(parts[i])
        }
        return NSAttributedString(attributedString: text)
    }
}

@MainActor
enum MarkdownSegment {
    case prose(MarkdownProse)
    case codeBlock(MarkdownCode, context: MarkdownBlockContext)
    case math(MarkdownMath, context: MarkdownBlockContext)
    case image(source: String, alt: String, context: MarkdownBlockContext)
    case media(source: String, name: String, context: MarkdownBlockContext)
    case table(MarkdownTable, context: MarkdownBlockContext, ordinal: Int)
    case divider(context: MarkdownBlockContext)

    var identity: String {
        switch self {
        case .prose: return "prose"
        case .codeBlock: return "code"
        case .math: return "math"
        case .image: return "image"
        case .media(let source, _, _): return "media:" + source
        case .table: return "table"
        case .divider: return "divider"
        }
    }

    static func segments(from blocks: [MarkdownBlock], resources: [MarkdownResourceKey: MarkdownRenderedResource] = [:], failed: Set<MarkdownResourceKey> = [], typography: ReadingTypography = ReadingTypography()) -> [MarkdownSegment] {
        var builder = MarkdownSegmentBuilder(resources: resources, failed: failed, typography: typography)
        builder.append(blocks, context: MarkdownBlockContext())
        return builder.finish()
    }
}

/// 每个文档视图持有自己的两项缓存，既不共享空间内容，也不积攒流式快照。
@MainActor
final class MarkdownRenderCache {
    private var final: (source: String, bodyOffset: Int, typography: ReadingTypography, segments: [MarkdownSegment])?
    private var intermediate: (source: String, bodyOffset: Int, typography: ReadingTypography, segments: [MarkdownSegment])?

    func segments(for document: MarkdownDocument, streaming: Bool = false, typography: ReadingTypography = ReadingTypography()) -> [MarkdownSegment] {
        let cached = streaming ? intermediate : final
        if let cached, cached.source == document.source, cached.bodyOffset == document.bodyOffset, cached.typography == typography { return cached.segments }
        let segments = MarkdownSegment.segments(from: document.blocks, typography: typography)
        // 超大源码仍可阅读，但不额外保留双份渲染缓存。
        if document.source.utf8.count <= MarkdownParser.maximumSourceBytes {
            if streaming { intermediate = (document.source, document.bodyOffset, typography, segments) }
            else { final = (document.source, document.bodyOffset, typography, segments); intermediate = nil }
        }
        return segments
    }
}

/// Instruments intervals contain timings and byte counts only. Each run has its own correlation ID.
enum MarkdownTiming {
    static let log = OSLog(subsystem: "com.agroom.app", category: .pointsOfInterest)
}

@MainActor
final class MarkdownFirstFrame {
    private var pending: OSSignpostID?
    private var documentID: String?

    func begin(documentID: String) {
        guard MarkdownTiming.log.signpostsEnabled, self.documentID != documentID else { return }
        if let pending { os_signpost(.end, log: MarkdownTiming.log, name: "Markdown first draw", signpostID: pending, "superseded") }
        let id = OSSignpostID(log: MarkdownTiming.log)
        pending = id
        self.documentID = documentID
        os_signpost(.begin, log: MarkdownTiming.log, name: "Markdown first draw", signpostID: id)
    }

    func displayed(documentID: String) {
        guard self.documentID == documentID, let pending else { return }
        os_signpost(.end, log: MarkdownTiming.log, name: "Markdown first draw", signpostID: pending)
        self.pending = nil
    }

    func disappear(documentID: String) {
        guard self.documentID == documentID else { return }
        if let pending { os_signpost(.end, log: MarkdownTiming.log, name: "Markdown first draw", signpostID: pending, "view closed") }
        pending = nil
        self.documentID = nil
    }
}

/// 顺序解析；等待进入 actor 的旧任务会在真正解析前检查取消。
actor MarkdownParsingWorker {
    private var lastParseStart: ContinuousClock.Instant?
    private var pendingRequest = UUID()
    private(set) var parseCount = 0
    private(set) var parsedBytes = 0
    private(set) var lastDuration: Duration = .zero
    private var interval: Duration { min(.milliseconds(400), max(.milliseconds(100), lastDuration * 2)) }
    func parse(_ source: String, strippingFrontmatter: Bool = false, streaming: Bool = false) async -> MarkdownDocument? {
        guard !Task.isCancelled else { return nil }
        let request = UUID()
        pendingRequest = request
        if streaming, let lastParseStart {
            do { try await ContinuousClock().sleep(until: lastParseStart.advanced(by: interval)) }
            catch { return nil }
        }
        guard !Task.isCancelled, pendingRequest == request else { return nil }
        let started = ContinuousClock.now
        lastParseStart = started
        parseCount += 1
        let bytes = source.utf8.count
        parsedBytes += bytes
        let id = OSSignpostID(log: MarkdownTiming.log)
        os_signpost(.begin, log: MarkdownTiming.log, name: "Markdown parse", signpostID: id, "bytes %ld", bytes)
        defer {
            lastDuration = started.duration(to: .now)
            os_signpost(.end, log: MarkdownTiming.log, name: "Markdown parse", signpostID: id)
        }
        let document = MarkdownParser.parse(source, strippingFrontmatter: strippingFrontmatter)
        return Task.isCancelled ? nil : document
    }
}

struct MarkdownRenderRequest: Hashable {
    let text: String
    var streaming = false
    var documentID = ""
    var strippingFrontmatter = false
    var context = MarkdownSourceContext()
    var dark = false
    var retryRevision = 0
    var typography = ReadingTypography()

    func continues(_ previous: Self) -> Bool {
        streaming && previous.streaming && documentID == previous.documentID && context == previous.context
            && strippingFrontmatter == previous.strippingFrontmatter && dark == previous.dark
            && retryRevision == previous.retryRevision && typography == previous.typography
            && text.utf8.starts(with: previous.text.utf8)
    }
}

@MainActor @Observable
final class MarkdownRenderModel {
    let firstFrame = MarkdownFirstFrame()
    @ObservationIgnored private var blockCache = MarkdownBlockRenderCache()
    private(set) var segments: [MarkdownSegment] = []
    private(set) var documentID: String?
    private(set) var hasRenderedSnapshot = false
    private(set) var resources: [MarkdownResourceKey: MarkdownRenderedResource] = [:]
    private(set) var failedResources: Set<MarkdownResourceKey> = []
    private(set) var resourceErrors: [MarkdownResourceKey: MarkdownResourceError] = [:]
    private(set) var context = MarkdownSourceContext()
    private(set) var dark = false
    private(set) var typography = ReadingTypography()
    @ObservationIgnored private let imageLoader = MarkdownImageLoader()
    @ObservationIgnored private var allocatedPixels = 0
    @ObservationIgnored private var allocatedVectorBytes = 0
    private(set) var resourceRequestID = UUID()
    private(set) var tablePages: [Int: Int] = [:]
    @ObservationIgnored private var resourcePlan = MarkdownResourcePlan([])
    @ObservationIgnored private var resourceKeys: [MarkdownResourceKey] = []
    @ObservationIgnored private var overLimit: Set<MarkdownResourceKey> = []
    private struct ResourceLoad {
        let id = UUID()
        let key: MarkdownResourceKey
        let task: Task<MarkdownRenderedResource, any Error>
    }
    @ObservationIgnored private var inFlight: ResourceLoad?
    @ObservationIgnored private var currentBlocks: [MarkdownBlock] = []
    private var requestID: UUID?
    private var source: String?
    private var wasStreaming = false
    private var stripsFrontmatter = false
    typealias Parser = @Sendable (String, Bool, Bool) async -> MarkdownDocument?
    @ObservationIgnored private let parse: Parser
    @ObservationIgnored private var latestStreamRequest: MarkdownRenderRequest?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var parsedDocument: MarkdownDocument?
    typealias ResourceLoader = @MainActor (MarkdownResourceKey, MarkdownSourceContext, Bool) async throws -> MarkdownRenderedResource
    @ObservationIgnored private let resourceLoader: ResourceLoader?
    init(resourceLoader: ResourceLoader? = nil, parse: Parser? = nil) {
        self.resourceLoader = resourceLoader
        let worker = MarkdownParsingWorker()
        self.parse = parse ?? { await worker.parse($0, strippingFrontmatter: $1, streaming: $2) }
    }

    /// An append may arrive before parsing finishes. Publish that valid prefix
    /// and then consume only the latest queued append. An edit or scope change
    /// cancels the old stream immediately, as does switching to the final text.
    func present(_ request: MarkdownRenderRequest) async {
        guard !Task.isCancelled else { return }
        if let previous = latestStreamRequest, request.continues(previous) {
            latestStreamRequest = request
            return
        }
        stopStreaming()
        guard request.streaming else { await apply(request); return }
        latestStreamRequest = request
        streamTask = Task { [weak self] in
            while !Task.isCancelled, let next = self?.latestStreamRequest {
                await self?.apply(next)
                guard !Task.isCancelled else { return }
                if self?.latestStreamRequest == next { self?.latestStreamRequest = nil }
            }
            if !Task.isCancelled { self?.streamTask = nil }
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        latestStreamRequest = nil
    }

    private func apply(_ r: MarkdownRenderRequest) async {
        await update(r.text, documentID: r.documentID, streaming: r.streaming, strippingFrontmatter: r.strippingFrontmatter,
                     context: r.context, dark: r.dark, retryRevision: r.retryRevision, typography: r.typography, loadingResources: false)
    }

    func update(_ source: String, documentID: String, streaming: Bool, strippingFrontmatter: Bool = false, context: MarkdownSourceContext = MarkdownSourceContext(), dark: Bool = false, retryRevision: Int = 0, typography: ReadingTypography = ReadingTypography(), loadingResources: Bool = true) async {
        guard !Task.isCancelled else { return }
        firstFrame.begin(documentID: documentID)
        let request = UUID()
        requestID = request
        if self.documentID == documentID, self.source == source, wasStreaming == streaming,
           stripsFrontmatter == strippingFrontmatter, self.context == context, self.dark == dark,
           hasRenderedSnapshot, resourcesFinished, self.retryRevision == retryRevision, self.typography == typography { return }
        if self.documentID != documentID || stripsFrontmatter != strippingFrontmatter || self.context != context || self.dark != dark {
            self.documentID = documentID
            self.source = nil
            segments = []
            hasRenderedSnapshot = false
            blockCache = MarkdownBlockRenderCache()
            parsedDocument = nil
            resourceKeys = []; currentBlocks = []; tablePages = [:]; overLimit = []; resourcePlan = MarkdownResourcePlan([])
            invalidateResourceLoad()
            resources = [:]
            failedResources = []
            resourceErrors = [:]
            allocatedPixels = 0
            allocatedVectorBytes = 0
        }
        if self.retryRevision != retryRevision {
            failedResources = []; resourceErrors = [:]; overLimit = []
            if inFlight == nil { resourceRequestID = UUID() }
        }
        self.retryRevision = retryRevision
        self.context = context
        self.dark = dark
        stripsFrontmatter = strippingFrontmatter
        let previousAllowed = resourcePlan.allowed
        let document: MarkdownDocument
        if let parsedDocument, parsedDocument.source == source {
            document = parsedDocument
        } else {
            guard let parsed = await parse(source, strippingFrontmatter, streaming), !Task.isCancelled,
                  requestID == request, self.documentID == documentID else { return }
            document = parsed
            parsedDocument = source.utf8.count <= MarkdownParser.maximumSourceBytes ? parsed : nil
            let plan = MarkdownResourcePlan(parsed.blocks)
            if !tablePages.isEmpty {
                let pages = tablePages.reduce(into: [Int: Int]()) { pages, entry in
                    let index = entry.key
                    guard resourcePlan.tables.indices.contains(index), plan.tables.indices.contains(index),
                          plan.tables[index].pageCount > 1,
                          plan.tables[index].header == resourcePlan.tables[index].header else { return }
                    pages[index] = min(entry.value, plan.tables[index].pageCount - 1)
                }
                if pages != tablePages { tablePages = pages }
            }
            resourcePlan = plan
        }
        currentBlocks = document.blocks
        self.typography = typography
        updateResourcePlan(eligibilityChanged: previousAllowed != resourcePlan.allowed)
        renderCurrentBlocks()
        self.source = source
        wasStreaming = streaming
        hasRenderedSnapshot = true
        if loadingResources { await loadResources() }
    }

    func setTablePage(_ proposed: Int, for ordinal: Int) {
        guard resourcePlan.tables.indices.contains(ordinal) else { return }
        let page = min(max(proposed, 0), resourcePlan.tables[ordinal].pageCount - 1)
        guard page != tablePages[ordinal, default: 0] else { return }
        tablePages[ordinal] = page == 0 ? nil : page
        updateResourcePlan()
        renderCurrentBlocks()
    }

    private func updateResourcePlan(eligibilityChanged: Bool = false) {
        let visible = resourcePlan.visibleKeys(tablePages: tablePages)
        let allowed = resourcePlan.allowed
        let keys = visible.filter { allowed.contains($0) }
        let excluded = Set(visible).subtracting(allowed)
        guard eligibilityChanged || keys != resourceKeys || excluded != overLimit else { return }
        if keys != resourceKeys {
            resourceKeys = keys
            if inFlight.map({ keys.contains($0.key) }) != true { invalidateResourceLoad() }
        }
        failedResources.subtract(overLimit)
        for key in overLimit { resourceErrors[key] = nil }
        overLimit = excluded
        resources = resources.filter { allowed.contains($0.key) }
        failedResources.formIntersection(allowed)
        resourceErrors = resourceErrors.filter { allowed.contains($0.key) }
        failedResources.formUnion(excluded)
        for key in excluded { resourceErrors[key] = .tooLarge }
        allocatedPixels = resources.values.reduce(0) { total, resource in total + resource.pixelCount }
        allocatedVectorBytes = resources.values.reduce(0) { $0 + ($1.vectorPDF?.count ?? 0) }
    }

    private func invalidateResourceLoad() {
        inFlight?.task.cancel()
        inFlight = nil
        resourceRequestID = UUID()
    }

    private func renderCurrentBlocks() {
        segments = blockCache.segments(currentBlocks, resources: resources, failed: failedResources, typography: typography)
    }

    /// Re-read the visible plan after each completion. Appending another key
    /// preserves the active task; removing its key or changing scope cancels it.
    func loadResources() async {
        let request = resourceRequestID
        let renderer = MarkdownWebRenderer(reusingHost: true)
        defer { renderer.close() }
        while !Task.isCancelled, resourceRequestID == request,
              let key = inFlight?.key ?? resourceKeys.first(where: { resources[$0] == nil && !failedResources.contains($0) }) {
            let load: ResourceLoad
            if let inFlight { load = inFlight }
            else {
                let task = Task { [context, dark, resourceLoader, imageLoader] in
                    if let resourceLoader { return try await resourceLoader(key, context, dark) }
                    switch key {
                    case .image(let source):
                        let data = try await imageLoader.load(source, context: context)
                        let image = try await imageLoader.decodeImage(data)
                        return MarkdownRenderedResource(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), pixelCount: image.width * image.height)
                    case .math, .mermaid:
                        return try await renderer.render(key, dark: dark)
                    }
                }
                load = ResourceLoad(key: key, task: task)
                inFlight = load
            }
            let result = await withTaskCancellationHandler {
                await load.task.result
            } onCancel: { load.task.cancel() }
            guard resourceRequestID == request, inFlight?.id == load.id else { continue }
            inFlight = nil
            guard !Task.isCancelled, !load.task.isCancelled else { continue }
            do {
                var resource = try result.get()
                guard allocatedPixels + resource.pixelCount <= 16_000_000 else { throw MarkdownResourceError.tooLarge }
                if allocatedVectorBytes + (resource.vectorPDF?.count ?? 0) > 16 * 1_024 * 1_024 {
                    resource = MarkdownRenderedResource(image: resource.image, descent: resource.descent, pixelCount: resource.pixelCount)
                }
                resources[key] = resource
                allocatedVectorBytes += resource.vectorPDF?.count ?? 0
                allocatedPixels += resource.pixelCount
            } catch {
                guard !Task.isCancelled, resourceRequestID == request else { return }
                failedResources.insert(key)
                let reason = error as? MarkdownResourceError ?? .failed
                resourceErrors[key] = reason
                let kind: String
                switch key { case .image: kind = "image"; case .math: kind = "math"; case .mermaid: kind = "mermaid" }
                // 不记录 URL、公式、图表源码或包含源码的 JavaScript 异常详情。
                HubLogger.shared.warning("Markdown preview failed: kind=\(kind), reason=\(reason.diagnosticCode)")
            }
            // 新建不可变附件与 attributed string，让显示和测量同时失效。
            renderCurrentBlocks()
        }
    }

    private var resourcesFinished: Bool { resourceKeys.allSatisfy { resources[$0] != nil || failedResources.contains($0) } }
    var canRetryResources: Bool { resourceKeys.contains(where: failedResources.contains) }
    @ObservationIgnored private var retryRevision = 0
}

@MainActor
final class MarkdownBlockRenderCache {
    private struct Entry {
        let block: MarkdownBlock
        let typography: ReadingTypography
        let keys: Set<MarkdownResourceKey>
        let images: [MarkdownResourceKey: ObjectIdentifier]
        let failed: Set<MarkdownResourceKey>
        let segments: [MarkdownSegment]
    }
    private var entries: [Int: Entry] = [:]
    private(set) var rebuildCount = 0
    private var merged: [MarkdownSegment] = []
    private var proseRuns: [Int: MarkdownProse] = [:]
    func segments(_ blocks: [MarkdownBlock], resources: [MarkdownResourceKey: MarkdownRenderedResource],
                  failed: Set<MarkdownResourceKey>, typography: ReadingTypography) -> [MarkdownSegment] {
        var partsToMerge: [[MarkdownSegment]] = []
        var changed = entries.count != blocks.count
        if entries.count > blocks.count {
            for index in blocks.count..<entries.count { entries[index] = nil }
        }
        for (index, block) in blocks.enumerated() {
            let previous = entries[index].flatMap { $0.block == block ? $0 : nil }
            let keys = previous?.keys ?? Set(MarkdownResourcePlan.keys(in: [block], includeTableCells: false))
            let images = Dictionary(uniqueKeysWithValues: keys.compactMap { key in resources[key].map { (key, ObjectIdentifier($0.image)) } })
            let failures = failed.intersection(keys)
            let parts: [MarkdownSegment]
            if let entry = previous, entry.typography == typography,
               entry.images == images, entry.failed == failures { parts = entry.segments }
            else {
                parts = MarkdownSegment.segments(from: [block], resources: resources, failed: failed, typography: typography)
                entries[index] = Entry(block: block, typography: typography, keys: keys, images: images, failed: failures, segments: parts)
                rebuildCount += 1
                changed = true
            }
            partsToMerge.append(parts)
        }
        if changed { merged = merge(partsToMerge) }
        return merged
    }

    private func merge(_ groups: [[MarkdownSegment]]) -> [MarkdownSegment] {
        var result: [MarkdownSegment] = [], pending: [NSAttributedString] = []
        var next: [Int: MarkdownProse] = [:]
        var run = 0, tableIndex = 0
        func flush() {
            guard !pending.isEmpty else { return }
            let old = proseRuns[run]
            let prefix = old?.matchingPrefix(of: pending) ?? .init()
            let text: MarkdownProse
            if let old, prefix.count == old.parts.count, prefix.count == pending.count { text = old }
            else { text = MarkdownProse(parts: pending, previous: old, prefix: prefix) }
            next[run] = text
            result.append(.prose(text))
            run += 1; pending.removeAll(keepingCapacity: true)
        }
        for segment in groups.joined() {
            if case .prose(let text) = segment { pending.append(contentsOf: text.parts) }
            else {
                flush()
                if case .table(let table, let context, _) = segment {
                    result.append(.table(table, context: context, ordinal: tableIndex))
                    tableIndex += 1
                } else { result.append(segment) }
            }
        }
        flush(); proseRuns = next
        return result
    }
}

@MainActor
enum MarkdownAttributedStringBuilder {
    struct Style {
        var size: CGFloat = ReadingTypography().bodySize
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var color: NSColor = .labelColor
        var link: URL?
        var resources: [MarkdownResourceKey: MarkdownRenderedResource] = [:]
        var failed: Set<MarkdownResourceKey> = []
    }

    static func inline(_ nodes: [MarkdownInline], style: Style = Style()) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for node in nodes {
            var childStyle = style
            switch node.content {
            case .text(let text): output.append(literal(text, style: style))
            case .softBreak: output.append(literal(" ", style: style))
            // TextKit 段内换行，避免列表 / 引用续行重新应用首行缩进。
            case .hardBreak: output.append(literal("\u{2028}", style: style))
            case .code(let text):
                childStyle.code = true
                output.append(literal(text, style: childStyle))
            case .emphasis(let children):
                childStyle.italic = true
                output.append(inline(children, style: childStyle))
            case .strong(let children):
                childStyle.bold = true
                output.append(inline(children, style: childStyle))
            case .strikethrough(let children):
                childStyle.strike = true
                output.append(inline(children, style: childStyle))
            case .link(let destination, _, let children):
                if let destination, let url = URL(string: destination),
                   let scheme = url.scheme?.lowercased(), ["https", "http", "mailto", "agroom-mail"].contains(scheme) {
                    childStyle.link = url
                }
                output.append(inline(children, style: childStyle))
            case .math(let math):
                if let resource = style.resources[.math(math)] {
                    let attachment = NSMutableAttributedString(attributedString: resource.attachment(maxWidth: 320, maxHeight: 120, scale: style.size / 13))
                    attachment.addAttribute(.markdownAlternative, value: math.source, range: NSRange(location: 0, length: attachment.length))
                    output.append(attachment)
                } else { output.append(literal(math.source, style: style)) }
            case .image(let source, _, let alt):
                let text = alt.map(\.plainText).joined()
                let alternative = text.isEmpty ? L.string("md.image") : text
                let key = MarkdownResourceKey.image(source ?? "")
                if let resource = style.resources[key] {
                    let attachment = NSMutableAttributedString(attributedString: resource.attachment(maxWidth: 160, maxHeight: 100))
                    attachment.addAttribute(.markdownAlternative, value: alternative, range: NSRange(location: 0, length: attachment.length))
                    output.append(attachment)
                } else {
                    let status = L.string(style.failed.contains(key) ? "md.resource.failed" : "md.resource.loading")
                    output.append(literal("[" + alternative + " · " + status + "]", style: style))
                }
            }
        }
        return output
    }

    static func literal(_ text: String, style: Style) -> NSAttributedString {
        let weight: NSFont.Weight = style.bold ? .bold : .regular
        let base = style.code ? NSFont.monospacedSystemFont(ofSize: style.size, weight: weight)
            : NSFont.systemFont(ofSize: style.size, weight: weight)
        let font = style.italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color]
        if style.code { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link { attributes[.link] = link }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

@MainActor
private struct MarkdownSegmentBuilder {
    private struct Marker {
        let text: String
        let position: CGFloat
    }

    let resources: [MarkdownResourceKey: MarkdownRenderedResource]
    let failed: Set<MarkdownResourceKey>
    let typography: ReadingTypography
    private var result: [MarkdownSegment] = []
    private var tableIndex = 0

    init(resources: [MarkdownResourceKey: MarkdownRenderedResource], failed: Set<MarkdownResourceKey>, typography: ReadingTypography) {
        self.resources = resources
        self.failed = failed
        self.typography = typography
    }
    private var prose = NSMutableAttributedString()
    mutating func append(_ blocks: [MarkdownBlock], context: MarkdownBlockContext) {
        append(blocks, context: context, marker: nil)
    }

    private mutating func append(_ blocks: [MarkdownBlock], context: MarkdownBlockContext, marker: Marker?) {
        var pendingMarker = marker
        for block in blocks {
            let marker = pendingMarker
            pendingMarker = nil
            switch block.content {
            case .paragraph(let inline):
                if let media = MarkdownMediaReference(inline) {
                    if let marker { appendText(NSAttributedString(string: ""), context: context, marker: marker) }
                    flushProse()
                    result.append(.media(source: media.source, name: media.name, context: context))
                    continue
                }
                if inline.count == 1, case .image(let source?, _, let alt) = inline[0].content {
                    if let marker { appendText(NSAttributedString(string: ""), context: context, marker: marker) }
                    flushProse()
                    result.append(.image(source: source, alt: alt.map(\.plainText).joined(), context: context))
                    continue
                }
                appendText(MarkdownAttributedStringBuilder.inline(inline, style: style(context)), context: context, marker: marker)
            case .heading(let level, let inline):
                var headingStyle = style(context)
                headingStyle.size = typography.headingSize(level: level)
                headingStyle.bold = true
                appendText(MarkdownAttributedStringBuilder.inline(inline, style: headingStyle), context: context, marker: marker, heading: true)
            case .raw(let text):
                appendText(MarkdownAttributedStringBuilder.literal(text, style: style(context)), context: context, marker: marker)
            case .quote(let children):
                var childContext = context
                childContext.quoteIndents.append(context.indent)
                childContext.indent += 12
                append(children, context: childContext, marker: marker)
            case .list(let start, let items):
                if let marker { appendText(NSAttributedString(string: ""), context: context, marker: marker) }
                for (index, item) in items.enumerated() {
                    let bullet = start.map { "\($0 + index)." } ?? "•"
                    let checkbox = item.checked.map { $0 ? "☑" : "☐" }
                    let label = checkbox.map { start == nil ? $0 : bullet + " " + $0 } ?? bullet
                    let font = NSFont.systemFont(ofSize: typography.bodySize)
                    let width = max(14, ceil((label as NSString).size(withAttributes: [.font: font]).width) + 5)
                    var childContext = context
                    childContext.indent += width
                    let itemMarker = Marker(text: label, position: context.indent)
                    if item.blocks.isEmpty { appendText(NSAttributedString(string: ""), context: childContext, marker: itemMarker) }
                    else { append(item.blocks, context: childContext, marker: itemMarker) }
                }
            case .code(let code):
                if let marker { appendText(NSAttributedString(string: ""), context: context, marker: marker) }
                flushProse()
                result.append(.codeBlock(code, context: context))
            case .math(let math):
                if let marker { appendText(NSAttributedString(string: ""), context: context, marker: marker) }
                flushProse()
                result.append(.math(math, context: context))
            case .table(let table):
                if let marker { appendText(NSAttributedString(string: ""), context: context, marker: marker) }
                flushProse()
                result.append(.table(table, context: context, ordinal: tableIndex))
                tableIndex += 1
            case .divider:
                if let marker { appendText(NSAttributedString(string: ""), context: context, marker: marker) }
                flushProse()
                result.append(.divider(context: context))
            }
        }
    }

    private func style(_ context: MarkdownBlockContext) -> MarkdownAttributedStringBuilder.Style {
        var style = MarkdownAttributedStringBuilder.Style(size: typography.bodySize)
        style.resources = resources
        style.failed = failed
        if !context.quoteIndents.isEmpty { style.color = .secondaryLabelColor }
        return style
    }

    private mutating func appendText(_ text: NSAttributedString, context: MarkdownBlockContext, marker: Marker?, heading: Bool = false) {
        if prose.length > 0 { prose.append(NSAttributedString(string: "\n")) }
        let paragraph = NSMutableAttributedString()
        var prefixes = context.quoteIndents.map { Marker(text: "▎", position: $0) }
        if let marker { prefixes.append(marker) }
        prefixes.sort { $0.position < $1.position }
        if !prefixes.isEmpty {
            var prefixStyle = style(context)
            prefixStyle.color = .secondaryLabelColor
            for prefix in prefixes {
                var markerStyle = prefixStyle
                // 方块字形的 advance 可能宽于引用槽，越过 tab stop 会另起一行。
                if prefix.text == "▎" { markerStyle.size = 10 }
                paragraph.append(MarkdownAttributedStringBuilder.literal(prefix.text + "\t", style: markerStyle))
            }
        }
        paragraph.append(text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = prefixes.first?.position ?? context.indent
        paragraphStyle.headIndent = context.indent
        paragraphStyle.tabStops = (prefixes.dropFirst().map(\.position) + [context.indent]).map {
            NSTextTab(textAlignment: .left, location: $0)
        }
        paragraphStyle.paragraphSpacing = marker == nil ? 6 : 3
        paragraphStyle.paragraphSpacingBefore = heading ? 6 : 0
        paragraph.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: paragraph.length))
        prose.append(paragraph)
    }

    private mutating func flushProse() {
        guard prose.length > 0 else { return }
        result.append(.prose(MarkdownProse(parts: [NSAttributedString(attributedString: prose)])))
        prose = NSMutableAttributedString()
    }

    mutating func finish() -> [MarkdownSegment] {
        flushProse()
        return result
    }
}
