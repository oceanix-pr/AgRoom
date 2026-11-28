import Foundation

// MARK: - Team Task Status

/// 团队任务状态：P0 只在内存中流转，P1 再落空间库。
public enum TeamTaskStatus: String, Codable, Sendable, Equatable {
    case planning
    case running
    case waitingForUser
    case waitingForApproval
    case verifying
    case cancelling
    case completed
    case failed
    case cancelled
    case interrupted
}

/// 单个子任务的终态分类。`blocked` 表示上游失败、预算不足或需要用户介入，
/// 与 `failed` 区分，便于汇总时说明「为什么没跑」。
public enum TeamSubtaskOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case needsInput
    case blocked
    case failed
}

// MARK: - Team Role

/// 角色而不是具体智体名：计划绑定职责，协调器运行时再解析成具体 Agent，
/// Agent 被禁用或换模型时可以替换而不重写计划。
public struct TeamRole: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let researcher = TeamRole("researcher")
    public static let analyst = TeamRole("analyst")
    public static let reviewer = TeamRole("reviewer")
    public static let synthesizer = TeamRole("synthesizer")
}

// MARK: - Budget & Usage

/// 团队的局部预算。默认只统计 Token，调用方可显式指定累计上限。
public struct TeamBudget: Codable, Sendable, Equatable {
    public var maxTokens: Int?
    public var maxToolCalls: Int
    public var maxWallClockSeconds: TimeInterval
    public var maxConcurrentWorkers: Int

    public init(
        maxTokens: Int? = nil,
        maxToolCalls: Int = 160,
        maxWallClockSeconds: TimeInterval = 600,
        maxConcurrentWorkers: Int = 3
    ) {
        self.maxTokens = maxTokens.map { max(1, $0) }
        self.maxToolCalls = max(1, maxToolCalls)
        self.maxWallClockSeconds = max(1, maxWallClockSeconds)
        self.maxConcurrentWorkers = min(max(1, maxConcurrentWorkers), 4)
    }

    public static let `default` = TeamBudget()
}

/// 实际用量。Worker 必须把嵌套模型请求的 token 一并带回，任务账本才不是只算宿主。
public struct TeamUsage: Codable, Sendable, Equatable {
    public var tokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var toolCalls: Int
    public var duration: TimeInterval

    public init(
        tokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        toolCalls: Int = 0,
        duration: TimeInterval = 0
    ) {
        self.tokens = max(0, tokens)
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.toolCalls = max(0, toolCalls)
        self.duration = max(0, duration)
    }

    public static let zero = TeamUsage()

    public func adding(_ other: TeamUsage) -> TeamUsage {
        TeamUsage(
            tokens: tokens + other.tokens,
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            toolCalls: toolCalls + other.toolCalls,
            duration: duration + other.duration
        )
    }
}

// MARK: - Verification

/// 独立验证者的结论。验证者是单独一次模型调用，不共享 Worker 的上下文；
/// 只有 `passed == true` 才允许任务进入 `completed`。
public struct TeamVerification: Codable, Sendable, Equatable {
    public enum FailureKind: String, Codable, Sendable {
        case acceptance, evidence, unavailable
    }

    public var passed: Bool
    public var summary: String
    public var issues: [String]
    public var usage: TeamUsage
    public var failureKind: FailureKind?

    public init(
        passed: Bool,
        summary: String,
        issues: [String] = [],
        usage: TeamUsage = .zero,
        failureKind: FailureKind? = nil
    ) {
        self.passed = passed
        self.summary = summary
        self.issues = issues
        self.usage = usage
        self.failureKind = failureKind
    }

    var rejectedDeliverables: Bool {
        guard !passed else { return false }
        if let failureKind { return failureKind == .acceptance }
        // Older reports stored only the verdict text. Exclude the host's fixed
        // failure messages before using a saved review as revision feedback.
        return (!issues.isEmpty || !summary.isEmpty) && summary != DispatcherTeamVerifier.hostFailureSummary
            && summary != "Verifier returned a malformed response."
            && summary != "Verification was cancelled." && !summary.hasPrefix("Verifier failed:")
    }
}

/// The model receives deliverables as JSON data. Only the host handles write receipts.
struct TeamReviewMaterial: Codable, Sendable, Equatable {
    struct Finding: Codable, Sendable, Equatable {
        let title: String
        let outcome: TeamSubtaskOutcome
        let summary: String
        let evidence: [String]
    }

    let findings: [Finding]
    let artifacts: [TeamArtifactDraft]

    init(subtasks: [TeamSubtaskReport], artifacts: [TeamArtifact], excerptsOnly: Bool = false) {
        findings = subtasks.map { report in
            Finding(title: report.title, outcome: report.outcome,
                    summary: excerptsOnly ? String(report.summary.prefix(800)) : report.summary,
                    evidence: excerptsOnly ? report.evidence.prefix(3).map { String($0.prefix(300)) } : report.evidence)
        }
        let included = excerptsOnly ? artifacts.prefix(8) : artifacts[...]
        self.artifacts = included.map {
            TeamArtifactDraft(kind: $0.kind, title: $0.title,
                              content: excerptsOnly ? $0.excerpt(maxCharacters: 1_000) : $0.content)
        }
    }
}

/// Stored with the new plan so an interrupted revision can use the same inputs.
/// A further revision takes the latest deliverables, never a copy of the previous plan.
struct TeamRevision: Codable, Sendable, Equatable {
    let reviewSummary: String
    let issues: [String]
    let material: TeamReviewMaterial
    let openQuestions: [String]
}

// MARK: - Plan

/// 子任务规格：输入是上游产物引用，输出是可校验的结构，不是自由散文。
public struct TeamSubtask: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var objective: String
    public var role: TeamRole
    /// 可选：指定具体智体名/昵称；nil 时按 role 解析。
    public var assignee: String?
    public var dependsOn: [UUID]
    /// 期望的产物类型（report / findings / comparison / ...）。
    public var outputKind: String
    public var acceptance: [String]
    public var maxSteps: Int
    public var estimatedTokens: Int
    /// P0 只支持只读协作；非空写范围会被计划校验直接拒绝。
    public var writeScopes: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        objective: String,
        role: TeamRole = .researcher,
        assignee: String? = nil,
        dependsOn: [UUID] = [],
        outputKind: String = "report",
        acceptance: [String] = [],
        maxSteps: Int = 8,
        estimatedTokens: Int = 12_000,
        writeScopes: [String] = []
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.role = role
        self.assignee = assignee
        self.dependsOn = dependsOn
        self.outputKind = outputKind
        self.acceptance = acceptance
        self.maxSteps = maxSteps
        self.estimatedTokens = estimatedTokens
        self.writeScopes = writeScopes
    }
}

/// 重试时复用原任务的资源范围与目录身份。
public struct TeamRetryScope: Codable, Sendable, Equatable {
    public let resourceContext: RunResourceContext
    public let workspaceName: String
    public let directories: [TaskDirectoryIdentity]

    public init(resourceContext: RunResourceContext, workspaceName: String, directories: [TaskDirectoryIdentity]) {
        self.resourceContext = resourceContext
        self.workspaceName = workspaceName
        self.directories = directories
    }

    public func matches(_ workspace: ChatWorkspace) -> Bool {
        resourceContext.isValid && resourceContext.space == workspace.space && resourceContext.workspaceID == workspace.id
            && !directories.isEmpty && directories.count == workspace.folderURLs.count
            && zip(directories, workspace.folderURLs).allSatisfy { $0.matches($1) }
    }
}

/// 可校验、可持久化、可重放的协作计划。
public struct TeamPlan: Codable, Sendable, Equatable {
    public var goal: String
    public var acceptance: [String]
    public var subtasks: [TeamSubtask]
    public var maxConcurrency: Int
    public var retryScope: TeamRetryScope? = nil
    var revision: TeamRevision?

    /// 模型提供的估算只作计划参考。合计无法表示时，任务板省略该数字。
    public var estimatedTokens: Int? {
        var total = 0
        for subtask in subtasks {
            let (sum, overflow) = total.addingReportingOverflow(subtask.estimatedTokens)
            guard subtask.estimatedTokens >= 0, !overflow else { return nil }
            total = sum
        }
        return total
    }

    public init(
        goal: String,
        acceptance: [String] = [],
        subtasks: [TeamSubtask],
        maxConcurrency: Int = 3
    ) {
        self.goal = goal
        self.acceptance = acceptance
        self.subtasks = subtasks
        self.maxConcurrency = maxConcurrency
    }
}

// MARK: - Artifact

/// Worker 提交的产物草稿；协调器负责补任务/子任务/生产者身份。
public struct TeamArtifactDraft: Codable, Sendable, Equatable {
    public var kind: String
    public var title: String
    public var content: String
    /// Set by the host only after the approved write has been marked applied.
    var writeRecordID: UUID?

    public init(kind: String = "report", title: String, content: String) {
        self.kind = kind
        self.title = title
        self.content = content
    }
}

/// 黑板上的不可变产物引用：下游只拿引用和摘录，不共享完整上下文。
public struct TeamArtifactRef: Codable, Sendable, Hashable, Equatable {
    public let id: UUID
    public let kind: String
    public let title: String

    public init(id: UUID, kind: String, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

/// 版本化产物。P0 内容留在内存黑板；P1 改为空间目录 + 内容哈希。
public struct TeamArtifact: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let subtaskID: UUID
    public let kind: String
    public let title: String
    public let content: String
    public let producer: String
    public let createdAt: Date
    /// 内容 SHA-256（旧快照可能没有；验证时据此核对证据未被替换）
    public let contentDigest: String?
    /// 同一子任务内从 1 开始递增的产物版本
    public let version: Int?
    public let writeRecordID: UUID?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        subtaskID: UUID,
        kind: String,
        title: String,
        content: String,
        producer: String,
        createdAt: Date = Date(),
        contentDigest: String? = nil,
        version: Int? = nil,
        writeRecordID: UUID? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.subtaskID = subtaskID
        self.kind = kind
        self.title = title
        self.content = content
        self.producer = producer
        self.createdAt = createdAt
        self.contentDigest = contentDigest
        self.version = version
        self.writeRecordID = writeRecordID
    }

    public var ref: TeamArtifactRef {
        TeamArtifactRef(id: id, kind: kind, title: title)
    }

    /// 给下游/汇总的有限摘录；完整内容留在黑板。
    public func excerpt(maxCharacters: Int) -> String {
        let limit = max(0, maxCharacters)
        guard limit > 0 else { return "" }
        guard content.count > limit else { return content }
        let end = content.index(content.startIndex, offsetBy: limit)
        return String(content[..<end]) + "\n… [artifact truncated at \(limit) characters]"
    }
}

// MARK: - Worker Result

/// Worker 的结构化结果：大内容放 `artifacts`，摘要给下游/汇总。
public struct TeamSubtaskResult: Codable, Sendable, Equatable {
    public var subtaskID: UUID
    public var outcome: TeamSubtaskOutcome
    public var summary: String
    public var artifacts: [TeamArtifactDraft]
    public var evidence: [String]
    public var openQuestions: [String]
    public var usage: TeamUsage

    public init(
        subtaskID: UUID,
        outcome: TeamSubtaskOutcome = .succeeded,
        summary: String,
        artifacts: [TeamArtifactDraft] = [],
        evidence: [String] = [],
        openQuestions: [String] = [],
        usage: TeamUsage = .zero
    ) {
        self.subtaskID = subtaskID
        self.outcome = outcome
        self.summary = summary
        self.artifacts = artifacts
        self.evidence = evidence
        self.openQuestions = openQuestions
        self.usage = usage
    }
}

// MARK: - Report

public struct TeamSubtaskReport: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let role: String
    public let outcome: TeamSubtaskOutcome
    public let summary: String
    public let artifacts: [TeamArtifactRef]
    public let evidence: [String]
    public let usage: TeamUsage
    public let error: String?

    public init(
        id: UUID,
        title: String,
        role: String,
        outcome: TeamSubtaskOutcome,
        summary: String,
        artifacts: [TeamArtifactRef] = [],
        evidence: [String] = [],
        usage: TeamUsage = .zero,
        error: String? = nil
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.outcome = outcome
        self.summary = summary
        self.artifacts = artifacts
        self.evidence = evidence
        self.usage = usage
        self.error = error
    }
}

/// 任务最终报告：给工具调用方一段可读摘要，同时保留结构化字段供 P1 UI/审计使用。
public struct TeamTaskReport: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let goal: String
    public let status: TeamTaskStatus
    public let subtasks: [TeamSubtaskReport]
    public let artifacts: [TeamArtifact]
    public let usage: TeamUsage
    public let openQuestions: [String]
    public let errors: [String]
    public let startedAt: Date
    public let finishedAt: Date
    public let verification: TeamVerification?
    /// 计划阶段的 token 估算（子任务 estimatedTokens 之和）；nil = 旧数据/未估算。
    public let estimatedTokens: Int?

    public init(
        taskID: UUID,
        goal: String,
        status: TeamTaskStatus,
        subtasks: [TeamSubtaskReport],
        artifacts: [TeamArtifact],
        usage: TeamUsage,
        openQuestions: [String],
        errors: [String],
        startedAt: Date,
        finishedAt: Date,
        verification: TeamVerification? = nil,
        estimatedTokens: Int? = nil
    ) {
        self.taskID = taskID
        self.goal = goal
        self.status = status
        self.subtasks = subtasks
        self.artifacts = artifacts
        self.usage = usage
        self.openQuestions = openQuestions
        self.errors = errors
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.verification = verification
        self.estimatedTokens = estimatedTokens
    }

    public var isComplete: Bool { status == .completed }

    /// 回填主模型的摘要：限制每条产物/摘要长度，避免整段塞进 Engine 的 6000 字符工具结果上限。
    public func digest(
        maxArtifactCharacters: Int = 700,
        maxTotalCharacters: Int = 5_800
    ) -> String {
        var lines: [String] = [
            "Team task: \(goal)",
            "Status: \(status.rawValue)",
        ]
        if let estimatedTokens {
            lines.append("Estimated: \(estimatedTokens) tokens")
        }
        if let verification {
            lines.append(
                "Verification: \(verification.passed ? "passed" : "failed") — "
                    + Self.shortened(verification.summary, limit: 500)
            )
            if !verification.issues.isEmpty {
                lines.append("Verification issues:")
                lines.append(contentsOf: verification.issues.prefix(8).map {
                    "- \(Self.shortened($0, limit: 300))"
                })
            }
        }
        if !subtasks.isEmpty {
            lines.append("Subtask results:")
            for subtask in subtasks {
                var line = "- [\(subtask.outcome.rawValue)] \(subtask.title): "
                    + Self.shortened(subtask.summary, limit: 400)
                if let error = subtask.error, !error.isEmpty {
                    line += " (error: \(Self.shortened(error, limit: 200)))"
                }
                lines.append(line)
            }
        }
        let evidence = subtasks.flatMap(\.evidence)
        if !evidence.isEmpty {
            lines.append("Evidence:")
            lines.append(contentsOf: evidence.prefix(10).map {
                "- \(Self.shortened($0, limit: 300))"
            })
        }
        if artifacts.isEmpty {
            lines.append("Artifacts: none")
        } else {
            lines.append("Artifacts:")
            for artifact in artifacts {
                lines.append("- [\(artifact.kind)] \(artifact.title)")
                let excerpt = artifact.excerpt(maxCharacters: maxArtifactCharacters)
                if !excerpt.isEmpty {
                    lines.append(excerpt)
                }
            }
        }
        if !openQuestions.isEmpty {
            lines.append("Open questions:")
            lines.append(contentsOf: openQuestions.prefix(8).map {
                "- \(Self.shortened($0, limit: 300))"
            })
        }
        if !errors.isEmpty {
            lines.append("Errors:")
            lines.append(contentsOf: errors.prefix(8).map {
                "- \(Self.shortened($0, limit: 300))"
            })
        }
        lines.append(
            "Usage: \(usage.tokens) tokens "
                + "(\(usage.inputTokens) in / \(usage.outputTokens) out), "
                + "\(usage.toolCalls) tool calls, "
                + String(format: "%.1fs", usage.duration)
        )
        lines.append("Note: team workers were read-only; no files were written and no external side effects were performed.")
        let text = lines.joined(separator: "\n")
        guard maxTotalCharacters > 0, text.count > maxTotalCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxTotalCharacters)
        return String(text[..<end]) + "\n… [team digest truncated]"
    }

    private static func shortened(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }
}

// MARK: - Events

/// P0 事件流：先给测试和后续任务板使用，不进入主对话上下文。
public enum TeamTaskEvent: Sendable, Equatable {
    case started(taskID: UUID, goal: String)
    case subtaskStarted(taskID: UUID, subtaskID: UUID, title: String, role: String, agent: String)
    case subtaskFinished(taskID: UUID, subtaskID: UUID, outcome: TeamSubtaskOutcome, summary: String)
    case finished(TeamTaskReport)
}

// MARK: - Errors

public enum TeamError: LocalizedError, Equatable, Sendable {
    case noEnabledAgent
    case retryUnavailable
    case invalidArguments(String)
    case invalidPlan(TeamPlanError)
    case workerUnavailable(String)
    case budgetExceeded

    public var errorDescription: String? {
        switch self {
        case .noEnabledAgent:
            return "No enabled sub-agent is available for this team task."
        case .retryUnavailable:
            return "This task is no longer available for a read-only retry."
        case .invalidArguments(let message):
            return "Invalid team task arguments: \(message)"
        case .invalidPlan(let error):
            return error.errorDescription
        case .workerUnavailable(let message):
            return "Team worker is unavailable: \(message)"
        case .budgetExceeded:
            return "The team task exceeded its budget before it could finish."
        }
    }
}
