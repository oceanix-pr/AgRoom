import CryptoKit
import Foundation

/// 文件读取、游标和编辑使用同一份原始 UTF-8 字节身份。
struct ManagedTextSnapshot {
    static let maximumBytes = RepositoryReader.fileLimit
    let url: URL
    let root: URL
    let rootIdentity: TaskDirectoryIdentity
    let data: Data
    let text: String
    var sha256: String { Self.digest(data) }

    init(path: String, service: FileAreaService, limit: Int = maximumBytes) throws {
        guard (1...Self.maximumBytes).contains(limit) else {
            throw ToolExecutionFailure(message: "Invalid managed text size limit.")
        }
        let url = try service.resolveManaged(path)
        guard let root = service.managedRoots.map({ $0.standardizedFileURL.resolvingSymlinksInPath() })
            .filter({ url.path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) else {
            throw FileAreaService.AreaError.unsafePath
        }
        rootIdentity = try TaskDirectoryIdentity.capture(root)
        let data: Data
        do {
            data = try ScriptFileIdentity.read(url, root: root, limit: limit)
        } catch let error as CocoaError where error.code == .fileReadTooLarge {
            throw ToolExecutionFailure(message: "This file exceeds the managed text limit of \(limit) bytes. Use repo_search or files_read_range for bounded inspection. Nothing was edited.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolExecutionFailure(message: "The file is not UTF-8 text. Use a dedicated binary file tool.")
        }
        self.url = url; self.root = root; self.data = data; self.text = text
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private struct Cursor: Codable { let pathHash: String; let sha256: String; let offset: Int }
    struct Page: Codable {
        let path: String
        let sha256: String
        let total_characters: Int
        let offset: Int
        let next_cursor: String?
        let content: String
    }

    func page(args: [String: Any]) throws -> String {
        var offset = 0
        let pathHash = Self.digest(Data(url.path.utf8))
        if let raw = args["cursor"] {
            guard let value = raw as? String, value.utf8.count <= 1024, let bytes = Data(base64Encoded: value),
                  let cursor = try? JSONDecoder().decode(Cursor.self, from: bytes), cursor.pathHash == pathHash,
                  cursor.sha256 == sha256 else {
                throw ToolExecutionFailure(message: "The read cursor is invalid or the file changed. Start files_read again without a cursor; do not combine pages from different file versions.")
            }
            offset = cursor.offset
        }
        let totalCharacters = text.count
        guard (0...totalCharacters).contains(offset),
              args["max_chars"] == nil || args["max_chars"] is Int else {
            throw ToolExecutionFailure(message: "Invalid read cursor or max_chars. max_chars must be an integer from 1 to 4000.")
        }
        let maximum = args["max_chars"] as? Int ?? 3500
        guard (1...4000).contains(maximum) else { throw ToolExecutionFailure(message: "max_chars must be from 1 to 4000.") }
        var count = min(maximum, totalCharacters - offset)
        let startIndex = text.index(text.startIndex, offsetBy: offset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while true {
            let next = offset + count
            let cursor = next < totalCharacters
                ? try encoder.encode(Cursor(pathHash: pathHash, sha256: sha256, offset: next)).base64EncodedString() : nil
            let endIndex = text.index(startIndex, offsetBy: count)
            let page = Page(path: url.path, sha256: sha256, total_characters: totalCharacters, offset: offset,
                next_cursor: cursor, content: String(text[startIndex..<endIndex]))
            let result = String(decoding: try encoder.encode(page), as: UTF8.self)
            // JSON 转义也计入模型的 6000 字符预算，保证游标对应的内容全部送达。
            if result.count <= 5500 { return result }
            guard count > 1 else { throw ToolExecutionFailure(message: "The file metadata exceeds the page budget.") }
            count = max(1, count - (result.count - 5500))
        }
    }
}

public struct FilesEditTool: DispatcherTool {
    let service: FileAreaService
    let space: AppSpace
    let leases: TeamLeaseCenter
    /// 任务恢复点存储；nil = 旧装配/测试，不能自动批准已有文件编辑。
    let recoveryStore: TaskFileRecoveryStore?
    /// 当前任务身份；恢复点与审计按它归属，子代理共享父任务。
    let taskID: UUID?
    /// 可控的发布前挂起，用于验证保存恢复点与实际落盘之间的取消边界。
    var beforePublication: (@Sendable () async -> Void)?
    public init(
        service: FileAreaService,
        space: AppSpace = .work,
        leases: TeamLeaseCenter = .shared,
        recoveryStore: TaskFileRecoveryStore? = nil,
        taskID: UUID? = nil
    ) {
        self.service = service; self.space = space; self.leases = leases
        self.recoveryStore = recoveryStore; self.taskID = taskID
    }
    public var requiresConfirmation: Bool { true }
    public var permissionClass: PermissionClass { .workspaceMutation }
    public func validateArguments(argumentsJSON: String) throws {
        let args = ToolArguments.parse(argumentsJSON)
        guard argumentsJSON.utf8.count <= 512 * 1024,
              let path = args["path"] as? String, FileAreaService.expandHome(path) != nil,
              let digest = args["expected_sha256"] as? String,
              digest.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              let old = args["old_text"] as? String, !old.isEmpty, old.utf8.count <= 256 * 1024,
              let new = args["new_text"] as? String, new.utf8.count <= 256 * 1024 else {
            throw ToolExecutionFailure(message: "Provide an absolute path, the current SHA-256 and a bounded unique literal edit.")
        }
    }
    /// 有恢复点存储和任务身份时才允许进入确定性审批；否则保持仅人工。
    public func approvalRoute(argumentsJSON: String) -> ApprovalRoute {
        recoveryStore != nil && taskID != nil ? .deterministic : .manualOnly
    }
    public func autoReviewEvidence(argumentsJSON: String) -> [String: String] {
        ["recovery_store": recoveryStore != nil && taskID != nil ? "true" : "false"]
    }
    /// 授权范围按文件：同一轮内对同一文件的后续编辑复用首次批准。
    public var confirmationScope: ConfirmationRequirement.Scope { .fileArea }
    /// 本轮允许此文件：只绑定规范化路径，不绑定内容。
    /// 每次执行仍校验 expected_sha256 并在写入前核对旧字节；内容变化会失败关闭，
    /// 不会把旧批准应用到新内容。
    public func roundAuthorizationKey(argumentsJSON: String) -> String? {
        let args = ToolArguments.parse(argumentsJSON)
        guard let path = args["path"] as? String, !path.isEmpty,
              let url = FileAreaService.expandHome(path) else { return nil }
        return "files_edit#" + url.standardizedFileURL.resolvingSymlinksInPath().path
    }
    public func writeTargets(argumentsJSON: String) -> [String] { [ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")] }
    public var definition: ToolDefinition {
        ToolDefinition(name: "files_edit", description:
            "Edit an existing UTF-8 file up to 16 MiB by replacing exactly one unique literal old_text with new_text. Obtain expected_sha256 from repo_search, files_read_range or files_read; stale content, multiple matches and symbolic links are rejected. Preserves all other bytes and writes atomically under the existing workspace/skill/subtask policy. A verified edit in the active workspace grant needs no further approval; every edit still revalidates expected_sha256, the unique match and the old bytes before writing, and a failed recovery point aborts the write. files_write only creates new files and is not an editing tool.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute existing file path"},"expected_sha256":{"type":"string","description":"SHA-256 from the current files_read version"},"old_text":{"type":"string","description":"Nonempty exact text that occurs once; include more context if ambiguous"},"new_text":{"type":"string","description":"Replacement, possibly empty"}},"required":["path","expected_sha256","old_text","new_text"],"additionalProperties":false}"#)
    }

    static func prepared(args: [String: Any], service: FileAreaService) throws -> (ManagedTextSnapshot, String) {
        guard let path = args["path"] as? String, let expected = args["expected_sha256"] as? String,
              expected.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let old = args["old_text"] as? String, !old.isEmpty, old.utf8.count <= 256 * 1024,
              let new = args["new_text"] as? String, new.utf8.count <= 256 * 1024,
              let supplied = FileAreaService.expandHome(path) else { throw ToolExecutionFailure(message: "files_edit requires path, expected_sha256, nonempty old_text and new_text.") }
        try Task.checkCancellation()
        let snapshot = try ManagedTextSnapshot(path: path, service: service)
        guard supplied.standardizedFileURL.path == snapshot.url.path else { throw FileAreaService.AreaError.unsafePath }
        guard expected == snapshot.sha256 else { throw ToolExecutionFailure(message: "The file changed since it was read. Nothing was edited. Read the current version before preparing another edit.") }
        let oldBytes = Data(old.utf8)
        guard let range = try uniqueByteRange(in: snapshot.data, needle: oldBytes) else {
            throw ToolExecutionFailure(message: "old_text must match exactly once as UTF-8 bytes. Nothing was edited. Read the file and supply a larger unique context.")
        }
        let newBytes = Data(new.utf8)
        let unchangedSize = snapshot.data.count - oldBytes.count
        guard newBytes.count <= ManagedTextSnapshot.maximumBytes - unchangedSize else {
            throw ToolExecutionFailure(message: "Edited text exceeds the 16 MiB managed edit limit. Nothing was edited.")
        }
        var updated = Data()
        updated.reserveCapacity(unchangedSize + newBytes.count)
        updated.append(snapshot.data[..<range.lowerBound])
        updated.append(newBytes)
        updated.append(snapshot.data[range.upperBound...])
        guard let updatedText = String(data: updated, encoding: .utf8) else {
            throw ToolExecutionFailure(message: "The requested edit would not be valid UTF-8. Nothing was edited.")
        }
        try Task.checkCancellation()
        return (snapshot, updatedText)
    }

    /// KMP finds overlapping occurrences in linear time without materializing
    /// the file as Character objects. The result is an exact raw UTF-8 byte range.
    static func uniqueByteRange(in data: Data, needle: Data) throws -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        var prefix = [Int](repeating: 0, count: needle.count)
        var matched = 0
        if needle.count > 1 {
            for index in 1..<needle.count {
                while matched > 0 && needle[index] != needle[matched] { matched = prefix[matched - 1] }
                if needle[index] == needle[matched] { matched += 1 }
                prefix[index] = matched
            }
        }
        matched = 0
        var found: Range<Int>?
        for (index, byte) in data.enumerated() {
            if index & 0xFFFF == 0 { try Task.checkCancellation() }
            while matched > 0 && byte != needle[matched] { matched = prefix[matched - 1] }
            if byte == needle[matched] { matched += 1 }
            if matched == needle.count {
                if found != nil { return nil }
                found = (index + 1 - needle.count)..<(index + 1)
                matched = prefix[matched - 1]
            }
        }
        return found
    }

    public func execute(argumentsJSON: String) async throws -> String {
        guard argumentsJSON.utf8.count <= 512 * 1024 else {
            throw ToolExecutionFailure(message: "The managed edit request exceeds the 512 KiB argument limit. Nothing was edited.")
        }
        let args = ToolArguments.parse(argumentsJSON)
        let path = ToolArguments.string(args, "path")
        let target = try service.resolveManaged(path)
        let other = space == .work ? AppSpace.personal : .work
        let forbidden = service.defaultWriteRoots(for: other) + [service.defaultChatRoot(for: other)] + ScriptSandbox.privateRoots(space: space)
        guard !forbidden.contains(where: { FileAreaService.isInside(target, root: $0) }) else { throw FileAreaService.AreaError.unsafePath }
        let taskID = taskID ?? UUID()
        let lease = try await leases.acquire(space: space.rawValue, path: target.path, taskID: taskID, subtaskID: UUID())
        do {
            let (snapshot, updated) = try Self.prepared(args: args, service: service)
            try Task.checkCancellation()
            let data = Data(updated.utf8)
            let newDigest = ManagedTextSnapshot.digest(data)
            var recoveryID: UUID?
            if let recoveryStore {
                do {
                    let record = try await recoveryStore.record(
                        taskID: taskID,
                        space: space.rawValue,
                        rootPath: snapshot.root.path, rootIdentity: snapshot.rootIdentity,
                        path: snapshot.url.path,
                        oldData: snapshot.data,
                        newDigest: newDigest,
                        policyVersion: AutoReviewService.ruleVersion
                    )
                    recoveryID = record.id
                } catch {
                    throw ToolExecutionFailure(message: "The task recovery point could not be saved, so nothing was edited. \(error.localizedDescription)")
                }
            }
            do {
                if let beforePublication { await beforePublication() }
                try Task.checkCancellation()
                guard try service.resolveManaged(path).path == snapshot.url.path else { throw FileAreaService.AreaError.unsafePath }
                try SecureFileWriter.write(data, to: snapshot.url, root: snapshot.root, policy: .matching(snapshot.data), expectedRoot: snapshot.rootIdentity)
            } catch {
                if let recoveryStore, let recoveryID {
                    try? await recoveryStore.markFailed(id: recoveryID, needsRecovery: false)
                }
                throw error
            }
            if let recoveryStore, let recoveryID {
                do {
                    try await recoveryStore.markApplied(id: recoveryID)
                } catch {
                    try? await recoveryStore.markFailed(id: recoveryID, needsRecovery: true)
                    throw ToolExecutionFailure(message: "Edited \(snapshot.url.path), but the recovery record could not be finalized. Do not retry the same edit; inspect the file and recover manually.")
                }
            }
            try await ToolArtifactCapture.record(snapshot.url, root: snapshot.root,
                baseline: .existing(snapshot.data), expectedContents: data, recoveryID: recoveryID)
            await leases.release(lease)
            return "Edited \(snapshot.url.path)\nsha256: \(newDigest)"
        } catch { await leases.release(lease); throw error }
    }
}
