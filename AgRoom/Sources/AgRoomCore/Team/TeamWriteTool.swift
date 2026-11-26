import Foundation

// MARK: - Write Log

/// 记录本 Worker 实际写成功的文件，完成后并入 `TeamSubtaskResult.artifacts`，
/// 让任务板能看到文件变更，而不是只依赖模型在正文里描述。
final class TeamWriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [TeamArtifactDraft] = []

    func record(_ write: TeamWriteRecord) {
        var draft = TeamArtifactDraft(kind: "file-change", title: write.path, content: write.newContent)
        draft.writeRecordID = write.id
        lock.withLock { entries.append(draft) }
    }

    func drafts() -> [TeamArtifactDraft] {
        lock.withLock { entries }
    }
}

// MARK: - Team Write Tool

/// P2a 的受控文件写：只允许写当前会话工作区内的文本文件。
/// 每次写入都先在中央审批中心挂起，任务板审批收件箱由用户逐次决定；
/// 批准后才申请路径级写租约，写入前再次校验文件未被改动。
struct TeamWriteTool: DispatcherTool {
    let taskID: UUID
    let taskGoal: String
    let subtaskID: UUID
    let subtaskTitle: String
    let space: AppSpace
    let root: URL
    /// 宿主核验后的子任务写范围（默认整个 root）。
    let allowedRoots: [URL]
    let approvals: TeamApprovalCenter
    let leases: TeamLeaseCenter
    let writeStore: TeamWriteStore?
    let writeLog: TeamWriteLog

    private static let maxContentBytes = 1_000_000
    private static let maxPathLength = 1_024
    /// 审批与快照策略版本：规则变化时旧批准失效。
    static let policyVersion = 2

    init(
        taskID: UUID,
        taskGoal: String,
        subtaskID: UUID,
        subtaskTitle: String,
        space: AppSpace,
        root: URL,
        allowedRoots: [URL]? = nil,
        approvals: TeamApprovalCenter,
        leases: TeamLeaseCenter,
        writeStore: TeamWriteStore? = nil,
        writeLog: TeamWriteLog = TeamWriteLog()
    ) {
        self.taskID = taskID
        self.taskGoal = taskGoal
        self.subtaskID = subtaskID
        self.subtaskTitle = subtaskTitle
        self.space = space
        self.root = root
        self.allowedRoots = allowedRoots ?? [root]
        self.approvals = approvals
        self.leases = leases
        self.writeStore = writeStore
        self.writeLog = writeLog
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "team_write",
            description: "Write a UTF-8 text file inside this task's conversation workspace. "
                + "Every write is shown to the user in the team approval inbox and must be approved; "
                + "the tool waits for that decision. Paths outside the workspace, binary files, and files larger than 1 MB are rejected. "
                + "Use this only for the task's deliverables. You cannot run shell commands, delete files, or write outside the workspace.",
            parametersSchemaJSON: #"""
            {"type":"object","properties":{"path":{"type":"string","description":"Absolute path inside the conversation workspace, or a path relative to it"},"content":{"type":"string","description":"Full UTF-8 text content to write; this replaces the file"}},"required":["path","content"]}
            """#
        )
    }

    let requiresConfirmation = false
    var sideEffectClass: ToolSideEffectClass { .nonIdempotentWrite }
    var permissionClass: PermissionClass { .workspaceMutation }
    func writeTargets(argumentsJSON: String) -> [String] {
        let raw = ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return [expanded] }
        return [root.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(expanded, isDirectory: false).path]
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let rawPath = ToolArguments.string(args, "path")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty, rawPath.count <= Self.maxPathLength else {
            throw TeamWriteError.invalidPath
        }
        guard let content = args["content"] as? String, !content.utf8.contains(0) else {
            throw TeamWriteError.invalidContent
        }
        guard content.utf8.count <= Self.maxContentBytes else {
            throw TeamWriteError.tooLarge
        }

        let rootIdentity = try TaskDirectoryIdentity.capture(root)
        let target = try resolve(rawPath)
        guard FileAreaService.isInside(target, root: URL(fileURLWithPath: rootIdentity.canonicalPath)),
              rootIdentity.matches(root) else { throw TeamWriteError.outsideWorkspace }
        let oldContent = try readTextIfExists(target, rootIdentity: rootIdentity)
        guard let writeStore else {
            throw TeamWriteError.snapshotUnavailable
        }

        let request = TeamApprovalRequest(
            space: space.rawValue,
            taskID: taskID,
            taskGoal: taskGoal,
            subtaskID: subtaskID,
            subtaskTitle: subtaskTitle,
            path: target.path,
            oldContent: oldContent,
            newContent: content,
            expiresAt: Date().addingTimeInterval(600),
            policyVersion: Self.policyVersion
        )
        let decision = await approvals.request(request, timeout: 600)
        let auditDecision: String
        let auditReason: String
        switch decision {
        case .approved:
            auditDecision = "approved"
            auditReason = "user_approved_once"
        case .denied:
            auditDecision = "denied"
            auditReason = "user_denied"
        case .expired:
            auditDecision = "expired"
            auditReason = "approval_timeout"
        case .cancelled:
            auditDecision = "cancelled"
            auditReason = "task_cancelled"
        }
        try? await writeStore.recordApproval(
            taskID: taskID,
            space: space.rawValue,
            path: target.path,
            decision: auditDecision,
            reason: auditReason
        )
        switch decision {
        case .approved:
            break
        case .denied:
            throw TeamApprovalError.denied
        case .expired:
            throw TeamApprovalError.expired
        case .cancelled:
            throw CancellationError()
        }
        try Task.checkCancellation()

        let lease = try await leases.acquire(
            space: space.rawValue,
            path: target.path,
            taskID: taskID,
            subtaskID: subtaskID
        )
        do {
            try Task.checkCancellation()
            // 审批展示的是批准前的版本；申请租约后再次核对路径与内容，
            // 避免批准后文件被改或被替换成符号链接。策略版本变化同样使批准失效。
            guard Self.policyVersion == request.policyVersion else {
                throw TeamWriteError.policyChanged
            }
            let revalidated = try resolve(rawPath)
            guard revalidated.path == target.path, rootIdentity.matches(root) else {
                throw TeamWriteError.changedSinceApproval
            }
            let current = try readTextIfExists(target, rootIdentity: rootIdentity)
            guard current == oldContent else {
                throw TeamWriteError.changedSinceApproval
            }
            // 先落回滚快照再写；快照写不进去时宁可不写，保证每次团队写都可审阅。
            let record = try await writeStore.record(
                taskID: taskID,
                space: space.rawValue,
                rootPath: rootIdentity.canonicalPath,
                path: target.path,
                oldContent: oldContent,
                newContent: content,
                policyVersion: Self.policyVersion, rootIdentity: rootIdentity
            )
            do {
                // 从工作区根逐级 openat(O_NOFOLLOW)，在父目录句柄上临时文件 + renameat。
                try SecureFileWriter.write(Data(content.utf8), to: target, root: URL(fileURLWithPath: rootIdentity.canonicalPath),
                    policy: oldContent.map { .matching(Data($0.utf8)) } ?? .createOnly, expectedRoot: rootIdentity)
                try await writeStore.markApplied(id: record.id)
                writeLog.record(record)
            } catch {
                // 保留快照并标记失败/需恢复，不能静默删除写历史。
                try? await writeStore.markFailed(id: record.id, needsRecovery: true)
                await leases.release(lease)
                throw error
            }
            try await ToolArtifactCapture.record(target, root: root, rootIdentity: rootIdentity,
                                                 expectedContents: Data(content.utf8))
            await leases.release(lease)
            let action = oldContent == nil ? "Created" : "Updated"
            return "\(action) \(target.path) (\(content.utf8.count) bytes) after user approval."
        } catch {
            await leases.release(lease)
            throw error
        }
    }

    // MARK: Path & Read

    private func resolve(_ rawPath: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded, isDirectory: false)
        } else {
            candidate = rootResolved.appendingPathComponent(expanded, isDirectory: false)
        }
        let standardizedCandidate = candidate.standardizedFileURL
        if let candidateValues = try? standardizedCandidate.resourceValues(forKeys: [.isSymbolicLinkKey]),
           candidateValues.isSymbolicLink == true {
            throw TeamWriteError.symlinkNotAllowed
        }
        let resolved = standardizedCandidate.resolvingSymlinksInPath()
        let confined = allowedRoots.contains { allowed in
            let rootResolved = allowed.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = rootResolved.path.hasSuffix("/") ? rootResolved.path : rootResolved.path + "/"
            return resolved.path != rootResolved.path && resolved.path.hasPrefix(prefix)
        }
        guard confined else {
            throw TeamWriteError.outsideWorkspace
        }
        if let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if values.isDirectory == true { throw TeamWriteError.isDirectory }
            if values.isSymbolicLink == true { throw TeamWriteError.symlinkNotAllowed }
        }
        return resolved
    }

    private func readTextIfExists(_ url: URL, rootIdentity: TaskDirectoryIdentity) throws -> String? {
        guard rootIdentity.matches(root) else { throw TeamWriteError.changedSinceApproval }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw type == .typeDirectory ? TeamWriteError.isDirectory : TeamWriteError.notRegularFile
        }
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maxContentBytes {
            throw TeamWriteError.tooLarge
        }
        var text = ""
        _ = try WorkspaceTextReader.scan(url, root: URL(fileURLWithPath: rootIdentity.canonicalPath),
            limit: Self.maxContentBytes, expectedRoot: rootIdentity) { line in
            text += line.text
            if line.terminated { text += "\n" }
        }
        return text
    }
}

// MARK: - Write Errors

enum TeamWriteError: LocalizedError, Equatable {
    case invalidPath
    case invalidContent
    case outsideWorkspace
    case isDirectory
    case notRegularFile
    case symlinkNotAllowed
    case binaryFile
    case tooLarge
    case changedSinceApproval
    case snapshotUnavailable
    case policyChanged

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "team_write requires a non-empty relative or absolute path inside the conversation workspace."
        case .invalidContent:
            return "team_write requires a string 'content' argument (empty string is allowed)."
        case .outsideWorkspace:
            return "team_write target is outside the conversation workspace. Choose a path inside it."
        case .isDirectory:
            return "team_write target is a directory; it only writes text files."
        case .notRegularFile:
            return "team_write target is not a regular file; devices, pipes and special files are rejected."
        case .symlinkNotAllowed:
            return "team_write refuses symbolic links. Choose a regular file inside the workspace."
        case .binaryFile:
            return "team_write refuses to overwrite a non-UTF8/binary file."
        case .tooLarge:
            return "team_write is limited to 1 MB of UTF-8 text."
        case .changedSinceApproval:
            return "The file changed after the user approved the write; approve a fresh write to the current version."
        case .snapshotUnavailable:
            return "Team writes are disabled because the write-snapshot store is unavailable; no file was changed."
        case .policyChanged:
            return "The approval was issued under an older write policy; request a fresh approval."
        }
    }
}
