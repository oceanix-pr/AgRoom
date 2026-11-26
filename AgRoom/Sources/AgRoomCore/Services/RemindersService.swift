import Foundation
import EventKit

// MARK: - Reminders Service

/// 提醒事项桥层服务（EventKit）：授权预检 + CRUD。
/// 「待办走系统提醒事项、不自研待办中心」——本服务是 Agent 侧的唯一入口。
/// EKEventStore 官方文档确认线程安全；授权状态分 notDetermined（首次主动弹窗）
/// 与 denied/restricted（返回引导文案，不重复骚扰）
public final class RemindersService: @unchecked Sendable {

    public enum RemindersError: LocalizedError, Equatable {
        case notAuthorized
        case denied
        case reminderNotFound(String)
        case invalidDate(String)

        public var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Reminders access was not granted."
            case .denied:
                return "Reminders access is denied. Enable it in System Settings → Privacy & Security → Reminders."
            case .reminderNotFound(let id):
                return "No reminder found with id \(id)."
            case .invalidDate(let raw):
                return "Unrecognized date format: \(raw). Use ISO 8601 (yyyy-MM-dd'T'HH:mm:ss) or yyyy-MM-dd HH:mm."
            }
        }
    }

    /// 提醒事项条目（工具输出形态）
    public struct ReminderItem: Sendable, Equatable {
        public let id: String
        public let title: String
        public let notes: String?
        public let dueDate: Date?
        public let priority: Int
        public let isCompleted: Bool
        public let listName: String?
    }

    private let store = EKEventStore()

    public init() {}

    // MARK: - Authorization

    /// 授权状态（无副作用查询；denied/restricted 视同拒绝）
    public var isAuthorized: Bool {
        Self.hasAccess(EKEventStore.authorizationStatus(for: .reminder))
    }

    /// 请求提醒事项授权（macOS 14+ full access；幂等，notDetermined 时弹 TCC 窗）
    public static func requestAuthorization() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if hasAccess(status) { return true }
        guard status == .notDetermined else { return false }
        return (try? await EKEventStore().requestFullAccessToReminders()) ?? false
    }

    static func hasAccess(_ status: EKAuthorizationStatus) -> Bool {
        // deployment target macOS 15：新枚举值 fullAccess（writeOnly 对提醒事项 CRUD 不够用）
        status == .fullAccess
    }

    /// 未授权时的用户引导文案（与 MeetMemo 既有文案风格一致）
    public static func denialGuidance() -> String {
        "Reminders access is not authorized. Ask the user to grant it in "
            + "System Settings → Privacy & Security → Reminders (add AgRoom), then retry."
    }

    public struct ReminderList: Sendable, Identifiable {
        public let id: String
        public let title: String
    }
    /// Listing is read-only and never requests authorization implicitly.
    public func availableLists() -> [ReminderList] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
    }
    public func requestAccess() async throws { try await ensureAuthorized() }

    // MARK: - CRUD

    /// 新建提醒事项；dueDate 为 nil 时不设截止时间
    @discardableResult
    public func create(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        priority: Int = 0,
        url: URL? = nil,
        alarmOffsetMinutes: Int? = nil,
        calendarID: String? = nil
    ) async throws -> String {
        try await ensureAuthorized()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.url = url
        if let calendarID, !calendarID.isEmpty {
            guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowedEntityTypes.contains(.reminder), calendar.allowsContentModifications else { throw RemindersError.reminderNotFound(calendarID) }
            reminder.calendar = calendar
        } else { reminder.calendar = store.defaultCalendarForNewReminders() }
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }
        if let dueDate, let minutes = alarmOffsetMinutes, (0...525_600).contains(minutes) {
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate.addingTimeInterval(-Double(minutes) * 60)))
        }
        if priority > 0 {
            reminder.priority = Self.clampPriority(priority)
        }
        try store.save(reminder, commit: true)
        HubLogger.shared.info("Reminder created: hasDueDate=\(dueDate != nil)")
        return reminder.calendarItemIdentifier
    }

    /// 查询提醒事项：未完成优先，关键词在内存过滤（标题/备注），limit 上限保护
    public func list(keyword: String? = nil, limit: Int = 20) async throws -> [ReminderItem] {
        try await ensureAuthorized()
        let query = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 未完成谓词（macOS 10.8+）：起止都传 nil 取全部未完成项，关键词内存过滤。
        // EKReminder 非 Sendable：在回调内立即转为值类型快照再传出（严格并发安全）
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let items: [ReminderItem] = await withCheckedContinuation { (continuation: CheckedContinuation<[ReminderItem], Never>) in
            // fetchReminders 的 completion 无 error 通道（nil 结果按空集处理）
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap { Self.item(from: $0) })
            }
        }
        return items
            .filter { item in
                query.isEmpty
                    || item.title.localizedCaseInsensitiveContains(query)
                    || (item.notes?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.title < rhs.title
                }
            }
            .prefix(max(1, min(limit, 100)))
            .map { $0 }
    }

    /// 标记完成
    public func complete(id: String) async throws {
        try await ensureAuthorized()
        let reminder = try fetchReminder(id: id)
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    /// 删除提醒事项（不可恢复）
    public func delete(id: String) async throws {
        try await ensureAuthorized()
        let reminder = try fetchReminder(id: id)
        try store.remove(reminder, commit: true)
    }

    // MARK: - Private

    /// 授权闸：notDetermined → 主动请求（首次使用时弹窗，符合预期）；
    /// denied/restricted → 抛引导文案错误（不重复弹窗骚扰）
    private func ensureAuthorized() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if Self.hasAccess(status) { return }
        if status == .notDetermined {
            guard await Self.requestAuthorization() else {
                throw RemindersError.notAuthorized
            }
            return
        }
        throw RemindersError.denied
    }

    private func fetchReminder(id: String) throws -> EKReminder {
        guard let item = store.calendarItem(withIdentifier: id),
              let reminder = item as? EKReminder else {
            throw RemindersError.reminderNotFound(id)
        }
        return reminder
    }

    private static func item(from reminder: EKReminder) -> ReminderItem? {
        let dueDate = reminder.dueDateComponents.flatMap {
            Calendar.current.date(from: $0)
        }
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            dueDate: dueDate,
            priority: reminder.priority,
            isCompleted: reminder.isCompleted,
            listName: reminder.calendar?.title
        )
    }

    /// EventKit priority 语义：0 无；1-4 高（1 最高）；5-8 中；9 低
    public static func clampPriority(_ raw: Int) -> Int {
        Swift.min(Swift.max(raw, 0), 9)
    }

    /// high/medium/low（LLM 输入）→ EventKit 优先级
    public static func priorityValue(for label: String) -> Int {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        default: return 0
        }
    }

    /// 宽容解析截止时间：ISO8601（带/不带时区）→ "yyyy-MM-dd HH:mm" → "yyyy-MM-dd"
    public static func parseDueDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 裸 ISO8601（无时区）按本地时区解释：
        // ISO8601DateFormatter 的 timeZone 默认 UTC，解析时同样生效，必须显式覆盖
        let localISO = ISO8601DateFormatter()
        localISO.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        localISO.timeZone = .current
        if let date = localISO.date(from: text) { return date }
        // 带 ISO8601 时区后缀（如 ...+08:00 / ...Z）
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
