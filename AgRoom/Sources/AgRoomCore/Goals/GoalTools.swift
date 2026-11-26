import Foundation

/// Model-authored notes are inert until the host evaluates a real segment receipt.
public actor GoalProgressState {
    private var report: GoalProgressReport?
    public init() {}
    public func snapshot() -> GoalProgressReport? { report }
    func record(_ report: GoalProgressReport) { self.report = report }
}

public struct GoalCheckpointTool: DispatcherTool {
    public let state: GoalProgressState
    public init(state: GoalProgressState) { self.state = state }
    public var requiresConfirmation: Bool { false }
    public var sideEffectClass: ToolSideEffectClass { .readOnly }
    public var definition: ToolDefinition {
        .init(name: "goal_checkpoint", description: "Report bounded execution notes for this goal segment. This only records model-authored candidate progress; it cannot complete a goal, change acceptance criteria, grant access or approve an action. Call before finishing. Supply concrete next_actions when more work remains, or ready_for_review=true to request host/user verification. A claim of completion is never verification.",
            parametersSchemaJSON: #"{"type":"object","properties":{"summary":{"type":"string","maxLength":2000},"next_actions":{"type":"array","items":{"type":"string","maxLength":500},"maxItems":8},"ready_for_review":{"type":"boolean"}},"required":["summary","ready_for_review"],"additionalProperties":false}"#)
    }
    private func parse(_ arguments: String) throws -> GoalProgressReport {
        struct Arguments: Decodable {
            let summary: String
            let ready_for_review: Bool
            let next_actions: [String]?
        }
        guard arguments.utf8.count <= 16_000,
              let raw = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              Set(raw.keys).isSubset(of: ["summary", "next_actions", "ready_for_review"]) else { throw GoalError.invalid }
        let decoded = try JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8))
        let value = GoalProgressReport(summary: decoded.summary, nextActions: decoded.next_actions ?? [], readyForReview: decoded.ready_for_review)
        guard value.isValid else { throw GoalError.invalid }; return value
    }
    public func validateArguments(argumentsJSON: String) throws { _ = try parse(argumentsJSON) }
    public func execute(argumentsJSON: String) async throws -> String {
        try Task.checkCancellation()
        let value = try parse(argumentsJSON)
        await state.record(value)
        return "Candidate checkpoint recorded. The host will evaluate actual evidence; this is not goal completion."
    }
}

public struct GoalDraftReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let version: Int
    public let space: AppSpace
    public let sessionID: UUID
    public let workspaceID: UUID
    public let definition: GoalDefinition
    public static func read(_ text: String, space: AppSpace, sessionID: UUID, workspaceID: UUID) throws -> Self {
        guard text.utf8.count <= 24_000 else { throw GoalError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.version == 1, value.space == space, value.sessionID == sessionID,
              value.workspaceID == workspaceID, value.definition.isValid,
              value.definition.criteria.allSatisfy({ $0.kind == .manual && $0.verdict == .unknown && $0.evidenceRunID == nil }) else { throw GoalError.invalid }
        return value
    }
}

struct GoalDraftTool: DispatcherTool {
    let space: AppSpace
    let sessionID: UUID
    let workspaceID: UUID
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition {
        .init(name: "goal_draft", description: "Prepare an execution goal only when the user asks to set a goal for sustained execution. Returns an inert draft for native preview; does not save, start or authorize execution. The user reviews objective, acceptance criteria and existing permissions before starting. Do not claim a goal has started. App must remain running. Criteria are human-reviewed; the draft cannot declare them passed. No goal-level token, tool-call, segment or time budget is configured.",
            parametersSchemaJSON: #"{"type":"object","properties":{"title":{"type":"string","maxLength":120},"objective":{"type":"string","maxLength":8000},"criteria":{"type":"array","items":{"type":"string","maxLength":500},"minItems":1,"maxItems":20},"constraints":{"type":"string","maxLength":4000}},"required":["title","objective","criteria"],"additionalProperties":false}"#)
    }
    func execute(argumentsJSON: String) async throws -> String {
        try Task.checkCancellation()
        let receipt = GoalDraftReceipt(id: UUID(), version: 1, space: space, sessionID: sessionID, workspaceID: workspaceID, definition: try parse(argumentsJSON))
        let result = try JSONEncoder().encode(receipt)
        guard result.count <= 24_000, String(decoding: result, as: UTF8.self).count <= 16_000 else { throw GoalError.invalid }
        return String(decoding: result, as: UTF8.self)
    }
    func validateArguments(argumentsJSON: String) throws { _ = try parse(argumentsJSON) }
    private func parse(_ text: String) throws -> GoalDefinition {
        struct Arguments: Decodable {
            let title: String, objective: String, criteria: [String]
            var constraints: String?
        }
        guard text.utf8.count <= 24_000,
              let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(raw.keys).isSubset(of: ["title", "objective", "criteria", "constraints"]) else { throw GoalError.invalid }
        let args = try JSONDecoder().decode(Arguments.self, from: Data(text.utf8))
        let value = GoalDefinition(title: args.title, objective: args.objective,
            criteria: args.criteria.map { .init(text: $0) }, constraints: args.constraints ?? "")
        guard value.isValid else { throw GoalError.invalid }; return value
    }
}
