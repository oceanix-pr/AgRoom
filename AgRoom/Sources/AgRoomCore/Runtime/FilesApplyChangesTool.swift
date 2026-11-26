import Foundation

/// 可恢复的批量编辑：全量校验、保存全部恢复点，然后逐文件条件原子写；部分失败按逆序恢复。
struct FilesApplyChangesTool: DispatcherTool {
    let reader: RepositoryReader
    let recoveryStore: TaskFileRecoveryStore
    let space: AppSpace
    let taskID: UUID
    var leases: TeamLeaseCenter = .shared
    /// 用于确定性交错/故障回归，不由模型提供。
    var beforeWrite: (@Sendable (Int) async throws -> Void)? = nil
    var requiresConfirmation: Bool { true }
    var permissionClass: PermissionClass { .workspaceMutation }
    func approvalRoute(argumentsJSON: String) -> ApprovalRoute { .deterministic }
    func autoReviewEvidence(argumentsJSON: String) -> [String: String] { ["recovery_store": "true"] }
    func validateArguments(argumentsJSON: String) throws {
        guard argumentsJSON.utf8.count <= 512 * 1024 else {
            throw ToolExecutionFailure(message: "Provide 1-20 version-checked existing-file changes, within 512 KiB.")
        }
        let args = ToolArguments.parse(argumentsJSON)
        guard Set(args.keys) == ["changes"],
              let changes = args["changes"] as? [[String: Any]], (1...20).contains(changes.count) else {
            throw ToolExecutionFailure(message: "Provide 1-20 version-checked existing-file changes, within 512 KiB.")
        }
        var seen = Set<String>()
        for change in changes {
            guard Set(change.keys) == ["path", "expected_sha256", "edits"],
                  let path = change["path"] as? String, path.hasPrefix("/"),
                  let expected = change["expected_sha256"] as? String,
                  expected.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let edits = change["edits"] as? [[String: Any]], (1...40).contains(edits.count) else {
                throw ToolExecutionFailure(message: "Each change needs a unique absolute path, SHA-256 and 1-40 literal edits.")
            }
            let target = try reader.readerForMutation(at: path).resolve(path)
            guard seen.insert(target.path).inserted else { throw ToolExecutionFailure(message: "Each file must appear only once.") }
            for edit in edits {
                guard Set(edit.keys) == ["old_text", "new_text"],
                      let old = edit["old_text"] as? String, !old.isEmpty,
                      edit["new_text"] is String else {
                    throw ToolExecutionFailure(message: "Each literal edit needs nonempty old_text and new_text.")
                }
            }
        }
    }
    func writeTargets(argumentsJSON: String) -> [String] {
        (ToolArguments.parse(argumentsJSON)["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
    }
    var definition: ToolDefinition {
        ToolDefinition(name: "files_apply_changes", description: "Apply a reviewed set of literal edits to 1-20 existing UTF-8 project files, each up to 16 MiB and with a 32 MiB combined file budget. Each file needs its current SHA-256. All edits and versions are validated and all recovery points saved before writing. Each old_text must match exactly once in the file version produced by preceding edits. Concurrent changes are rejected. On partial failure, already written files are conditionally restored without overwriting subsequent user changes. This is recoverable multi-file editing, not a filesystem transaction. The active workspace grant covers verified edits in the main folder and its explicitly writable references. It never grants shell/build permissions.",
            parametersSchemaJSON: #"{"type":"object","properties":{"changes":{"type":"array","minItems":1,"maxItems":20,"items":{"type":"object","properties":{"path":{"type":"string","description":"Absolute existing project file"},"expected_sha256":{"type":"string"},"edits":{"type":"array","minItems":1,"maxItems":40,"items":{"type":"object","properties":{"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["old_text","new_text"],"additionalProperties":false}}},"required":["path","expected_sha256","edits"],"additionalProperties":false}}},"required":["changes"],"additionalProperties":false}"#)
    }

    struct Prepared: Sendable { let path: String; let reader: RepositoryReader; let old: Data; let new: Data }
    func prepare(_ arguments: String) throws -> [Prepared] {
        try Self.prepare(arguments, reader: reader)
    }
    static func prepare(_ arguments: String, reader: RepositoryReader) throws -> [Prepared] {
        guard arguments.utf8.count <= 512 * 1024 else {
            throw ToolExecutionFailure(message: "Provide 1-20 version-checked existing-file changes, within 512 KiB.")
        }
        let args = ToolArguments.parse(arguments)
        guard Set(args.keys) == ["changes"],
              let changes = args["changes"] as? [[String: Any]], (1...20).contains(changes.count) else {
            throw ToolExecutionFailure(message: "Provide 1-20 version-checked existing-file changes, within 512 KiB.")
        }
        var seen = Set<String>()
        var prepared: [Prepared] = []
        var batchBytes = 0
        for change in changes {
            try Task.checkCancellation()
            guard Set(change.keys) == ["path", "expected_sha256", "edits"],
                  let path = change["path"] as? String, path.hasPrefix("/"),
                  let expected = change["expected_sha256"] as? String,
                  let edits = change["edits"] as? [[String: Any]], (1...40).contains(edits.count) else {
                throw ToolExecutionFailure(message: "Each change needs an absolute path, expected_sha256 and 1-40 literal edits.")
            }
            let fileReader = try reader.readerForMutation(at: path)
            let target = try fileReader.resolve(path)
            guard seen.insert(target.path).inserted else { throw ToolExecutionFailure(message: "Each file must appear only once in a change set.") }
            let data = try fileReader.read(path)
            guard ManagedTextSnapshot.digest(data) == expected, String(data: data, encoding: .utf8) != nil else {
                throw ToolExecutionFailure(message: "A file changed or is not UTF-8. Nothing was edited. Read all affected files again.")
            }
            guard data.count <= WorkspaceTextLimits.maximumBatchEditBytes - batchBytes else {
                throw ToolExecutionFailure(message: "The change set exceeds the 32 MiB combined file budget. Nothing was edited.")
            }
            var updated = data
            for edit in edits {
                guard Set(edit.keys) == ["old_text", "new_text"], let old = edit["old_text"] as? String, !old.isEmpty,
                      let new = edit["new_text"] as? String,
                      let range = try FilesEditTool.uniqueByteRange(in: updated, needle: Data(old.utf8)) else {
                    throw ToolExecutionFailure(message: "Every old_text must match exactly once after the preceding edits. Nothing was edited.")
                }
                let newBytes = Data(new.utf8)
                let unchangedSize = updated.count - range.count
                guard newBytes.count <= WorkspaceTextLimits.maximumEditBytes - unchangedSize else {
                    throw ToolExecutionFailure(message: "An edited file exceeds the 16 MiB managed edit limit. Nothing was edited.")
                }
                var next = Data()
                next.reserveCapacity(unchangedSize + newBytes.count)
                next.append(updated[..<range.lowerBound])
                next.append(newBytes)
                next.append(updated[range.upperBound...])
                updated = next
            }
            guard String(data: updated, encoding: .utf8) != nil else {
                throw ToolExecutionFailure(message: "An edited file would not be valid UTF-8. Nothing was edited.")
            }
            let fileBudget = max(data.count, updated.count)
            guard fileBudget <= WorkspaceTextLimits.maximumBatchEditBytes - batchBytes else {
                throw ToolExecutionFailure(message: "The change set exceeds the 32 MiB combined file budget. Nothing was edited.")
            }
            batchBytes += fileBudget
            prepared.append(Prepared(path: target.path, reader: fileReader, old: data, new: updated))
        }
        return prepared.sorted { $0.path < $1.path }
    }

    func execute(argumentsJSON: String) async throws -> String {
        try validateArguments(argumentsJSON: argumentsJSON)
        let paths = writeTargets(argumentsJSON: argumentsJSON).sorted()
        let owner = UUID()
        var acquired: [TeamLease] = []
        var records: [TaskFileRecoveryRecord] = []
        var written: [Prepared] = []
        let outputs: [Prepared]
        do {
            for path in paths {
                let target = try reader.readerForMutation(at: path).resolve(path)
                acquired.append(try await leases.acquire(space: space.rawValue, path: target.path, taskID: taskID, subtaskID: owner, ttl: 600))
            }
            let prepared = try await Task.detached { try prepare(argumentsJSON) }.value
            for file in prepared {
                records.append(try await recoveryStore.record(taskID: taskID, space: space.rawValue, rootPath: file.reader.root.path, rootIdentity: file.reader.identity,
                    path: file.path, oldData: file.old, newDigest: ManagedTextSnapshot.digest(file.new), policyVersion: AutoReviewService.ruleVersion))
            }
            for (index, file) in prepared.enumerated() {
                if let beforeWrite { try await beforeWrite(index) }
                try Task.checkCancellation()
                _ = try file.reader.resolve(file.path)
                try SecureFileWriter.write(file.new, to: URL(fileURLWithPath: file.path), root: file.reader.root, policy: .matching(file.old), expectedRoot: file.reader.identity)
                written.append(file)
                try await recoveryStore.markApplied(id: records[index].id)
            }
            outputs = prepared
        } catch {
            var recoveryRequired: [String] = []
            for file in written.reversed() {
                guard let record = records.first(where: { $0.path == file.path }) else { continue }
                do {
                    _ = try file.reader.resolve(file.path)
                    try SecureFileWriter.write(file.old, to: URL(fileURLWithPath: file.path), root: file.reader.root, policy: .matching(file.new), expectedRoot: file.reader.identity)
                    try await recoveryStore.markReverted(id: record.id)
                } catch {
                    recoveryRequired.append(file.path)
                    try? await recoveryStore.markFailed(id: record.id, needsRecovery: true)
                }
            }
            for record in records where !written.contains(where: { $0.path == record.path }) {
                try? await recoveryStore.markFailed(id: record.id, needsRecovery: false)
            }
            for lease in acquired { await leases.release(lease) }
            if !recoveryRequired.isEmpty {
                throw ToolExecutionFailure(message: "The change set stopped and some files require recovery: \(recoveryRequired.joined(separator: ", ")). Later edits were preserved. Inspect the files and recovery records; do not replay the change set.")
            }
            if error is CancellationError { throw CancellationError() }
            throw ToolExecutionFailure(message: "The change set was not applied; earlier writes were restored. \(error.localizedDescription)")
        }
        // Version persistence is after the applied change-set boundary. Its failure
        // must not turn a successful edit into an implicit rollback or replay.
        do {
            var failed = false
            for (output, recovery) in zip(outputs, records) {
                do {
                    try await ToolArtifactCapture.record(URL(fileURLWithPath: output.path), root: output.reader.root,
                        baseline: .existing(output.old), expectedContents: output.new, recoveryID: recovery.id)
                } catch { failed = true }
            }
            if failed { throw ToolExecutionFailure(message: "Files were edited, but some artifact versions could not be saved. Do not repeat the operation; inspect the existing files.") }
        }
        catch {
            for lease in acquired { await leases.release(lease) }
            throw error
        }
        for lease in acquired { await leases.release(lease) }
        return try CodingJSON.encode(outputs.map { ["path": $0.path, "sha256": ManagedTextSnapshot.digest($0.new)] })
    }
}
