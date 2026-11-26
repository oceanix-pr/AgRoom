import Foundation
import Markdown

/// UI 无关的值模型；第三方解析树只在解析任务内使用，不跨 actor 传递。
struct MarkdownDocument: Sendable, Equatable {
    let source: String
    let blocks: [MarkdownBlock]
    let bodyOffset: Int

    var plainText: String { blocks.map(\.plainText).joined(separator: "\n\n") }
}

struct MarkdownBlock: Sendable, Equatable {
    indirect enum Content: Sendable, Equatable {
        case paragraph([MarkdownInline])
        case heading(level: Int, content: [MarkdownInline])
        case code(MarkdownCode)
        case math(MarkdownMath)
        case table(MarkdownTable)
        case list(start: Int?, items: [MarkdownListItem])
        case quote([MarkdownBlock])
        case divider
        case raw(String)
    }

    let content: Content
    /// 原文的 UTF-8 半开区间，不是 NSTextView 的 UTF-16 区间。
    let sourceRange: Range<Int>?

    var plainText: String {
        switch content {
        case .paragraph(let inline), .heading(_, let inline):
            return inline.map(\.plainText).joined()
        case .code(let code): return code.code
        case .math(let math): return math.source
        case .table(let table): return table.plainText
        case .quote(let blocks): return blocks.map(\.plainText).joined(separator: "\n\n")
        case .list(let start, let items):
            return items.enumerated().map { index, item in
                let marker = start.map { "\($0 + index)." } ?? "-"
                let checkbox = item.checked.map { $0 ? "[x] " : "[ ] " } ?? ""
                let body = item.blocks.map(\.plainText).joined(separator: "\n\n")
                return marker + " " + checkbox + body.replacingOccurrences(of: "\n", with: "\n  ")
            }.joined(separator: "\n")
        case .divider: return "---"
        case .raw(let source): return source
        }
    }
}

struct MarkdownInline: Sendable, Equatable {
    indirect enum Content: Sendable, Equatable {
        case text(String)
        case emphasis([MarkdownInline])
        case strong([MarkdownInline])
        case strikethrough([MarkdownInline])
        case code(String)
        case math(MarkdownMath)
        case link(destination: String?, title: String?, content: [MarkdownInline])
        case image(source: String?, title: String?, alt: [MarkdownInline])
        case softBreak
        case hardBreak
    }

    let content: Content
    let sourceRange: Range<Int>?

    var plainText: String {
        switch content {
        case .text(let text), .code(let text): return text
        case .math(let math): return math.source
        case .emphasis(let children), .strong(let children), .strikethrough(let children),
             .link(_, _, let children), .image(_, _, let children):
            return children.map(\.plainText).joined()
        case .softBreak: return " "
        case .hardBreak: return "\n"
        }
    }
}

struct MarkdownCode: Sendable, Equatable {
    let info: String
    let code: String
    var isClosed = true

    var language: String { info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "" }
}

struct MarkdownListItem: Sendable, Equatable {
    let checked: Bool?
    let blocks: [MarkdownBlock]
}

struct MarkdownTable: Sendable, Equatable {
    enum Alignment: Sendable, Equatable { case leading, center, trailing }
    let header: [[MarkdownInline]]
    let rows: [[[MarkdownInline]]]
    let alignments: [Alignment]

    static let maximumPreviewColumns = 32
    static let maximumPreviewCells = 2_000
    var previewColumnCount: Int { min(header.count, Self.maximumPreviewColumns) }
    var previewRowCount: Int { min(rows.count, 500, max(0, Self.maximumPreviewCells / max(1, previewColumnCount) - 1)) }
    var previewTruncated: Bool { previewColumnCount < header.count || previewRowCount < rows.count }
    // The full preview is bounded separately. Only one page owns native cell
    // views and requests images/formulas at a time, even for very wide tables.
    var rowsPerPage: Int { min(24, 192 / max(1, previewColumnCount) - 1) }
    var pageCount: Int { max(1, (previewRowCount + rowsPerPage - 1) / rowsPerPage) }
    func pageRange(_ page: Int) -> Range<Int> {
        let lower = min(max(0, page), pageCount - 1) * rowsPerPage
        return lower..<min(lower + rowsPerPage, previewRowCount)
    }
    func previewRows(page: Int) -> [[[MarkdownInline]]] {
        ([header] + rows[pageRange(page)]).map { Array($0.prefix(previewColumnCount)) }
    }

    var plainText: String {
        ([header] + rows).map { row in
            row.map { $0.map(\.plainText).joined() }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

enum MarkdownParser {
    /// 保留超限输入的原文，避免深递归适配或过大的第三方解析任务。
    static let maximumSourceBytes = 2 * 1_024 * 1_024
    private static let maximumDepth = 128

    static func parse(_ source: String, strippingFrontmatter: Bool = false) -> MarkdownDocument {
        guard source.utf8.count <= maximumSourceBytes else {
            return MarkdownDocument(source: source, blocks: [MarkdownBlock(content: .raw(source), sourceRange: nil)], bodyOffset: 0)
        }
        let offset = strippingFrontmatter ? frontmatterBodyOffset(source) : 0
        let body = String(decoding: source.utf8.dropFirst(offset), as: UTF8.self)
        let initial = Document(parsing: body, options: [.disableSmartOpts])
        let initialMap = SourceMap(source, parserStart: offset)
        // Ordinary Markdown needs neither an exclusion-tree walk nor a second
        // source map/masked byte buffer. Math delimiters always contain $ or \.
        if !source.contains("$"), !source.contains(#"\("#), !source.contains(#"\["#) {
            return MarkdownDocument(source: source, blocks: initial.children.map { block($0, map: initialMap, depth: 0) }, bodyOffset: offset)
        }
        var excluded: [Range<Int>] = []
        func excludeCode(_ node: any Markup, depth: Int = 0) {
            if depth >= maximumDepth || node is CodeBlock || node is InlineCode || node is HTMLBlock || node is InlineHTML || node is Markdown.Image {
                if let range = initialMap.range(node.range) { excluded.append(range) }
                return
            }
            if node is Link, let range = initialMap.range(node.range) {
                let children = Array(node.children)
                if let first = children.first.flatMap({ initialMap.range($0.range) }),
                   let last = children.last.flatMap({ initialMap.range($0.range) }) {
                    excluded += [range.lowerBound..<first.lowerBound, last.upperBound..<range.upperBound]
                }
            }
            for child in node.children { excludeCode(child, depth: depth + 1) }
        }
        excludeCode(initial)
        let protection = MarkdownMathProtection(source: source, startingAt: offset, excluded: excluded)
        let map = SourceMap(source, parserStart: offset, protection: protection)
        let document = protection.spans.isEmpty ? initial : Document(
            parsing: String(decoding: protection.bytes.dropFirst(offset), as: UTF8.self), options: [.disableSmartOpts]
        )
        return MarkdownDocument(source: source, blocks: document.children.map { block($0, map: map, depth: 0) }, bodyOffset: offset)
    }

    /// 文件入口的完整 frontmatter 预处理；未闭合时保留全部原文。
    static func bodyWithoutFrontmatter(_ source: String) -> String {
        String(decoding: source.utf8.dropFirst(frontmatterBodyOffset(source)), as: UTF8.self)
    }

    private static func frontmatterBodyOffset(_ source: String) -> Int {
        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
              }) else { return 0 }
        return min(source.utf8.count, lines.prefix(end + 1).reduce(0) { $0 + $1.utf8.count + 1 })
    }

    private static func block(_ node: any Markup, map: SourceMap, depth: Int) -> MarkdownBlock {
        let range = map.range(node.range)
        let content: MarkdownBlock.Content
        guard depth < maximumDepth else {
            return MarkdownBlock(content: .raw(map.text(range) ?? node.format()), sourceRange: range)
        }
        switch node {
        case let node as Paragraph:
            let inline = inlines(node, map: map, depth: depth + 1)
            if inline.count == 1, case .math(let math) = inline[0].content, math.display { content = .math(math) }
            else { content = .paragraph(inline) }
        case let node as Heading:
            content = .heading(level: node.level, content: inlines(node, map: map, depth: depth + 1))
        case let node as CodeBlock:
            let raw = map.text(range) ?? ""
            let lines = raw.components(separatedBy: .newlines)
            let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let fence = String(first.prefix(while: { $0 == "`" || $0 == "~" }))
            var last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.trimmingCharacters(in: .whitespaces) ?? ""
            for _ in 0..<map.quoteDepth(before: range) {
                guard last.first == ">" else { break }
                last = String(last.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let closed = fence.count >= 3 && lines.count > 1 && last.count >= fence.count && last.allSatisfy { $0 == fence.first }
            content = .code(MarkdownCode(info: node.language ?? "", code: node.code, isClosed: closed))
        case let node as BlockQuote:
            content = .quote(node.children.map { block($0, map: map, depth: depth + 1) })
        case let node as OrderedList:
            content = .list(start: Int(clamping: node.startIndex), items: items(node, map: map, depth: depth + 1))
        case let node as UnorderedList:
            content = .list(start: nil, items: items(node, map: map, depth: depth + 1))
        case let node as Table:
            let header = node.head.cells.map { inlines($0, map: map, depth: depth + 1) }
            let rows = node.body.children.map { row in row.children.map { inlines($0, map: map, depth: depth + 1) } }
            let alignments: [MarkdownTable.Alignment] = node.columnAlignments.map {
                switch $0 {
                case .center: return .center
                case .right: return .trailing
                default: return .leading
                }
            }
            content = .table(MarkdownTable(header: Array(header), rows: rows, alignments: alignments))
        case is ThematicBreak:
            content = .divider
        case let node as HTMLBlock:
            content = .raw(node.rawHTML)
        default:
            content = .raw(map.text(range) ?? node.format())
        }
        return MarkdownBlock(content: content, sourceRange: range)
    }

    private static func items(_ node: any Markup, map: SourceMap, depth: Int) -> [MarkdownListItem] {
        node.children.compactMap { child in
            guard let item = child as? ListItem else { return nil }
            let checked: Bool? = item.checkbox.map { $0 == .checked }
            return MarkdownListItem(checked: checked, blocks: item.children.map { block($0, map: map, depth: depth) })
        }
    }

    private static func inlines(_ node: any Markup, map: SourceMap, depth: Int) -> [MarkdownInline] {
        let children = Array(node.children)
        // cmark can omit a break's range. Only math protection needs the gap
        // between its nearest located siblings; exported ranges stay as parsed.
        let ranges = children.map { map.range($0.range) }
        var nextStart: [Int?] = []
        if map.protection?.spans.isEmpty == false {
            nextStart = Array(repeating: nil, count: children.count)
            var following: Int?
            for index in ranges.indices.reversed() {
                nextStart[index] = following
                if let range = ranges[index] { following = range.lowerBound }
            }
        }
        var previousEnd: Int?
        return children.enumerated().flatMap { index, child -> [MarkdownInline] in
            let range = ranges[index]
            defer { if let range { previousEnd = range.upperBound } }
            let breakRange: Range<Int>?
            if !nextStart.isEmpty, range == nil, child is SoftBreak || child is LineBreak,
               let previousEnd, let next = nextStart[index], previousEnd <= next {
                breakRange = previousEnd..<next
            } else { breakRange = range }
            let content: MarkdownInline.Content
            guard depth < maximumDepth else {
                return [MarkdownInline(content: .text(map.text(range) ?? child.format()), sourceRange: range)]
            }
            switch child {
            case let child as Markdown.Text: return map.expandMath(in: child.string, range: range)
            case is SoftBreak where map.isInsideMath(breakRange): return []
            case is LineBreak where map.isInsideMath(breakRange): return []
            case let child as InlineCode: content = .code(child.code)
            case is SoftBreak: content = .softBreak
            case is LineBreak: content = .hardBreak
            case is Emphasis: content = .emphasis(inlines(child, map: map, depth: depth + 1))
            case is Strong: content = .strong(inlines(child, map: map, depth: depth + 1))
            case is Strikethrough: content = .strikethrough(inlines(child, map: map, depth: depth + 1))
            case let child as Link:
                content = .link(destination: child.destination, title: child.title, content: inlines(child, map: map, depth: depth + 1))
            case let child as Markdown.Image:
                content = .image(source: child.source, title: child.title, alt: inlines(child, map: map, depth: depth + 1))
            default: content = .text(map.text(range) ?? child.format())
            }
            return [MarkdownInline(content: content, sourceRange: range)]
        }
    }

    /// cmark 的列号按 UTF-8 字节计数；保留 CRLF / CR 的原始偏移。
    private struct SourceMap {
        let bytes: [UInt8]
        let lineStarts: [Int]
        let protection: MarkdownMathProtection?

        init(_ source: String, parserStart: Int, protection: MarkdownMathProtection? = nil) {
            self.protection = protection
            bytes = Array(source.utf8)
            var starts = [parserStart]
            for index in parserStart..<bytes.count {
                if bytes[index] == 10 || (bytes[index] == 13 && (index + 1 == bytes.count || bytes[index + 1] != 10)) {
                    starts.append(index + 1)
                }
            }
            lineStarts = starts
        }

        func quoteDepth(before range: Range<Int>?) -> Int {
            guard let range else { return 0 }
            let start = bytes[..<range.lowerBound].lastIndex(of: 10).map { $0 + 1 } ?? 0
            return bytes[start..<range.lowerBound].filter { $0 == 62 }.count
        }

        func isInsideMath(_ range: Range<Int>?) -> Bool {
            guard let range else { return false }
            return protection?.spans.contains(where: { $0.range.overlaps(range) }) ?? false
        }

        func expandMath(in text: String, range: Range<Int>?) -> [MarkdownInline] {
            guard let range, let protection else { return [MarkdownInline(content: .text(text), sourceRange: range)] }
            var remaining = text[...]
            var result: [MarkdownInline] = []
            for span in protection.spans where span.range.overlaps(range) {
                let overlap = max(span.range.lowerBound, range.lowerBound)..<min(span.range.upperBound, range.upperBound)
                let mask = String(decoding: protection.bytes[overlap], as: UTF8.self)
                guard let match = remaining.range(of: mask) else { continue }
                if match.lowerBound > remaining.startIndex {
                    result.append(MarkdownInline(content: .text(String(remaining[..<match.lowerBound])), sourceRange: nil))
                }
                if range.contains(span.range.lowerBound) {
                    let content: MarkdownInline.Content = span.math.map { .math($0) } ?? .text(self.text(span.range) ?? "")
                    result.append(MarkdownInline(content: content, sourceRange: span.range))
                }
                remaining = remaining[match.upperBound...]
            }
            if !remaining.isEmpty { result.append(MarkdownInline(content: .text(String(remaining)), sourceRange: range)) }
            return result
        }

        func range(_ range: SourceRange?) -> Range<Int>? {
            guard let range, let start = offset(range.lowerBound), let end = offset(range.upperBound), start <= end else { return nil }
            return start..<end
        }

        private func offset(_ location: SourceLocation) -> Int? {
            guard location.line > 0, location.line <= lineStarts.count, location.column > 0 else { return nil }
            return min(bytes.count, lineStarts[location.line - 1] + location.column - 1)
        }

        func text(_ range: Range<Int>?) -> String? {
            range.map { String(decoding: bytes[$0], as: UTF8.self) }
        }
    }
}
