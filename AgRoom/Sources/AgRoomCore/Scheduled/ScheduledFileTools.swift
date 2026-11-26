import Foundation

// MARK: - Scheduled File Read Scope

/// 定时运行的只读文件范围：只允许当前空间的受管根、默认工作区、default-chat 与登记工作区。
/// 不能复用普通 `files_*` 工具的“全受管根可读”行为：无人值守运行不应读取另一空间的
/// 默认工作区或 default-chat。
public struct ScheduledFileReadScope: Sendable {
    let service: FileAreaService
    let allowedRoots: [URL]

    public init(service: FileAreaService, space: AppSpace) {
        self.service = service
        let roots = service.scopedRoots ?? ([service.filesRoot]
            + service.defaultWriteRoots(for: space)
            + [service.defaultChatRoot(for: space)]
            + service.additionalRoots)
        self.allowedRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    func resolve(_ path: String) throws -> URL {
        let url = try service.resolveManaged(path)
        guard allowedRoots.contains(where: { FileAreaService.isInside(url, root: $0) }) else {
            throw LLMError.configurationError(
                reason: "Path is outside the current space's readable roots"
            )
        }
        return url
    }
}

// MARK: - Scheduled Files List Tool

/// 定时运行的 `files_list`：仅列当前空间可读根。
public struct ScheduledFilesListTool: DispatcherTool {
    let scope: ScheduledFileReadScope

    public init(scope: ScheduledFileReadScope) {
        self.scope = scope
    }

    public var requiresConfirmation: Bool { false }
    public var sideEffectClass: ToolSideEffectClass { .readOnly }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_list",
            description: "List a folder inside this task's readable roots: "
                + scope.allowedRoots.map(\.path).joined(separator: ", ")
                + ". Other workspace folders are not accessible. Omit path to list the first readable root.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute folder path inside the current space's readable roots"},"include_hidden":{"type":"boolean","description":"Include Finder-hidden items (default true)"}}}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawPath = ToolArguments.string(args, "path")
        let includeHidden = (args["include_hidden"] as? Bool) ?? true
        let target = try scope.resolve(rawPath.isEmpty ? scope.service.defaultReadRoot.path : rawPath)
        let entries = try scope.service.entries(at: target.path, includeHidden: includeHidden)
        guard !entries.isEmpty else { return "(empty folder) \(target.path)" }
        var lines = ["\(target.path) — \(entries.count) item(s)"]
        for entry in entries.prefix(500) {
            var line = entry.isDirectory ? "- \(entry.name)/" : "- \(entry.name)"
            if entry.isHidden { line += " [hidden]" }
            if let size = entry.byteSize { line += " (\(size) bytes)" }
            lines.append(line)
        }
        if entries.count > 500 { lines.append("... \(entries.count - 500) more") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Scheduled Files Read Tool

/// 定时运行的 `files_read`：仅读当前空间可读根。
public struct ScheduledFilesReadTool: DispatcherTool {
    let scope: ScheduledFileReadScope

    public init(scope: ScheduledFileReadScope) {
        self.scope = scope
    }

    public var requiresConfirmation: Bool { false }
    public var sideEffectClass: ToolSideEffectClass { .readOnly }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_read",
            description: "Read a UTF-8 text file inside the current space's readable file area. "
                + "Other spaces' default workspaces are not readable. "
                + "Returns paginated JSON with sha256 and next_cursor; continue until next_cursor is absent. Binary or oversized files are rejected.",
            parametersSchemaJSON: FilesReadTool(service: scope.service).definition.parametersSchemaJSON
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        guard !path.isEmpty else {
            throw LLMError.configurationError(reason: "files_read requires a 'path' argument")
        }
        let target = try scope.resolve(path)
        return try ManagedTextSnapshot(path: target.path, service: scope.service, limit: 2 * 1024 * 1024).page(args: args)
    }
}
