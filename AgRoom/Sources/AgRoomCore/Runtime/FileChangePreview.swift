import Foundation

// MARK: - File Change Preview（写操作 dry-run 预览）

/// 写类文件工具执行前的变更预览：确认卡片据此展示「将要发生什么」。
/// 与确认流互补——用户批准前先看到 diff，而不是只看到原始参数
public struct FileChangePreview: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case create
        case overwrite
        case delete
        case mkdir
        case rename
        case copy
        case move
    }

    public let kind: Kind
    /// 主目标路径（写/删/建的目标，rename/copy/move 的源）
    public let path: String
    /// 次目标（rename 后的完整新路径，copy/move 的目标完整路径）
    public let destination: String?
    /// 覆盖统计：create 为新内容行数；overwrite 为旧/新行数与增删统计
    public let oldLines: Int?
    public let newLines: Int?
    public let addedLines: Int?
    public let removedLines: Int?
    /// 统一 diff（仅 overwrite 且双方均为可读文本且规模适中时生成）
    public let diff: String?

    public init(
        kind: Kind,
        path: String,
        destination: String? = nil,
        oldLines: Int? = nil,
        newLines: Int? = nil,
        addedLines: Int? = nil,
        removedLines: Int? = nil,
        diff: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.destination = destination
        self.oldLines = oldLines
        self.newLines = newLines
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.diff = diff
    }
}

// MARK: - Preview Builder

/// 由工具名 + 参数 + 文件区服务生成变更预览（纯读取，不执行任何写操作）
public enum FileChangePreviewBuilder {

    /// Bounded plain-text comparison, also used when reviewing app definitions.
    public static func textDiff(old: String, new: String) -> String? {
        unifiedDiff(old: old, new: new).text
    }

    /// 写类工具的 diff 规模上限（行）：超过则只给统计不展开 diff
    static let maxDiffLines = 160
    /// LCS 单侧行数上限（内存保护）：超过按整体替换处理
    static let maxLCSLines = 1000

    /// 生成写类工具的变更预览；非写类工具/必要参数缺失时返回 nil（确认卡退回纯参数展示）
    public static func build(
        toolName: String,
        argumentsJSON: String,
        service: FileAreaService?,
        repository: RepositoryReader? = nil
    ) -> FileChangePreview? {
        guard FileAreaPolicy.isWriteTool(toolName) else { return nil }
        let args = ToolArguments.parse(argumentsJSON)
        switch toolName {
        case "files_apply_changes":
            guard let repository, let changes = try? FilesApplyChangesTool.prepare(argumentsJSON, reader: repository) else { return nil }
            var parts: [String] = []
            var added: Int? = 0
            var removed: Int? = 0
            for change in changes {
                let difference = unifiedDiff(old: String(decoding: change.old, as: UTF8.self), new: String(decoding: change.new, as: UTF8.self))
                if let current = added, let value = difference.added { added = current + value } else { added = nil }
                if let current = removed, let value = difference.removed { removed = current + value } else { removed = nil }
                if let text = difference.text { parts.append("--- \(change.path)\n+++ \(change.path)\n" + text) }
            }
            let combined = parts.joined(separator: "\n\n")
            return FileChangePreview(kind: .overwrite, path: repository.root.path, addedLines: added, removedLines: removed,
                diff: combined.count <= 24_000 ? combined : nil)
        case "files_write":
            return writePreview(args: args, service: service)
        case "files_edit":
            guard let service, let (snapshot, content) = try? FilesEditTool.prepared(args: args, service: service) else { return nil }
            let diff = unifiedDiff(old: snapshot.text, new: content)
            return FileChangePreview(kind: .overwrite, path: snapshot.url.path,
                oldLines: lineCount(snapshot.text),
                newLines: lineCount(content),
                addedLines: diff.added, removedLines: diff.removed, diff: diff.text)
        case "files_mkdir":
            let path = ToolArguments.string(args, "path")
            guard !path.isEmpty else { return nil }
            return FileChangePreview(kind: .mkdir, path: path)
        case "files_delete":
            let path = ToolArguments.string(args, "path")
            guard !path.isEmpty else { return nil }
            return FileChangePreview(kind: .delete, path: path)
        case "files_rename":
            let path = ToolArguments.string(args, "path")
            let newName = ToolArguments.string(args, "new_name")
            guard !path.isEmpty, !newName.isEmpty else { return nil }
            let destination = ((path as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(newName)
            return FileChangePreview(kind: .rename, path: path, destination: destination)
        case "files_copy", "files_move":
            let source = ToolArguments.string(args, "source")
            let destDir = ToolArguments.string(args, "destination_dir")
            guard !source.isEmpty, !destDir.isEmpty else { return nil }
            let destination = (destDir as NSString)
                .appendingPathComponent((source as NSString).lastPathComponent)
            return FileChangePreview(
                kind: toolName == "files_copy" ? .copy : .move,
                path: source,
                destination: destination
            )
        default:
            return nil
        }
    }

    /// files_write 预览：目标存在且可读 → 旧/新行 diff；不存在或不可读 → 新建
    private static func writePreview(args: [String: Any], service: FileAreaService?) -> FileChangePreview? {
        let path = ToolArguments.string(args, "path")
        let content = ToolArguments.string(args, "content")
        guard !path.isEmpty else { return nil }
        let newLines = lineCount(content)

        guard let service, let old = try? service.readText(at: path) else {
            return FileChangePreview(kind: .create, path: path, newLines: newLines)
        }
        let oldLines = lineCount(old)
        let diff = unifiedDiff(old: old, new: content)
        return FileChangePreview(
            kind: .overwrite,
            path: path,
            oldLines: oldLines,
            newLines: newLines,
            addedLines: diff.added,
            removedLines: diff.removed,
            diff: diff.text
        )
    }

    // MARK: - Diff

    /// LCS diff 结果：巨大变更中段无法精确计数时 added/removed 为 nil。
    struct DiffResult: Sendable {
        let text: String?
        let added: Int?
        let removed: Int?
    }

    private static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } + (text.isEmpty || text.utf8.last == 10 ? 0 : 1)
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.utf8.last == 10 { lines.removeLast() }
        return lines
    }

    /// 统一 diff：先剥离共同首尾行，再只对有界的变更窗口做 LCS。
    /// 大文件的小改动不会把其余每一行误报为删掉再新增。
    static func unifiedDiff(old: String, new: String) -> DiffResult {
        guard !old.utf8.elementsEqual(new.utf8) else {
            return DiffResult(text: nil, added: 0, removed: 0)
        }
        guard lineCount(old) <= 100_000, lineCount(new) <= 100_000 else {
            return DiffResult(text: nil, added: nil, removed: nil)
        }
        let oldLines = lines(old)
        let newLines = lines(new)
        var commonPrefix = 0
        while commonPrefix < oldLines.count, commonPrefix < newLines.count,
              oldLines[commonPrefix].utf8.elementsEqual(newLines[commonPrefix].utf8) {
            commonPrefix += 1
        }
        // The bytes differ only by the final line terminator.
        if commonPrefix == oldLines.count, commonPrefix == newLines.count, let last = oldLines.last {
            let marker = "\n\\ No newline at end of file"
            let text = last.utf8.count < 10_000
                ? "@@ -\(commonPrefix),1 +\(commonPrefix),1 @@\n-\(last)\(old.utf8.last == 10 ? "" : marker)\n+\(last)\(new.utf8.last == 10 ? "" : marker)" : nil
            return DiffResult(text: text, added: 1, removed: 1)
        }
        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > commonPrefix, newEnd > commonPrefix,
              oldLines[oldEnd - 1].utf8.elementsEqual(newLines[newEnd - 1].utf8) {
            oldEnd -= 1
            newEnd -= 1
        }
        let commonSuffix = oldLines.count - oldEnd
        let contextBefore = min(2, commonPrefix)
        let contextAfter = min(2, commonSuffix)
        var oldStart = commonPrefix - contextBefore
        var newStart = commonPrefix - contextBefore
        var oldWindow = oldLines[oldStart..<(oldEnd + contextAfter)]
        var newWindow = newLines[newStart..<(newEnd + contextAfter)]
        var windowBytes = oldWindow.reduce(0) { $0 + $1.utf8.count + 1 }
            + newWindow.reduce(0) { $0 + $1.utf8.count + 1 }
        if windowBytes > 64 * 1024 {
            // A long unchanged neighboring line must not hide a tiny insertion.
            oldStart = commonPrefix
            newStart = commonPrefix
            oldWindow = oldLines[oldStart..<oldEnd]
            newWindow = newLines[newStart..<newEnd]
            windowBytes = oldWindow.reduce(0) { $0 + $1.utf8.count + 1 }
                + newWindow.reduce(0) { $0 + $1.utf8.count + 1 }
        }
        guard oldWindow.count <= maxLCSLines, newWindow.count <= maxLCSLines,
              windowBytes <= 64 * 1024 else {
            if oldEnd == commonPrefix || newEnd == commonPrefix {
                return DiffResult(text: nil, added: newEnd - commonPrefix, removed: oldEnd - commonPrefix)
            }
            // A single very long line can still show an exact local excerpt.
            if oldEnd - commonPrefix == 1, newEnd - commonPrefix == 1 {
                let excerpt = singleLineExcerpt(
                   old: oldLines[commonPrefix][...], new: newLines[commonPrefix][...],
                   oldLine: commonPrefix + 1, newLine: commonPrefix + 1
                )
                return DiffResult(text: excerpt, added: 1, removed: 1)
            }
            return DiffResult(text: nil, added: nil, removed: nil)
        }
        let ops = lcsOps(Array(oldWindow), Array(newWindow))
        let added = ops.reduce(0) { $0 + ($1.isInsert ? 1 : 0) }
        let removed = ops.reduce(0) { $0 + ($1.isDelete ? 1 : 0) }
        let text = formatHunks(ops: ops, context: 2, oldLineOffset: oldStart, newLineOffset: newStart)
        guard text?.utf8.count ?? 0 <= 24_000 else {
            return DiffResult(text: nil, added: added, removed: removed)
        }
        return DiffResult(text: text, added: added, removed: removed)
    }

    /// A changed one-line JSON value may occupy most of a large file. Show only
    /// its differing fragment and nearby text; the marker makes truncation explicit.
    private static func singleLineExcerpt(
        old: Substring, new: Substring, oldLine: Int, newLine: Int
    ) -> String? {
        var oldStart = old.startIndex
        var newStart = new.startIndex
        while oldStart < old.endIndex, newStart < new.endIndex, old[oldStart] == new[newStart] {
            old.formIndex(after: &oldStart)
            new.formIndex(after: &newStart)
        }
        var oldEnd = old.endIndex
        var newEnd = new.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let oldPrevious = old.index(before: oldEnd)
            let newPrevious = new.index(before: newEnd)
            guard old[oldPrevious] == new[newPrevious] else { break }
            oldEnd = oldPrevious
            newEnd = newPrevious
        }
        let commonBefore = String(old[..<oldStart].suffix(80))
        let commonAfter = String(old[oldEnd...].prefix(80))
        let oldChanged = old[oldStart..<oldEnd]
        let newChanged = new[newStart..<newEnd]
        let oldFragment = commonBefore + String(oldChanged.prefix(200)) + commonAfter
        let newFragment = commonBefore + String(newChanged.prefix(200)) + commonAfter
        let excerpt = "@@ -\(oldLine),1 +\(newLine),1 @@ …\n"
            + "-…\(oldFragment)…\n+…\(newFragment)…"
        return excerpt.utf8.count <= 24_000 ? excerpt : nil
    }

    private enum DiffOp {
        case equal(String)
        case delete(String)
        case insert(String)

        var isDelete: Bool { if case .delete = self { return true }; return false }
        var isInsert: Bool { if case .insert = self { return true }; return false }
        var isChange: Bool { isDelete || isInsert }
        var line: String {
            switch self {
            case .equal(let text), .delete(let text), .insert(let text): return text
            }
        }
    }

    /// 经典 LCS 回溯产出按序操作序列（equal/delete/insert）
    private static func lcsOps(_ old: [String], _ new: [String]) -> [DiffOp] {
        let n = old.count
        let m = new.count
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let rowBase = i * width
            let nextBase = (i + 1) * width
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[rowBase + j] = old[i].utf8.elementsEqual(new[j].utf8)
                    ? table[nextBase + j + 1] &+ 1
                    : Swift.max(table[nextBase + j], table[rowBase + j + 1])
            }
        }
        var ops: [DiffOp] = []
        ops.reserveCapacity(n + m)
        var i = 0
        var j = 0
        while i < n, j < m {
            if old[i].utf8.elementsEqual(new[j].utf8) {
                ops.append(.equal(old[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                ops.append(.delete(old[i]))
                i += 1
            } else {
                ops.append(.insert(new[j]))
                j += 1
            }
        }
        while i < n {
            ops.append(.delete(old[i]))
            i += 1
        }
        while j < m {
            ops.append(.insert(new[j]))
            j += 1
        }
        return ops
    }

    /// 操作序列 → 统一 diff 文本（@@ 变更区块，上下文折叠）
    private static func formatHunks(
        ops: [DiffOp], context: Int, oldLineOffset: Int = 0, newLineOffset: Int = 0
    ) -> String? {
        // 变更点索引 → 展开上下文后合并为区块
        var ranges: [(start: Int, end: Int)] = []
        for (index, op) in ops.enumerated() where op.isChange {
            let start = Swift.max(0, index - context)
            let end = Swift.min(ops.count - 1, index + context)
            if let last = ranges.last, start <= last.end + 1 {
                ranges[ranges.count - 1].end = end
            } else {
                ranges.append((start, end))
            }
        }
        guard !ranges.isEmpty else { return nil }

        var lines: [String] = []
        var oldLine = oldLineOffset + 1
        var newLine = newLineOffset + 1
        // 快进到首个区块前（同步行号计数）
        var consumed = 0

        func advance(to index: Int) {
            while consumed < index {
                switch ops[consumed] {
                case .equal: oldLine += 1; newLine += 1
                case .delete: oldLine += 1
                case .insert: newLine += 1
                }
                consumed += 1
            }
        }

        for range in ranges {
            advance(to: range.start)
            // 区块头：统计区块内 old/new 行数
            var oldCount = 0
            var newCount = 0
            for op in ops[range.start...range.end] {
                if op.isDelete { oldCount += 1 }
                if op.isInsert { newCount += 1 }
                if case .equal = op { oldCount += 1; newCount += 1 }
            }
            lines.append("@@ -\(oldLine),\(oldCount) +\(newLine),\(newCount) @@")
            while consumed <= range.end {
                switch ops[consumed] {
                case .equal(let text):
                    lines.append(" \(text)")
                    oldLine += 1
                    newLine += 1
                case .delete(let text):
                    lines.append("-\(text)")
                    oldLine += 1
                case .insert(let text):
                    lines.append("+\(text)")
                    newLine += 1
                }
                consumed += 1
            }
        }
        if lines.count > maxDiffLines {
            let omitted = lines.count - maxDiffLines
            lines = Array(lines.prefix(maxDiffLines))
            lines.append("… (\(omitted) more diff lines omitted)")
        }
        return lines.joined(separator: "\n")
    }
}
