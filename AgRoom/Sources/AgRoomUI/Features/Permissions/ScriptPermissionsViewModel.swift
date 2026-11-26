import Foundation
import AgRoomCore

/// 脚本与权限页面状态：只绑定当前空间的规则库与审批记录，
/// 不跨空间预读，也不把展示状态当成执行授权。
@MainActor
final class ScriptPermissionsViewModel: ObservableObject {
    enum RulesState {
        case loading
        case missing
        case loaded([ShellApprovalRule])
        case corrupt
        case unavailable
    }

    @Published private(set) var rulesState: RulesState = .loading
    @Published private(set) var auditEntries: [AutoReviewAuditEntry] = []
    @Published private(set) var auditUnavailable = false
    @Published private(set) var recoverable: [TaskFileRecoveryRecord] = []
    @Published private(set) var recoveryUnavailable = false
    @Published var errorMessage: String?

    let space: AppSpace
    private let store: ShellApprovalRuleStore
    private let auditLog: AutoReviewAuditLog?
    private var recoveryStore: TaskFileRecoveryStore?
    private let recoveryStoreProvider: @MainActor () -> TaskFileRecoveryStore?
    private let fileAreaService: FileAreaService
    private var loadGeneration = 0

    convenience init(hub: Hub, space: AppSpace) {
        self.init(
            space: space,
            store: ShellApprovalRuleStore.standard(space: space),
            auditLog: hub.makeSkillStore(for: space).map {
                AutoReviewAuditLog(skillsDirectoryURL: $0.skillsDirectoryURL)
            },
            recoveryStore: hub.makeTaskFileRecoveryStore(for: space),
            recoveryStoreProvider: { hub.makeTaskFileRecoveryStore(for: space) },
            fileAreaService: FileAreaService.standard.merging(
                additionalRoots: WorkspaceRegistry.shared.workspaces(for: space).flatMap(\.folderURLs)
            )
        )
    }

    /// 显式依赖便于验证损坏规则文件的页面状态；所有依赖仍绑定同一空间。
    init(
        space: AppSpace,
        store: ShellApprovalRuleStore,
        auditLog: AutoReviewAuditLog?,
        recoveryStore: TaskFileRecoveryStore?,
        recoveryStoreProvider: @escaping @MainActor () -> TaskFileRecoveryStore? = { nil },
        fileAreaService: FileAreaService
    ) {
        self.space = space
        self.store = store
        self.auditLog = auditLog
        self.recoveryStore = recoveryStore
        self.recoveryStoreProvider = recoveryStoreProvider
        self.fileAreaService = fileAreaService
    }

    /// 读取当前空间规则与审批记录；迟到结果按代次丢弃。
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        rulesState = .loading
        if recoveryStore == nil {
            // A transiently unavailable space database may become available while
            // this sheet stays open. Retry must reacquire the same space's store.
            recoveryStore = recoveryStoreProvider()
        }
        let store = self.store
        let auditLog = self.auditLog
        let recoveryStore = self.recoveryStore
        let result: (ShellApprovalRuleStore.LoadResult, AutoReviewAuditLog.LoadResult,
                     [TaskFileRecoveryRecord]?, Bool) = await Task.detached(
            priority: .userInitiated
        ) {
            let audit = auditLog?.loadResult() ?? .unavailable
            let recoveries: [TaskFileRecoveryRecord]?
            if let recoveryStore {
                do {
                    recoveries = try await recoveryStore.recoverable()
                } catch {
                    HubLogger.shared.warning("Script permissions recovery load failed: \(HubLogger.safeErrorSummary(error))")
                    recoveries = nil
                }
            } else {
                recoveries = nil
            }
            return (store.loadResult(), audit, recoveries, recoveryStore == nil)
        }.value
        guard generation == loadGeneration else { return }
        recoverable = result.2 ?? []
        recoveryUnavailable = result.3 || result.2 == nil
        switch result.0 {
        case .loaded(let rules):
            rulesState = .loaded(rules)
        case .missing:
            rulesState = .missing
        case .corrupt:
            HubLogger.shared.warning("Script permissions rule load failed: corrupt")
            rulesState = .corrupt
        case .unavailable:
            HubLogger.shared.warning("Script permissions rule load failed: unavailable")
            rulesState = .unavailable
        }
        switch result.1 {
        case .loaded(let entries):
            auditEntries = Array(entries.sorted { $0.time > $1.time }.prefix(50))
            auditUnavailable = false
        case .missing:
            auditEntries = []
            auditUnavailable = false
        case .corrupt, .unavailable:
            auditEntries = []
            auditUnavailable = true
        }
    }

    /// 恢复一次仍等于 AI 写入版本的编辑；用户后续改过的文件会被拒绝。
    func restore(_ record: TaskFileRecoveryRecord) async {
        guard let recoveryStore else {
            errorMessage = L.string("permissions.recovery.unavailable")
            return
        }
        let service = TaskFileRecoveryService(
            store: recoveryStore,
            service: fileAreaService
        )
        do {
            _ = try await service.restore(record)
            await load()
        } catch {
            HubLogger.shared.warning("Script permissions restore failed: \(HubLogger.safeErrorSummary(error))")
            errorMessage = Self.restoreFailureMessage(error)
        }
    }

    /// 撤销一条规则；失败时保留列表并显示原因，不伪装成已撤销。
    func revoke(_ rule: ShellApprovalRule) async {
        let store = self.store
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.removeChecked(id: rule.id)
            }.value
            await load()
        } catch {
            HubLogger.shared.warning("Script permissions revoke failed: \(HubLogger.safeErrorSummary(error))")
            errorMessage = Self.ruleMutationFailureMessage(error, actionKey: "permissions.error.revokeFailed")
        }
    }

    /// 清空当前空间规则；损坏文件不会被覆盖。
    func clearAll() async {
        let store = self.store
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.removeAllChecked()
            }.value
            await load()
        } catch {
            HubLogger.shared.warning("Script permissions clear failed: \(HubLogger.safeErrorSummary(error))")
            errorMessage = Self.ruleMutationFailureMessage(error, actionKey: "permissions.error.clearFailed")
        }
    }

    /// Only localized, fixed guidance crosses the UI boundary. StoreError details
    /// can contain the private approval-rule path and must never enter an alert.
    static func ruleMutationFailureMessage(_ error: Error, actionKey: String) -> String {
        let reasonKey: String
        if let storeError = error as? ShellApprovalRuleStore.StoreError {
            switch storeError {
            case .corrupt: reasonKey = "permissions.error.ruleCorrupt"
            case .unavailable: reasonKey = "permissions.error.ruleUnavailable"
            case .writeFailed: reasonKey = "permissions.error.ruleWriteFailed"
            }
        } else {
            reasonKey = "permissions.error.ruleWriteFailed"
        }
        return L.format(actionKey, L.string(reasonKey))
    }

    static func restoreFailureMessage(_ error: Error) -> String {
        let reasonKey: String
        if let recoveryError = error as? TaskFileRecoveryError {
            switch recoveryError {
            case .changedSinceWrite: reasonKey = "permissions.recovery.reason.changed"
            case .missingFile: reasonKey = "permissions.recovery.reason.missing"
            case .noPreviousVersion: reasonKey = "permissions.recovery.reason.newFile"
            case .oversizedFile: reasonKey = "permissions.recovery.reason.oversized"
            case .wrongSpace, .notRestorable, .outsideRoot, .symlink:
                reasonKey = "permissions.recovery.reason.unsafe"
            }
        } else {
            reasonKey = "permissions.recovery.reason.unavailable"
        }
        return L.format("permissions.recovery.failed", L.string(reasonKey))
    }
}
