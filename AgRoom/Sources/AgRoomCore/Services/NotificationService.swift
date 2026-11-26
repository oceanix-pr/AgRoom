import Foundation
import UserNotifications

// MARK: - Notification Service

/// 系统通知桥层服务（UserNotifications）：
/// 授权懒请求（首次发送时才弹窗，不在启动时打扰）；
/// delayMinutes > 0 时走 UNTimeIntervalNotificationTrigger——系统级定时，
/// App 退出后依然触发（恰好补上「Client 端不做定时任务」的空白，仅限提醒场景）
public final class NotificationService: @unchecked Sendable {

    /// 通知分类（设置页按类型开关）
    public enum NotificationCategory: String, Sendable, CaseIterable {
        /// Agent 主动通知（notify_user 工具：用户对话中显式要求的提醒）
        case agent
        /// 后台任务完成通知（备份导出/恢复、AI 技能生成、音频转写）
        case background
        /// 定时任务完成/失败/错过通知
        case scheduled
    }

    public enum NotificationError: LocalizedError, Equatable {
        case notAuthorized
        case denied
        case delayTooShort(Double)
        case delayTooLong(Double)

        public var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Notification authorization was not granted."
            case .denied:
                return "Notifications are denied. Enable them in System Settings → Notifications → AgRoom."
            case .delayTooShort(let minutes):
                return "Scheduled notifications need at least \(NotificationService.minimumDelayMinutes) minutes (got \(minutes))."
            case .delayTooLong(let minutes):
                return "Scheduled notifications are limited to \(NotificationService.maximumDelayDays) days (got \(minutes) minutes)."
            }
        }
    }

    /// 系统触发器下限（分钟）：低于 1 分钟的定时通知不可靠
    public static let minimumDelayMinutes: Double = 1
    /// 定时上限（天）：超过的提示用户改用提醒事项（有截止时间语义）
    public static let maximumDelayDays: Double = 14
    static var maximumDelayMinutes: Double { maximumDelayDays * 24 * 60 }

    /// 分类开关持久化键（默认全开；关闭后 send 直接返回不投递）
    static let categoryEnabledKey = "agroom.notifications.categoryEnabled"

    public init() {}

    // MARK: - Category Toggles

    /// 分类开关查询（UserDefaults 持久化；未设置视为开）
    public static func isEnabled(_ category: NotificationCategory) -> Bool {
        guard let dict = UserDefaults.standard.dictionary(forKey: categoryEnabledKey),
              let value = dict[category.rawValue] as? Bool else { return true }
        return value
    }

    public static func setEnabled(_ enabled: Bool, for category: NotificationCategory) {
        var dict = UserDefaults.standard.dictionary(forKey: categoryEnabledKey) ?? [:]
        dict[category.rawValue] = enabled
        UserDefaults.standard.set(dict, forKey: categoryEnabledKey)
    }

    // MARK: - Authorization

    /// 授权状态查询（无副作用）
    public static var isAuthorized: Bool {
        get async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    /// 请求通知授权（幂等；notDetermined 时弹 TCC 窗）
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 未授权时的用户引导文案
    public static func denialGuidance() -> String {
        "Notification authorization is denied. Ask the user to enable it in "
            + "System Settings → Notifications → AgRoom, then retry."
    }

    // MARK: - Send

    /// 发送本地通知；delayMinutes 为 nil 立即送达，否则定时触发（系统级，App 退出仍有效）。
    /// 分类开关关闭时静默跳过（返回标识含 "skipped" 前缀，调用方可据此反馈）
    @discardableResult
    public func send(
        title: String,
        body: String,
        delayMinutes: Double? = nil,
        category: NotificationCategory = .agent
    ) async throws -> String {
        guard Self.isEnabled(category) else {
            HubLogger.shared.info("Notification skipped: category=\(category.rawValue), reason=disabled")
            return "skipped-\(category.rawValue)"
        }
        var delay: TimeInterval?
        if let minutes = delayMinutes {
            delay = try Self.validatedDelay(minutes) * 60
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        case .notDetermined:
            guard await Self.requestAuthorization() else {
                throw NotificationError.notAuthorized
            }
        default:
            throw NotificationError.denied
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let identifier = "agroom-\(UUID().uuidString.prefix(8))"
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
        if let delay {
            HubLogger.shared.info("Notification scheduled: category=\(category.rawValue), delayMinutes=\(Int(delay / 60))")
        } else {
            HubLogger.shared.info("Notification sent: category=\(category.rawValue)")
        }
        return identifier
    }

    /// 定时参数校验：<1 分钟不可靠、>14 天该用提醒事项
    static func validatedDelay(_ minutes: Double) throws -> Double {
        guard minutes >= minimumDelayMinutes else {
            throw NotificationError.delayTooShort(minutes)
        }
        guard minutes <= maximumDelayMinutes else {
            throw NotificationError.delayTooLong(minutes)
        }
        return minutes
    }
}
