import CryptoKit
import Darwin
import Foundation

/// 只读取本轮绑定的项目；目录替换、符号链接和另一个空间的私有目录均拒绝。
public struct RepositoryReader: Sendable {
    public let root: URL
    let space: AppSpace
    let service: FileAreaService
    let identity: TaskDirectoryIdentity
    let forbidden: [URL]
    /// Deterministic directory-swap fixture; never supplied by model arguments.
    var beforeDirectoryEnumeration: (@Sendable (URL) throws -> Void)? = nil
    static let fileLimit = WorkspaceTextLimits.maximumEditBytes
    static let entryLimit = 12_000
    static let excludedNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".next", ".venv", "venv",
        "__pycache__", ".DS_Store", ".agroom-runs", ".agroom-builds", ".agroom-lsp", ".agroom-write-tmp", ".agroom-attachments",
    ]

    public init(root: URL, service: FileAreaService, space: AppSpace) throws {
        let resolved = try service.resolveManaged(root.path)
        self.space = space
        self.root = resolved
        self.service = service
        identity = try TaskDirectoryIdentity.capture(resolved)
        forbidden = ScriptSandbox.privateRoots(space: space) + AppSpace.allCases.filter { $0 != space }.flatMap {
            service.defaultWriteRoots(for: $0) + [service.defaultChatRoot(for: $0)]
        }
        guard !forbidden.contains(where: { FileAreaService.isInside(resolved, root: $0) }) else {
            throw FileAreaService.AreaError.unsafePath
        }
    }

    func resolve(_ path: String = ".") throws -> URL {
        guard identity.matches(root), !path.contains("\0"), !path.split(separator: "/").contains("..") else {
            throw ToolExecutionFailure(message: "The project directory changed or the path is invalid. Reopen the registered workspace.")
        }
        let target = (FileAreaService.expandHome(path) ?? root.appendingPathComponent(path)).standardizedFileURL
        let resolved = try service.resolveManaged(target.path)
        guard resolved.path == target.path, FileAreaService.isInside(resolved, root: root),
              !forbidden.contains(where: { FileAreaService.isInside(resolved, root: $0) }) else {
            throw FileAreaService.AreaError.unsafePath
        }
        return resolved
    }

    /// Engineering reads stay in the selected project. File mutations and their
    /// recovery records may also belong to an explicitly mounted reference.
    func readerForMutation(at path: String) throws -> RepositoryReader {
        guard let target = FileAreaService.expandHome(path) else { throw FileAreaService.AreaError.unsafePath }
        if FileAreaService.isInside(target, root: root) { return self }
        guard identity.matches(root), let reference = service.scopedRoots?
            .filter({ FileAreaService.isInside(target, root: $0) })
            .max(by: { $0.path.count < $1.path.count }) else { throw FileAreaService.AreaError.unsafePath }
        return try RepositoryReader(root: reference, service: service, space: space)
    }

    func read(_ path: String, limit: Int = RepositoryReader.fileLimit) throws -> Data {
        let target = try resolve(path)
        let data = try ScriptFileIdentity.read(target, root: root, limit: limit)
        guard identity.matches(root) else { throw FileAreaService.AreaError.unsafePath }
        return data
    }

    func relative(_ url: URL) -> String {
        // Only normalize fixed system aliases. Resolving a mutable child link here
        // could turn a safe project name into an outside/private path fragment.
        func physicalPath(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
        }
        let rootPath = physicalPath(root)
        let path = physicalPath(url)
        guard path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    struct Instructions: Codable, Sendable {
        let path: String
        let scope: String
        let sha256: String
        let content: String
        let truncated: Bool
    }

    /// 仅加载项目根到目标目录之间的规则，不向上读取项目外的目录。
    func instructions(for path: String = ".") throws -> [Instructions] {
        let target = try resolve(path)
        let isDirectory = try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let directory = isDirectory ? target : target.deletingLastPathComponent()
        var directories = [root]
        if directory.path != root.path {
            var current = root
            for part in relative(directory).split(separator: "/") {
                current.appendPathComponent(String(part), isDirectory: true)
                directories.append(current)
            }
        }
        var result: [Instructions] = []
        var remaining = 16_000
        for directory in directories {
            let url = directory.appendingPathComponent("AGENTS.md")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try read(url.path, limit: 128 * 1024)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ToolExecutionFailure(message: "Project instructions must be UTF-8: \(relative(url))")
            }
            let content = String(text.prefix(max(0, remaining)))
            result.append(Instructions(path: relative(url), scope: directory.path, sha256: ManagedTextSnapshot.digest(data),
                content: content, truncated: content.count < text.count))
            remaining -= content.count
        }
        return result
    }

    struct Listing: Sendable { var files: [URL]; var truncated: Bool; var skipped: Int; var symlinks = 0 }

    /// 每个目录的 .gitignore 只作用于其子树；不读取宿主的全局 Git 配置。
    func listing(path: String = ".") throws -> Listing {
        let start = try resolve(path)
        if try start.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            return Listing(files: [start], truncated: false, skipped: 0)
        }
        var listing = Listing(files: [], truncated: false, skipped: 0)
        var visited = 0
        func visit(_ directory: URL, rules inherited: [IgnoreRule], depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 48, visited < Self.entryLimit else { listing.truncated = true; return }
            let directory = try resolve(directory.path)
            var rules = inherited
            let ignore = directory.appendingPathComponent(".gitignore")
            if FileManager.default.fileExists(atPath: ignore.path) {
                let data = try read(ignore.path, limit: 64 * 1024)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ToolExecutionFailure(message: "Cannot read .gitignore as UTF-8.")
                }
                rules += text.components(separatedBy: .newlines).compactMap { IgnoreRule(line: $0, base: relative(directory)) }
            }
            let entries = try WorkspaceTextReader.directoryEntries(directory, root: root,
                limit: Self.entryLimit - visited,
                beforeEnumeration: { try beforeDirectoryEnumeration?(directory) })
            listing.truncated = listing.truncated || entries.truncated
            for entry in entries.entries {
                try Task.checkCancellation()
                guard visited < Self.entryLimit else { listing.truncated = true; break }
                visited += 1
                let url = directory.appendingPathComponent(entry.name)
                if Self.excludedNames.contains(url.lastPathComponent)
                    || forbidden.contains(where: { FileAreaService.isInside(url, root: $0) }) {
                    listing.skipped += 1; continue
                }
                if entry.isSymbolicLink { listing.symlinks += 1; listing.skipped += 1; continue }
                let relativePath = relative(url)
                var ignored = false
                for rule in rules where rule.matches(relativePath, directory: entry.isDirectory) { ignored = !rule.negated }
                // AGENTS.md / .gitignore 始终可见，避免规则被忽略后悄悄失效。
                if ignored && !["AGENTS.md", ".gitignore"].contains(url.lastPathComponent) { listing.skipped += 1; continue }
                if entry.isDirectory { try visit(url, rules: rules, depth: depth + 1) }
                else if entry.isRegularFile { listing.files.append(url) }
            }
        }
        // 搜索子目录时也继承父级忽略规则。
        var inherited: [IgnoreRule] = []
        if start.path != root.path {
            var directory = root
            for part in relative(start).split(separator: "/") {
                let ignore = directory.appendingPathComponent(".gitignore")
                if FileManager.default.fileExists(atPath: ignore.path) {
                    let text = String(decoding: try read(ignore.path, limit: 64 * 1024), as: UTF8.self)
                    inherited += text.components(separatedBy: .newlines).compactMap { IgnoreRule(line: $0, base: relative(directory)) }
                }
                directory.appendPathComponent(String(part), isDirectory: true)
            }
        }
        try visit(start, rules: inherited, depth: 0)
        guard identity.matches(root) else { throw FileAreaService.AreaError.unsafePath }
        return listing
    }

    /// 编译前后核对项目输入；超限/不可读时拒绝宣称验证通过。
    func revision() throws -> String {
        let listing = try listing()
        guard !listing.truncated, listing.symlinks == 0 else { throw ToolExecutionFailure(message: "Project input scan exceeded its limit or contains symlink inputs; validation cannot be bound to a complete revision.") }
        var hasher = SHA256()
        var bytes = 0
        for file in listing.files {
            let data = try read(file.path)
            bytes += data.count
            guard bytes <= 64 * 1024 * 1024 else { throw ToolExecutionFailure(message: "Project inputs exceed the revision budget.") }
            let name = Data(relative(file).utf8)
            // 路径与正文分别摘要，避免分隔符造成清单歧义。
            hasher.update(data: Data(ManagedTextSnapshot.digest(name).utf8))
            hasher.update(data: Data(ManagedTextSnapshot.digest(data).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct IgnoreRule {
        let base: String
        let pattern: String
        let negated: Bool
        let directoriesOnly: Bool
        init?(line: String, base: String) {
            var line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            negated = line.hasPrefix("!")
            if negated { line.removeFirst() }
            directoriesOnly = line.hasSuffix("/")
            if directoriesOnly { line.removeLast() }
            guard !line.isEmpty else { return nil }
            self.base = base
            pattern = line
        }
        func matches(_ path: String, directory: Bool) -> Bool {
            guard !directoriesOnly || directory else { return false }
            let prefix = base.isEmpty ? "" : base + "/"
            guard path.hasPrefix(prefix) else { return false }
            let local = String(path.dropFirst(prefix.count))
            let anchored = pattern.hasPrefix("/") || pattern.contains("/")
            let pattern = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
            if anchored { return fnmatch(pattern, local, FNM_PATHNAME) == 0 || Self.globstar(pattern, local) }
            return local.split(separator: "/").contains { fnmatch(pattern, String($0), 0) == 0 }
        }
        static func globstar(_ pattern: String, _ path: String) -> Bool {
            guard pattern.contains("**") else { return false }
            // **/ 可匹配零个或多个目录；普通 * 不越过目录边界。
            var regex = "^"
            var index = pattern.startIndex
            while index < pattern.endIndex {
                let rest = pattern[index...]
                if rest.hasPrefix("**/") { regex += "(?:.*/)?"; index = pattern.index(index, offsetBy: 3) }
                else if rest.hasPrefix("**") { regex += ".*"; index = pattern.index(index, offsetBy: 2) }
                else {
                    let character = pattern[index]
                    regex += character == "*" ? "[^/]*" : character == "?" ? "[^/]" : NSRegularExpression.escapedPattern(for: String(character))
                    index = pattern.index(after: index)
                }
            }
            return path.range(of: regex + "$", options: .regularExpression) != nil
        }
    }
}

enum CodingJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

struct ProjectInspectTool: DispatcherTool {
    let reader: RepositoryReader
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition {
        ToolDefinition(name: "project_inspect", description: "Inspect the bound project: manifests, source/test folders and scoped AGENTS.md rules. Call for a target directory before changing its files. Deeper rules apply only in their subtree and cannot override user instructions, permission limits or confirmations. No scripts execute.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Project-relative directory; default project root"},"instruction_offset":{"type":"integer","minimum":0}},"additionalProperties":false}"#)
    }
    struct Report: Encodable {
        let root: String; var files: [String]; var manifests: [String]; let instructions: [RepositoryReader.Instructions]
        var truncated: Bool; let skipped: Int; let next_instruction: Int?
    }
    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard args["path"] == nil || args["path"] is String,
              args["instruction_offset"] == nil || args["instruction_offset"] is Int else {
            throw ToolExecutionFailure(message: "path must be text and instruction_offset must be an integer.")
        }
        let path = args["path"] as? String ?? "."
        let offset = args["instruction_offset"] as? Int ?? 0
        return try await Task.detached {
            let listing = try reader.listing(path: path)
            let paths = listing.files.map { reader.relative($0) }
            let manifests: Set<String> = ["Package.swift", "project.yml", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Makefile"]
            let allInstructions = try reader.instructions(for: path)
            guard (0...allInstructions.count).contains(offset) else { throw ToolExecutionFailure(message: "Invalid instruction_offset.") }
            let instructions = allInstructions.dropFirst(offset).prefix(2).map {
                RepositoryReader.Instructions(path: $0.path, scope: $0.scope, sha256: $0.sha256,
                    content: String($0.content.prefix(1000)), truncated: $0.truncated || $0.content.count > 1000)
            }
            var report = Report(root: reader.root.path, files: Array(paths.prefix(30)),
                manifests: Array(paths.filter { manifests.contains(URL(fileURLWithPath: $0).lastPathComponent) || $0.hasSuffix("project.pbxproj") }.prefix(30)),
                instructions: instructions, truncated: listing.truncated || paths.count > 30, skipped: listing.skipped,
                next_instruction: offset + instructions.count < allInstructions.count ? offset + instructions.count : nil)
            while try CodingJSON.encode(report).count > 5500, !report.files.isEmpty || !report.manifests.isEmpty {
                if !report.files.isEmpty { report.files.removeLast() } else { report.manifests.removeLast() }
                report.truncated = true
            }
            guard try CodingJSON.encode(report).count <= 5500 else {
                throw ToolExecutionFailure(message: "Project instruction metadata exceeds the result budget. Inspect a shallower directory and read its AGENTS.md directly with files_read_range.")
            }
            return try CodingJSON.encode(report)
        }.value
    }
}

struct FilesReadRangeTool: DispatcherTool {
    let reader: RepositoryReader
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition {
        ToolDefinition(name: "files_read_range", description: "Read a UTF-8 project file by one-based line range, including the complete file SHA-256 for versioned edits. Streams files up to 32 MiB without loading every line into memory. Returns numbered lines and next_line when more lines remain. A long first line returns a bounded fragment with line_truncated=true and next_cursor: continue with files_read(path, cursor=next_cursor), rather than repeating this range or using head/grep/Shell. Managed edits support files up to 16 MiB. No shell or subprocess.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}"#)
    }
    struct Line: Codable { let number: Int; let text: String; var line_truncated = false }
    struct Page: Codable {
        let path: String; let sha256: String; let total_lines: Int
        var lines: [Line]; var next_line: Int?; var next_cursor: String? = nil
    }
    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard let path = args["path"] as? String,
              args["start_line"] == nil || args["start_line"] is Int,
              args["end_line"] == nil || args["end_line"] is Int else { throw ToolExecutionFailure(message: "path and integer line numbers are required.") }
        let start = args["start_line"] as? Int ?? 1
        let end = args["end_line"] as? Int ?? (start > Int.max - 79 ? Int.max : start + 79)
        guard start > 0, end >= start, end - start < 500 else { throw ToolExecutionFailure(message: "Read between 1 and 500 lines with one-based line numbers.") }
        return try await WorkspaceTextReader.perform {
            let url = try reader.resolve(path)
            let placeholderDigest = String(repeating: "0", count: 64)
            let placeholderCursor = try WorkspaceTextReader.cursor(url: url, sha256: placeholderDigest, offset: Int.max)
            var selected: [Line] = []
            var nextLine: Int?
            var nextOffset: Int?
            var stopped = false
            let summary = try WorkspaceTextReader.scan(url, root: reader.root) { source in
                guard !stopped, source.number >= start, source.number <= end else { return }
                let bounded = RepositoryTextPresentation.prefix(source.text, characters: 4000, bytes: 5000)
                let complete = bounded == source.text
                let line = Line(number: source.number, text: bounded)
                let candidate = Page(path: url.path, sha256: placeholderDigest, total_lines: Int.max,
                    lines: selected + [line], next_line: Int.max)
                if complete, try CodingJSON.encode(candidate).utf8.count <= 5400 {
                    selected.append(line)
                    return
                }
                guard selected.isEmpty else { nextLine = source.number; stopped = true; return }
                var fragment = RepositoryTextPresentation.prefix(source.text, characters: 3500, bytes: 4200)
                while true {
                    // A cursor counts CRLF as one Character; keep the pair for the continuation.
                    if source.terminated, source.text.hasSuffix("\r"), fragment == source.text {
                        fragment.removeLast()
                    }
                    let partial = Page(path: url.path, sha256: placeholderDigest, total_lines: Int.max,
                        lines: [Line(number: source.number, text: fragment, line_truncated: true)],
                        next_line: nil, next_cursor: placeholderCursor)
                    if try CodingJSON.encode(partial).utf8.count <= 5400 { break }
                    guard !fragment.isEmpty else { throw ToolExecutionFailure(message: "The file path or a text character exceeds the read result budget.") }
                    fragment.removeLast()
                }
                guard !fragment.isEmpty else { throw ToolExecutionFailure(message: "A text character exceeds the read result budget; no partial UTF-8 character was returned.") }
                selected.append(Line(number: source.number, text: fragment, line_truncated: true))
                nextOffset = source.characterOffset + fragment.count
                stopped = true
            }
            guard reader.identity.matches(reader.root) else { throw FileAreaService.AreaError.unsafePath }
            guard start <= summary.totalLines else { throw ToolExecutionFailure(message: "start_line exceeds the file's \(summary.totalLines) lines.") }
            if !stopped, let last = selected.last, last.number < summary.totalLines { nextLine = last.number + 1 }
            let cursor = try nextOffset.map { try WorkspaceTextReader.cursor(url: url, sha256: summary.sha256, offset: $0) }
            let page = Page(path: url.path, sha256: summary.sha256, total_lines: summary.totalLines,
                lines: selected, next_line: nextLine, next_cursor: cursor)
            return try CodingJSON.encode(page)
        }
    }
}

private enum RepositoryTextPresentation {
    static func prefix(_ text: String, characters: Int = 350, bytes: Int = 1400) -> String {
        var result = ""
        var size = 0
        var count = 0
        for character in text {
            let width = String(character).utf8.count
            guard count < characters, width <= bytes - size else { break }
            result.append(character); size += width; count += 1
        }
        return result
    }

    static func snippet(_ text: String, range: Range<String.Index>) -> (text: String, column: Int, offset: Int, truncated: Bool) {
        var before = String(text[..<range.lowerBound].suffix(100))
        var after = String(text[range.upperBound...].prefix(200))
        while before.utf8.count > 400 { before.removeFirst() }
        while after.utf8.count > 800 { after.removeLast() }
        let match = String(text[range])
        let column = text[..<range.lowerBound].count + 1
        let offset = column - before.count - 1
        return (before + match + after, column, offset, offset > 0 || after.count < text[range.upperBound...].count)
    }
}

struct RepositorySearchTool: DispatcherTool {
    let reader: RepositoryReader
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition {
        ToolDefinition(name: "repo_search", description: "Search literal single-line text or file paths in the bound project, respecting nested .gitignore and private/symlink boundaries. Supply query OR up to 8 queries; a batch scans each file once and returns query_indices plus matching-line/file counts per query. output=paths returns only matching file paths; output=count omits source text. include/exclude are project-relative glob filters (*, **, ?). Set path to a known file/directory to narrow scanning. context_before/context_after add up to 20 nearby lines for output=matches. Matches include full-file SHA-256, line/column and read_cursor for long lines. Total scan is bounded to 32 MiB. count_is_exact=false, truncated or skipped_files never prove absence; narrow the scope. Default is case-sensitive. No Shell or subprocess.",
            parametersSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"},"queries":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":8},"path":{"type":"string"},"mode":{"type":"string","enum":["content","path"]},"output":{"type":"string","enum":["matches","paths","count"]},"include":{"type":"array","items":{"type":"string"},"maxItems":16},"exclude":{"type":"array","items":{"type":"string"},"maxItems":16},"case_sensitive":{"type":"boolean"},"max_results":{"type":"integer","minimum":1,"maximum":50},"context_before":{"type":"integer","minimum":0,"maximum":20},"context_after":{"type":"integer","minimum":0,"maximum":20}},"additionalProperties":false}"#)
    }
    struct ContextLine: Codable { let number: Int; let text: String; let line_truncated: Bool }
    struct Match: Codable {
        let path: String; let line: Int?; let text: String; let sha256: String?; let line_truncated: Bool
        var column: Int? = nil
        var context_before: [ContextLine]? = nil
        var context_after: [ContextLine]? = nil
        var context_truncated = false
        var read_cursor: String? = nil
        var query_indices: [Int]? = nil
    }
    struct Report: Codable {
        var matches: [Match] = []; var truncated = false; var skipped_files = 0; var scanned_files = 0
        var skipped_large_files = 0; var guidance: String? = nil
        var matching_lines: [Int] = []
        var matching_files: [Int] = []
        var count_is_exact = true
    }
    private struct PendingMatch {
        let number: Int; let text: String; let column: Int; let offset: Int; let truncated: Bool
        let before: [ContextLine]; var after: [ContextLine] = []
        var queries: [Int] = []
    }
    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let queries: [String]
        if let query = args["query"] as? String, args["queries"] == nil { queries = [query] }
        else if args["query"] == nil, let batch = args["queries"] as? [String] { queries = batch }
        else { throw ToolExecutionFailure(message: "Supply query OR queries (1...8 literal single-line strings).") }
        guard (1...8).contains(queries.count), queries.allSatisfy({ !$0.isEmpty && $0.count <= 500 && !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0") }),
              queries.reduce(0, { $0 + $1.utf8.count }) <= 4096,
              args["max_results"] == nil || args["max_results"] is Int,
              args["path"] == nil || args["path"] is String,
              args["mode"] == nil || args["mode"] is String,
              args["case_sensitive"] == nil || args["case_sensitive"] is Bool,
              args["context_before"] == nil || args["context_before"] is Int,
              args["context_after"] == nil || args["context_after"] is Int,
              args["output"] == nil || args["output"] is String,
              args["include"] == nil || args["include"] is [String],
              args["exclude"] == nil || args["exclude"] is [String] else { throw ToolExecutionFailure(message: "Provide literal single-line queries (500 characters each / 4096 UTF-8 bytes total), text path/mode/output, glob arrays, boolean case_sensitive and integer limits.") }
        let path = args["path"] as? String ?? "."
        let mode = args["mode"] as? String ?? "content"
        let output = args["output"] as? String ?? "matches"
        let includes = args["include"] as? [String] ?? []
        let excludes = args["exclude"] as? [String] ?? []
        let maximum = args["max_results"] as? Int ?? 20
        let before = args["context_before"] as? Int ?? 0
        let after = args["context_after"] as? Int ?? 0
        guard ["path", "content"].contains(mode), ["matches", "paths", "count"].contains(output),
              includes.count <= 16, excludes.count <= 16,
              (includes + excludes).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }), (1...50).contains(maximum),
              (0...20).contains(before), (0...20).contains(after) else { throw ToolExecutionFailure(message: "mode must be content or path; max_results must be 1...50 and context_before/context_after must be 0...20.") }
        let sensitive = args["case_sensitive"] as? Bool ?? true
        return try await WorkspaceTextReader.perform {
            let requested = try reader.resolve(path)
            let listing = try reader.listing(path: path)
            var report = Report(truncated: listing.truncated, skipped_files: listing.skipped)
            report.matching_lines = Array(repeating: 0, count: queries.count)
            report.matching_files = Array(repeating: 0, count: queries.count)
            report.count_is_exact = !listing.truncated && listing.skipped == 0
            let includePatterns = try includes.map(Self.glob)
            let excludePatterns = try excludes.map(Self.glob)
            var bytes = 0
            let options: String.CompareOptions = sensitive ? [.literal] : [.literal, .caseInsensitive]
            for file in listing.files {
                try Task.checkCancellation()
                let relative = reader.relative(file)
                let range = NSRange(relative.startIndex..., in: relative)
                if !includePatterns.isEmpty && !includePatterns.contains(where: { $0.firstMatch(in: relative, range: range) != nil }) { continue }
                if excludePatterns.contains(where: { $0.firstMatch(in: relative, range: range) != nil }) { continue }
                if output == "matches", report.matches.count >= maximum { report.truncated = true; report.count_is_exact = false; break }
                let explicitFile = reader.relative(requested) == relative
                if mode == "path" {
                    report.scanned_files += 1
                    let matched = queries.indices.filter { relative.range(of: queries[$0], options: options) != nil }
                    for index in matched { report.matching_lines[index] += 1; report.matching_files[index] += 1 }
                    if !matched.isEmpty, output != "count" {
                        if report.matches.count < maximum {
                            report.matches.append(Match(path: relative, line: nil, text: relative, sha256: nil, line_truncated: false, query_indices: matched))
                        } else { report.truncated = true }
                    }
                } else {
                    let remaining = WorkspaceTextLimits.maximumReadBytes - bytes
                    guard remaining > 0 else { report.truncated = true; report.count_is_exact = false; break }
                    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        if size > WorkspaceTextLimits.maximumReadBytes {
                            if explicitFile {
                                throw ToolExecutionFailure(message: "The text file exceeds the 32 MiB managed read limit. Nothing was searched. Do not retry the same file through Shell.")
                            }
                            report.skipped_files += 1; report.skipped_large_files += 1; report.count_is_exact = false
                            continue
                        }
                        if size > remaining { report.truncated = true; report.count_is_exact = false; break }
                    }
                    var pending: [PendingMatch] = []
                    var preceding: [ContextLine] = []
                    var hasMoreMatches = false
                    var lineCounts = Array(repeating: 0, count: queries.count)
                    let remainingMatches = maximum - report.matches.count
                    let summary: WorkspaceTextReader.Summary
                    do {
                        summary = try WorkspaceTextReader.scan(file, root: reader.root, limit: remaining) { line in
                            let matches = queries.indices.compactMap { index -> (Int, Range<String.Index>)? in
                                line.text.range(of: queries[index], options: options).map { (index, $0) }
                            }
                            for (index, _) in matches { lineCounts[index] += 1 }
                            guard output == "matches" else { return }
                            let visible = RepositoryTextPresentation.prefix(line.text)
                            let context = ContextLine(number: line.number, text: visible, line_truncated: visible != line.text)
                            for index in pending.indices where pending[index].after.count < after {
                                pending[index].after.append(context)
                            }
                            if !hasMoreMatches, let range = matches.first?.1 {
                                if pending.count >= remainingMatches { hasMoreMatches = true }
                                else {
                                    let snippet = RepositoryTextPresentation.snippet(line.text, range: range)
                                    pending.append(PendingMatch(number: line.number, text: snippet.text, column: snippet.column,
                                        offset: line.characterOffset + snippet.offset, truncated: snippet.truncated, before: preceding, queries: matches.map(\.0)))
                                }
                            }
                            if before > 0 {
                                preceding.append(context)
                                if preceding.count > before { preceding.removeFirst() }
                            }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard reader.identity.matches(reader.root) else { throw FileAreaService.AreaError.unsafePath }
                        if let error = error as? CocoaError, error.code == .fileReadTooLarge {
                            if remaining < WorkspaceTextLimits.maximumReadBytes { report.truncated = true; report.count_is_exact = false; break }
                            report.skipped_large_files += 1
                        }
                        if explicitFile { throw error }
                        report.skipped_files += 1
                        report.count_is_exact = false
                        continue
                    }
                    guard reader.identity.matches(reader.root) else { throw FileAreaService.AreaError.unsafePath }
                    bytes += summary.byteCount
                    report.scanned_files += 1
                    for index in queries.indices {
                        report.matching_lines[index] += lineCounts[index]
                        if lineCounts[index] > 0 { report.matching_files[index] += 1 }
                    }
                    if output == "paths", lineCounts.contains(where: { $0 > 0 }) {
                        if report.matches.count < maximum {
                            report.matches.append(Match(path: relative, line: nil, text: relative, sha256: summary.sha256,
                                line_truncated: false, query_indices: queries.indices.filter { lineCounts[$0] > 0 }))
                        } else { report.truncated = true }
                    }
                    report.truncated = report.truncated || hasMoreMatches
                    for item in pending {
                        let cursor = try WorkspaceTextReader.cursor(url: file, sha256: summary.sha256, offset: item.offset)
                        report.matches.append(Match(path: relative, line: item.number, text: item.text, sha256: summary.sha256,
                            line_truncated: item.truncated, column: item.column,
                            context_before: before > 0 ? item.before : nil, context_after: after > 0 ? item.after : nil,
                            read_cursor: cursor, query_indices: item.queries))
                        while try CodingJSON.encode(report).utf8.count > 5200 {
                            var last = report.matches.removeLast()
                            if var lines = last.context_after, !lines.isEmpty {
                                lines.removeLast(); last.context_after = lines
                            } else if var lines = last.context_before, !lines.isEmpty {
                                lines.removeFirst(); last.context_before = lines
                            } else {
                                report.truncated = true; report.count_is_exact = false
                                guard !report.matches.isEmpty else { throw ToolExecutionFailure(message: "The match or file path exceeds the result budget. Narrow the query or use files_read_range.") }
                                return try CodingJSON.encode(report)
                            }
                            last.context_truncated = true
                            report.matches.append(last)
                        }
                    }
                }
                if try CodingJSON.encode(report).utf8.count > 5200 { report.matches.removeLast(); report.truncated = true; report.count_is_exact = false; break }
            }
            guard reader.identity.matches(reader.root) else { throw FileAreaService.AreaError.unsafePath }
            if report.skipped_files > 0 || report.truncated {
                report.guidance = "Narrow path to the known file and query; use context_before/context_after or files_read_range/read_cursor for nearby text. Skipped or truncated input is not proof of no matches. Files above 32 MiB are not supported; do not retry the same read through Shell."
                if try CodingJSON.encode(report).utf8.count > 5500 { report.guidance = nil }
            }
            return try CodingJSON.encode(report)
        }
    }

    private static func glob(_ pattern: String) throws -> NSRegularExpression {
        let characters = Array(pattern)
        var result = "^", index = 0
        while index < characters.count {
            if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                if index + 2 < characters.count, characters[index + 2] == "/" { result += "(?:.*/)?"; index += 3 }
                else { result += ".*"; index += 2 }
            } else {
                switch characters[index] {
                case "*": result += "[^/]*"
                case "?": result += "[^/]"
                default: result += NSRegularExpression.escapedPattern(for: String(characters[index]))
                }
                index += 1
            }
        }
        return try NSRegularExpression(pattern: result + "$")
    }
}

/// 固定 Git 只读动作复用 Shell 的已核验沙箱路径，不接受模型提供的命令或选项。
struct RepositoryChangesTool: DispatcherTool {
    let reader: RepositoryReader
    let shell: ShellRunTool

    var requiresConfirmation: Bool { false }
    var permissionClass: PermissionClass { .readOnly }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition {
        ToolDefinition(name: "repo_changes", description:
            "Read Git status or a tracked-file diff in the bound workspace without shell approval. "
                + "The repository's .git metadata must be inside the bound workspace; choose its project-relative directory if it is a nested repository. "
                + "Status shows the repository's changed paths. Diff may be narrowed to an existing file or directory; staged=true reads the index diff. "
                + "This runs only the hardened, sandboxed read-only Git command. If output is truncated, narrow the diff path. "
                + "If Git metadata is outside the workspace, select the containing repository as the workspace rather than trying git -C or host Shell.",
            parametersSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["status","diff"]},"directory":{"type":"string","description":"Project-relative Git repository root; default ."},"path":{"type":"string","description":"Existing file or directory relative to directory; diff only"},"staged":{"type":"boolean","description":"Diff the index instead of unstaged changes; diff only"}},"required":["action"],"additionalProperties":false}"#)
    }

    func validateArguments(argumentsJSON: String) throws {
        _ = try command(argumentsJSON: argumentsJSON)
    }

    private func command(argumentsJSON: String) throws -> String {
        let input = ToolArguments.parse(argumentsJSON)
        guard input.keys.allSatisfy({ ["action", "directory", "path", "staged"].contains($0) }),
              let action = input["action"] as? String, ["status", "diff"].contains(action),
              input["directory"] == nil || input["directory"] is String,
              input["path"] == nil || input["path"] is String,
              input["staged"] == nil || input["staged"] is Bool,
              action == "diff" || (input["path"] == nil && input["staged"] == nil) else {
            throw ToolExecutionFailure(message: "repo_changes accepts status, or diff with an optional path and staged flag.")
        }
        let directory = try reader.resolve(input["directory"] as? String ?? ".")
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path),
              GitRepositoryInspector.isConfined(directory: directory, workspace: reader.root) else {
            throw ToolExecutionFailure(message: "Git metadata is not confined to this workspace. Select the containing repository as the workspace to inspect its changes; no command ran.")
        }
        var arguments = action == "status" ? ["status", "--short"] : ["diff", "--no-color"]
        if action == "diff" {
            if input["staged"] as? Bool == true { arguments.append("--cached") }
            if let path = input["path"] as? String {
                guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                      !path.split(separator: "/").contains("..") else {
                    throw ToolExecutionFailure(message: "The diff path must be relative to the selected repository.")
                }
                _ = try reader.resolve(directory.appendingPathComponent(path).path)
                arguments += ["--", path]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "program": "git", "arguments": arguments, "working_directory": directory.path
        ], options: [.sortedKeys])
        let request = String(decoding: data, as: UTF8.self)
        guard shell.permissionClass(argumentsJSON: request) == .readOnly,
              !shell.requiresHardConfirmation(argumentsJSON: request) else {
            throw ToolExecutionFailure(message: "The requested Git operation did not pass the sandbox read-only policy; no command ran.")
        }
        try shell.validateArguments(argumentsJSON: request)
        return request
    }

    func execute(argumentsJSON: String) async throws -> String {
        try await shell.executeVerifiedReadOnly(argumentsJSON: command(argumentsJSON: argumentsJSON))
    }
}
