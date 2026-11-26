import SwiftUI
import Observation
import AgRoomCore

// MARK: - App Language

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public var nativeDisplayName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }

    /// 调度 Agent 回复语言指令名（英文，供系统提示词注入）；
    /// .system 时按系统首选语言解析（与 UI 语言设置独立），保证默认与系统语言一致
    public var agentReplyLanguageName: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
                return "Traditional Chinese"
            }
            if preferred.hasPrefix("zh") {
                return "Simplified Chinese"
            }
            return "English"
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        }
    }
}

// MARK: - Language Manager

/// 语言管理器：手动切换即时生效（@Observable + version 强刷）
@MainActor
@Observable
public final class LanguageManager {
    public static let shared = LanguageManager()

    private static let storageKey = "agroom.language"

    /// 语言变化时递增，供 UI 用 .id 强刷
    public private(set) var version = 0

    public var currentLanguage: AppLanguage {
        didSet {
            guard currentLanguage != oldValue else { return }
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: Self.storageKey)
            version += 1
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        self.currentLanguage = AppLanguage(rawValue: saved) ?? .system
    }

    /// 实际生效的语言代码（system 时跟随系统首选语言）
    public var activeLanguageCode: String {
        switch currentLanguage {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
                return "zh-Hant"
            }
            if preferred.hasPrefix("zh") {
                return "zh-Hans"
            }
            return "en"
        default:
            return currentLanguage.rawValue
        }
    }

    /// 实际生效语言的英文名：供模型提示使用（会话标题等生成内容应随应用语言设置）
    public var activeLanguageName: String {
        switch activeLanguageCode {
        case "zh-Hans": return "Simplified Chinese"
        case "zh-Hant": return "Traditional Chinese"
        default: return "English"
        }
    }
}

// MARK: - L

/// 本地化辅助：统一管理三语字符串
public enum L {
    /// 团队旧快照以英文字符串保存错误；展示时也应用当前语言。
    @MainActor
    public static func teamMessage(_ message: String) -> String {
        let prefix = "Verification failed: "
        let isVerdict = message.hasPrefix(prefix)
        var result = isVerdict ? String(message.dropFirst(prefix.count)) : message
        if result == DispatcherTeamVerifier.fileVersionIssue { result = string("team.verification.fileVersion") }
        if result == DispatcherTeamVerifier.hostFailureSummary { result = string("team.verification.hostCheck") }
        let keys: [(BudgetError, String)] = [
            (.tokensExhausted, "team.budget.reservation_failed"),
            (.toolCallsExhausted, "product.budget.exhausted.tools"),
            (.deadlineExceeded, "product.budget.exhausted.time")
        ]
        for (error, key) in keys {
            if let description = error.errorDescription {
                result = result.replacingOccurrences(of: description, with: string(key))
            }
        }
        return isVerdict ? format("team.verification.failure_reason", result) : result
    }

    /// Error text for a user action. Never forwards an unknown service or file
    /// error description, which may contain a path, server response, or secret.
    @MainActor
    public static func actionableError(_ error: Error, fallbackKey: String) -> String {
        if error is FileAreaService.AreaError || error is TeamWriteRevertError
            || error is TeamWriteBatchRevertError || error is TeamError
            || error is KnowledgeOrganizationError || error is KnowledgeImportError
            || error is WorkspaceProjectError || error is AgentModelError || error is ImageGenerationError {
            return errorDescription(error)
        }
        if let voice = error as? NoteVoiceprintError {
            switch voice {
            case .identityConflict: return string("notes.voiceprint.identityConflict")
            case .consentRequired: return string("notes.voiceprint.consentRequired")
            }
        }
        if error is NotePrivacyScanError { return string("notes.privacy.localRequired") }
        if let note = error as? NoteStoreError {
            switch note {
            case .conflict: return string("notes.conflict")
            case .invalidContent: return string("notes.error.content")
            case .tooLarge: return string("notes.error.size")
            case .missing: return string("notes.error.missing")
            }
        }
        if let ocr = error as? OCRService.OCRError {
            switch ocr {
            case .cannotLoadImage: return string("error.actionable.ocr_image")
            case .noTextFound: return string("error.actionable.ocr_no_text")
            case .screenCaptureNotPermitted: return string("error.actionable.ocr_permission")
            }
        }
        if let speech = error as? TranscriptionService.TranscriptionError {
            switch speech {
            case .microphoneNotAuthorized: return string("error.actionable.microphone_permission")
            case .notAuthorized: return string("error.actionable.speech_permission")
            case .recognizerUnavailable: return string("error.actionable.speech_unavailable")
            case .noResult: return string("error.actionable.speech_no_result")
            }
        }
        if let llm = error as? LLMError {
            switch llm {
            case .providerUnavailable: return string("error.actionable.provider_missing")
            case .invalidAPIKey: return string("error.actionable.provider_key")
            case .rateLimited: return string("error.actionable.provider_rate")
            case .balanceUnsupported: return string("error.actionable.balance_unsupported")
            case .configurationError: return string("error.actionable.provider_config")
            case .networkError(let statusCode, let message):
                if statusCode == 503, CloudProvider.isModelCapacityMessage(message) { return string("error.model_capacity") }
                if (statusCode == 400 || statusCode == 422),
                   CloudProvider.isUnsupportedParameterMessage(message) || CloudProvider.isOutputLimitMessage(message) {
                    return errorDescription(error)
                }
                switch statusCode {
                case 401, 403: return string("error.actionable.provider_key")
                case 402: return string("error.actionable.provider_balance")
                case 429: return string("error.actionable.provider_rate")
                case 500...599: return string("error.actionable.provider_server")
                default: return string("error.actionable.provider_connection")
                }
            case .responseTooLarge, .contextBudgetExceeded, .invalidToolSchema, .unsupportedParameter:
                return errorDescription(error)
            case .imageUnsupported: return string("error.actionable.image_unsupported")
            case .streamStalled, .streamIncomplete: return string("error.actionable.network")
            case .responseParsingFailed, .unparsedToolCall, .reasoningOnlyResponse, .toolCallFinishMismatch:
                return string("error.actionable.provider_response")
            }
        }

        if let maintenance = error as? MaintenanceError {
            switch maintenance {
            case .busy: return string("error.actionable.database_busy")
            case .unavailable: return string("error.database")
            }
        }
        let diagnostic = error as NSError
        if diagnostic.domain == "GRDB.DatabaseError" {
            switch diagnostic.code & 0xFF {
            case 5, 6: return string("error.actionable.database_busy")
            case 13: return string("error.actionable.storage_full")
            default: break
            }
        }
        if diagnostic.domain == NSCocoaErrorDomain {
            switch diagnostic.code {
            case NSFileWriteOutOfSpaceError: return string("error.actionable.storage_full")
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return string("error.actionable.permission")
            case NSFileNoSuchFileError:
                return string("error.actionable.missing")
            case NSFileWriteFileExistsError:
                return string("error.actionable.exists")
            default: break
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost:
                return string("error.actionable.network")
            default: break
            }
        }
        return string(fallbackKey)
    }

    @MainActor
    public static func errorDescription(_ error: Error) -> String {
        if let policyError = error as? TaskDataPolicyError {
            return string(policyError == .localModelRequired ? "permissions.data.localModelRequired" : "permissions.data.outsideOrigin")
        }
        if let goal = error as? GoalError {
            switch goal {
            case .invalid: return string("goal.error.invalid")
            case .changed: return string("goal.error.changed")
            case .busy: return string("goal.error.busy")
            case .unavailable: return string("error.database")
            case .scopeChanged: return string("goal.error.scope")
            }
        }
        if let document = error as? WebDocumentError { return string("documentation.error." + document.rawValue) }
        if let image = error as? ImageGenerationError {
            switch image {
            case .textModelRequired: return string("error.image.text_model_required")
            case .unsupportedEndpoint: return string("error.image.endpoint")
            case .invalidImage: return string("error.image.invalid")
            case .saveFailed: return string("error.image.save")
            case .cannotResume: return string("error.image.resume")
            case .modelUnavailable: return string("error.image.model_unavailable")
            }
        }
        if let llm = error as? LLMError, case .networkError(let status, let message) = llm,
           status == 503, CloudProvider.isModelCapacityMessage(message) { return string("error.model_capacity") }
        if let file = error as? FileAreaService.AreaError {
            switch file {
            case .unsafePath: return string("error.actionable.file_scope")
            case .notFound: return string("error.actionable.missing")
            case .invalidName: return string("error.actionable.invalid_name")
            case .alreadyExists: return string("error.actionable.exists")
            case .operationFailed: return string("error.actionable.files")
            }
        }
        if let batch = error as? TeamWriteBatchRevertError,
           case .partial(let result) = batch {
            return format("team.writes.error.partial", result.failedCount)
        }
        if let revert = error as? TeamWriteRevertError {
            switch revert {
            case .alreadyReverted: return string("team.writes.error.already_reverted")
            case .outsideWorkspace: return string("team.writes.error.outside_workspace")
            case .missingFile: return string("team.writes.error.missing_file")
            case .changedSinceWrite: return string("team.writes.error.changed")
            case .directory, .symlinkNotAllowed, .notRegularFile, .binaryFile, .tooLarge:
                return string("team.writes.error.unsupported_file")
            }
        }
        if let team = error as? TeamError {
            switch team {
            case .noEnabledAgent: return string("team.error.no_agent")
            case .retryUnavailable: return string("team.error.retry_unavailable")
            case .workerUnavailable: return string("team.error.worker_unavailable")
            case .budgetExceeded: return string("team.error.budget")
            case .invalidArguments, .invalidPlan: return string("team.error.plan")
            }
        }
        if let organization = error as? KnowledgeOrganizationError {
            return string("knowledge.error." + organization.rawValue)
        }
        if let error = error as? WorkspaceProjectError {
            let key: String
            switch error {
            case .invalid: key = "invalid"
            case .changed: key = "changed"
            case .wrongWorkspace: key = "workspace"
            case .unavailable: key = "unavailable"
            case .outsideKnowledgeScope: key = "knowledge_scope"
            }
            return string("project.error." + key)
        }
        if let error = error as? SpaceSearchError { return string("search.space.error." + error.rawValue) }
        if let error = error as? ScheduledExperienceError { return string("scheduled.experience.error." + error.rawValue) }
        if let error = error as? ScheduledTaskValidationError { return string("scheduled.error." + error.code) }
        if let error = error as? KnowledgeImportError { return string("knowledge.import.error." + error.rawValue) }
        if error is MaintenanceError { return string("error.maintenance_busy") }
        if error is ProductTaskHistoryError { return string("product.tasks.persistence_failed") }
        if let artifact = error as? TaskArtifactError {
            switch artifact {
            case .unavailable: return string("product.artifact.error.unavailable")
            case .unsafeFile: return string("product.artifact.error.unsafe")
            case .changedFile: return string("product.artifact.error.integrity")
            case .storage: return string("product.artifact.error.storage")
            case .previewInUse: return string("product.artifact.error.preview_in_use")
            case .cacheCleanupPending: return string("product.artifact.error.cleanup_pending")
            }
        }
        if let backup = error as? BackupError {
            switch backup {
            case .manifestMissing: return string("product.backup.error.manifest")
            case .unsupportedFormat(let version): return format("product.backup.error.version", version)
            case .dittoFailed: return string("product.backup.error.archive")
            case .corruptSection(let section, _): return format("product.backup.error.section", section)
            case .spaceMismatch: return string("product.backup.error.space")
            case .preflightFailed: return string("product.backup.error.preflight")
            case .rolledBack: return string("product.backup.error.rolled_back")
            case .restoreIncomplete(_, let path): return format("product.backup.error.incomplete", path)
            }
        }
        if let budget = error as? BudgetError {
            switch budget {
            case .deadlineExceeded: return string("product.budget.exhausted.time")
            case .tokensExhausted: return string("product.budget.exhausted.tokens")
            case .toolCallsExhausted: return string("product.budget.exhausted.tools")
            case .invalidReservation: return string("product.budget.invalid")
            }
        }
        if let session = error as? SessionServiceError, case .staleAfterRestore = session { return string("chat.restored.reload_required") }
        if let parameters = error as? ModelParameterService.ParameterError {
            switch parameters {
            case .invalidPreferences: return string("model.parameters.invalid")
            case .providerChanged: return string("model.parameters.provider_changed")
            case .invalidMetadata: return string("model.parameters.refresh_failed")
            }
        }
        if let llm = error as? LLMError, case .responseTooLarge = llm { return string("error.response_too_large") }
        if let llm = error as? LLMError, case .contextBudgetExceeded = llm { return string("error.context_budget_exceeded") }
        if let llm = error as? LLMError, case .invalidToolSchema(let toolName, let field) = llm {
            return String(format: string("error.invalid_tool_schema"), toolName, field)
        }
        if let llm = error as? LLMError, case .unsupportedParameter(let parameter) = llm {
            return String(format: string("error.unsupported_model_parameter"), parameter)
        }
        if let llm = error as? LLMError, case .networkError(let status, let message) = llm, status == 400 || status == 422 {
            if CloudProvider.isUnsupportedParameterMessage(message) {
                return String(format: string("error.unsupported_model_parameter"), CloudProvider.rejectedParameter(in: message) ?? "request")
            }
            if CloudProvider.isOutputLimitMessage(message) { return string("error.model_output_limit") }
        }
        if error is AgentModelError { return string("agents.model.unavailable.help") }
        if let mysql = error as? MySQLConnectorError { return string(mysql.localizationKey) }
        if let database = error as? DatabaseWorkbench.WorkbenchError {
            switch database {
            case .databaseNotFound: return string("db.error.not_found")
            case .invalidName: return string("db.error.invalid_name")
            case .alreadyExists: return string("db.error.exists")
            case .readOnlyViolation: return string("db.error.readonly")
            case .queryTimedOut: return string("db.error.timeout")
            case .unsupportedStatement: return string("db.error.unsupported")
            case .invalidDeletion: return string("db.error.invalid_deletion")
            }
        }
        if let script = error as? NativeAppScriptError {
            return string(script.localizationKey) + (script.details.isEmpty ? "" : "\n\n" + script.details)
        }
        if let app = error as? NativeAppError {
            return string(app.localizationKey) + (app.path.isEmpty ? "" : " (\(app.path))")
        }
        if let board = error as? NativeAppBoardError { return string(board.localizationKey) }
        if let mcp = error as? MCPError { return string(mcp.localizationKey) }
        if let isolation = error as? ScriptIsolationError { return string(isolation.localizationKey) }
        if let executor = error as? PythonExecutor.ExecutorError, case .noRuntime = executor {
            return format("python.runtime.required", PythonRuntimeManager.shared.environmentRoot.path)
        }
        if let environment = error as? PythonEnvironmentError {
            switch environment {
            case .noRuntime:
                return format("python.runtime.required", PythonRuntimeManager.shared.environmentRoot.path)
            case .notPrepared:
                return string("python.environment.not_prepared")
            case .venvCreationFailed(let reason):
                return format("python.environment.prepare_failed", reason)
            }
        }
        return error.localizedDescription
    }
    /// 资源 Bundle 定位（Xcode framework / SPM bundle 双兼容）
    private static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
        // SwiftPM's test helper lives outside .build; its main bundle is not the app.
        // The generated accessor also knows the package build resource location.
        return .module
        #else
        let frameworkBundle = Bundle(for: BundleFinder.self)
        if frameworkBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil {
            return frameworkBundle
        }
        let spmBundleName = "AgRoom_AgRoomUI"
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            frameworkBundle.resourceURL,
            Bundle.main.resourceURL,
            Bundle.main.bundleURL
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(spmBundleName + ".bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return frameworkBundle
        #endif
    }()

    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var stringsCache: [String: [String: String]] = [:]

    /// 获取本地化字符串，自动跟随 LanguageManager 当前语言
    @MainActor
    public static func string(_ key: String) -> String {
        let langCode = LanguageManager.shared.activeLanguageCode

        let cached: [String: String]? = cacheLock.withLock { stringsCache[langCode] }
        if let dict = cached {
            return dict[key] ?? englishString(key)
        }
        if let dict = loadStringsDict(for: langCode) {
            cacheLock.withLock { stringsCache[langCode] = dict }
            return dict[key] ?? englishString(key)
        }
        if langCode != "en", let dict = loadStringsDict(for: "en") {
            cacheLock.withLock { stringsCache[langCode] = dict }
            return dict[key] ?? key
        }
        return key
    }

    private static func englishString(_ key: String) -> String {
        if let cached = cacheLock.withLock({ stringsCache["en"] }) { return cached[key] ?? key }
        guard let english = loadStringsDict(for: "en") else { return key }
        cacheLock.withLock { stringsCache["en"] = english }
        return english[key] ?? key
    }

    /// 带格式化参数的本地化字符串
    @MainActor
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    /// 调度 Agent 显示名：用户设置的昵称优先，否则回退本地化默认名。
    /// 所有展示调度 Agent 名称的地方统一走此入口（改昵称后全局生效）。
    /// 模型自报的名字另由系统提示词携带（DispatcherSettings.dispatcherPromptName），
    /// 两者共用同一个昵称键；本入口只负责界面展示
    @MainActor
    public static func dispatcherName() -> String {
        let nickname = DispatcherSettings.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname.isEmpty ? string("dispatcher.default.name") : nickname
    }

    private static func loadStringsDict(for language: String) -> [String: String]? {
        if let url = resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(language).lproj") {
            if let dict = NSDictionary(contentsOf: url) as? [String: String] {
                return dict
            }
        }
        return nil
    }

    private final class BundleFinder {}
}

// MARK: - App Date Format

/// 全局日期格式设置：设置页维护，默认跟随系统格式。
/// 三种展示粒度：完整日期时间 / 仅日期 / 仅时间；
/// system 用系统本地化格式，预设/自定义用 DateFormatter 模式
public enum AppDateFormat: String, CaseIterable, Sendable {
    /// 系统格式（本地化，默认）
    case system
    /// 2026-08-28 21:30
    case iso
    /// 2026/08/28 21:30
    case slash
    /// 08/28/2026, 9:30 PM
    case us
    /// 28.08.2026 21:30
    case eu
    /// 自定义（Unicode 日期格式模式，如 "yyyy年M月d日 HH:mm"）
    case custom

    static let storageKey = "agroom.dateFormat"
    static let customPatternKey = "agroom.dateFormat.custom"

    /// 各预设对应的完整格式模式（dateOnly/timeOnly 从中派生）
    var fullPattern: String? {
        switch self {
        case .system: return nil
        case .iso: return "yyyy-MM-dd HH:mm"
        case .slash: return "yyyy/MM/dd HH:mm"
        case .us: return "MM/dd/yyyy h:mm a"
        case .eu: return "dd.MM.yyyy HH:mm"
        case .custom: return nil
        }
    }

    /// 当前生效的格式（存储值非法时回退 system）
    public static var current: AppDateFormat {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = AppDateFormat(rawValue: raw) else { return .system }
        return value
    }

    /// 自定义模式文本
    public static var customPattern: String {
        UserDefaults.standard.string(forKey: customPatternKey) ?? "yyyy-MM-dd HH:mm"
    }
}

/// 全局日期格式化：所有日期展示统一走此入口
public enum AppDate {
    /// DateFormatter 缓存（键 = 完整模式串）
    private static nonisolated(unsafe) var formatters: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    private static func formatter(pattern: String) -> DateFormatter {
        lock.withLock {
            if let cached = formatters[pattern] { return cached }
            let df = DateFormatter()
            df.locale = Locale.current
            df.dateFormat = pattern
            formatters[pattern] = df
            return df
        }
    }

    /// 完整日期时间
    public static func string(from date: Date) -> String {
        let format = AppDateFormat.current
        if format == .system {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        let pattern = format == .custom
            ? AppDateFormat.customPattern
            : (format.fullPattern ?? "yyyy-MM-dd HH:mm")
        return formatter(pattern: pattern).string(from: date)
    }

    /// 仅日期（控制台/知识库等窄场景）
    public static func dateString(from date: Date) -> String {
        let format = AppDateFormat.current
        switch format {
        case .system:
            return date.formatted(date: .abbreviated, time: .omitted)
        case .custom:
            // 自定义模式无法可靠拆出日期部分，统一回退 ISO 日期
            return formatter(pattern: "yyyy-MM-dd").string(from: date)
        default:
            let full = format.fullPattern ?? "yyyy-MM-dd HH:mm"
            // 预设模式：以空格分隔，日期部分在前
            if let datePart = full.split(separator: " ").first {
                return formatter(pattern: String(datePart)).string(from: date)
            }
            return formatter(pattern: "yyyy-MM-dd").string(from: date)
        }
    }

    /// 仅时间（控制台日志等）
    public static func timeString(from date: Date, includingSeconds: Bool = false) -> String {
        if includingSeconds { return date.formatted(date: .omitted, time: .standard) }
        let format = AppDateFormat.current
        switch format {
        case .system:
            return date.formatted(date: .omitted, time: .standard)
        case .custom:
            return formatter(pattern: "HH:mm:ss").string(from: date)
        default:
            let full = format.fullPattern ?? "yyyy-MM-dd HH:mm"
            let parts = full.split(separator: " ")
            if parts.count >= 2 {
                return formatter(pattern: parts.dropFirst().joined(separator: " ")).string(from: date)
            }
            return formatter(pattern: "HH:mm").string(from: date)
        }
    }
}
