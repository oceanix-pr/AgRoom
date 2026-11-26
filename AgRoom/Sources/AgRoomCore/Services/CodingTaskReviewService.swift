import Foundation

public struct CodingReviewEntry: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let before: String
    public let after: String
    public let digest: String?
    public let matchesRecordedVersion: Bool
    public let canRestore: Bool
    public let diff: String?
}

public struct CodingTaskReviewService: Sendable {
    let store: CodingTaskStore
    let reader: RepositoryReader
    let sessionID: UUID

    public init(store: CodingTaskStore, service: FileAreaService, space: AppSpace, root: URL, sessionID: UUID) throws {
        self.store = store; self.reader = try RepositoryReader(root: root, service: service, space: space); self.sessionID = sessionID
    }

    public func load() async throws -> (CodingTaskState?, [CodingReviewEntry], Bool) {
        let state = try await store.load(sessionID: sessionID, workspace: reader.identity)
        let changes = state?.changes ?? []
        let reader = self.reader
        let entries = try await Task.detached {
            try changes.map { change in
                let before = change.originalData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard let fileReader = try? reader.readerForMutation(at: change.path),
                      fileReader.identity == (change.rootIdentity ?? reader.identity),
                      let url = try? fileReader.resolve(change.path) else {
                    return CodingReviewEntry(path: change.path, before: before, after: "", digest: nil,
                        matchesRecordedVersion: false, canRestore: false, diff: nil)
                }
                let data = FileManager.default.fileExists(atPath: url.path) ? try fileReader.read(url.path) : nil
                let after = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let digest = data.map(ManagedTextSnapshot.digest)
                let matches = digest == change.currentDigest && !change.hasExternalChanges
                return CodingReviewEntry(path: change.path, before: before, after: after, digest: digest,
                    matchesRecordedVersion: matches, canRestore: matches && data != change.originalData && change.originalData != nil,
                    diff: FileChangePreviewBuilder.unifiedDiff(old: before, new: after).text)
            }
        }.value
        let revision = state?.verification == nil ? nil : try? await Task.detached { try reader.revision() }.value
        let checks = state?.latestChecks ?? []
        let requiredPresent = (state?.requiredChecks ?? []).allSatisfy { required in checks.contains { $0.identity == required.id } }
        let verified = requiredPresent && !checks.isEmpty && checks.allSatisfy { $0.revisionVerified && $0.outputRevision == revision }
        return (state, entries, verified)
    }

    /// UI 必须先展示差异并取得本次恢复确认；只恢复仍等于展示版本的已有文件。
    public func restore(path: String, expectedDigest: String, space: AppSpace) async throws {
        guard let state = try await store.load(sessionID: sessionID, workspace: reader.identity),
              let change = state.changes.first(where: { $0.path == path }), let old = change.originalData,
              change.currentDigest == expectedDigest, !change.hasExternalChanges else { throw TaskFileRecoveryError.changedSinceWrite }
        let fileReader = try reader.readerForMutation(at: path)
        guard fileReader.identity == (change.rootIdentity ?? reader.identity) else { throw TaskFileRecoveryError.outsideRoot }
        let url = try fileReader.resolve(path)
        let lease = try await TeamLeaseCenter.shared.acquire(space: space.rawValue, path: url.path, taskID: UUID(), subtaskID: UUID())
        do {
            let actual = try fileReader.read(path)
            guard ManagedTextSnapshot.digest(actual) == expectedDigest else { throw TaskFileRecoveryError.changedSinceWrite }
            let recoveries = TaskFileRecoveryStore(space: space, databaseQueue: store.databaseQueue)
            let record = try await recoveries.record(taskID: state.currentRunID, space: space.rawValue, rootPath: fileReader.root.path, rootIdentity: fileReader.identity,
                path: path, oldData: actual, newDigest: ManagedTextSnapshot.digest(old), policyVersion: AutoReviewService.ruleVersion)
            do {
                _ = try fileReader.resolve(path)
                try SecureFileWriter.write(old, to: url, root: fileReader.root, policy: .matching(actual), expectedRoot: fileReader.identity)
            } catch {
                try? await recoveries.markFailed(id: record.id, needsRecovery: false)
                throw error
            }
            do {
                try await recoveries.markApplied(id: record.id)
                try await store.update(sessionID: sessionID, workspace: reader.identity, runID: state.currentRunID) { state in
                    guard let index = state.changes.firstIndex(where: { $0.path == path }) else { return }
                    state.changes[index].currentDigest = ManagedTextSnapshot.digest(old)
                    state.changes[index].applied = false
                    state.verification = nil
                    state.verifications = nil
                }
            } catch {
                try? await recoveries.markFailed(id: record.id, needsRecovery: true)
                throw ToolExecutionFailure(message: "The file was restored, but its task record needs recovery. Inspect the file before retrying.")
            }
            await TeamLeaseCenter.shared.release(lease)
        } catch {
            await TeamLeaseCenter.shared.release(lease)
            throw error
        }
    }
}
