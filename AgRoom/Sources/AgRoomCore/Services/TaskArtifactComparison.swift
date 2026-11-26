import Foundation
import GRDB

public struct FileDiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, addition, removal }
    public let kind: Kind
    public let oldLine: Int?
    public let newLine: Int?
    public let text: String
    public fileprivate(set) var lacksFinalNewline = false
}

public struct FileDiffHunk: Equatable, Sendable, Identifiable {
    public let id: Int
    public let oldStart: Int
    public let newStart: Int
    public var lines: [FileDiffLine]
}

public struct TaskArtifactComparison: Equatable, Sendable {
    public enum State: Equatable, Sendable { case available, unchanged, baselineMissing, contentUnavailable, binary, tooLarge }
    public let state: State
    public let kind: TaskArtifactChange.Kind?
    public let added: Int?
    public let removed: Int?
    public let hunks: [FileDiffHunk]
    public let truncated: Bool
    /// A broken chain cannot attribute intervening user edits to the AI.
    public let interleaved: Bool

    static func result(_ state: State, kind: TaskArtifactChange.Kind? = nil, interleaved: Bool = false) -> Self {
        .init(state: state, kind: kind, added: nil, removed: nil, hunks: [], truncated: false, interleaved: interleaved)
    }

    static func compare(before: Data, after: Data, kind: TaskArtifactChange.Kind, interleaved: Bool) -> Self {
        guard before.count + after.count <= 32 * 1024 * 1024 else { return .result(.tooLarge, kind: kind, interleaved: interleaved) }
        guard !before.contains(0), !after.contains(0), let old = String(data: before, encoding: .utf8),
              let new = String(data: after, encoding: .utf8) else { return .result(.binary, kind: kind, interleaved: interleaved) }
        let diff = FileChangePreviewBuilder.unifiedDiff(old: old, new: new)
        let parsed = parse(diff.text ?? "")
        let state: State = diff.added == 0 && diff.removed == 0 ? .unchanged : (parsed.hunks.isEmpty ? .tooLarge : .available)
        return .init(state: state, kind: kind, added: diff.added, removed: diff.removed,
            hunks: parsed.hunks, truncated: parsed.truncated, interleaved: interleaved)
    }

    /// The bounded approval diff already has exact hunk offsets. Retain them for
    /// both renderers instead of deriving line numbers from the displayed rows.
    private static func parse(_ diff: String) -> (hunks: [FileDiffHunk], truncated: Bool) {
        var hunks: [FileDiffHunk] = [], old = 0, new = 0, truncated = false
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("@@ ") {
                let fields = line.split(separator: " ")
                guard fields.count >= 4,
                      let oldStart = Int(fields[1].dropFirst().split(separator: ",")[0]),
                      let newStart = Int(fields[2].dropFirst().split(separator: ",")[0]) else { continue }
                old = oldStart; new = newStart
                hunks.append(.init(id: hunks.count, oldStart: old, newStart: new, lines: []))
                if line.contains("…") { truncated = true }
            } else if line == "\\ No newline at end of file", let hunk = hunks.indices.last,
                      let previous = hunks[hunk].lines.indices.last {
                hunks[hunk].lines[previous].lacksFinalNewline = true
            } else if line.hasPrefix("…") { truncated = true }
            else if let marker = line.first, !hunks.isEmpty {
                let text = String(line.dropFirst()), row: FileDiffLine
                switch marker {
                case "+": row = .init(kind: .addition, oldLine: nil, newLine: new, text: text); new += 1
                case "-": row = .init(kind: .removal, oldLine: old, newLine: nil, text: text); old += 1
                case " ": row = .init(kind: .context, oldLine: old, newLine: new, text: text); old += 1; new += 1
                default: continue
                }
                hunks[hunks.count - 1].lines.append(row)
            }
        }
        return (hunks, truncated)
    }
}

public extension TaskArtifactStore {
    /// Reads only immutable receipts in this store. Never substitutes a live
    /// file, another run, an input attachment or a Git revision for a baseline.
    func comparison(of artifact: TaskArtifact) async throws -> TaskArtifactComparison {
        guard artifact.sourceSpace == space, let id = artifact.versionID else { throw TaskArtifactError.unsafeFile }
        let source: (Data?, Data?, TaskArtifactChange?, Bool) = try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT metadata,contents FROM artifact_versions WHERE id=?", arguments: [id.uuidString]) else {
                throw TaskArtifactError.unavailable
            }
            let record = try Self.decode(row["metadata"], space: space)
            guard record.id == id, record.artifact.path == artifact.path else { throw TaskArtifactError.unsafeFile }
            let after: Data? = row["contents"]
            try Self.validate(record, contents: after)
            let history = try Data.fetchAll(db, sql: """
                SELECT metadata FROM artifact_versions
                WHERE runID=? AND workspaceID IS ? AND sessionID IS ? AND path=? AND version<=?
                ORDER BY version LIMIT 1001
                """, arguments: [record.runID.uuidString, record.workspaceID, record.sessionID?.uuidString,
                    record.artifact.path, record.artifact.version])
                .map { try Self.decode($0, space: space) }
            guard history.allSatisfy({ $0.runID == record.runID && $0.workspaceID == record.workspaceID &&
                $0.sessionID == record.sessionID && $0.artifact.path == record.artifact.path }) else { throw TaskArtifactError.changedFile }
            var interleaved = history.count > 1000
            for (prior, next) in zip(history, history.dropFirst()) {
                if next.artifact.change?.kind != .modified || prior.artifact.sha256 == nil ||
                    prior.artifact.sha256 != next.artifact.change?.beforeSHA256 { interleaved = true }
            }
            let baseline = interleaved ? record : (history.first ?? record)
            let before: Data? = try Data.fetchOne(db, sql: "SELECT beforeContents FROM artifact_versions WHERE id=?", arguments: [baseline.id.uuidString])
            try Self.validateBaseline(baseline, contents: before)
            let data = baseline.artifact.change?.kind == .created && baseline.artifact.change?.beforeRetained == true ? Data() : before
            return (data, after, baseline.artifact.change, interleaved)
        }
        guard let change = source.2 else { return .result(.baselineMissing) }
        guard let before = source.0, let after = source.1 else {
            return .result(.contentUnavailable, kind: change.kind, interleaved: source.3)
        }
        return try await Task.detached {
            try Task.checkCancellation()
            return TaskArtifactComparison.compare(before: before, after: after, kind: change.kind, interleaved: source.3)
        }.value
    }

    /// Same shared maintenance lease as file previews; release on collapse or
    /// dismissal so explicit history removal can be retried immediately.
    func pinComparison() throws -> TaskArtifactPreviewPin {
        TaskArtifactPreviewPin(try ResourceMaintenance.Lease(key: cacheMaintenanceKey, exclusive: false))
    }
}
