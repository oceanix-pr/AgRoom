import Foundation

// MARK: - Permission Mode

/// 会话级权限模式：能力上限，不是审批策略。
///
/// - `readOnly`：只允许只读能力；任何用户可见写、代码执行、外发都拒绝。
/// - `workspaceWrite`：允许工作区文件写入和经确认的离线沙箱执行；宿主代码执行拒绝；
///   外部副作用要求人工确认。
/// - `dangerFullAccess`：取消会话工作区上限；文件工具仍受受管根/登记工作区约束，
///   代码执行与外部副作用仍走既有确认策略。
///
/// 模式只收紧能力，不扩大审批：拒绝先于一切确认/授权规则。
public enum PermissionMode: String, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    private var rank: Int {
        switch self {
        case .readOnly: 0
        case .workspaceWrite: 1
        case .dangerFullAccess: 2
        }
    }

    public static func < (lhs: PermissionMode, rhs: PermissionMode) -> Bool {
        lhs.rank < rhs.rank
    }

    /// 取更严格的模式（用于后台/子代理不放大父级权限）。
    public func restricted(to cap: PermissionMode) -> PermissionMode {
        self < cap ? self : cap
    }
}

// MARK: - Permission Class

/// 能力分类：由工具按实际参数声明。未声明的写类工具按 `.externalEffect` 处理，
/// 因此只读模式默认拒绝新工具；新增工具必须显式选择更窄的分类。
public enum PermissionClass: String, Codable, Sendable {
    /// 读取、检索、浏览、截图等无用户可见副作用的能力
    case readOnly
    /// 受 `FileAreaPolicy` 约束的文件写入/创建/删除/移动
    case workspaceMutation
    /// Shell、Python、技能脚本等自由代码执行
    case codeExecution
    /// 强制离线的产物处理；写入本次产物和独立容器，后端不可用时失败关闭。
    case confinedCodeExecution
    /// 邮件、提醒、通知、浏览器交互、空间数据写入等外部副作用
    case externalEffect
    /// 不可逆删除、恢复覆盖等破坏性操作
    case destructive
}

// MARK: - Permission Denial

/// 模式拒绝：稳定原因 + 面向模型的可操作说明。
public struct PermissionDenial: Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        /// 只读模式拒绝了写/代码执行/外部副作用
        case readOnlyMode
        /// 目标不在当前写范围
        case outsideWorkspace
        /// 目标属于另一个空间的专属目录
        case spaceIsolation
        /// 技能声明的工作区无效（无法解析/越界/无交集）
        case invalidSkillWorkspace
        /// 写范围无法核验（没有文件区策略或工作区）
        case unverifiedWorkspace
        /// 工作区内模式拒绝了自由代码执行
        case codeExecutionBlocked
        /// 只读模式拒绝了外部副作用
        case externalEffectBlocked
        /// 本次任务的执行范围不包含该能力，或目录身份已变化
        case taskScopeDenied
    }

    public let reason: Reason
    public let message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }
}

/// 权限模式拒绝事件：进入审批审计，但不改变拒绝结果。
public struct PermissionDenialEvent: Sendable, Equatable {
    public let callId: String
    public let toolName: String
    public let reason: PermissionDenial.Reason
    public let mode: PermissionMode
    public let message: String

    public init(
        callId: String,
        toolName: String,
        reason: PermissionDenial.Reason,
        mode: PermissionMode,
        message: String
    ) {
        self.callId = callId
        self.toolName = toolName
        self.reason = reason
        self.mode = mode
        self.message = message
    }
}

// MARK: - Permission Verdict

/// 模式判定结果：
/// - `.allow`：模式允许，继续走统一审批逻辑；
/// - `.requireApproval`：模式要求人工确认（用于既有工具未声明确认的外部副作用）；
/// - `.deny`：模式直接拒绝，不执行、不弹确认，任何授权都不能翻盘。
///
/// “是否免确认”不在这里决定。工作区内低风险写是否自动执行，由统一审批器
/// 根据当前任务范围与工具资格判断。
public enum PermissionVerdict: Sendable, Equatable {
    case allow
    case requireApproval
    case deny(PermissionDenial)
}

// MARK: - Permission Policy

/// 会话权限策略：只负责模式上限、文件写范围与空间隔离。
/// “是否需要确认/能否自动批准”由统一审批器结合任务范围判断；
/// 引擎在审批判定与执行两处调用同一份策略，避免“批准的是 A、执行的是 B”。
public struct PermissionPolicy: Sendable {
    public let mode: PermissionMode
    /// 文件写范围（与引擎的 FileAreaPolicy 使用同一份实例，路径解析一致）
    public let fileAreaPolicy: FileAreaPolicy?
    public init(
        mode: PermissionMode,
        fileAreaPolicy: FileAreaPolicy?
    ) {
        self.mode = mode
        self.fileAreaPolicy = fileAreaPolicy
    }

    /// 判定一次调用。只回答模式是否允许，不回答是否需要用户确认。
    public func assess(
        toolName: String,
        permissionClass: PermissionClass,
        argumentsJSON: String,
        skillWorkspace: String?,
        writeTargets: [String]? = nil,
        skillName: String? = nil,
        skillWorkspaceError: String? = nil,
        subtaskWriteRoots: [URL]? = nil
    ) -> PermissionVerdict {
        if permissionClass == .confinedCodeExecution, skillWorkspaceError != nil {
            return .deny(PermissionDenial(reason: .invalidSkillWorkspace,
                message: "The active skill has an invalid workspace. Fix its declaration before running code."))
        }
        switch mode {
        case .readOnly:
            return readOnlyVerdict(toolName: toolName, permissionClass: permissionClass)
        case .workspaceWrite:
            return workspaceWriteVerdict(
                toolName: toolName,
                permissionClass: permissionClass,
                argumentsJSON: argumentsJSON,
                skillWorkspace: skillWorkspace,
                writeTargets: writeTargets,
                skillName: skillName,
                skillWorkspaceError: skillWorkspaceError,
                subtaskWriteRoots: subtaskWriteRoots
            )
        case .dangerFullAccess:
            return fullAccessVerdict(
                toolName: toolName,
                permissionClass: permissionClass,
                argumentsJSON: argumentsJSON,
                skillWorkspace: skillWorkspace,
                writeTargets: writeTargets,
                skillName: skillName,
                skillWorkspaceError: skillWorkspaceError,
                subtaskWriteRoots: subtaskWriteRoots
            )
        }
    }

    // MARK: Verdicts

    private func readOnlyVerdict(
        toolName: String,
        permissionClass: PermissionClass
    ) -> PermissionVerdict {
        switch permissionClass {
        case .readOnly:
            return .allow
        case .workspaceMutation:
            return .deny(PermissionDenial(
                reason: .readOnlyMode,
                message: "Blocked by permission mode 'read-only': this session may only read. "
                    + "'\(toolName)' would modify files. Ask the user to switch this session to "
                    + "'workspace-write' or 'danger-full-access' if the change is intended."
            ))
        case .codeExecution, .confinedCodeExecution:
            return .deny(PermissionDenial(
                reason: .readOnlyMode,
                message: "Blocked by permission mode 'read-only': this session may only read. "
                    + "'\(toolName)' would execute code. Ask the user to switch this session to "
                    + "'workspace-write' for sandboxed execution, or 'danger-full-access' for host execution."
            ))
        case .externalEffect, .destructive:
            return .deny(PermissionDenial(
                reason: .externalEffectBlocked,
                message: "Blocked by permission mode 'read-only': this session may only read. "
                    + "'\(toolName)' would cause an external side effect. Ask the user to switch this "
                    + "session to 'workspace-write' or 'danger-full-access' if the action is intended."
            ))
        }
    }

    private func workspaceWriteVerdict(
        toolName: String,
        permissionClass: PermissionClass,
        argumentsJSON: String,
        skillWorkspace: String?,
        writeTargets: [String]?,
        skillName: String?,
        skillWorkspaceError: String?,
        subtaskWriteRoots: [URL]?
    ) -> PermissionVerdict {
        switch permissionClass {
        case .readOnly:
            return .allow
        case .workspaceMutation:
            guard let fileAreaPolicy else {
                return .deny(PermissionDenial(
                    reason: .unverifiedWorkspace,
                    message: "Blocked by permission mode 'workspace-write': the session workspace "
                        + "could not be verified, so file writes are not allowed. Ask the user to "
                        + "select a workspace and retry."
                ))
            }
            let targets = writeTargets ?? Self.legacyTargets(
                toolName: toolName, argumentsJSON: argumentsJSON
            )
            if skillWorkspaceError != nil {
                return .deny(PermissionDenial(
                    reason: .invalidSkillWorkspace,
                    message: "Blocked by permission mode 'workspace-write'. The active skill declares "
                        + "an invalid workspace folder, so writes are disabled rather than widened. "
                        + "Fix the skill's workspace-folder or unload the skill."
                ))
            }
            if let violation = fileAreaPolicy.writeViolation(
                targets: targets,
                skillName: skillName,
                skillWorkspace: skillWorkspace,
                subtaskRoots: subtaskWriteRoots
            ) {
                let reason: PermissionDenial.Reason = violation.contains("another space")
                    ? .spaceIsolation : .outsideWorkspace
                return .deny(PermissionDenial(
                    reason: reason,
                    message: "Blocked by permission mode 'workspace-write'. \(violation) "
                        + "Ask the user to switch modes or move the target into the workspace."
                ))
            }
            return .allow
        case .codeExecution:
            return .deny(PermissionDenial(
                reason: .codeExecutionBlocked,
                message: "Blocked by permission mode 'workspace-write': '\(toolName)' executes code "
                    + "that is not confined to the session workspace. Use a single literal sandbox "
                    + "command or the managed Python/file tools. Host scripts require the user to "
                    + "switch to 'danger-full-access' and explicitly approve that host operation. "
                    + "Do not use host mode to bypass a sandbox denial."
            ))
        case .confinedCodeExecution:
            guard skillWorkspaceError == nil else {
                return .deny(PermissionDenial(reason: .invalidSkillWorkspace,
                    message: "The active skill has an invalid workspace. Fix its declaration before running code."))
            }
            // 仍需工具自身的逐次确认；不享受低风险文件写的自动放行。
            return .allow
        case .externalEffect, .destructive:
            // 模式要求外部副作用走人工确认；工具自身若已要求确认/硬确认，仍以工具为准。
            return .requireApproval
        }
    }

    private func fullAccessVerdict(
        toolName: String,
        permissionClass: PermissionClass,
        argumentsJSON: String,
        skillWorkspace: String?,
        writeTargets: [String]?,
        skillName: String?,
        skillWorkspaceError: String?,
        subtaskWriteRoots: [URL]?
    ) -> PermissionVerdict {
        switch permissionClass {
        case .readOnly, .codeExecution, .confinedCodeExecution, .externalEffect, .destructive:
            return .allow
        case .workspaceMutation:
            // 完全权限只放宽“会话工作区”这一层；结构化文件工具仍不能越过当前空间的
            // 受管根/登记工作区，也不能写入另一个空间的默认工作区。
            guard let fileAreaPolicy else {
                return .deny(PermissionDenial(
                    reason: .unverifiedWorkspace,
                    message: "Blocked: the managed file area is unavailable, so file writes are not allowed."
                ))
            }
            if skillWorkspaceError != nil {
                return .deny(PermissionDenial(
                    reason: .invalidSkillWorkspace,
                    message: "Blocked: the active skill declares an invalid workspace folder, so writes "
                        + "are disabled rather than widened. Fix the skill or unload it."
                ))
            }
            let targets = writeTargets ?? Self.legacyTargets(
                toolName: toolName, argumentsJSON: argumentsJSON
            )
            if let violation = fileAreaPolicy.writeViolation(
                targets: targets,
                skillName: skillName,
                skillWorkspace: skillWorkspace,
                subtaskRoots: subtaskWriteRoots
            ) {
                let reason: PermissionDenial.Reason = violation.contains("another space")
                    ? .spaceIsolation : .outsideWorkspace
                return .deny(PermissionDenial(
                    reason: reason,
                    message: "Blocked: \(violation) This target is outside the space's managed roots "
                        + "or registered workspaces."
                ))
            }
            return .allow
        }
    }

    private static func legacyTargets(toolName: String, argumentsJSON: String) -> [String] {
        guard let keys = FileAreaPolicy.legacyWriteTargets[toolName] else { return [] }
        let args = ToolArguments.parse(argumentsJSON)
        return keys.compactMap { args[$0] as? String }.filter { !$0.isEmpty }
    }

    // MARK: Model-facing policy section

    /// 注入系统提示词的权限段（模型侧协议文本，不做 UI 本地化）。
    /// 与 UI 的三档标签解耦：这里有路径与拒绝语义，UI 只负责展示与切换。
    public func systemPromptSection(workspacePath: String?) -> String {
        let folders = fileAreaPolicy?.service.scopedRoots
        let workspace = folders?.map(\.path).joined(separator: ", ") ?? workspacePath.flatMap { $0.isEmpty ? nil : $0 }
            ?? "the current session's workspace"
        let boundary = folders == nil ? "" : """
        [Workspace Folder Boundary]
        File access is limited to the current workspace's main folder and explicit references: \(workspace).
        Other registered folders are unavailable in every permission mode. Ask the user to add a folder
        reference and start a new turn when needed. Do not switch tools or modes to bypass this boundary.


        """
        switch mode {
        case .readOnly:
            return boundary + """
            [Permission Mode: read-only]
            This session is read-only. You may read files, search, browse, and use read-only tools. \
            You cannot modify files, run arbitrary shell or Python code, send mail, change reminders, \
            submit browser forms, or perform any other user-visible side effect. \
            Blocked calls return a permission error. Do not retry them or try to bypass them. \
            Explain what you would do and ask the user to switch this session to "workspace-write" \
            or "danger-full-access" if the change is intended.
            """
        case .workspaceWrite:
            return boundary + """
            [Permission Mode: workspace-write]
            You may read and modify files inside this session's workspace: \(workspace). \
            Writes outside it are blocked. Single literal shell commands run in an offline App Sandbox: \
            statically read-only commands have read-only inputs; other commands require confirmation \
            and a working directory inside all session, skill and subtask write scopes. Host shell is blocked. \
            The workspace grant covers managed file changes without asking the user again; \
            every edit still revalidates the expected SHA-256, unique match and recovery point. Python and skill \
            scripts run offline; they may be model-reviewed, with read-only inputs and per-run outputs \
            (skill scratch outputs are published back). Each executor may also write its space-specific \
            sandbox container. Network access and child processes are blocked. \
            Do not attempt to bypass these restrictions through another tool. \
            External side effects (mail, reminders, notifications, browser actions, space data) still \
            follow their normal confirmation rules. Blocked calls return a permission error; do not retry \
            them. Explain the restriction and ask the user to switch modes if needed.
            """
        case .dangerFullAccess:
            let fileAccess = folders == nil
                ? "File tools may modify files in the current space's managed file areas and registered workspaces."
                : "File tools may access only this workspace's explicitly referenced folders: \(workspace)."
            let hostAccess = folders == nil
                ? "Explicit execution_mode=host requires a fresh hard confirmation on every call, without remembered or turn approvals."
                : "Arbitrary host shell scripts cannot enforce the folder boundary and are blocked. Use sandbox commands or explicitly approved project_build checks."
            return boundary + """
            [Permission Mode: danger-full-access]
            \(fileAccess) \
            Shell commands default to an offline App Sandbox. \(hostAccess) Never switch \
            to host execution to bypass a sandbox denial. Python and skill scripts remain offline. \
            Destructive and external operations may still require confirmation. Never bypass a confirmation \
            and never attempt to move files into another space.
            """
        }
    }
}
