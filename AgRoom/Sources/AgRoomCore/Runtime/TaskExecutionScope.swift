import Foundation
import Darwin
import CryptoKit

// MARK: - Task Execution Scope

/// Data destinations for one conversation, independent of its permission preset.
public enum TaskDataPolicy: String, Codable, CaseIterable, Sendable {
    case configuredServices
    case modelOnly
    case localOnly

    public var constraints: Set<TaskExecutionScope.Constraint> {
        switch self {
        case .configuredServices: []
        case .modelOnly: [.noExternalTools]
        case .localOnly: [.localOnly, .noExternalTools]
        }
    }

    public func restricted(by constraints: Set<TaskExecutionScope.Constraint>) -> Self {
        let combined = self.constraints.union(constraints)
        if combined.contains(.localOnly) { return .localOnly }
        return combined.contains(.noExternalTools) ? .modelOnly : .configuredServices
    }
}

/// 一次任务的执行范围：宿主在任务开始时根据会话、工作区、权限模式和真实用户指令构造。
///
/// 它只描述“本次任务允许推进到哪里”，不是一次具体调用的批准：
/// - 任务结束、停止或换工作区后由引擎撤销；
/// - 关闭模型审核不会撤销用户授予的工作区文件权限；
/// - 子任务取父范围的交集，不能自行增加目录或能力；
/// - 普通源码编辑不会改变目录身份，因此不会使整个范围失效。
public struct TaskExecutionScope: Codable, Sendable, Equatable {
    public enum Capability: String, Codable, CaseIterable, Sendable, Hashable {
        case read
        case write
        case edit
        case artifact
        case script
        case build
        case test
    }

    public enum Constraint: String, Codable, Sendable, Hashable {
        case noWrites
        case noCodeExecution
        case noHostExecution
        case noExternalTools
        case noMailSend
        case localOnly
    }

    public let id: UUID
    public let space: AppSpace
    public let sessionID: UUID?
    public let runID: UUID
    public let parentRunID: UUID?
    public let workspaceID: UUID?
    /// 工作区规范路径（空 = 未绑定工作区）。
    public let workspacePath: String
    /// 工作区目录身份，用于发现“路径相同但目录已被替换”。
    public let workspaceIdentity: TaskDirectoryIdentity?
    /// 写根 → 目录身份。只记录实际存在的根。
    public let writeRootIdentities: [String: TaskDirectoryIdentity]
    public let permissionMode: PermissionMode
    public let approvalPolicyVersion: String
    public let autoReviewEnabled: Bool
    /// 是否允许确定性规则直接批准文件写。后台/无头入口可关闭它，
    /// 但仍可把代码执行交给模型审核。
    public let allowsDeterministicApproval: Bool
    public let readRoots: [String]
    public let writeRoots: [String]
    public let artifactRoots: [String]
    public let capabilities: Set<Capability>
    public let constraints: Set<Constraint>
    /// 原始用户请求（有界）；审核模型只能据此判断操作是否符合任务。
    public let userRequest: String
    public internal(set) var mailTarget: MailTurnTarget?
    public let issuedAt: Date
    /// nil = 仅随任务生命周期失效；后台移交时由宿主设置明确的剩余有效期。
    public let expiresAt: Date?

    public init(
        id: UUID = UUID(),
        space: AppSpace,
        sessionID: UUID?,
        runID: UUID,
        parentRunID: UUID?,
        workspaceID: UUID?,
        workspacePath: String,
        workspaceIdentity: TaskDirectoryIdentity?,
        writeRootIdentities: [String: TaskDirectoryIdentity],
        permissionMode: PermissionMode,
        approvalPolicyVersion: String,
        autoReviewEnabled: Bool,
        allowsDeterministicApproval: Bool = true,
        readRoots: [String],
        writeRoots: [String],
        artifactRoots: [String],
        capabilities: Set<Capability>,
        constraints: Set<Constraint>,
        userRequest: String,
        mailTarget: MailTurnTarget? = nil,
        issuedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.space = space
        self.sessionID = sessionID
        self.runID = runID
        self.parentRunID = parentRunID
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.workspaceIdentity = workspaceIdentity
        self.writeRootIdentities = writeRootIdentities
        self.permissionMode = permissionMode
        self.approvalPolicyVersion = approvalPolicyVersion
        self.autoReviewEnabled = autoReviewEnabled
        self.allowsDeterministicApproval = allowsDeterministicApproval
        self.readRoots = Self.unique(readRoots)
        self.writeRoots = Self.unique(writeRoots)
        self.artifactRoots = Self.unique(artifactRoots)
        self.capabilities = capabilities
        self.constraints = constraints
        self.userRequest = String(userRequest.prefix(8_192))
        self.mailTarget = mailTarget
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// 构造宿主任务范围。工作区未绑定或目录不可核验时仍可得到只读范围，
    /// 但不会伪造写根；自动批准必须同时具备可核验的工作区身份。
    public static func make(
        space: AppSpace,
        sessionID: UUID?,
        runID: UUID,
        parentRunID: UUID?,
        workspaceID: UUID?,
        workspacePath: String,
        readRoots: [URL],
        writeRoots: [URL],
        artifactRoots: [URL],
        mode: PermissionMode,
        autoReviewEnabled: Bool,
        allowsDeterministicApproval: Bool = true,
        policyVersion: String,
        userRequest: String,
        dataPolicy: TaskDataPolicy = .configuredServices,
        allowsHostExecution: Bool = false
    ) -> TaskExecutionScope {
        var constraints = TaskConstraintExtractor.detect(in: userRequest).union(dataPolicy.constraints)
        if !allowsHostExecution { constraints.insert(.noHostExecution) }
        var capabilities = capabilities(for: mode)
        if constraints.contains(.noWrites) {
            capabilities.remove(.write)
            capabilities.remove(.edit)
            capabilities.remove(.artifact)
        }
        if constraints.contains(.noCodeExecution) {
            capabilities.remove(.script)
            capabilities.remove(.build)
            capabilities.remove(.test)
        }

        if !constraints.isDisjoint(with: [.noHostExecution, .localOnly, .noExternalTools]) {
            capabilities.subtract([.build, .test])
        }

        let canonicalWorkspace = canonical(workspacePath)
        let workspaceIdentity = canonicalWorkspace.flatMap {
            try? TaskDirectoryIdentity.capture(URL(fileURLWithPath: $0))
        }
        var identities: [String: TaskDirectoryIdentity] = [:]
        for root in writeRoots {
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            if let identity = try? TaskDirectoryIdentity.capture(root) {
                identities[path] = identity
            }
        }
        // 写根必须包含工作区；只把实际存在的目录纳入自动批准范围。
        let normalizedWrites = identities.keys.sorted()
        let normalizedReads = readRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let normalizedArtifacts = artifactRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        return TaskExecutionScope(
            space: space,
            sessionID: sessionID,
            runID: runID,
            parentRunID: parentRunID,
            workspaceID: workspaceID,
            workspacePath: canonicalWorkspace ?? workspacePath,
            workspaceIdentity: workspaceIdentity,
            writeRootIdentities: identities,
            permissionMode: mode,
            approvalPolicyVersion: policyVersion,
            autoReviewEnabled: autoReviewEnabled,
            allowsDeterministicApproval: allowsDeterministicApproval,
            readRoots: normalizedReads,
            writeRoots: normalizedWrites,
            artifactRoots: normalizedArtifacts,
            capabilities: capabilities,
            constraints: constraints,
            userRequest: userRequest
        )
    }

    public static func capabilities(for mode: PermissionMode) -> Set<Capability> {
        switch mode {
        case .readOnly:
            return [.read]
        case .workspaceWrite:
            return [.read, .write, .edit, .artifact, .script]
        case .dangerFullAccess:
            return [.read, .write, .edit, .artifact, .script]
        }
    }

    /// 任务是否仍有自动批准资格：未过期且所有已绑定目录的身份仍匹配。
    public func isActive(now: Date = Date()) -> Bool {
        if let expiresAt, now >= expiresAt { return false }
        return directoriesStillMatch()
    }

    public func directoriesStillMatch() -> Bool {
        if !workspacePath.isEmpty {
            guard let workspaceIdentity,
                  workspaceIdentity.matches(URL(fileURLWithPath: workspacePath)) else { return false }
        }
        for (path, identity) in writeRootIdentities {
            guard identity.matches(URL(fileURLWithPath: path)) else { return false }
        }
        return true
    }

    // Reviewed operations with no remote tool transport or implicit delegation. New tools
    // need an explicit assessment before becoming available under either restriction.
    private static let localTools: Set<String> = [
        "get_current_time", "files_list", "files_read", "files_read_range", "repo_search", "repo_symbols",
        "files_write", "files_edit", "files_apply_changes", "files_mkdir", "files_copy", "files_move",
        "files_rename", "files_delete", "skill_search", "skill_file", "skill_load", "skill_run_script",
        "python_execute", "python_packages", "shell_run", "sandbox_diagnose", "coding_task_read",
        "coding_task_update", "ask_user", ToolCatalog.searchName, "mail_save_draft", "project_inspect", "repo_changes"
    ]

    public func allowsTool(named name: String) -> Bool {
        if constraints.contains(.noMailSend), name == "mail_send" { return false }
        if constraints.contains(.noHostExecution), name == "project_build" { return false }
        guard constraints.contains(.localOnly) || constraints.contains(.noExternalTools) else { return true }
        return Self.localTools.contains(name)
    }

    public func allows(_ permissionClass: PermissionClass) -> Bool {
        switch permissionClass {
        case .readOnly:
            return capabilities.contains(.read)
        case .workspaceMutation:
            guard !constraints.contains(.noWrites) else { return false }
            return capabilities.contains(.write) || capabilities.contains(.edit)
        case .confinedCodeExecution:
            guard !constraints.contains(.noCodeExecution) else { return false }
            return capabilities.contains(.script)
        case .codeExecution:
            guard constraints.isDisjoint(with: [.noCodeExecution, .noHostExecution, .noExternalTools, .localOnly]) else { return false }
            return capabilities.contains(.script) || capabilities.contains(.build) || capabilities.contains(.test)
        case .externalEffect, .destructive:
            // 外部副作用仍由工具自身确认策略决定；任务范围不额外扩大它。
            return true
        }
    }

    /// 写目标必须落在任务写根内。空 targets 表示该调用不写文件，不做限制。
    public func containsWriteTargets(_ targets: [String]) -> Bool {
        Self.contains(targets, in: writeRoots)
    }

    func containsReadTargets(_ targets: [String]) -> Bool {
        Self.contains(targets, in: readRoots)
    }

    private static func contains(_ targets: [String], in paths: [String]) -> Bool {
        guard !targets.isEmpty else { return true }
        let roots = paths.map { URL(fileURLWithPath: $0) }
        guard !roots.isEmpty else { return false }
        for raw in targets {
            guard let url = FileAreaService.expandHome(raw) else { return false }
            guard roots.contains(where: { FileAreaService.isInside(url, root: $0) }) else { return false }
        }
        return true
    }

    /// Approval preferences can change while a task runs; directory and capability
    /// grants remain immutable. This copy never widens those grants.
    public func withAutoReviewEnabled(_ enabled: Bool) -> Self {
        Self(id: id, space: space, sessionID: sessionID, runID: runID, parentRunID: parentRunID,
             workspaceID: workspaceID, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
             writeRootIdentities: writeRootIdentities, permissionMode: permissionMode,
             approvalPolicyVersion: approvalPolicyVersion, autoReviewEnabled: enabled,
             allowsDeterministicApproval: allowsDeterministicApproval, readRoots: readRoots,
             writeRoots: writeRoots, artifactRoots: artifactRoots, capabilities: capabilities,
             constraints: constraints, userRequest: userRequest, mailTarget: mailTarget, issuedAt: issuedAt, expiresAt: expiresAt)
    }

    /// 子任务范围：同一空间/会话/工作区，能力与写根取交集，禁止项取并集。
    public func child(runID: UUID, subtaskID: UUID?) -> TaskExecutionScope {
        TaskExecutionScope(
            space: space,
            sessionID: sessionID,
            runID: runID,
            parentRunID: self.runID,
            workspaceID: workspaceID,
            workspacePath: workspacePath,
            workspaceIdentity: workspaceIdentity,
            writeRootIdentities: writeRootIdentities,
            permissionMode: permissionMode,
            approvalPolicyVersion: approvalPolicyVersion,
            autoReviewEnabled: autoReviewEnabled,
            allowsDeterministicApproval: allowsDeterministicApproval,
            readRoots: readRoots,
            writeRoots: writeRoots,
            artifactRoots: artifactRoots,
            capabilities: capabilities,
            constraints: constraints,
            userRequest: userRequest, mailTarget: mailTarget,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    /// 仅主动移交会携带此描述；它不是普通快照里的可重用批准。
    public func forHandoff(now: Date = Date()) -> Self {
        Self(id: id, space: space, sessionID: sessionID, runID: runID, parentRunID: parentRunID,
            workspaceID: workspaceID, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
            writeRootIdentities: writeRootIdentities, permissionMode: permissionMode,
            approvalPolicyVersion: approvalPolicyVersion, autoReviewEnabled: autoReviewEnabled,
            allowsDeterministicApproval: allowsDeterministicApproval, readRoots: readRoots,
            writeRoots: writeRoots, artifactRoots: artifactRoots, capabilities: capabilities,
            constraints: constraints, userRequest: userRequest, mailTarget: mailTarget, issuedAt: issuedAt,
            expiresAt: min(expiresAt ?? now.addingTimeInterval(86_400), now.addingTimeInterval(86_400)))
    }

    /// 后台重新核验身份，并与当前装配取交集；新目录、新能力和旧策略均不能混入。
    public func restored(restrictedTo current: Self, now: Date = Date()) throws -> Self {
        guard space == current.space, sessionID == current.sessionID, workspaceID == current.workspaceID,
              permissionMode <= current.permissionMode, workspacePath == current.workspacePath,
              approvalPolicyVersion == current.approvalPolicyVersion,
              expiresAt != nil, isActive(now: now) else {
            throw ToolExecutionFailure(message: "The handed-off task scope expired or no longer matches the session/workspace. Automatic continuation was stopped.")
        }
        let writes = writeRoots.filter { old in current.writeRoots.contains { FileAreaService.isInside(URL(fileURLWithPath: old), root: URL(fileURLWithPath: $0)) } }
        return Self(id: id, space: space, sessionID: sessionID, runID: current.runID, parentRunID: parentRunID,
            workspaceID: workspaceID, workspacePath: workspacePath, workspaceIdentity: workspaceIdentity,
            writeRootIdentities: writeRootIdentities.filter { writes.contains($0.key) },
            permissionMode: permissionMode, approvalPolicyVersion: approvalPolicyVersion,
            autoReviewEnabled: autoReviewEnabled && current.autoReviewEnabled,
            allowsDeterministicApproval: allowsDeterministicApproval && current.allowsDeterministicApproval,
            readRoots: readRoots.filter { old in current.readRoots.contains { FileAreaService.isInside(URL(fileURLWithPath: old), root: URL(fileURLWithPath: $0)) } },
            writeRoots: writes,
            artifactRoots: artifactRoots.filter { old in current.artifactRoots.contains { FileAreaService.isInside(URL(fileURLWithPath: old), root: URL(fileURLWithPath: $0)) } },
            capabilities: capabilities.intersection(current.capabilities),
            constraints: constraints.union(current.constraints), userRequest: userRequest, mailTarget: mailTarget,
            issuedAt: issuedAt, expiresAt: expiresAt)
    }

    /// 模型侧协议文本：说明本次任务硬性能力与禁止事项，不做 UI 本地化。
    public func systemPromptSection() -> String {
        let capabilityText = capabilities.map(\.rawValue).sorted().joined(separator: ", ")
        var lines = [
            "[Task Execution Scope]",
            "- Workspace: \(workspacePath.isEmpty ? "not bound" : workspacePath)",
            "- Capabilities for this task: \(capabilityText)",
            "- Automatic review: \(autoReviewEnabled ? "enabled for eligible calls; every call is revalidated before execution" : "off for model-reviewed calls; verified reads and managed changes within the granted folders need no additional approval")",
        ]
        if constraints.contains(.noWrites) {
            lines.append("- HARD CONSTRAINT: this task is analysis-only. Do not create, edit, move, delete, or overwrite files. File mutations will be blocked even if the permission mode would allow them.")
        }
        if constraints.contains(.noCodeExecution) {
            lines.append("- HARD CONSTRAINT: this task must not execute code or scripts. Shell, Python, and skill script calls will be blocked.")
        }
        if let mailTarget { lines.append(mailTarget.prompt) }
        if constraints.contains(.noMailSend) { lines.append("- The user requested a draft or prohibited mail delivery. Do not send through any service, tool, script or delegate.") }
        if constraints.contains(.localOnly) { lines.append("- Only a loopback model endpoint and reviewed local tools are available.") }
        if constraints.contains(.noExternalTools) { lines.append("- Do not submit data to external tools or delegate host operations.") }
        if constraints.contains(.noHostExecution) { lines.append("- Host code execution is disabled for this task.") }
        lines.append("- Stay inside this workspace. If a required directory is outside it, explain the exact directory and purpose and ask the user before requesting wider access.")
        return lines.joined(separator: "\n")
    }

    /// 任务范围的稳定摘要（用于审核缓存和审计；不含用户原文）。
    public var digest: String {
        struct Identity: Encodable {
            let id: String
            let space: String
            let workspacePath: String
            let writeRoots: [String]
            let capabilities: [String]
            let constraints: [String]
            let policyVersion: String
        }
        let value = Identity(
            id: id.uuidString,
            space: space.rawValue,
            workspacePath: workspacePath,
            writeRoots: writeRoots.sorted(),
            capabilities: capabilities.map(\.rawValue).sorted(),
            constraints: constraints.map(\.rawValue).sorted(),
            policyVersion: approvalPolicyVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return id.uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonical(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = FileAreaService.expandHome(trimmed) else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { raw in
            let path = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
            return seen.insert(path).inserted ? path : nil
        }
    }
}

// MARK: - Directory Identity

/// 规范路径 + 文件系统设备/inode。路径相同但目录被替换时 inode 会变化。
public struct TaskDirectoryIdentity: Codable, Sendable, Equatable {
    public let canonicalPath: String
    public let device: UInt64
    public let inode: UInt64

    public init(canonicalPath: String, device: UInt64, inode: UInt64) {
        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
    }

    public static func capture(_ url: URL) throws -> TaskDirectoryIdentity {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard stat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileNoSuchFile)
        }
        return TaskDirectoryIdentity(
            canonicalPath: canonical.path,
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    public func matches(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path == canonicalPath else { return false }
        var info = stat()
        guard stat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return UInt64(bitPattern: Int64(info.st_dev)) == device && UInt64(info.st_ino) == inode
    }
}

// MARK: - Task Constraint Extraction

/// 只识别明确的任务级限制。误判方向是收紧而不是放宽：
/// 命中后任务能力会被硬性降级，审核模型不能把它翻回来。
public enum TaskConstraintExtractor {
    private static let readOnlyPhrases = [
        "只分析", "仅分析", "只做分析", "仅做分析", "只查看", "仅查看", "只读", "仅只读",
        "only analyze", "analysis only", "only analyse", "read-only", "read only",
    ]
    private static let noWritePhrases = [
        "不要修改", "别修改", "不要改动", "别改动", "不要改代码", "别改代码",
        "不要写文件", "别写文件", "禁止修改", "禁止写入",
        "do not modify", "don't modify", "do not change", "don't change",
        "do not edit", "don't edit", "no edits", "no file changes",
    ]
    private static let noCodePhrases = [
        "不要执行", "别执行", "不要运行", "别运行", "禁止执行", "禁止运行",
        "do not run", "don't run", "do not execute", "don't execute", "no code execution",
    ]

    public static func detect(in request: String) -> Set<TaskExecutionScope.Constraint> {
        let text = request.lowercased()
        guard !text.isEmpty else { return [] }
        var result: Set<TaskExecutionScope.Constraint> = []
        if ToolRoutingHints.prohibitsMailDelivery(text) { result.insert(.noMailSend) }
        if readOnlyPhrases.contains(where: text.contains) {
            result.insert(.noWrites)
            result.insert(.noCodeExecution)
        }
        if noWritePhrases.contains(where: text.contains) {
            result.insert(.noWrites)
        }
        if noCodePhrases.contains(where: text.contains) {
            result.insert(.noCodeExecution)
        }
        // Match explicit directives as whole clauses. Quoted discussions about a setting
        // should not silently change where a conversation runs.
        let clauses = Set(text.components(separatedBy: CharacterSet(charactersIn: "，,。.!！;；\n:："))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if !clauses.isDisjoint(with: ["仅本机处理", "仅在本机处理", "只在本机处理", "仅在本機處理", "local only", "local processing only"]) {
            result.formUnion(TaskDataPolicy.localOnly.constraints)
        }
        if !clauses.isDisjoint(with: ["禁止对外提交", "不要对外提交", "禁止對外提交", "no external submissions"]) {
            result.insert(.noExternalTools)
        }
        if !clauses.isDisjoint(with: ["禁止宿主执行", "禁止宿主构建", "禁止宿主執行", "no host execution"]) {
            result.insert(.noHostExecution)
        }
        return result
    }
}
