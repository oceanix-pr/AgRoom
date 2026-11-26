import SwiftUI
import AgRoomCore

/// 共享预览门面。解析任务与缓存归属于当前文档视图，不使用跨空间内容单例。
struct MarkdownView: View {
    let text: String
    var streaming = false
    var documentID = ""
    var strippingFrontmatter = false
    var sourceContext = MarkdownSourceContext()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ReadingTypography.preferenceKey) private var readingPointSize = ReadingTypography.defaultSize
    @State private var model: MarkdownRenderModel
    @State private var retryRevision = 0

    init(text: String, streaming: Bool = false, documentID: String = "", strippingFrontmatter: Bool = false,
         sourceContext: MarkdownSourceContext = MarkdownSourceContext(), model: MarkdownRenderModel = MarkdownRenderModel()) {
        self.text = text
        self.streaming = streaming
        self.documentID = documentID
        self.strippingFrontmatter = strippingFrontmatter
        self.sourceContext = sourceContext
        self._model = State(initialValue: model)
    }

    private var typography: ReadingTypography { ReadingTypography(pointSize: readingPointSize) }
    private var request: MarkdownRenderRequest {
        MarkdownRenderRequest(text: text, streaming: streaming, documentID: documentID, strippingFrontmatter: strippingFrontmatter,
                              context: sourceContext, dark: colorScheme == .dark, retryRevision: retryRevision, typography: typography)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            if model.documentID == documentID, model.context == sourceContext, model.dark == (colorScheme == .dark), model.hasRenderedSnapshot {
                ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                        .id(segment.identity)
                }
                if model.canRetryResources {
                    Button(L.string("md.resource.retry")) { retryRevision += 1 }
                        .buttonStyle(.plain).font(MeetTypography.secondary).foregroundStyle(.secondary)
                }
            } else {
                Text(strippingFrontmatter ? MarkdownParser.bodyWithoutFrontmatter(text) : text)
                    .font(.system(size: typography.bodySize))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if MarkdownTiming.log.signpostsEnabled, model.hasRenderedSnapshot, model.documentID == documentID {
                MarkdownDrawProbe(trace: model.firstFrame, documentID: documentID)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: request) { await model.present(request) }
        .task(id: model.resourceRequestID) { await model.loadResources() }
        .onDisappear { model.stopStreaming(); model.firstFrame.disappear(documentID: documentID) }
    }

    /// 同一纯解析入口也用于回归测试；视图本身通过后台 worker 调用。
    nonisolated static func parse(_ source: String) -> [MarkdownBlock] {
        MarkdownParser.parse(source).blocks
    }

    @ViewBuilder
    private func segmentView(_ segment: MarkdownSegment) -> some View {
        switch segment {
        case .prose(let prose):
            SelectableMarkdownTextView(prose: prose)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let code, let context):
            if code.language.lowercased() == "mermaid", code.isClosed {
                contained(MarkdownRichBlock(resource: model.resources[.mermaid(code.code)], failed: model.failedResources.contains(.mermaid(code.code)), source: code.code, language: "mermaid", failure: model.resourceErrors[.mermaid(code.code)], typography: model.typography), in: context)
            } else { contained(CodeBlockView(code: code.code, language: code.language, typography: model.typography), in: context) }
        case .math(let math, let context):
            contained(MarkdownRichBlock(resource: model.resources[.math(math)], failed: model.failedResources.contains(.math(math)), source: math.source, language: "LaTeX", failure: model.resourceErrors[.math(math)], typography: model.typography), in: context)
        case .image(let source, let alt, let context):
            contained(MarkdownRichBlock(resource: model.resources[.image(source)], failed: model.failedResources.contains(.image(source)), source: source, language: "", alternative: alt, isImage: true, failure: model.resourceErrors[.image(source)]), in: context)
        case .media(let source, let name, let context):
            contained(MarkdownMediaBlock(source: source, name: name, context: sourceContext), in: context)
        case .table(let table, let context, let ordinal):
            contained(MarkdownTableView(table: table, page: model.tablePages[ordinal, default: 0],
                                        selectPage: { model.setTablePage($0, for: ordinal) },
                                        resources: model.resources, failed: model.failedResources, typography: model.typography), in: context)
        case .divider(let context):
            contained(Divider(), in: context)
        }
    }

    private func contained<Content: View>(_ content: Content, in context: MarkdownBlockContext) -> some View {
        content
            .padding(.leading, context.indent)
            .overlay(alignment: .leading) {
                ForEach(Array(context.quoteIndents.enumerated()), id: \.offset) { _, position in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 2)
                        .padding(.leading, position)
                }
            }
    }
}

/// The first actual AppKit draw of the formatted document, including documents containing only code or media.
private struct MarkdownDrawProbe: NSViewRepresentable {
    let trace: MarkdownFirstFrame
    let documentID: String

    final class Probe: NSView {
        weak var trace: MarkdownFirstFrame?
        var documentID = ""
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if window != nil && !visibleRect.isEmpty { trace?.displayed(documentID: documentID) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        if view.trace !== trace || view.documentID != documentID {
            view.trace = trace
            view.documentID = documentID
            view.needsDisplay = true
        }
    }
}

struct CodeBlockView: View {
    let code: String
    var language = ""
    var typography = ReadingTypography()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(MeetTypography.secondary.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .help(L.string("common.copy"))
                .accessibilityLabel(L.string("common.copy"))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: typography.codeSize, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onChange(of: code) { _, _ in copied = false }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let page: Int
    let selectPage: (Int) -> Void
    let resources: [MarkdownResourceKey: MarkdownRenderedResource]
    let failed: Set<MarkdownResourceKey>
    let typography: ReadingTypography
    @State private var cache = MarkdownTableLayoutCache()
    @State private var layout: MarkdownTableLayoutCache.Layout?
    private struct Input: Equatable {
        let table: MarkdownTable
        let page: Int
        let images: [MarkdownResourceKey: ObjectIdentifier]
        let failed: Set<MarkdownResourceKey>
        let typography: ReadingTypography
    }
    private var input: Input {
        var keys: Set<MarkdownResourceKey> = []
        for row in table.previewRows(page: page) {
            for cell in row { MarkdownResourcePlan.visitInline(cell) { keys.insert($0) } }
        }
        return Input(table: table, page: page, images: Dictionary(uniqueKeysWithValues: keys.compactMap { key in resources[key].map { (key, ObjectIdentifier($0.image)) } }), failed: failed.intersection(keys), typography: typography)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                if let layout, layout.page == page {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(layout.cells.indices, id: \.self) { row in
                            GridRow {
                                ForEach(layout.widths.indices, id: \.self) { column in
                                    SelectableMarkdownTextView(attributed: layout.cells[row][column])
                                        .frame(width: layout.widths[column], alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if row == 0 { Divider() }
                        }
                    }
                    .id(page)
                }
            }
            if table.pageCount > 1 {
                HStack(spacing: 10) {
                    Button { selectPage(page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0)
                        .accessibilityLabel(L.string("markdown.table.previous_page"))
                    let range = table.pageRange(page)
                    Text(L.format("markdown.table.row_range", range.lowerBound + 1, range.upperBound, table.previewRowCount))
                        .monospacedDigit()
                    Button { selectPage(page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(page + 1 >= table.pageCount)
                        .accessibilityLabel(L.string("markdown.table.next_page"))
                }
                .font(.caption)
            }
            if table.previewTruncated {
                Text(L.format("markdown.table.preview_bounds", table.previewRowCount, table.previewColumnCount)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { rebuild() }
        .onChange(of: input) { _, _ in rebuild() }
    }
    private func rebuild() {
        layout = cache.layout(table, page: page, resources: resources, failed: failed, typography: typography)
    }
}

/// Bounded, document-local cell cache. Editing a tail row never rebuilds or
/// measures the unchanged header and previous cells.
@MainActor
final class MarkdownTableLayoutCache {
    struct Layout {
        let page: Int
        let widths: [CGFloat]
        let cells: [[NSAttributedString]]
    }
    private struct Entry {
        let nodes: [MarkdownInline]
        let alignment: MarkdownTable.Alignment
        let header: Bool
        let typography: ReadingTypography
        let images: [MarkdownResourceKey: ObjectIdentifier]
        let failed: Set<MarkdownResourceKey>
        let text: NSAttributedString
        let width: CGFloat
    }
    private var entries: [Int: Entry] = [:]
    private(set) var rebuildCount = 0
    func layout(_ table: MarkdownTable, page: Int = 0, resources: [MarkdownResourceKey: MarkdownRenderedResource], failed: Set<MarkdownResourceKey>, typography: ReadingTypography) -> Layout {
        var next: [Int: Entry] = [:]
        var widths = Array(repeating: CGFloat(72), count: table.previewColumnCount)
        let firstDataRow = table.pageRange(page).lowerBound
        let cells = table.previewRows(page: page).enumerated().map { row, values in
            widths.indices.map { column -> NSAttributedString in
                let nodes = column < values.count ? values[column] : []
                var keys: Set<MarkdownResourceKey> = []
                MarkdownResourcePlan.visitInline(nodes) { keys.insert($0) }
                let images = Dictionary(uniqueKeysWithValues: keys.compactMap { key in resources[key].map { (key, ObjectIdentifier($0.image)) } })
                let failures = failed.intersection(keys)
                let alignment = column < table.alignments.count ? table.alignments[column] : .leading
                let id = (row == 0 ? 0 : firstDataRow + row) * MarkdownTable.maximumPreviewColumns + column
                let entry: Entry
                if let old = entries[id], old.nodes == nodes, old.header == (row == 0), old.alignment == alignment,
                   old.typography == typography, old.images == images, old.failed == failures { entry = old }
                else {
                    var style = MarkdownAttributedStringBuilder.Style(size: typography.bodySize)
                    style.bold = row == 0; style.resources = resources; style.failed = failed
                    let text = NSMutableAttributedString(attributedString: MarkdownAttributedStringBuilder.inline(nodes, style: style))
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = alignment == .trailing ? .right : alignment == .center ? .center : .left
                    text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
                    entry = Entry(nodes: nodes, alignment: alignment, header: row == 0, typography: typography, images: images, failed: failures,
                                  text: NSAttributedString(attributedString: text), width: min(320, max(72, ceil(text.size().width))))
                    rebuildCount += 1
                }
                next[id] = entry
                widths[column] = max(widths[column], entry.width)
                return entry.text
            }
        }
        entries = next
        return Layout(page: page, widths: widths, cells: cells)
    }
}
