import Foundation

/// A recoverable, inert tool receipt. Activation is a separate explicit UI save.
public struct ScheduledTaskDraft: Codable, Sendable, Identifiable {
    public let id: UUID
    public let space: AppSpace
    public let task: ScheduledTask
    public let version: Int
    public init(space: AppSpace, task: ScheduledTask) { id = UUID(); self.space = space; self.task = task; version = 1 }
    public static func read(_ text: String, space: AppSpace) throws -> Self {
        guard text.utf8.count <= 96 * 1024 else { throw ScheduledExperienceError.invalidDraft }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.version == 1, value.space == space, value.task.isProfileSupported,
              value.task.effectiveOptions.isValid, value.task.name.count <= 240, value.task.prompt.count <= 20_000,
              !value.task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.task.schedule.validate(now: .distantPast) == nil else { throw ScheduledExperienceError.invalidDraft }
        return value
    }
}

public struct ScheduledDraftTool: DispatcherTool {
    public let space: AppSpace
    public init(space: AppSpace) { self.space = space }
    public var requiresConfirmation: Bool { false }
    public var sideEffectClass: ToolSideEffectClass { .readOnly }
    public var definition: ToolDefinition {
        .init(name: "schedule_draft", description: "Prepare a read-only scheduled Agent task for the user to review. This tool only returns an inert draft receipt; it does NOT save, enable or run a schedule. The user must open the draft's preview in the conversation and explicitly save it. Do not claim it is scheduled before that. Runs require the App to be running and the master scheduling switch enabled. No shell, code, writes, mail sending, browser or questions are allowed. Use get_current_time before resolving relative dates. Specify an IANA time_zone and rule; once uses an ISO8601 at, daily/weekly use hour and minute, weekly uses ISO weekdays 1...7, interval uses interval_minutes (5...1440). For change-only monitoring supply comparison_instructions describing a stable value to compare; the first success establishes a quiet baseline, later changed observations notify, failures still notify. Budget caps: max_tokens 1000...500000, max_tool_calls 1...128, max_seconds 1...180. All instructions and settings remain editable in the preview.",
            parametersSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string"},"prompt":{"type":"string"},"rule":{"type":"string","enum":["once","daily","weekly","interval"]},"time_zone":{"type":"string"},"at":{"type":"string"},"hour":{"type":"integer"},"minute":{"type":"integer"},"weekdays":{"type":"array","items":{"type":"integer"}},"interval_minutes":{"type":"integer"},"max_tokens":{"type":"integer"},"max_tool_calls":{"type":"integer"},"max_seconds":{"type":"integer"},"comparison_instructions":{"type":"string"}},"required":["name","prompt","rule","time_zone"],"additionalProperties":false}"#)
    }

    public func execute(argumentsJSON: String) async throws -> String {
        try Task.checkCancellation()
        guard argumentsJSON.utf8.count <= 96 * 1024,
              let args = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] else {
            throw ToolExecutionFailure(message: "Provide a schedule draft object within 96 KiB.")
        }
        let allowed: Set<String> = ["name","prompt","rule","time_zone","at","hour","minute","weekdays","interval_minutes","max_tokens","max_tool_calls","max_seconds","comparison_instructions"]
        guard Set(args.keys).isSubset(of: allowed) else { throw ToolExecutionFailure(message: "Unsupported schedule draft fields.") }
        for key in ["name","prompt","rule","time_zone","at","comparison_instructions"] where args[key] != nil {
            guard args[key] is String else { throw ToolExecutionFailure(message: "\(key) must be a string.") }
        }
        func string(_ key: String) -> String { args[key] as? String ?? "" }
        func integer(_ key: String, default fallback: Int? = nil) throws -> Int {
            if args[key] == nil, let fallback { return fallback }
            guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max),
                  number.doubleValue == Double(number.intValue) else { throw ToolExecutionFailure(message: "\(key) must be an integer.") }
            return number.intValue
        }
        let zone = string("time_zone")
        guard TimeZone(identifier: zone) != nil else { throw ToolExecutionFailure(message: "time_zone must be a valid IANA time zone.") }
        let rule: ScheduledTaskSchedule.ScheduledRule
        let timing: Set<String> = ["at","hour","minute","weekdays","interval_minutes"]
        let requiredTiming: [String: Set<String>] = ["once":["at"],"daily":["hour","minute"],"weekly":["hour","minute","weekdays"],"interval":["interval_minutes"]]
        guard let selectedTiming = requiredTiming[string("rule")], timing.intersection(args.keys).isSubset(of: selectedTiming) else {
            throw ToolExecutionFailure(message: "Use only the time fields for the selected rule.")
        }
        switch string("rule") {
        case "once":
            let formatter = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard string("at").count <= 128, let date = formatter.date(from: string("at")) ?? fractional.date(from: string("at")) else { throw ToolExecutionFailure(message: "at must be a future ISO8601 timestamp with a UTC offset.") }
            rule = .once(date)
        case "daily": rule = .daily(hour: try integer("hour"), minute: try integer("minute"))
        case "weekly":
            guard let days = args["weekdays"] as? [NSNumber], !days.isEmpty, days.count <= 7,
                  days.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == Double($0.intValue) && (1...7).contains($0.intValue) }) else {
                throw ToolExecutionFailure(message: "weekdays must contain ISO weekday integers 1...7.")
            }
            rule = .weekly(weekdays: Array(Set(days.map(\.intValue))).sorted(), hour: try integer("hour"), minute: try integer("minute"))
        case "interval": rule = .interval(minutes: try integer("interval_minutes"), anchor: Date())
        default: throw ToolExecutionFailure(message: "Choose rule=once, daily, weekly or interval.")
        }
        let budget = ScheduledTaskBudget(maxTokens: try integer("max_tokens", default: 100_000),
            maxToolCalls: try integer("max_tool_calls", default: 64), seconds: try integer("max_seconds", default: 180))
        let comparison = string("comparison_instructions").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = ScheduledTaskOptions(budget: budget, notifyOnlyOnChange: !comparison.isEmpty, comparisonInstructions: comparison)
        let task = ScheduledTask(name: string("name"), prompt: string("prompt"), schedule: .init(rule: rule, timeZoneIdentifier: zone), options: options)
        guard task.validate() == nil, task.name.count <= 240, task.prompt.count <= 20_000 else {
            throw ToolExecutionFailure(message: "Invalid schedule draft. Check name, instructions, future time, interval, comparison and budget ranges.")
        }
        let receipt = String(decoding: try JSONEncoder().encode(ScheduledTaskDraft(space: space, task: task)), as: UTF8.self)
        guard receipt.count <= 16_000 else { throw ToolExecutionFailure(message: "This draft is too large for a recoverable conversation receipt. Shorten its instructions or comparison criterion and prepare it again.") }
        return receipt
    }
}
