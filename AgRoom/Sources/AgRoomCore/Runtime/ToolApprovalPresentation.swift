import Foundation

/// 可信执行摘要：由工具或执行器按实际参数生成，供确认卡展示「读什么、写什么、为什么问」。
/// UI 只展示，不据此推算权限；授权资格仍由 `ConfirmationRequirement` 与执行侧决定。
public struct ToolApprovalPresentation: Codable, Sendable, Equatable {
    /// 执行档：决定确认卡的风险样式与能力说明。
    public enum ExecutionKind: String, Codable, Sendable {
        /// 离线 App Sandbox 单命令（只读或写工作目录）
        case sandboxCommand
        /// 强制离线的 Python 产物处理
        case offlinePython
        /// 强制离线的技能脚本
        case offlineSkill
        /// 显式宿主 Shell（任意 zsh，不受 App Sandbox 保护）
        case hostCommand
        /// 显式宿主构建/测试
        case hostBuild
        /// Project language services may evaluate manifests and build settings on the host.
        case hostLanguageService
        /// 结构化文件写入
        case fileMutation
        /// A remote endpoint; local filesystem/process capability claims do not apply.
        case remoteMCP
        case other
    }

    /// 实际资源范围。`verified` 表示范围由执行器/策略核验；
    /// 宿主执行或无法核验的路径必须为 false，UI 不得展示成强制边界。
    public struct ResourceAccess: Codable, Sendable, Equatable {
        public static let host = Self(readable: [ScopeToken.hostAccessibleFiles],
            writable: [ScopeToken.hostAccessibleFiles], systemBaseline: true, verified: false)
        public let readable: [String]
        public let writable: [String]
        public let outputs: [String]
        public let temporary: [String]
        public let executorContainer: String?
        public let systemBaseline: Bool
        public let verified: Bool

        public init(
            readable: [String] = [],
            writable: [String] = [],
            outputs: [String] = [],
            temporary: [String] = [],
            executorContainer: String? = nil,
            systemBaseline: Bool = false,
            verified: Bool
        ) {
            self.readable = readable
            self.writable = writable
            self.outputs = outputs
            self.temporary = temporary
            self.executorContainer = executorContainer
            self.systemBaseline = systemBaseline
            self.verified = verified
        }
    }

    /// 执行器真实能力（不是模型声明）。
    public struct Capability: Codable, Sendable, Equatable {
        public let allowed: Bool
        /// 稳定说明标识或路径；nil = 无补充
        public let detail: String?

        public init(allowed: Bool, detail: String? = nil) {
            self.allowed = allowed
            self.detail = detail
        }
    }

    /// 将保存的持久规则预览：匹配条件与到期时间由规则策略计算。
    public struct RulePreview: Codable, Sendable, Equatable {
        public let conditions: [String]
        public let expiresAt: Date?

        public init(conditions: [String], expiresAt: Date?) {
            self.conditions = conditions
            self.expiresAt = expiresAt
        }
    }

    /// Observed browser facts. Localization belongs to the UI actor, never the execution boundary.
    public struct BrowserAction: Codable, Sendable, Equatable {
        public struct Field: Codable, Sendable, Equatable {
            public let label: String
            public let value: String
            public init(label: String, value: String) { self.label = label; self.value = value }
        }
        public let pageTitle: String
        public let origin: String?
        public let targetLabel: String?
        public let destination: String?
        public let fields: [Field]
        public let formTruncated: Bool

        public init(pageTitle: String, origin: String?, targetLabel: String?, destination: String?,
                    fields: [Field], formTruncated: Bool) {
            self.pageTitle = pageTitle
            self.origin = origin
            self.targetLabel = targetLabel
            self.destination = destination
            self.fields = fields
            self.formTruncated = formTruncated
        }
    }

    /// 资源范围中的稳定占位符：UI 负责本地化；以 `/` 开头的值按真实路径展示。
    public enum ScopeToken {
        public static let hostAccessibleFiles = "$host-accessible-files"
        public static let systemBaseline = "$system-baseline"
        public static let runTemporary = "$run-temporary"
        public static let executorContainer = "$executor-container"
        public static let skillPackage = "$skill-package"
        public static let skillScratch = "$skill-scratch"
        public static let pythonOutput = "$python-output"
    }

    public static let currentSchemaVersion = 1

    /// Host-recorded documentation coverage, displayed before the skill package is installed.
    public struct Documentation: Codable, Sendable, Equatable {
        public let url: String
        public let scope: String
        public let version: String
        public let collectedPages: Int
        public let readPages: Int
        public let missingPages: Int
        public let partial: Bool
        public let skillAlias: String?
        public let skillDescription: String?
        public let verificationStepCount: Int?
    }

    public let schemaVersion: Int
    public let executionKind: ExecutionKind
    public let startingDirectory: String?
    public let resourceAccess: ResourceAccess
    public let network: Capability
    public let childProcesses: Capability
    /// 稳定原因码，UI 负责本地化（如 sandbox_command / offline_python / host_execution）
    public let reasonCode: String
    /// 限制来源：space / sessionWorkspace / skill / subtask / executor / mode
    public let constraintSources: [String]
    /// 可审阅事实：程序、argv、cwd、技能、超时、环境身份等，逐行展示
    public let executionDetails: [String]
    public let rulePreview: RulePreview?
    public let browserAction: BrowserAction?
    public let documentation: Documentation?

    public init(
        schemaVersion: Int = ToolApprovalPresentation.currentSchemaVersion,
        executionKind: ExecutionKind,
        startingDirectory: String? = nil,
        resourceAccess: ResourceAccess,
        network: Capability,
        childProcesses: Capability,
        reasonCode: String,
        constraintSources: [String],
        executionDetails: [String],
        rulePreview: RulePreview? = nil,
        browserAction: BrowserAction? = nil,
        documentation: Documentation? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.executionKind = executionKind
        self.startingDirectory = startingDirectory
        self.resourceAccess = resourceAccess
        self.network = network
        self.childProcesses = childProcesses
        self.reasonCode = reasonCode
        self.constraintSources = constraintSources
        self.executionDetails = executionDetails
        self.rulePreview = rulePreview
        self.browserAction = browserAction
        self.documentation = documentation
    }
}
