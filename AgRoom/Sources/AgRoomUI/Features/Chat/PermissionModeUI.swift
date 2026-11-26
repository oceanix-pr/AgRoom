import AgRoomCore

/// 权限模式的展示元数据：Core 只负责能力语义，标签/图标/说明由 UI 层按三语资源提供。
extension PermissionMode {
    var nameKey: String {
        switch self {
        case .readOnly: "chat.permission.readOnly"
        case .workspaceWrite: "chat.permission.workspaceWrite"
        case .dangerFullAccess: "chat.permission.fullAccess"
        }
    }

    var descriptionKey: String {
        switch self {
        case .readOnly: "chat.permission.readOnly.desc"
        case .workspaceWrite: "chat.permission.workspaceWrite.desc"
        case .dangerFullAccess: "chat.permission.fullAccess.desc"
        }
    }

    var iconName: String {
        switch self {
        case .readOnly: "eye"
        case .workspaceWrite: "folder.badge.gearshape"
        case .dangerFullAccess: "exclamationmark.shield"
        }
    }
}

extension PermissionPreset {
    var nameKey: String { "chat.permission.preset.\(rawValue)" }
    var descriptionKey: String { "\(nameKey).desc" }

    var iconName: String {
        switch self {
        case .readOnly: "eye"
        case .workspaceWrite: "folder"
        case .extendedAccess: "exclamationmark.shield"
        case .autoReview: "sparkles"
        case .custom: "slider.horizontal.3"
        }
    }
}
