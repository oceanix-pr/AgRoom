import CryptoKit
import Foundation

public struct ScheduledTaskBudget: Codable, Sendable, Equatable {
    public var maxTokens: Int
    public var maxToolCalls: Int
    public var seconds: Int

    public init(maxTokens: Int = 100_000, maxToolCalls: Int = 64, seconds: Int = 180) {
        self.maxTokens = maxTokens; self.maxToolCalls = maxToolCalls; self.seconds = seconds
    }
    public var isValid: Bool {
        (1_000...500_000).contains(maxTokens) && (1...128).contains(maxToolCalls) && (1...180).contains(seconds)
    }
    public func checkpoint(now: Date) -> ExecutionBudgetCheckpoint {
        .init(maxTokens: maxTokens, maxToolCalls: maxToolCalls, spentTokens: 0, toolCalls: 0,
            deadline: now.addingTimeInterval(Double(seconds)))
    }
}

public struct ScheduledTaskOptions: Codable, Sendable, Equatable {
    public var budget: ScheduledTaskBudget
    public var notifyOnlyOnChange: Bool {
        didSet { if oldValue != notifyOnlyOnChange { comparisonRevision = UUID() } }
    }
    public var comparisonInstructions: String
    public var comparisonRevision: UUID?
    public init(budget: ScheduledTaskBudget = .init(), notifyOnlyOnChange: Bool = false, comparisonInstructions: String = "", comparisonRevision: UUID? = nil) {
        self.budget = budget; self.notifyOnlyOnChange = notifyOnlyOnChange; self.comparisonInstructions = comparisonInstructions
        self.comparisonRevision = comparisonRevision ?? (notifyOnlyOnChange ? UUID() : nil)
    }
    public var isValid: Bool {
        budget.isValid && comparisonInstructions.count <= 2_000 &&
            (!notifyOnlyOnChange || !comparisonInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

public enum ScheduledComparisonState: String, Codable, Sendable { case baseline, unchanged, changed, unavailable }

/// Facts captured for this execution, independent of later edits to its task.
public struct ScheduledRunExperience: Codable, Sendable, Equatable {
    public var budget: ScheduledTaskBudget
    public var usageKnown = false
    public var budgetSpentTokens: Int?
    public var providerID: UUID?
    public var model: String?
    public var outputTruncated = false
    public var definitionFingerprint: String?
    public var comparisonValue: String?
    public var comparisonState: ScheduledComparisonState?
    public var baselineRunID: UUID?
    public init(budget: ScheduledTaskBudget) { self.budget = budget }
}

extension ScheduledTask {
    public var effectiveOptions: ScheduledTaskOptions { options ?? .init() }
    public var comparisonFingerprint: String {
        // A changed definition starts a fresh baseline. Run state and budget do
        // not change the meaning of an observation.
        struct Definition: Encodable {
            let prompt: String
            let profile: String
            let schedule: ScheduledTaskSchedule
            let comparison: String
            let revision: UUID?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = Definition(prompt: prompt, profile: profileVersion, schedule: schedule,
            comparison: effectiveOptions.comparisonInstructions, revision: effectiveOptions.comparisonRevision)
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ScheduledComparison {
    public struct Observation: Codable, Sendable, Equatable {
        public let comparison_value: String
        public let result: String
    }
    /// Only an explicit, bounded observation is comparable. Free prose, missing
    /// fields and truncated JSON never silently become a changed observation.
    public static func parse(_ text: String) throws -> Observation {
        guard text.utf8.count <= 512 * 1024 else { throw ScheduledExperienceError.invalidComparison }
        let value = try JSONDecoder().decode(Observation.self, from: Data(text.utf8))
        guard !value.comparison_value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.comparison_value.count <= 4_096, !value.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScheduledExperienceError.invalidComparison
        }
        return value
    }
    public static func canonical(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
    public static func shouldNotify(_ run: ScheduledRun) -> Bool {
        run.status == .succeeded && (run.experience?.comparisonState == nil || run.experience?.comparisonState == .changed)
    }
}

public enum ScheduledExperienceError: String, Error, Sendable {
    case invalidDraft, invalidComparison, missing, changed, resultSaveFailed
}
