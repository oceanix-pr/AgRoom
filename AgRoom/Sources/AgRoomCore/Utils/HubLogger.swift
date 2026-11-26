import Foundation
import os.log

// MARK: - Log Entry

/// 内存日志条目（控制台页面展示用）
public struct HubLogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let level: HubLogLevel
    public let message: String

    public init(level: HubLogLevel, message: String) {
        self.id = UUID()
        self.date = Date()
        self.level = level
        self.message = message
    }
}

public enum HubLogLevel: String, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
    case critical
}

// MARK: - Hub Logger

/// 统一日志系统：os.log 输出 + 内存环形缓冲（供控制台页面实时查看）
public final class HubLogger: @unchecked Sendable {
    public static let shared = HubLogger()

    /// A diagnostic fingerprint that cannot contain a path, server response,
    /// prompt, credential, or user-supplied error description.
    public static func safeErrorSummary(_ error: any Error) -> String {
        "\(String(reflecting: type(of: error))) [code \((error as NSError).code)]"
    }

    /// 新日志写入时发出的通知（日志面板监听以刷新）
    public static let newEntryNotification = Notification.Name("HubLoggerNewEntryNotification")

    private let logger: Logger
    private let entriesLock = NSLock()
    private var _entries: [HubLogEntry] = []
    private let maxEntries = 500

    private init(subsystem: String = "com.agroom.app", category: String = "AgRoom") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public var entries: [HubLogEntry] {
        entriesLock.withLock { _entries }
    }

    public func clearEntries() {
        entriesLock.withLock { _entries.removeAll() }
        NotificationCenter.default.post(name: Self.newEntryNotification, object: nil)
    }

    public func debug(_ message: String) {
        logger.debug("🔧 \(message, privacy: .public)")
        append(level: .debug, message: message)
    }

    public func info(_ message: String) {
        logger.info("ℹ️ \(message, privacy: .public)")
        append(level: .info, message: message)
    }

    public func warning(_ message: String) {
        logger.warning("⚠️ \(message, privacy: .public)")
        append(level: .warning, message: message)
    }

    public func error(_ message: String) {
        logger.error("❌ \(message, privacy: .public)")
        append(level: .error, message: message)
    }

    public func critical(_ message: String) {
        logger.critical("🚨 \(message, privacy: .public)")
        append(level: .critical, message: message)
    }

    private func append(level: HubLogLevel, message: String) {
        let entry = HubLogEntry(level: level, message: message)
        entriesLock.withLock {
            _entries.append(entry)
            if _entries.count > maxEntries {
                _entries.removeFirst(_entries.count - maxEntries)
            }
        }
        NotificationCenter.default.post(name: Self.newEntryNotification, object: nil)
    }
}
