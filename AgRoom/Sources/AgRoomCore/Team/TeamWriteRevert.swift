import Foundation

// MARK: - Revert Errors

public enum TeamWriteBatchRevertError: LocalizedError, Equatable {
    case partial(TeamWriteBatchRevertResult)

    public var errorDescription: String? {
        guard case .partial(let result) = self else { return nil }
        let details = result.outcomes
            .filter { !$0.succeeded }
            .map { "\($0.path): \($0.error ?? "failed")" }
            .joined(separator: "; ")
        return "Batch revert partially failed: \(result.failedCount) item(s) still need recovery. \(details)"
    }
}

public enum TeamWriteRevertError: LocalizedError, Equatable {
    case alreadyReverted
    case outsideWorkspace
    case missingFile
    case changedSinceWrite
    case directory
    case symlinkNotAllowed
    case notRegularFile
    case binaryFile
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .alreadyReverted:
            return "This team write is already reverted."
        case .outsideWorkspace:
            return "The recorded write path is outside its workspace; refusing to revert."
        case .missingFile:
            return "The written file no longer exists; it cannot be reverted safely."
        case .changedSinceWrite:
            return "The file changed after the team write; refusing to overwrite newer content."
        case .directory:
            return "The recorded path is a directory; refusing to revert."
        case .symlinkNotAllowed:
            return "The recorded path is a symbolic link; refusing to revert."
        case .notRegularFile:
            return "The recorded path is not a regular file; refusing to revert."
        case .binaryFile:
            return "The current file is not UTF-8 text; refusing to revert."
        case .tooLarge:
            return "The file is larger than the 1 MB revert limit."
        }
    }
}

// MARK: - Batch Revert Result

/// 批量回滚的逐项结果：预检失败不改文件；应用阶段的单项失败不掩盖其他项，
/// 调用方据此展示“哪些已恢复、哪些仍需继续恢复”。
public struct TeamWriteRevertOutcome: Sendable, Equatable {
    public let recordID: UUID
    public let path: String
    public let error: String?

    public var succeeded: Bool { error == nil }
}

public struct TeamWriteBatchRevertResult: Sendable, Equatable {
    public let outcomes: [TeamWriteRevertOutcome]
    public var succeededCount: Int { outcomes.filter(\.succeeded).count }
    public var failedCount: Int { outcomes.filter { !$0.succeeded }.count }
    public var needsRecovery: Bool { failedCount > 0 }
}

// MARK: - Revert Service

/// 单文件回滚：只回滚「当前内容仍等于团队写入内容」的文件；
/// 团队新建的文件回滚为删除，已有文件回滚为恢复旧内容。
public struct TeamWriteRevertService: Sendable {
    public let store: TeamWriteStore
    public let leases: TeamLeaseCenter

    public init(store: TeamWriteStore, leases: TeamLeaseCenter = .shared) {
        self.store = store
        self.leases = leases
    }

    private static let maxContentBytes = 1_000_000

    public func revert(_ record: TeamWriteRecord) async throws -> TeamWriteRecord {
        guard !record.isReverted else { throw TeamWriteRevertError.alreadyReverted }
        let target = try resolve(record)
        let current = try readText(target)
        guard current == record.newContent else {
            throw TeamWriteRevertError.changedSinceWrite
        }

        let lease = try await leases.acquire(
            space: record.space,
            path: target.path,
            taskID: record.taskID,
            subtaskID: record.id
        )
        do {
            try Task.checkCancellation()
            let rechecked = try readText(target)
            guard rechecked == record.newContent else {
                throw TeamWriteRevertError.changedSinceWrite
            }
            if let oldContent = record.oldContent {
                try oldContent.write(to: target, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(at: target)
            }
            let now = Date()
            try await store.markReverted(id: record.id)
            await leases.release(lease)
            return TeamWriteRecord(
                id: record.id,
                taskID: record.taskID,
                space: record.space,
                rootPath: record.rootPath,
                path: record.path,
                oldContent: record.oldContent,
                newContent: record.newContent,
                createdAt: record.createdAt,
                revertedAt: now
            )
        } catch {
            await leases.release(lease)
            throw error
        }
    }

    /// 批量回滚一个任务的全部未回滚写入：先完整预检，再按路径从新到旧恢复。
    /// 预检失败时不会改动任何文件；应用阶段逐项记录结果，部分失败可继续恢复。
    public func revertAllDetailed(taskID: UUID) async throws -> TeamWriteBatchRevertResult {
        let records = try await store.records(taskID: taskID).filter { !$0.isReverted }
        guard !records.isEmpty else {
            return TeamWriteBatchRevertResult(outcomes: [])
        }

        let grouped = Dictionary(grouping: records, by: \.path)
        var resolved: [String: URL] = [:]
        var ordered: [String: [TeamWriteRecord]] = [:]
        for (path, group) in grouped {
            let sorted = group.sorted { $0.createdAt > $1.createdAt }
            guard let newest = sorted.first else { continue }
            let url = try resolve(newest)
            var current: String? = try readText(url)
            for (index, record) in sorted.enumerated() {
                guard current == record.newContent else {
                    throw TeamWriteRevertError.changedSinceWrite
                }
                current = record.oldContent
                if current == nil, index < sorted.count - 1 {
                    throw TeamWriteRevertError.changedSinceWrite
                }
            }
            resolved[path] = url
            ordered[path] = sorted
        }

        var heldLeases: [TeamLease] = []
        do {
            for (path, group) in ordered {
                guard let url = resolved[path], let first = group.first else { continue }
                let lease = try await leases.acquire(
                    space: first.space,
                    path: url.path,
                    taskID: taskID,
                    subtaskID: UUID()
                )
                heldLeases.append(lease)
            }

            // 拿齐租约后重新预检，避免预检到加锁之间被其他写入改动。
            for (path, group) in ordered {
                guard let url = resolved[path] else { continue }
                var current: String? = try readText(url)
                for (index, record) in group.enumerated() {
                    guard current == record.newContent else {
                        throw TeamWriteRevertError.changedSinceWrite
                    }
                    current = record.oldContent
                    if current == nil, index < group.count - 1 {
                        throw TeamWriteRevertError.changedSinceWrite
                    }
                }
            }

            var outcomes: [TeamWriteRevertOutcome] = []
            for (path, group) in ordered {
                guard let url = resolved[path] else { continue }
                do {
                    for record in group {
                        if let oldContent = record.oldContent {
                            try oldContent.write(to: url, atomically: true, encoding: .utf8)
                        } else {
                            try FileManager.default.removeItem(at: url)
                        }
                        try await store.markReverted(id: record.id)
                        outcomes.append(TeamWriteRevertOutcome(
                            recordID: record.id, path: path, error: nil
                        ))
                    }
                } catch {
                    outcomes.append(TeamWriteRevertOutcome(
                        recordID: group.first?.id ?? UUID(),
                        path: path,
                        error: error.localizedDescription
                    ))
                }
            }
            for lease in heldLeases {
                await leases.release(lease)
            }
            return TeamWriteBatchRevertResult(outcomes: outcomes)
        } catch {
            for lease in heldLeases {
                await leases.release(lease)
            }
            throw error
        }
    }

    /// 兼容入口：成功返回回滚条数；出现部分失败时抛出包含逐项结果的状态错误。
    @discardableResult
    public func revertAll(taskID: UUID) async throws -> Int {
        let result = try await revertAllDetailed(taskID: taskID)
        guard !result.needsRecovery else {
            throw TeamWriteBatchRevertError.partial(result)
        }
        return result.succeededCount
    }

    private func resolve(_ record: TeamWriteRecord) throws -> URL {
        let root = URL(fileURLWithPath: record.rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: record.path)
        let standardized = candidate.standardizedFileURL
        if let values = try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw TeamWriteRevertError.symlinkNotAllowed
        }
        let resolved = standardized.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path != root.path, resolved.path.hasPrefix(prefix) else {
            throw TeamWriteRevertError.outsideWorkspace
        }
        return resolved
    }

    private func readText(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TeamWriteRevertError.missingFile
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attributes[.type] as? FileAttributeType {
            if type == .typeDirectory { throw TeamWriteRevertError.directory }
            if type != .typeRegular { throw TeamWriteRevertError.notRegularFile }
        }
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maxContentBytes {
            throw TeamWriteRevertError.tooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maxContentBytes else { throw TeamWriteRevertError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TeamWriteRevertError.binaryFile
        }
        return text
    }
}
