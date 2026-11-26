import Foundation

// MARK: - Scheduled Task

/// 定时任务定义：属于单一空间（空间库表），执行时显式绑定该空间。
/// P0a 只支持只读 Agent 任务；提示词是用户自己写的指令，不是外部内容。
public struct ScheduledTask: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var prompt: String
    public var schedule: ScheduledTaskSchedule
    /// 能力档版本（例如 `readOnly.v1`）；能力面由代码解释，不把工具清单存进数据库。
    public var profileVersion: String
    public var notificationPolicy: ScheduledNotificationPolicy
    public let createdAt: Date
    public var updatedAt: Date
    /// 下一次计划触发时刻（列表展示用；以重算结果为准）。
    public var nextFireAt: Date?
    public var lastRunAt: Date?
    public var lastRunStatus: ScheduledRunStatus?
    public var options: ScheduledTaskOptions?

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        prompt: String,
        schedule: ScheduledTaskSchedule,
        profileVersion: String = ScheduledCapabilityProfile.readOnlyV1,
        notificationPolicy: ScheduledNotificationPolicy = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        nextFireAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastRunStatus: ScheduledRunStatus? = nil,
        options: ScheduledTaskOptions? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.prompt = prompt
        self.schedule = schedule
        self.profileVersion = profileVersion
        self.notificationPolicy = notificationPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nextFireAt = nextFireAt
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.options = options
    }

    /// 能力档是否被当前版本支持；未知版本拒绝运行。
    public var isProfileSupported: Bool {
        ScheduledCapabilityProfile.toolNames(for: profileVersion) != nil
    }

    /// 保存前校验：名称/指令非空、能力档受支持、触发规则合法。
    public func validate(now: Date = Date()) -> ScheduledTaskValidationError? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyName
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyPrompt
        }
        guard isProfileSupported else { return .unsupportedProfile }
        guard effectiveOptions.isValid, name.count <= 240, prompt.count <= 20_000 else { return .invalidOptions }
        return schedule.validate(now: now)
    }
}

// MARK: - Schedule

/// 触发规则 + IANA 时区。时区显式保存：系统时区变化不能让「每天 09:00」静默漂移。
public struct ScheduledTaskSchedule: Codable, Sendable, Equatable {
    public var rule: ScheduledRule
    public var timeZoneIdentifier: String

    public init(rule: ScheduledRule, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.rule = rule
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    public enum ScheduledRule: Codable, Sendable, Equatable {
        case once(Date)
        case daily(hour: Int, minute: Int)
        /// ISO 星期：1 = 周一 … 7 = 周日。
        case weekly(weekdays: [Int], hour: Int, minute: Int)
        /// 从 anchor 起每 N 分钟；不是「上次完成后 N 分钟」。
        case interval(minutes: Int, anchor: Date)
    }

    // 手写 Codable：JSON 是空间库快照的一部分，使用稳定的 kind 字段，
    // 不依赖 Swift 枚举关联值合成格式。
    private enum CodingKeys: String, CodingKey {
        case kind, timeZoneIdentifier, date, hour, minute, weekdays, minutes, anchor
    }

    private enum Kind: String, Codable {
        case once, daily, weekly, interval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
        switch try container.decode(Kind.self, forKey: .kind) {
        case .once:
            rule = .once(try container.decode(Date.self, forKey: .date))
        case .daily:
            rule = .daily(
                hour: try container.decode(Int.self, forKey: .hour),
                minute: try container.decode(Int.self, forKey: .minute)
            )
        case .weekly:
            rule = .weekly(
                weekdays: try container.decode([Int].self, forKey: .weekdays),
                hour: try container.decode(Int.self, forKey: .hour),
                minute: try container.decode(Int.self, forKey: .minute)
            )
        case .interval:
            rule = .interval(
                minutes: try container.decode(Int.self, forKey: .minutes),
                anchor: try container.decode(Date.self, forKey: .anchor)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        switch rule {
        case .once(let date):
            try container.encode(Kind.once, forKey: .kind)
            try container.encode(date, forKey: .date)
        case .daily(let hour, let minute):
            try container.encode(Kind.daily, forKey: .kind)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .weekly(let weekdays, let hour, let minute):
            try container.encode(Kind.weekly, forKey: .kind)
            try container.encode(weekdays, forKey: .weekdays)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .interval(let minutes, let anchor):
            try container.encode(Kind.interval, forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
            try container.encode(anchor, forKey: .anchor)
        }
    }

    /// 保存前校验：非法规则不落库，也不注册到调度中心。
    public func validate(now: Date = Date()) -> ScheduledTaskValidationError? {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { return .invalidTimeZone }
        switch rule {
        case .once(let date):
            guard date.timeIntervalSince1970.isFinite, date <= .distantFuture else { return .invalidTime }
            guard date > now else { return .onceInPast }
        case .daily(let hour, let minute):
            guard (0...23).contains(hour), (0...59).contains(minute) else { return .invalidTime }
        case .weekly(let weekdays, let hour, let minute):
            guard (0...23).contains(hour), (0...59).contains(minute) else { return .invalidTime }
            guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
                return .invalidWeekdays
            }
        case .interval(let minutes, let anchor):
            guard anchor.timeIntervalSince1970.isFinite, anchor >= .distantPast, anchor <= .distantFuture else { return .invalidTime }
            guard minutes >= ScheduledTaskSchedule.minimumIntervalMinutes else {
                return .intervalTooShort
            }
            guard minutes <= ScheduledTaskSchedule.maximumIntervalMinutes else { return .intervalTooLong }
        }
        return nil
    }

    /// Agent 定时任务的最小间隔，避免模型调用堆积和费用失控。
    public static let minimumIntervalMinutes = 5
    public static let maximumIntervalMinutes = 1_440
}

// MARK: - Schedule Calculator

/// 纯函数触发计算：不读数据库、不依赖 UI，便于覆盖夏令时、时区与时钟回拨。
public enum ScheduleCalculator {
    public static let defaultMisfireGrace: TimeInterval = 60 * 60

    /// `after` 之后的下一次触发；一次任务已过期返回 nil。
    public static func nextFireDate(
        for schedule: ScheduledTaskSchedule,
        after date: Date
    ) -> Date? {
        guard schedule.validate(now: .distantPast) == nil, date.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZone

        switch schedule.rule {
        case .once(let fireAt):
            return fireAt > date ? fireAt : nil
        case .daily(let hour, let minute):
            return nextMatchingDate(
                calendar: calendar,
                after: date,
                weekdays: nil,
                hour: hour,
                minute: minute
            )
        case .weekly(let weekdays, let hour, let minute):
            return nextMatchingDate(
                calendar: calendar,
                after: date,
                weekdays: Set(weekdays),
                hour: hour,
                minute: minute
            )
        case .interval(let minutes, let anchor):
            guard minutes >= ScheduledTaskSchedule.minimumIntervalMinutes else { return nil }
            if anchor > date { return anchor }
            let interval = TimeInterval(minutes * 60)
            let elapsed = date.timeIntervalSince(anchor)
            let steps = floor(elapsed / interval) + 1
            return anchor.addingTimeInterval(steps * interval)
        }
    }

    /// 当天/当周的下一个本地时刻。不存在的本地时间顺延到之后第一个有效时刻；
    /// 重复的本地时间只取较早的一次（`repeatedTimePolicy: .first`）。
    private static func nextMatchingDate(
        calendar: Calendar,
        after date: Date,
        weekdays: Set<Int>?,
        hour: Int,
        minute: Int
    ) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        if let weekdays {
            var earliest: Date?
            for isoWeekday in weekdays {
                // Calendar.weekday：1 = 周日 … 7 = 周六；ISO：1 = 周一 … 7 = 周日。
                var dayComponents = components
                dayComponents.weekday = isoWeekday == 7 ? 1 : isoWeekday + 1
                let candidate = calendar.nextDate(
                    after: date,
                    matching: dayComponents,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                )
                if let candidate {
                    if let current = earliest {
                        if candidate < current { earliest = candidate }
                    } else {
                        earliest = candidate
                    }
                }
            }
            return earliest
        }

        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    public enum DueDecision: Equatable, Sendable {
        case notDue
        case run(scheduledFor: Date, trigger: ScheduledRunTrigger)
        case skipOverlap(scheduledFor: Date)
        case missed(scheduledFor: Date)
    }

    /// 到期判定：先看是否过期，再看同一任务是否已有运行，最后看宽限窗口。
    public static func dueDecision(
        task: ScheduledTask,
        now: Date,
        grace: TimeInterval = defaultMisfireGrace,
        isActive: Bool
    ) -> DueDecision {
        guard task.enabled, task.isProfileSupported, task.effectiveOptions.isValid,
              task.schedule.validate(now: .distantPast) == nil, let scheduledFor = task.nextFireAt else {
            return .notDue
        }
        guard scheduledFor <= now else { return .notDue }
        if isActive { return .skipOverlap(scheduledFor: scheduledFor) }
        if now.timeIntervalSince(scheduledFor) <= grace {
            return .run(scheduledFor: scheduledFor, trigger: .scheduled)
        }
        return .missed(scheduledFor: scheduledFor)
    }
}

// MARK: - Scheduled Prompt Context

/// 定时运行的提示词上下文：计划时刻必须显式传入，补跑时模型才知道
/// 「今天/昨天」应该按哪个时刻解释。
public struct ScheduledPromptContext: Sendable, Equatable {
    public let taskName: String
    public let scheduledFor: Date
    public let timeZoneIdentifier: String
    public let comparisonInstructions: String?

    public init(taskName: String, scheduledFor: Date, timeZoneIdentifier: String, comparisonInstructions: String? = nil) {
        self.taskName = taskName
        self.scheduledFor = scheduledFor
        self.timeZoneIdentifier = timeZoneIdentifier
        self.comparisonInstructions = comparisonInstructions
    }
}

// MARK: - Run Trigger

public enum ScheduledRunTrigger: String, Codable, Sendable, Equatable {
    case scheduled
    case manual
    case catchUp
}

// MARK: - Run

public enum ScheduledRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
    case missed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .succeeded, .failed, .skipped, .missed, .cancelled, .interrupted: return true
        }
    }
}

public struct ScheduledRun: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let taskID: UUID
    /// 任务删除后历史仍可读；不依赖外键级联。
    public let taskName: String
    public let trigger: ScheduledRunTrigger
    public let scheduledFor: Date?
    public var status: ScheduledRunStatus
    public var startedAt: Date?
    public var finishedAt: Date?
    public var outputText: String?
    public var summary: String?
    public var toolNames: [String]
    public var toolCallCount: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var errorCode: String?
    public var errorText: String?
    public var durationMs: Int?
    public var experience: ScheduledRunExperience?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        taskName: String,
        trigger: ScheduledRunTrigger,
        scheduledFor: Date?,
        status: ScheduledRunStatus = .pending,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        outputText: String? = nil,
        summary: String? = nil,
        toolNames: [String] = [],
        toolCallCount: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        errorCode: String? = nil,
        errorText: String? = nil,
        durationMs: Int? = nil,
        experience: ScheduledRunExperience? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskName = taskName
        self.trigger = trigger
        self.scheduledFor = scheduledFor
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputText = outputText
        self.summary = summary
        self.toolNames = toolNames
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.errorCode = errorCode
        self.errorText = errorText
        self.durationMs = durationMs
        self.experience = experience
    }

    public var isTerminal: Bool { status.isTerminal }
}

// MARK: - Notification Policy

public struct ScheduledNotificationPolicy: Codable, Sendable, Equatable {
    public var notifyOnSuccess: Bool
    public var notifyOnFailure: Bool
    public var notifyOnMissed: Bool

    public init(notifyOnSuccess: Bool = true, notifyOnFailure: Bool = true, notifyOnMissed: Bool = false) {
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
        self.notifyOnMissed = notifyOnMissed
    }

    public static let `default` = ScheduledNotificationPolicy()
}

// MARK: - Capability Profile

/// 无人值守运行的能力面：版本号由代码解释，数据库只存版本字符串。
/// 白名单显式构造工具面；新增写工具不会因为遗漏排除项而自动暴露。
public enum ScheduledCapabilityProfile {
    public static let readOnlyV1 = "readOnly.v1"

    public static let allowedToolNames: Set<String> = [
        "get_current_time",
        "memory_search",
        "knowledge_search",
        "files_list",
        "files_read",
        "web_search",
        "web_fetch",
        "reminders_list",
        "mail_accounts_list",
        "mail_folders_list",
        "mail_list",
        "mail_read",
        "mail_search",
    ]

    public static func toolNames(for version: String) -> Set<String>? {
        version == readOnlyV1 ? allowedToolNames : nil
    }

    public static let maxSteps = 12
    public static let maxOutputTokens = 4_096
    public static let wallClockSeconds: TimeInterval = 180
    public static let outputTextLimit = 64 * 1024
}

// MARK: - Validation

public enum ScheduledTaskValidationError: Error, Equatable, Sendable {
    case emptyName
    case emptyPrompt
    case onceInPast
    case invalidTime
    case invalidWeekdays
    case intervalTooShort
    case unsupportedProfile
    case invalidOptions
    case invalidTimeZone
    case intervalTooLong

    /// 面向用户的文案由 UI 通过本地化键映射；Core 只提供稳定错误码。
    public var code: String {
        switch self {
        case .emptyName: return "empty_name"
        case .emptyPrompt: return "empty_prompt"
        case .onceInPast: return "once_in_past"
        case .invalidTime: return "invalid_time"
        case .invalidWeekdays: return "invalid_weekdays"
        case .intervalTooShort: return "interval_too_short"
        case .unsupportedProfile: return "unsupported_profile"
        case .invalidOptions: return "invalid_options"
        case .invalidTimeZone: return "invalid_timezone"
        case .intervalTooLong: return "interval_too_long"
        }
    }
}
