import Foundation

/// Local estimates, never provider-reported or billable counts. Categories do not overlap.
public struct RequestTokenEstimate: Codable, Sendable, Equatable {
    public var system = 0
    public var toolSchema = 0
    public var history = 0
    public var conversation = 0
    public var sourceEvidence = 0
    public var taskState = 0
    public var otherToolResults = 0
    public var continuation = 0
    public var images = 0
    public var framing = 0

    public var total: Int {
        system + toolSchema + history + conversation + sourceEvidence + taskState
            + otherToolResults + continuation + images + framing
    }
    var isValid: Bool {
        [system, toolSchema, history, conversation, sourceEvidence, taskState,
         otherToolResults, continuation, images, framing].allSatisfy { $0 >= 0 && $0 <= 100_000_000 }
    }
}

/// Request identity and sizes only: never retain a prompt, path, tool arguments or source text.
public struct ProviderRequestMetadata: Codable, Sendable, Equatable {
    public var space: AppSpace?
    public var runID: UUID?
    public var parentRunID: UUID?
    public var rootRunID: UUID?
    public var purpose: BudgetPurpose?
    public var estimate: RequestTokenEstimate?

    public init(runID: UUID? = nil, parentRunID: UUID? = nil, purpose: BudgetPurpose? = nil,
                estimate: RequestTokenEstimate? = nil, space: AppSpace? = nil, rootRunID: UUID? = nil) {
        self.runID = runID; self.parentRunID = parentRunID; self.purpose = purpose; self.estimate = estimate
        self.space = space
        self.rootRunID = rootRunID
    }
}

/// Task-local identity follows provider adaptation retries without mutating shared providers.
enum ProviderRequestContext {
    @TaskLocal static var current: ProviderRequestMetadata?
}

/// Each callback describes one completed HTTP attempt, including an interrupted stream.
/// Preserve reported partial totals; missing counts never become complete zero usage.
final class ProviderAttemptUsage: @unchecked Sendable {
    struct Snapshot: Sendable {
        var requests = 0
        var input = 0
        var output = 0
        var complete = true
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func record(_ usage: ProviderTokenUsage) {
        lock.withLock {
            value.requests += 1
            value.input += max(0, usage.input ?? 0)
            value.output += max(0, usage.output ?? 0)
            value.complete = value.complete && usage.hasCompleteTokenCounts
        }
    }
    var snapshot: Snapshot { lock.withLock { value } }
}

/// Reasoning is a subset of output, not the size of the visible thought transcript.
/// Keep coverage so a missing report never becomes a reported zero.
public struct ReasoningTokenUsage: Codable, Sendable, Equatable {
    public private(set) var reportedTokens: Int?
    public private(set) var reportedRequests = 0
    public private(set) var unreportedRequests = 0

    public init() {}

    public var requestCount: Int { reportedRequests + unreportedRequests }
    public var isComplete: Bool { reportedTokens != nil && unreportedRequests == 0 }

    public mutating func record(_ tokens: Int?) {
        guard let tokens, tokens >= 0 else { unreportedRequests += 1; return }
        let sum = (reportedTokens ?? 0).addingReportingOverflow(tokens)
        guard !sum.overflow else { unreportedRequests += 1; return }
        reportedTokens = sum.partialValue
        reportedRequests += 1
    }
}

/// Provider-reported counts. A missing field remains unknown, including cache information.
public struct ProviderTokenUsage: Codable, Sendable, Equatable {
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var ordinaryInput: Int?
    public var reasoning: Int?
    public var inputText: Int?
    public var inputImage: Int?
    public var outputImage: Int?
    public var reportedModel: String?

    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil,
                ordinaryInput: Int? = nil, reasoning: Int? = nil, reportedModel: String? = nil, inputText: Int? = nil, inputImage: Int? = nil, outputImage: Int? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.inputText = inputText; self.inputImage = inputImage; self.outputImage = outputImage
        self.ordinaryInput = ordinaryInput; self.reasoning = reasoning; self.reportedModel = reportedModel
    }

    public var hasCompleteImageTokenCounts: Bool {
        guard let input, let output, let inputText, let inputImage, let outputImage,
              [input, output, inputText, inputImage, outputImage].allSatisfy({ $0 >= 0 }),
              let sum = Self.sum([inputText, inputImage]) else { return false }
        return sum == input && outputImage == output
    }

    public var hasCompleteTokenCounts: Bool { input != nil && output != nil }
    public var reportedTotal: Int? {
        guard input != nil || output != nil else { return nil }
        return Self.sum([input ?? 0, output ?? 0])
    }

    static func decode(_ usage: [String: Any]?, anthropic: Bool) -> Self {
        guard let usage else { return .init() }
        func count(_ value: Any?) -> Int? {
            guard let value = value as? Int, value >= 0 else { return nil }; return value
        }
        if anthropic {
            let ordinary = count(usage["input_tokens"])
            let read = count(usage["cache_read_input_tokens"]), write = count(usage["cache_creation_input_tokens"])
            return .init(input: ordinary.flatMap { sum([$0, read ?? 0, write ?? 0]) },
                         output: count(usage["output_tokens"]), cacheRead: read, cacheWrite: write, ordinaryInput: ordinary)
        }
        let details = (usage["prompt_tokens_details"] ?? usage["input_tokens_details"]) as? [String: Any]
        let input = count(usage["prompt_tokens"] ?? usage["input_tokens"])
        let read = count(details?["cached_tokens"] ?? usage["prompt_cache_hit_tokens"])
        let write = count(details?["cache_write_tokens"])
        // Gateways with a documented hit/miss pair can report the ordinary portion directly.
        let ordinary = count(usage["prompt_cache_miss_tokens"]) ?? ordinaryInput(total: input, read: read, write: write)
        let outputDetails = (usage["completion_tokens_details"] ?? usage["output_tokens_details"]) as? [String: Any]
        return .init(input: input, output: count(usage["completion_tokens"] ?? usage["output_tokens"]), cacheRead: read, cacheWrite: write,
                     ordinaryInput: ordinary, reasoning: count(outputDetails?["reasoning_tokens"]),
                     inputText: count(details?["text_tokens"]), inputImage: count(details?["image_tokens"]),
                     outputImage: count(outputDetails?["image_tokens"]))
    }

    mutating func merge(_ newer: Self, anthropic: Bool) {
        if let value = newer.input { input = value }
        if let value = newer.output { output = value }
        if let value = newer.cacheRead { cacheRead = value }
        if let value = newer.cacheWrite { cacheWrite = value }
        if let value = newer.ordinaryInput { ordinaryInput = value }
        if let value = newer.reasoning { reasoning = value }
        if let value = newer.inputText { inputText = value }
        if let value = newer.inputImage { inputImage = value }
        if let value = newer.outputImage { outputImage = value }
        if let value = newer.reportedModel { reportedModel = value }
        if anthropic, let ordinaryInput { input = Self.sum([ordinaryInput, cacheRead ?? 0, cacheWrite ?? 0]) }
        if !anthropic, newer.input != nil || newer.cacheRead != nil || newer.cacheWrite != nil {
            ordinaryInput = newer.ordinaryInput ?? Self.ordinaryInput(total: input, read: cacheRead, write: cacheWrite)
        }
    }

    private static func ordinaryInput(total: Int?, read: Int?, write: Int?) -> Int? {
        guard let total, let read, let write, let cache = sum([read, write]), cache <= total else { return nil }
        return total - cache
    }
    private static func sum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values { let result = total.addingReportingOverflow(value); guard !result.overflow else { return nil }; total = result.partialValue }
        return total
    }
}

public struct ProviderUsageRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let sessionID: String?
    public let providerID: String?
    public let providerName: String?
    public let requestedModel: String
    public let source: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: String
    public let usage: ProviderTokenUsage
    // Display-only join values; no conversation content is retained in a receipt.
    public var sessionTitle: String? = nil
    public var sessionDeleted: Bool = false
    public var request: ProviderRequestMetadata? = nil
}

public struct UsageModelSummary: Identifiable, Sendable {
    public let id: String
    public let model: String
    public let providerName: String?
    public let isReportedModel: Bool
    public var providerID: String?
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var requests = 0
    public var unknownCacheRequests = 0
    public var imageInputText = 0
    public var imageInputImage = 0
    public var imageOutputImage = 0
    public var completeImageRecords = 0
    public var reportedInputRecords = 0
    public var reportedOutputRecords = 0
    public var reportedCacheReadRecords = 0
    public var reportedCacheWriteRecords = 0
}

/// A display group keeps response-confirmed and request-only identities as separate sources.
/// Provider identity, rather than its editable display name, determines the group boundary.
public struct UsageModelGroup: Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let providerID: String?
        public let model: String
    }
    public let id: ID
    public let sources: [UsageModelSummary]
    public var model: String { id.model }
    public var providerName: String? { sources.compactMap(\.providerName).first }
    public var input: Int { sources.reduce(0) { $0 + $1.input } }
    public var output: Int { sources.reduce(0) { $0 + $1.output } }
    public var cacheRead: Int { sources.reduce(0) { $0 + $1.cacheRead } }
    public var cacheWrite: Int { sources.reduce(0) { $0 + $1.cacheWrite } }
    public var records: Int { sources.reduce(0) { $0 + $1.requests } }
    public var unknownCacheRecords: Int { sources.reduce(0) { $0 + $1.unknownCacheRequests } }
    public var completeImageRecords: Int { sources.reduce(0) { $0 + $1.completeImageRecords } }
    public var imageUsage: ProviderTokenUsage {
        .init(input: input, output: output,
              inputText: completeImageRecords == records ? sources.reduce(0) { $0 + $1.imageInputText } : nil,
              inputImage: completeImageRecords == records ? sources.reduce(0) { $0 + $1.imageInputImage } : nil,
              outputImage: completeImageRecords == records ? sources.reduce(0) { $0 + $1.imageOutputImage } : nil)
    }
    public var reportedInputRecords: Int { sources.reduce(0) { $0 + $1.reportedInputRecords } }
    public var reportedOutputRecords: Int { sources.reduce(0) { $0 + $1.reportedOutputRecords } }
    public var reportedCacheReadRecords: Int { sources.reduce(0) { $0 + $1.reportedCacheReadRecords } }
    public var reportedCacheWriteRecords: Int { sources.reduce(0) { $0 + $1.reportedCacheWriteRecords } }
}

extension UsageStats {
    public var modelGroups: [UsageModelGroup] {
        Dictionary(grouping: byModel) { UsageModelGroup.ID(providerID: $0.providerID, model: $0.model) }
            .map { id, sources in
                UsageModelGroup(id: id, sources: sources.sorted { $0.isReportedModel && !$1.isReportedModel })
            }
            .sorted {
                if $0.input + $0.output != $1.input + $1.output { return $0.input + $0.output > $1.input + $1.output }
                if $0.model != $1.model { return $0.model < $1.model }
                return ($0.id.providerID ?? "") < ($1.id.providerID ?? "")
            }
    }
}

public enum UsageRequestFilter: String, CaseIterable, Sendable {
    case all, failedOrCancelled, failed, cancelled, unreported, incompleteCache, unfinished
}

public enum UsagePeriod: String, CaseIterable, Sendable {
    case all, today, last7Days, thisMonth, custom

    /// Local calendar days, queried as a half-open interval [start, end).
    /// Calendar arithmetic preserves the intended days across daylight-saving transitions.
    public func interval(now: Date = Date(), calendar: Calendar = .current,
                         customStart: Date = Date(), customEnd: Date = Date()) -> DateInterval? {
        switch self {
        case .all: return nil
        case .today: return calendar.dateInterval(of: .day, for: now)
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)
        case .last7Days:
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  let start = calendar.date(byAdding: .day, value: -7, to: end) else { return nil }
            return DateInterval(start: start, end: end)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            guard let end = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: max(customStart, customEnd))) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}
