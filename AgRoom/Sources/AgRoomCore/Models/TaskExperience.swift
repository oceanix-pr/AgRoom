import Foundation

/// Persisted alongside the assistant message; legacy messages have no explicit state.
/// `succeeded` 只表示引擎正常结束；`incomplete` 表示任务已开始执行但缺少必需产物
/// （依据实际执行回执与文件校验判定，见 `TaskCompletionAssessment`）。
public enum TaskRunStatus: String, Codable, Sendable {
    case running, waitingForConfirmation, waitingForInput, succeeded, incomplete, failed, cancelled, recoveryRequired
}

public struct RequestContextReport: Codable, Equatable, Sendable {
    public var includedHistory: [UUID] = []
    public var truncatedHistory: [UUID] = []
    public var omittedHistory: [UUID] = []
    public var attachments: [String] = []
    public var attachmentWarnings: [String]?
    public var omittedImages: [String] = []
    public var memoryIDs: [UUID] = []
    public var memoryContents: [String]?
    public var resourceContext: RunResourceContext?
    public var compressedToolResults: Int?
    public var repositoryEvidence: [RepositoryEvidenceReference]?
    public var nativeCompactions: Int?
    public var toolNames: [String] = []
    public var toolDisclosure: String?
    /// Validated domain only; no routing prompt or raw classifier output is retained.
    public var intentRoutingDomain: String?
    public var toolDiscoveryRecoveryCount: Int?
    public var sourceMismatchRecovery: Bool?
    var mailAnswerBinding: MailAnswerBinding?
    /// Callable registry, including deferred tools; retained during text-only finalization.
    public var availableToolNames: [String]?
    public var mcpServers: [MCPServerToolSummary]?
    /// Callable MCP tools, including tools reached through discovery.
    public var mcpToolNames: [String]?
    public var permissionMode: PermissionMode?
    public var estimatedTokens = 0
    public var tokenEstimate: RequestTokenEstimate?
    /// Number of retained messages preceding this run's user request (system excluded).
    public var initialHistoryMessageCount: Int?
    /// Older engine snapshots left message IDs to the foreground host.
    var recordedHistorySelection: Bool?
    /// Effective local input ceiling; absent on older request reports.
    public var contextTokenBudget: Int?
    public var requestOutputLimit: Int?
    public var requestReasoningLevel: String?
    public var imageCount = 0
    public var systemCharacters = 0
    public var requestCount = 0
    public init() {}

    public mutating func mergeHistoryDisplay(from source: Self) {
        if recordedHistorySelection == true {
            var known = Set(includedHistory + omittedHistory)
            for id in source.omittedHistory + source.includedHistory where known.insert(id).inserted {
                omittedHistory.append(id)
            }
        } else {
            includedHistory = source.includedHistory
            omittedHistory = source.omittedHistory
        }
        let kept = Set(includedHistory)
        truncatedHistory = source.truncatedHistory.filter(kept.contains)
    }
}

public enum TaskArtifactRetentionReason: String, Codable, Sendable { case fileTooLarge, operationLimit, removedByUser }

/// Evidence from a managed write, independent of the file's current contents.
public struct TaskArtifactChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case created, modified }
    public let kind: Kind
    public let beforeSHA256: String?
    public let beforeByteCount: Int
    public var beforeRetained: Bool
}

/// A receipt or explicitly labelled filesystem observation, never a path guessed from model prose.
public struct TaskArtifact: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var versionID: UUID?
    public var version: Int?
    public var sha256: String?
    public var byteCount: Int?
    public var createdAt: Date?
    public var sourceTool: String?
    public var sourceSpace: AppSpace?
    public var contentRetained: Bool?
    public var recordingFailed: Bool?
    /// A filesystem change observed during an execution, rather than a managed write receipt.
    public var observedChange: Bool?
    public var retentionReason: TaskArtifactRetentionReason?
    /// Versions explicitly attached to this task; this is provenance, not proof of model use.
    public var inputVersionIDs: [UUID]?
    public var change: TaskArtifactChange? = nil
    public var id: String { versionID?.uuidString ?? path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public init(path: String, versionID: UUID? = nil, version: Int? = nil, sha256: String? = nil,
                byteCount: Int? = nil, createdAt: Date? = nil, sourceTool: String? = nil,
                sourceSpace: AppSpace? = nil, contentRetained: Bool? = nil, recordingFailed: Bool? = nil,
                observedChange: Bool? = nil, retentionReason: TaskArtifactRetentionReason? = nil,
                inputVersionIDs: [UUID]? = nil) {
        self.path = path; self.versionID = versionID; self.version = version; self.sha256 = sha256
        self.byteCount = byteCount; self.createdAt = createdAt; self.sourceTool = sourceTool
        self.sourceSpace = sourceSpace; self.contentRetained = contentRetained; self.recordingFailed = recordingFailed
        self.observedChange = observedChange
        self.retentionReason = retentionReason
        self.inputVersionIDs = inputVersionIDs
    }

    public static func from(toolName: String, result: String) -> TaskArtifact? {
        guard ["files_write", "file_write"].contains(toolName),
              let range = result.range(of: #"^Written [0-9]+ characters to /"#, options: .regularExpression),
              !result.contains("\n") else { return nil }
        let path = "/" + result[range.upperBound...]
        return TaskArtifact(path: path)
    }
}

public struct KnowledgeCitation: Codable, Equatable, Identifiable, Sendable {
    public let itemID: UUID
    public let title: String
    public let passage: Int
    public let offset: Int
    public var id: String { "\(itemID):\(passage)" }
    public var link: String { "knowledge://\(itemID.uuidString)/\(passage)" }

    /// Retrieval hits are candidates. Only explicit final-answer links become answer sources.
    /// Unknown IDs, other passages, and examples inside code blocks cannot invent citations.
    public static func used(in answer: String, candidates: [KnowledgeCitation]) -> [KnowledgeCitation] {
        var fence: String?
        let prose = answer.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                return false
            }
            return fence == nil
        }.joined(separator: "\n").replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
        let pattern = #"\]\(<?knowledge://([A-Fa-f0-9-]{36})/([1-9][0-9]*)>?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = prose as NSString
        let ids = Set(regex.matches(in: prose, range: NSRange(location: 0, length: ns.length)).compactMap { match -> String? in
            guard let uuid = UUID(uuidString: ns.substring(with: match.range(at: 1))),
                  let passage = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return "\(uuid):\(passage)"
        })
        var seen = Set<String>()
        return candidates.filter { ids.contains($0.id) && seen.insert($0.id).inserted }
    }

    public static func from(result: String) -> [KnowledgeCitation] {
        if let data = result.data(using: .utf8), let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let candidates = envelope["candidates"] as? [[String: Any]] {
            return candidates.compactMap { row in
                guard let raw = row["item_id"] as? String, let id = UUID(uuidString: raw),
                      let title = row["title"] as? String, let passage = row["passage"] as? Int, passage > 0,
                      let offset = row["offset"] as? Int, offset >= 0 else { return nil }
                return .init(itemID: id, title: title, passage: passage, offset: offset)
            }
        }
        // Legacy trace results used a textual header; keep historical conversations readable.
        let pattern = #"(?m)^\[(.+)\] \(entry: ([A-Fa-f0-9-]{36}), passage: ([0-9]+), character offset: ([0-9]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = result as NSString
        return regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let id = UUID(uuidString: ns.substring(with: match.range(at: 2))),
                  let passage = Int(ns.substring(with: match.range(at: 3))),
                  let offset = Int(ns.substring(with: match.range(at: 4))) else { return nil }
            return KnowledgeCitation(itemID: id, title: ns.substring(with: match.range(at: 1)), passage: passage, offset: offset)
        }
    }
}
