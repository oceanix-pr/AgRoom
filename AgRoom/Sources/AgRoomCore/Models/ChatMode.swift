import Foundation

// MARK: - Chat Mode

/// Internal workflow profile, resolved automatically for each new foreground turn.
/// Persisted raw values remain compatible with older sessions and frozen handoffs.
/// A session's value is only a continuation hint; it never grants capabilities or permissions.
public enum ChatMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 日常聊天：较小输出上限、较高温度、常规步数与历史窗口
    case chat
    /// 编码：更大输出上限与步数预算、更低温度、更长历史窗口
    case coding

    public var id: String { rawValue }

    /// 本地化 key（用户可见文案统一走 `L.string`）
    public var nameKey: String {
        switch self {
        case .chat: return "chat.mode.chat"
        case .coding: return "chat.mode.coding"
        }
    }

    /// 列表/输入栏标识图标
    public var iconName: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
