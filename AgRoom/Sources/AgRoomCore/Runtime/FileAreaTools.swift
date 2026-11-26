import Foundation

// MARK: - File Area Policy（文件区写权限策略）

/// 文件区写权限策略（引擎在执行写类工具前校验）：
/// - 对话读类工具只能访问当前工作区主目录与显式引用的文件夹。
/// - 写类工具的目标必须**同时**落在空间、会话、技能、子任务四层范围内。
///
/// 四层是交集而不是替换：技能声明只能收窄会话范围，不能把目标替换成另一个目录；
/// 子任务范围也一样。任何一层为空或无法核验时 fail closed，不回退到更宽范围。
public struct FileAreaPolicy: Sendable {
    public let service: FileAreaService
    /// 目标所属空间；另一空间的默认工作区是独立硬禁区。
    public let space: AppSpace
    /// 技能名 → 指定工作区路径（SKILL.md frontmatter workspace-folder）。
    /// 只保存已解析且落在当前空间范围内的声明。
    public let skillWorkspaces: [String: String]
    /// 技能名 → 声明无效的原因（无法解析、越界、与空间/会话范围无交集）。
    public let skillWorkspaceErrors: [String: String]
    /// 会话写根（权限模式决定的这一层；不是唯一的写范围）。
    public let defaultWriteRoots: [URL]
    /// 当前空间允许的写根（受管文件树、当前空间默认工作区、当前空间登记工作区）。
    public let spaceWriteRoots: [URL]
    /// 当前空间不可写入的另一空间专属目录（独立硬约束）。
    public let forbiddenSpaceRoots: [URL]

    public init(
        service: FileAreaService,
        space: AppSpace = .work,
        skillWorkspaces: [String: String] = [:],
        skillWorkspaceErrors: [String: String] = [:],
        defaultWriteRoots: [URL],
        spaceWriteRoots: [URL]? = nil
    ) {
        self.service = service
        self.space = space
        self.skillWorkspaces = skillWorkspaces
        self.skillWorkspaceErrors = skillWorkspaceErrors
        self.defaultWriteRoots = Self.normalized(defaultWriteRoots)
        let currentDefault = service.defaultWriteRoots(for: space)
        let broad = spaceWriteRoots ?? service.scopedRoots ?? ([service.filesRoot] + currentDefault + service.additionalRoots)
        self.spaceWriteRoots = Self.normalized(broad)
        let otherSpaces = AppSpace.allCases.filter { $0 != space }
        self.forbiddenSpaceRoots = Self.normalized(
            otherSpaces.flatMap {
                service.defaultWriteRoots(for: $0) + [service.defaultChatRoot(for: $0), PythonSpacePaths.root(space: $0)]
            }
        )
        self.subtaskWriteRoots = nil
    }

    /// 写类工具名 → 参数中承载写入目标的键。
    /// 仅保留给确认预览/旧调用方；引擎以工具自己声明的 `writeTargets` 为准。
    static let legacyWriteTargets: [String: [String]] = [
        "files_write": ["path"],
        "files_edit": ["path"],
        "files_apply_changes": [],
        "file_write": ["path"],
        "files_mkdir": ["path"],
        "files_delete": ["path"],
        "files_rename": ["path"],
        "files_copy": ["destination_dir"],
        "files_move": ["source", "destination_dir"],
        "team_write": ["path"],
        "skill_export_zip": ["destination_dir"]
    ]

    /// 兼容旧调用方：判断工具名是否属于已知写类工具。不要用它做授权判定。
    public static func isWriteTool(_ name: String) -> Bool {
        legacyWriteTargets[name] != nil
    }

    private static func normalized(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for root in roots {
            let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(resolved.path).inserted {
                result.append(resolved)
            }
        }
        return result
    }

    /// 为当前策略附加子任务写范围。子任务范围只能进一步收窄。
    public func restricted(toSubtaskRoots roots: [URL]) -> FileAreaPolicy {
        FileAreaPolicy(
            service: service,
            space: space,
            skillWorkspaces: skillWorkspaces,
            skillWorkspaceErrors: skillWorkspaceErrors,
            defaultWriteRoots: defaultWriteRoots,
            spaceWriteRoots: spaceWriteRoots,
            subtaskWriteRoots: roots
        )
    }

    /// 当前生效的子任务写范围（nil = 没有子任务层）。
    public let subtaskWriteRoots: [URL]?

    private init(
        service: FileAreaService,
        space: AppSpace,
        skillWorkspaces: [String: String],
        skillWorkspaceErrors: [String: String],
        defaultWriteRoots: [URL],
        spaceWriteRoots: [URL],
        subtaskWriteRoots: [URL]?
    ) {
        self.service = service
        self.space = space
        self.skillWorkspaces = skillWorkspaces
        self.skillWorkspaceErrors = skillWorkspaceErrors
        self.defaultWriteRoots = Self.normalized(defaultWriteRoots)
        self.spaceWriteRoots = Self.normalized(spaceWriteRoots)
        let otherSpaces = AppSpace.allCases.filter { $0 != space }
        self.forbiddenSpaceRoots = Self.normalized(
            otherSpaces.flatMap {
                service.defaultWriteRoots(for: $0) + [service.defaultChatRoot(for: $0), PythonSpacePaths.root(space: $0)]
            }
        )
        self.subtaskWriteRoots = subtaskWriteRoots.map(Self.normalized)
    }

    /// 技能声明是否无效（无效时禁止任何写，而不是回退到会话范围）。
    public func skillWorkspaceError(for skillName: String?) -> String? {
        guard let name = skillName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return skillWorkspaceErrors[name]
    }

    /// 校验一组已由工具声明的写目标：放行返回 nil，违规返回面向模型的拒绝原因。
    public func writeViolation(
        targets: [String],
        skillName: String? = nil,
        skillWorkspace: String? = nil,
        subtaskRoots: [URL]? = nil
    ) -> String? {
        guard !targets.isEmpty else { return nil }
        if let error = skillWorkspaceError(for: skillName) {
            return "Blocked: the active skill's workspace declaration is invalid, so no file writes "
                + "are allowed while it is active. \(error) Fix the skill's workspace-folder "
                + "or unload the skill; the engine will not fall back to a wider scope."
        }

        var layers: [(name: String, roots: [URL])] = [
            ("current space", spaceWriteRoots),
            ("this session", defaultWriteRoots),
        ]
        if let workspace = skillWorkspace?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty {
            guard let root = try? service.resolveManaged(workspace) else {
                return "Blocked: the active skill's workspace folder '\(workspace)' cannot be verified."
            }
            layers.append(("active skill", [root]))
        }
        if let subtaskRoots {
            layers.append(("current subtask", subtaskRoots))
        }

        for layer in layers where layer.roots.isEmpty {
            return "Blocked: the \(layer.name) has no writable roots, so no file write can be authorized."
        }

        for raw in targets {
            guard let url = FileAreaService.expandHome(raw) else {
                return "Blocked: write target '\(raw)' must be an absolute path (~/… allowed)."
            }
            // 空间隔离是独立硬约束：即使调用方把另一空间的目录登记进某个更宽范围，
            // 也不能在当前空间写入。
            if let forbidden = forbiddenSpaceRoots.first(where: { FileAreaService.isInside(url, root: $0) }) {
                return "Blocked: '\(raw)' is inside another space's exclusive directory "
                    + "(\(forbidden.path)). Spaces are physically isolated; write to a root owned "
                    + "by the current '\(space.rawValue)' space instead."
            }
            for layer in layers {
                let inside = layer.roots.contains { FileAreaService.isInside(url, root: $0) }
                guard inside else {
                    let description = layer.roots.map(\.path).joined(separator: " or ")
                    return "Blocked: write target '\(raw)' is outside the \(layer.name) write scope "
                        + "(\(description)). All effective scopes must contain the target; "
                        + "a loaded skill can only narrow the session scope."
                }
            }
        }
        return nil
    }

    /// 旧入口：按工具名从参数里取路径。新工具应实现 `writeTargets(argumentsJSON:)`。
    public func writeViolation(
        toolName: String,
        argumentsJSON: String,
        skillWorkspace: String?
    ) -> String? {
        guard let keys = Self.legacyWriteTargets[toolName] else { return nil }
        let args = ToolArguments.parse(argumentsJSON)
        let targets = keys.compactMap { args[$0] as? String }.filter { !$0.isEmpty }
        return writeViolation(targets: targets, skillWorkspace: skillWorkspace)
    }
}

// MARK: - File Area Tools（文件区调度工具组）

/// 文件区工具：读类（files_list / files_read）免确认；写类需用户确认。
/// 权限模型两层分工：
/// - 工具自身校验路径落在受管根内（files / workspace / privatespace 三个根）
/// - 引擎按 FileAreaPolicy 在 perform 守卫中校验写类工具的目标路径落在写根内
///   （活跃技能工作区优先，否则默认工作区；读类不受限）
public struct FilesListTool: DispatcherTool {
    let service: FileAreaService
    public init(service: FileAreaService) { self.service = service }

    public var requiresConfirmation: Bool { false }
    /// 只读：不入副作用日志，可安全重试
    public var sideEffectClass: ToolSideEffectClass { .readOnly }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_list",
            description: "List a folder within the allowed roots: "
                + service.managedRoots.map(\.path).joined(separator: ", ") + ". "
                + "Other workspaces are not implicitly accessible. Omit path to list \(service.defaultReadRoot.path). Folders sort first; hidden items are marked.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute folder path inside the managed roots (default: the file tree root)"},"include_hidden":{"type":"boolean","description":"Include Finder-hidden items (default true)"}}}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawPath = ToolArguments.string(args, "path")
        let includeHidden = (args["include_hidden"] as? Bool) ?? true
        let path = rawPath.isEmpty ? service.defaultReadRoot.path : rawPath
        let entries = try service.entries(at: path, includeHidden: includeHidden)
        guard !entries.isEmpty else { return "(empty folder) \(path)" }
        var lines = ["\(path) — \(entries.count) item(s)"]
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

public struct FilesReadTool: DispatcherTool {
    let service: FileAreaService
    public init(service: FileAreaService) { self.service = service }

    public var requiresConfirmation: Bool { false }
    /// 只读：不入副作用日志，可安全重试
    public var sideEffectClass: ToolSideEffectClass { .readOnly }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_read",
            description: "Read a UTF-8 text file within the allowed roots: "
                + service.managedRoots.map(\.path).joined(separator: ", ") + ". Other workspaces are not implicitly accessible. "
                + "Streams UTF-8 files up to 32 MiB and returns a bounded JSON page with content, the complete file sha256, offset, total_characters and next_cursor. Continue using next_cursor until absent; it also accepts read_cursor from repo_search or next_cursor from files_read_range to start near a long-line match. If the file changes restart the read. Pages fit the model result budget, including JSON escaping. Use sha256 with files_edit for files up to 16 MiB. Binary or oversized files are rejected; do not retry the same read through Shell.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute file path inside the managed roots"},"cursor":{"type":"string","description":"Opaque next_cursor from the previous page; omit for first page"},"max_chars":{"type":"integer","minimum":1,"maximum":4000,"description":"Maximum content characters, default 3500; may be reduced to fit the result budget"}},"required":["path"]}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        guard !path.isEmpty else {
            throw LLMError.configurationError(reason: "files_read requires a 'path' argument")
        }
        return try await WorkspaceTextReader.perform {
            try WorkspaceTextReader.page(path: path, service: service, args: ToolArguments.parse(argumentsJSON))
        }
    }
}

public struct FilesWriteTool: DispatcherTool {
    let service: FileAreaService
    let space: AppSpace
    let leases: TeamLeaseCenter
    public init(
        service: FileAreaService,
        space: AppSpace = .work,
        leases: TeamLeaseCenter = .shared
    ) {
        self.service = service
        self.space = space
        self.leases = leases
    }

    public var requiresConfirmation: Bool { true }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public func validateArguments(argumentsJSON: String) throws {
        let args = ToolArguments.parse(argumentsJSON)
        guard let path = args["path"] as? String, FileAreaService.expandHome(path) != nil, args["content"] is String else {
            throw ToolExecutionFailure(message: "files_write requires an absolute path and text content.")
        }
    }
    public func writeTargets(argumentsJSON: String) -> [String] {
        [ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")].filter { !$0.isEmpty }
    }

    /// 自动审核资格：写入受 FileAreaPolicy 写范围约束，且同名冲突自动改名、从不覆盖，
    /// 属可自动放行的低风险写。引擎与服务仍会按会话工作区核对目标路径：
    /// 未选定工作区转人工，落在工作区外直接拒绝
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_write",
            description: "Write text content to a file in the managed file area (creates the file; "
                + "if the name already exists the new file gets ' 2', ' 3' suffixes automatically — existing files are never overwritten; "
                + "intermediate folders are created). Writes must stay inside the current write scope: "
                + "the active skill's workspace folder if a skill with a workspace is loaded, "
                + "otherwise this session's workspace directory (see the [Managed File Area] section of the environment). "
                + "Paths outside the scope are blocked by the engine.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute destination path, e.g. ~/Documents/AgRoom/workspace/notes.md"},"content":{"type":"string","description":"Full text content to write"}},"required":["path","content"]}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        let content = ToolArguments.string(args, "content")
        guard !path.isEmpty else {
            throw LLMError.configurationError(reason: "files_write requires a 'path' argument")
        }
        guard let target = FileAreaService.expandHome(path) else {
            throw LLMError.configurationError(reason: "files_write requires an absolute path")
        }
        // 与团队写共用同一进程内路径租约，避免主对话与 Worker 同时写同一文件。
        let lease = try await leases.acquire(
            space: space.rawValue,
            path: target.standardizedFileURL.resolvingSymlinksInPath().path,
            taskID: UUID(),
            subtaskID: UUID()
        )
        do {
            let url = try service.writeText(at: path, content: content)
            try await ToolArtifactCapture.record(url, root: url.deletingLastPathComponent(), logicalPath: target.standardizedFileURL.path,
                baseline: .created, expectedContents: Data(content.utf8))
            await leases.release(lease)
            return "Written \(content.count) characters to \(url.path)"
        } catch {
            await leases.release(lease)
            throw error
        }
    }
}

public struct FilesMkdirTool: DispatcherTool {
    let service: FileAreaService
    public init(service: FileAreaService) { self.service = service }

    public var requiresConfirmation: Bool { true }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public func writeTargets(argumentsJSON: String) -> [String] {
        [ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")].filter { !$0.isEmpty }
    }

    /// 自动审核资格：仅创建目录、不删改既有内容，属可自动放行的低风险写；
    /// 目标路径同样由引擎与服务按会话工作区核对
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_mkdir",
            description: "Create a folder (including intermediate folders) in the managed file area. "
                + "Must stay inside the current write scope (active skill workspace, or this session's workspace directory).",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute folder path to create, e.g. ~/Documents/AgRoom/files/projects/demo"}},"required":["path"]}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        guard !path.isEmpty else {
            throw LLMError.configurationError(reason: "files_mkdir requires a 'path' argument")
        }
        let url = try service.createDirectory(at: path)
        return "Created folder \(url.path)"
    }
}

public struct FilesDeleteTool: DispatcherTool {
    let service: FileAreaService
    let space: AppSpace
    public init(service: FileAreaService, space: AppSpace = .work) {
        self.service = service
        self.space = space
    }

    public var requiresConfirmation: Bool { true }
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public func writeTargets(argumentsJSON: String) -> [String] {
        [ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")].filter { !$0.isEmpty }
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_delete",
            description: "Move a file or folder (recursive) in the managed file area to the system Trash, "
                + "recoverable from Finder via 'Put Back'; must stay inside the current write scope.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path of the file or folder to delete"}},"required":["path"]}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        guard !path.isEmpty else {
            throw LLMError.configurationError(reason: "files_delete requires a 'path' argument")
        }
        let trashed = try service.delete(at: path, space: space)
        let destination = trashed.map { " (now at \($0.path))" } ?? ""
        return "Moved to Trash: \(path)\(destination)"
    }
}

public struct FilesRenameTool: DispatcherTool {
    let service: FileAreaService
    let space: AppSpace
    public init(service: FileAreaService, space: AppSpace = .work) {
        self.service = service
        self.space = space
    }

    public var requiresConfirmation: Bool { true }
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public func validateArguments(argumentsJSON: String) throws {
        let args = ToolArguments.parse(argumentsJSON)
        try FileAreaService.validateName(ToolArguments.string(args, "new_name").trimmingCharacters(in: .whitespacesAndNewlines))
        guard FileAreaService.expandHome(ToolArguments.string(args, "path")) != nil else { throw FileAreaService.AreaError.unsafePath }
    }
    public func writeTargets(argumentsJSON: String) -> [String] {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        let name = ToolArguments.string(args, "new_name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = FileAreaService.expandHome(path), (try? FileAreaService.validateName(name)) != nil else { return [] }
        return [path, item.deletingLastPathComponent().appendingPathComponent(name).path]
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_rename",
            description: "Rename a file or folder in place (the new full name may change the extension, "
                + "e.g. 'notes.txt' → 'notes.md'). Must stay inside the current write scope.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path of the item to rename"},"new_name":{"type":"string","description":"New full name (no path separators), including the extension if any"}},"required":["path","new_name"]}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        let newName = ToolArguments.string(args, "new_name")
        guard !path.isEmpty, !newName.isEmpty else {
            throw LLMError.configurationError(reason: "files_rename requires 'path' and 'new_name' arguments")
        }
        let url = try service.rename(at: path, to: newName, space: space)
        try await ToolArtifactCapture.recordItem(url, logicalPath: FileAreaService.expandHome(path)?.standardizedFileURL.path)
        return "Renamed to \(url.path)"
    }
}

public struct FilesCopyTool: DispatcherTool {
    let service: FileAreaService
    let space: AppSpace
    public init(service: FileAreaService, space: AppSpace = .work) {
        self.service = service
        self.space = space
    }

    public var requiresConfirmation: Bool { true }
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public func readTargets(argumentsJSON: String) -> [String] {
        [ToolArguments.string(ToolArguments.parse(argumentsJSON), "source")]
    }
    public func writeTargets(argumentsJSON: String) -> [String] {
        [ToolArguments.string(ToolArguments.parse(argumentsJSON), "destination_dir")].filter { !$0.isEmpty }
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_copy",
            description: "Copy a file or folder into a destination folder (source is readable from any managed root; "
                + "name conflicts get ' 2', ' 3' suffixes automatically). "
                + "The destination folder must be inside the current write scope.",
            parametersSchemaJSON: #"{"type":"object","properties":{"source":{"type":"string","description":"Absolute path of the file/folder to copy (any managed root)"},"destination_dir":{"type":"string","description":"Absolute destination folder path (must be inside the write scope)"}},"required":["source","destination_dir"]}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let source = ToolArguments.string(args, "source")
        let destDir = ToolArguments.string(args, "destination_dir")
        guard !source.isEmpty, !destDir.isEmpty else {
            throw LLMError.configurationError(reason: "files_copy requires 'source' and 'destination_dir' arguments")
        }
        let url = try service.copyItem(from: source, toDirectory: destDir, space: space)
        try await ToolArtifactCapture.recordItem(url)
        return "Copied to \(url.path)"
    }
}

public struct FilesMoveTool: DispatcherTool {
    let service: FileAreaService
    let space: AppSpace
    public init(service: FileAreaService, space: AppSpace = .work) {
        self.service = service
        self.space = space
    }

    public var requiresConfirmation: Bool { true }
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public func writeTargets(argumentsJSON: String) -> [String] {
        let args = ToolArguments.parse(argumentsJSON)
        return [
            ToolArguments.string(args, "source"),
            ToolArguments.string(args, "destination_dir"),
        ].filter { !$0.isEmpty }
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files_move",
            description: "Move a file or folder into a destination folder (both must be inside the current write scope; "
                + "moving into the same folder is a no-op). Name conflicts get ' 2', ' 3' suffixes automatically.",
            parametersSchemaJSON: #"{"type":"object","properties":{"source":{"type":"string","description":"Absolute path of the file/folder to move (must be inside the write scope)"},"destination_dir":{"type":"string","description":"Absolute destination folder path (must be inside the write scope)"}},"required":["source","destination_dir"]}"#
        )
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let source = ToolArguments.string(args, "source")
        let destDir = ToolArguments.string(args, "destination_dir")
        guard !source.isEmpty, !destDir.isEmpty else {
            throw LLMError.configurationError(reason: "files_move requires 'source' and 'destination_dir' arguments")
        }
        let url = try service.moveItem(from: source, toDirectory: destDir, space: space)
        if let url { try await ToolArtifactCapture.recordItem(url, logicalPath: FileAreaService.expandHome(source)?.standardizedFileURL.path) }
        return url.map { "Moved to \($0.path)" } ?? "Source already in destination folder (no-op)"
    }
}
