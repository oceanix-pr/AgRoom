import Foundation
import CryptoKit

// MARK: - Team Blackboard

/// 任务内的版本化产物黑板。P0 只保存在内存；P1 改为空间目录 + 内容哈希。
///
/// 不共享聊天上下文：下游 Worker 只拿到上游产物的引用与有限摘录，
/// 完整内容留在这里，避免 N 个智体把彼此的历史互相灌进上下文。
public actor TeamBlackboard {
    private var storage: [UUID: [TeamArtifact]] = [:]

    public init() {}

    /// 提交一个 Worker 的产物草稿，补全任务/子任务/生产者身份。
    @discardableResult
    public func commit(
        taskID: UUID,
        subtaskID: UUID,
        producer: String,
        drafts: [TeamArtifactDraft]
    ) -> [TeamArtifact] {
        let existingVersions = (storage[taskID] ?? [])
            .filter { $0.subtaskID == subtaskID }
            .count
        let created = drafts.enumerated().map { index, draft in
            let digest = SHA256.hash(data: Data(draft.content.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return TeamArtifact(
                taskID: taskID,
                subtaskID: subtaskID,
                kind: draft.kind,
                title: draft.title,
                content: draft.content,
                producer: producer,
                contentDigest: digest,
                version: existingVersions + index + 1,
                writeRecordID: draft.writeRecordID
            )
        }
        storage[taskID, default: []].append(contentsOf: created)
        return created
    }

    public func artifacts(for taskID: UUID) -> [TeamArtifact] {
        storage[taskID] ?? []
    }

    public func artifacts(for taskID: UUID, subtaskID: UUID) -> [TeamArtifact] {
        (storage[taskID] ?? []).filter { $0.subtaskID == subtaskID }
    }

    public func references(for taskID: UUID) -> [TeamArtifactRef] {
        (storage[taskID] ?? []).map(\.ref)
    }
}
