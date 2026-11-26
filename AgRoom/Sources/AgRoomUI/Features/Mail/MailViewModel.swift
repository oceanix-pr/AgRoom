import Foundation
import Observation
import AgRoomCore

// MARK: - Mail View Model

/// 邮箱页视图模型（per-space，由 RootView 按空间持有，切页签/切空间不丢状态）。
///
/// 只做「编排 + 状态」：本地读写委托 `MailService`，网络委托 `MailSyncService`
/// （两者均从 `Hub` 现取现建，遵守空间隔离且不缓存空间内服务）。
@MainActor
@Observable
final class MailViewModel {
    private let hub: Hub
    /// 本模型所属空间：在 init 时固定，之后**不再**读 `hub.spaceStore.current`。
    ///
    /// 空间切换后仍会有旧空间的异步任务在途（正文拉取、同步）。若这些任务跨 `await`
    /// 再用「当前空间」重建服务，迟到回调就会读写另一个空间的数据。把 space 固定在
    /// 模型上，服务的创建来源与 UI 状态归属就始终一致。
    private let space: AppSpace
    var makeSyncService: @MainActor () -> MailSyncService?

    private(set) var accounts: [MailAccount] = []
    private(set) var folders: [MailFolder] = [] { didSet { updateFolderVisibility() } }
    private(set) var messages: [MailMessage] = []
    private(set) var attachments: [MailAttachment] = []
    let attachmentQueue: MailAttachmentQueue
    let autoSync: MailAutoSyncController
    var downloadingAttachments: Set<UUID> { attachmentQueue.pendingIDs }
    private(set) var editableDrafts: [MailDraft] = []
    private(set) var lockedDrafts: [MailDraft] = []
    private var pendingErrors: [String] = []
    private(set) var body: MailBody?
    private(set) var inlineImages: MailInlineImageSource?
    private(set) var isConversationVisible = false
    private(set) var focusedConversationMessageID: UUID?
    private(set) var conversationMessages: [MailMessage] = []
    private(set) var conversationHasMore = false
    private(set) var isLoadingConversation = false
    private(set) var conversationError: String?
    private var conversationCursor: MailConversationCursor?
    private var conversationPageLimit = 50
    private var conversationGeneration = UUID()
    private var conversationTask: Task<Void, Never>?
    private(set) var coverage: MailSyncCoverage?

    private(set) var selectedAccountId: UUID?
    private(set) var selectedFolderId: UUID?
    private(set) var selectedMessageId: UUID?
    private(set) var selectedMessageIDs: Set<UUID> = []
    private(set) var listFilter = MailListFilter()
    private(set) var listPresentation = MailListPresentation()
    private var presentationLoaded = false
    private var presentationRevision = UUID()
    private(set) var searchScope: MailSearchScope = .folder
    private(set) var importBatchContext: MailImportBatchContext?
    private(set) var savedSearches: [MailSavedSearch] = []
    private(set) var searchSaveError: String?
    private(set) var folderPreferences: [MailFolderPreference] = [] { didSet { updateFolderVisibility() } }
    private(set) var folderVisibility = MailFolderSidebarState(folders: [], preferences: [])
    var showHiddenFolders = false
    private(set) var unifiedInboxUnreadCount = 0
    private(set) var unifiedSyncFailures: [UUID] = []
    private(set) var isUnifiedSync = false
    private(set) var isPerformingBatch = false
    private(set) var batchProgress: (done: Int, total: Int) = (0, 0)
    private(set) var batchResult: MailBatchResult?
    private(set) var batchAction: MailBatchAction?
    private(set) var operationUndoReview: MailOperationUndoReview?
    private var batchTask: Task<Void, Never>?
    private var batchOperationID: UUID?

    private(set) var hasLoaded = false
    private(set) var isSyncing = false
    private(set) var isLoadingBody = false
    /// 是否还有下一页（当前文件夹已加载条数等于一页时认为可能还有）。
    private(set) var hasMoreMessages = false
    /// 是否正在续载下一页（防止重复触发）。
    private(set) var isLoadingMore = false
    private(set) var errorText: String?
    /// 同步进度（已完成文件夹数 / 总数）；0/0 表示尚未上报。
    private(set) var syncProgress: (done: Int, total: Int) = (0, 0)
    /// 已投递但本地未归档的草稿（投递凭证仍在，用于提示核实，禁止直接重发）。
    private(set) var deliveredDrafts: [MailDraft] = []

    /// 正文加载的请求令牌：只有最后一次请求的结果可以写 UI。
    ///
    /// 快速切换邮件时先发的慢请求可能后返回，若不核对就会把 A 的正文写到 B 的标题下
    /// （内容错配，可能涉及隐私）。
    private var bodyRequestToken = 0
    /// 列表/文件夹刷新的世代号：级联刷新的旧结果不得覆盖新选择。
    private var refreshGeneration = 0
    /// 正文加载任务：再次选择前取消上一个，避免无谓等待与竞态窗口。
    private var bodyTask: Task<Void, Never>?
    private var readWritebacks: [UUID: Task<Void, Never>] = [:]
    private var readGeneration = UUID()
    private var openedUnreadID: UUID?
    /// 同步任务：取消会结束网络等待；已完成批次保留。
    private var syncTask: Task<Void, Never>?
    private var syncOperationID: UUID?
    /// A source opened from search may be older than the first list page.
    private var sourceMessageID: UUID?
    private var messagePageCursor: MailService.MailPageCursor?
    private var pinnedListID: UUID?
    private var messagePageLimit = 200
    private var sourceNavigationID = UUID()

    /// 列表每页条数（与 `MailService` 默认页大小一致）。
    private static let messagePageSize = 200

    init(hub: Hub, space: AppSpace) {
        attachmentQueue = MailAttachmentQueue(hub: hub, space: space)
        autoSync = MailAutoSyncController(hub: hub, space: space)
        self.hub = hub
        self.space = space
        self.makeSyncService = { hub.makeMailSyncService(for: space) }
    }

    var sourceSpace: AppSpace { space }

    func exportIDs(folderID: UUID, includingDescendants: Bool = false) async -> [UUID]? {
        let navigation = sourceNavigationID
        do {
            guard let mail = hub.makeMailService(for: space) else { return nil }
            let ids = try await mail.messageIDs(folderId: folderID, includingDescendants: includingDescendants)
            guard navigation == sourceNavigationID, !Task.isCancelled else { return nil }
            if ids.isEmpty { errorText = L.string("mail.export.empty"); return nil }
            return ids
        } catch { report(error); return nil }
    }

    func exportSearchIDs() async -> [UUID]? {
        let navigation = sourceNavigationID, filter = listFilter
        guard let location = queryLocation else { return nil }
        do {
            guard let mail = hub.makeMailService(for: space) else { return nil }
            let ids = try await mail.messageIDs(in: location, matching: filter)
            guard navigation == sourceNavigationID, filter == listFilter, location == queryLocation, !Task.isCancelled else { return nil }
            if ids.isEmpty { errorText = L.string("mail.export.empty"); return nil }
            return ids
        } catch { report(error); return nil }
    }

    /// 取消本模型所有在途任务并作废其回调（空间切走时调用）。
    ///
    /// 已写入的本地数据保留；这里只是让旧空间的迟到结果不再写 UI、不再继续占用网络。
    func cancelPendingWork() {
        readGeneration = UUID()
        for task in readWritebacks.values { task.cancel() }
        readWritebacks.removeAll()
        attachmentQueue.cancelAll()
        autoSync.stop()
        batchTask?.cancel()
        batchOperationID = nil; batchTask = nil; operationUndoReview = nil; isPerformingBatch = false
        conversationTask?.cancel(); conversationGeneration = UUID(); isLoadingConversation = false
        syncTask?.cancel()
        syncTask = nil
        syncOperationID = nil
        cancelBodyLoad()
        inlineImages?.cancelPending(); inlineImages = nil
        sourceNavigationID = UUID()
        refreshGeneration += 1
        isSyncing = false
        syncProgress = (0, 0)
        isLoadingBody = false
    }

    // MARK: - Derived

    var currentAccount: MailAccount? {
        accounts.first { $0.id == selectedAccountId }
    }

    var currentFolder: MailFolder? {
        folders.first { $0.id == selectedFolderId }
    }

    var isUnifiedInbox: Bool { searchScope == .inbox }
    var isImportBatch: Bool { searchScope == .importBatch }
    var availableSearchScopes: [MailSearchScope] { MailSearchScope.allCases.filter { $0 != .importBatch || importBatchContext != nil } }

    func openUnifiedInbox() async {
        await updateListFilter(.init(), scope: .inbox)
    }

    var currentMessage: MailMessage? {
        messages.first { $0.id == selectedMessageId }
    }

    func messageForActions(_ id: UUID) -> MailMessage? {
        messages.first { $0.id == id } ?? conversationMessages.first { $0.id == id }
    }

    private func actionMessages(_ ids: Set<UUID>) -> [MailMessage] { ids.compactMap(messageForActions) }

    var readerActionMessage: MailMessage? {
        if isConversationVisible, selectedMessageIDs.count == 1,
           let id = focusedConversationMessageID, let message = messageForActions(id) { return message }
        return currentMessage
    }

    var readerActionIDs: Set<UUID> {
        if isConversationVisible, selectedMessageIDs.count == 1,
           let id = focusedConversationMessageID, messageForActions(id) != nil { return [id] }
        return selectedMessageIDs
    }

    func focusConversationMessage(_ id: UUID?) {
        focusedConversationMessageID = id.flatMap { candidate in
            isConversationVisible && conversationMessages.contains { $0.id == candidate } ? candidate : nil
        }
    }

    func setConversationVisible(_ shown: Bool) {
        guard isConversationVisible != shown else { return }
        isConversationVisible = shown
        cancelBodyLoad(); clearBody()
        if shown { refreshConversation(keepingLoaded: false) }
        else if let id = selectedMessageId {
            let token = bodyRequestToken
            bodyTask = Task { [weak self] in await self?.loadBody(messageId: id, token: token) }
        }
    }

    func refreshConversation(keepingLoaded: Bool = true) {
        guard let anchor = currentMessage else { return }
        conversationTask?.cancel()
        let token = UUID(); conversationGeneration = token
        let limit = keepingLoaded ? conversationPageLimit : 50
        isLoadingConversation = true; conversationError = nil
        conversationTask = Task {
            defer { if conversationGeneration == token { isLoadingConversation = false; conversationTask = nil } }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailSearchError.unavailable }
                let page = try await mail.conversationMessages(accountID: anchor.accountId, anchorID: anchor.id, limit: limit + 1)
                guard let latest = try await mail.message(id: anchor.id), latest.accountId == anchor.accountId else { throw MailSearchError.unavailable }
                guard conversationGeneration == token, selectedMessageId == anchor.id, !Task.isCancelled else { return }
                conversationPageLimit = limit
                conversationHasMore = page.count > limit
                let records = Array(page.prefix(limit))
                conversationCursor = records.last.map { .init(date: $0.date, id: $0.id) }
                conversationMessages = Self.sortedConversation(records.contains(where: { $0.id == anchor.id }) ? records : records + [latest])
                if let index = messages.firstIndex(where: { $0.id == anchor.id }) { messages[index] = latest }
                if let id = focusedConversationMessageID, !conversationMessages.contains(where: { $0.id == id }) { focusedConversationMessageID = nil }
            } catch is CancellationError { }
            catch { if conversationGeneration == token { conversationError = MailErrorText.message(for: error) } }
        }
    }

    func loadMoreConversation() {
        guard !isLoadingConversation, conversationHasMore, let anchor = currentMessage, let cursor = conversationCursor else { return }
        let token = conversationGeneration
        isLoadingConversation = true; conversationError = nil
        conversationTask = Task {
            defer { if conversationGeneration == token { isLoadingConversation = false; conversationTask = nil } }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailSearchError.unavailable }
                let page = try await mail.conversationMessages(accountID: anchor.accountId, anchorID: anchor.id, after: cursor, limit: 51)
                guard conversationGeneration == token, selectedMessageId == anchor.id, !Task.isCancelled else { return }
                conversationHasMore = page.count > 50
                let records = Array(page.prefix(50))
                conversationPageLimit += 50
                if let last = records.last { conversationCursor = .init(date: last.date, id: last.id) }
                var rows = Dictionary(uniqueKeysWithValues: conversationMessages.map { ($0.id, $0) })
                for record in records { rows[record.id] = record }
                conversationMessages = Self.sortedConversation(Array(rows.values))
            } catch is CancellationError { }
            catch { if conversationGeneration == token { conversationError = MailErrorText.message(for: error) } }
        }
    }

    private static func sortedConversation(_ values: [MailMessage]) -> [MailMessage] {
        values.sorted {
            switch ($0.date, $1.date) {
            case let (left?, right?) where left != right: return left < right
            case (nil, _?): return true
            case (_?, nil): return false
            default: return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    /// 当前账号下的文件夹。
    var visibleFolders: [MailFolder] {
        folders.filter { $0.accountId == selectedAccountId }
    }

    private func updateFolderVisibility() { folderVisibility = .init(folders: folders, preferences: folderPreferences) }
    var sidebarFolders: [MailFolder] {
        let hidden = folderVisibility.hidden
        return visibleFolders.filter { showHiddenFolders || !hidden.contains($0.id) }
    }
    var hasHiddenFolders: Bool { let hidden = folderVisibility.hidden; return visibleFolders.contains { hidden.contains($0.id) } }
    func folderPath(_ folder: MailFolder) -> String {
        MailFolderPath.display(folder, isLocalArchive: accounts.first { $0.id == folder.accountId }?.isLocalArchive == true)
    }

    func setHidden(_ hidden: Bool, folderID: UUID) async {
        let navigation = sourceNavigationID
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.folderNotFound }
            try await mail.setFolderHidden(hidden, folderID: folderID)
            let preferences = try await mail.folderPreferences()
            guard navigation == sourceNavigationID, !Task.isCancelled else { return }
            folderPreferences = preferences
        } catch { if navigation == sourceNavigationID, !Task.isCancelled { report(error) } }
    }

    var queryLocation: MailQueryLocation? {
        switch searchScope {
        case .folder: selectedFolderId.map(MailQueryLocation.folder)
        case .account: selectedAccountId.map(MailQueryLocation.account)
        case .inbox: .inbox
        case .space: .space
        case .importBatch: importBatchContext.map { .importBatch(archiveID: $0.accountID, batchID: $0.id) }
        }
    }

    private func matchesLocation(_ message: MailMessage, _ location: MailQueryLocation) -> Bool {
        switch location { case .folder(let id): message.folderId == id; case .account(let id): message.accountId == id; case .inbox: folder(for: message)?.role == .inbox; case .space: true; case .importBatch: false }
    }

    func reloadSavedSearches() async {
        do { savedSearches = try await hub.makeMailService(for: space)?.savedSearches() ?? [] }
        catch { report(error) }
    }

    func saveSearch(name: String, filter: MailListFilter, scope: MailSearchScope,
                    replacing previous: MailSavedSearch? = nil, updateConditions: Bool = true) async -> Bool {
        searchSaveError = nil
        let location: MailQueryLocation?
        if let previous, !updateConditions { location = previous.location }
        else {
            switch scope {
            case .folder: location = selectedFolderId.map(MailQueryLocation.folder)
            case .account: location = selectedAccountId.map(MailQueryLocation.account)
            case .inbox: location = .inbox
            case .space: location = .space
            case .importBatch: location = importBatchContext.map { .importBatch(archiveID: $0.accountID, batchID: $0.id) }
            }
        }
        do {
            guard let location, let mail = hub.makeMailService(for: space) else { throw MailSearchError.unavailable }
            let criteria = updateConditions ? filter : (previous?.filter ?? filter)
            try await mail.saveSearch(.init(id: previous?.id ?? UUID(), name: name, filter: criteria, location: location), replacing: previous)
            await reloadSavedSearches(); return true
        } catch { searchSaveError = MailErrorText.message(for: error); return false }
    }

    func clearSearchSaveError() { searchSaveError = nil }

    func deleteSearch(_ saved: MailSavedSearch) async {
        do { try await hub.makeMailService(for: space)?.deleteSearch(id: saved.id); await reloadSavedSearches() }
        catch { report(error) }
    }

    func applySearch(_ saved: MailSavedSearch) async -> Bool {
        let ticket = UUID(); sourceNavigationID = ticket
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailSearchError.unavailable }
            let context = try await mail.searchContext(for: saved.location)
            let batch: MailImportBatchContext?
            if case .importBatch(let archiveID, let batchID) = saved.location { batch = try await mail.importBatchContext(batchID: batchID, archiveID: archiveID) } else { batch = nil }
            try Task.checkCancellation()
            guard sourceNavigationID == ticket else { return false }
            sourceMessageID = nil; refreshGeneration += 1
            if let account = context.accountID { selectedAccountId = account }
            if let folder = context.folderID { selectedFolderId = folder }
            else if context.accountID != nil { selectedFolderId = nil }
            listFilter = saved.filter; searchScope = saved.location.scope
            importBatchContext = batch
            messagePageLimit = Self.messagePageSize; messagePageCursor = nil
            selectedMessageId = nil; selectedMessageIDs = []; messages = []
            cancelBodyLoad(); clearBody()
            await reloadFolders(); return sourceNavigationID == ticket
        } catch { report(error); return false }
    }

    func folder(for message: MailMessage) -> MailFolder? { folders.first { $0.id == message.folderId && $0.accountId == message.accountId } }

    func readTargets(_ read: Bool, in ids: Set<UUID>) -> Set<UUID> {
        Set(actionMessages(ids).filter { $0.isRead != read }.map(\.id))
    }

    func starTargets(_ starred: Bool, in ids: Set<UUID>) -> Set<UUID> {
        Set(actionMessages(ids).filter { $0.isStarred != starred }.map(\.id))
    }

    func allInTrash(_ ids: Set<UUID>) -> Bool {
        let selected = actionMessages(ids)
        return selected.count == ids.count && !selected.isEmpty && selected.allSatisfy { folder(for: $0)?.role == .trash }
    }

    func hasTarget(_ role: MailFolderRole, ids: Set<UUID>) -> Bool {
        let selected = actionMessages(ids)
        return selected.count == ids.count && !selected.isEmpty && selected.allSatisfy { message in
            folders.contains { $0.accountId == message.accountId && $0.role == role && !$0.isContainer }
        }
    }

    func mutationBlockReason(_ ids: Set<UUID>) -> String? {
        if isPerformingBatch { return L.string("mail.action.unavailable.busy") }
        if ids.isEmpty { return L.string("mail.move.error.empty") }
        let selected = actionMessages(ids)
        guard selected.count == ids.count, selected.allSatisfy({ message in
            folders.contains { $0.id == message.folderId && $0.accountId == message.accountId && !$0.isContainer }
                && accounts.contains { $0.id == message.accountId }
        }) else { return L.string("mail.move.error.unavailable") }
        if selected.contains(where: { message in message.uid < MailService.localUIDFloor && accounts.contains { $0.id == message.accountId && !$0.isLocalArchive && !$0.isEnabled } }) {
            return L.string("mail.error.accountDisabled")
        }
        return nil
    }

    func moveBlockReason(_ ids: Set<UUID>) -> String? {
        if let reason = mutationBlockReason(ids) { return reason }
        if Set(actionMessages(ids).map(\.accountId)).count > 1 { return L.string("mail.move.error.mixedAccounts") }
        return moveTargets(for: ids).isEmpty ? L.string("mail.move.error.noDestination") : nil
    }

    func roleBlockReason(_ role: MailFolderRole, ids: Set<UUID>) -> String? {
        if let reason = mutationBlockReason(ids) { return reason }
        if !hasTarget(role, ids: ids) { return L.format("mail.action.unavailable.role", L.string(role.labelKey)) }
        if actionMessages(ids).allSatisfy({ folder(for: $0)?.role == role }) { return L.format("mail.action.unavailable.already", L.string(role.labelKey)) }
        return nil
    }

    func deleteBlockReason(_ ids: Set<UUID>) -> String? {
        allInTrash(ids) ? mutationBlockReason(ids) : roleBlockReason(.trash, ids: ids)
    }

    func moveTargets(for ids: Set<UUID>) -> [MailFolder] {
        let selected = actionMessages(ids)
        guard selected.count == ids.count, let owner = selected.first?.accountId, selected.allSatisfy({ $0.accountId == owner }) else { return [] }
        return folders.filter { folder in folder.accountId == owner && !folder.isContainer && !selected.allSatisfy { $0.folderId == folder.id } }
    }

    var favoriteFolderIDs: Set<UUID> { Set(folderPreferences.filter(\.isFavorite).map(\.folderID)) }
    var favoriteFolders: [MailFolder] {
        let favorites = favoriteFolderIDs
        return sidebarFolders.filter { favorites.contains($0.id) && !$0.isContainer }
    }

    func preferredMoveTargets(for ids: Set<UUID>) -> [MailFolder] {
        let eligible = Dictionary(uniqueKeysWithValues: moveTargets(for: ids).map { ($0.id, $0) })
        let recent = folderPreferences.filter { $0.lastMovedAt != nil }.sorted {
            if $0.lastMovedAt != $1.lastMovedAt { return ($0.lastMovedAt ?? .distantPast) > ($1.lastMovedAt ?? .distantPast) }
            return $0.folderID.uuidString < $1.folderID.uuidString
        }.compactMap { eligible[$0.folderID] }
        let favoriteIDs = favoriteFolderIDs, recentIDs = Set(recent.map(\.id))
        let favorites = moveTargets(for: ids).filter { folder in
            favoriteIDs.contains(folder.id) && !recentIDs.contains(folder.id)
        }
        return recent + favorites
    }

    func setFavorite(_ favorite: Bool, folderID: UUID) async {
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.folderNotFound }
            try await mail.setFolderFavorite(favorite, folderID: folderID)
            folderPreferences = try await mail.folderPreferences()
        } catch { report(error) }
    }

    private func rememberMoveDestination(_ folderID: UUID) async {
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailSyncError.folderNotFound }
            try await mail.recordMoveDestination(folderID)
            folderPreferences = try await mail.folderPreferences()
        } catch {
            // The move has already succeeded. A preference failure must not invite a replay.
            errorText = L.string("mail.folder.recentSaveFailed")
        }
    }

    var sourceLabels: [UUID: String] {
        guard searchScope != .folder else { return [:] }
        let owners = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.displayName.isEmpty ? ($0.emailAddress.isEmpty ? $0.username : $0.emailAddress) : $0.displayName) })
        let boxes = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.displayName) })
        return Dictionary(uniqueKeysWithValues: messages.map { message in
            let parts = searchScope == .space || searchScope == .inbox ? [owners[message.accountId] ?? "", boxes[message.folderId] ?? ""] : [boxes[message.folderId] ?? ""]
            return (message.id, parts.filter { !$0.isEmpty }.joined(separator: " · "))
        })
    }

    func sourceDescription(for message: MailMessage) -> String {
        let owner = accounts.first { $0.id == message.accountId }
        let title = owner.map { $0.displayName.isEmpty ? $0.emailAddress : $0.displayName } ?? ""
        return [title, folder(for: message)?.displayName ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Folder Tree（侧栏树形分组）

    /// 侧栏树节点：容器节点 + 可邮件文件夹混合；`OutlineGroup` 需要 children 为 KeyPath。
    struct FolderNode: Identifiable {
        let folder: MailFolder
        let children: [FolderNode]?
        var id: UUID { folder.id }
        var isContainer: Bool { folder.isContainer }

        /// 每层都按语义角色排序，保留服务器层级；父节点缺失时仍显示该文件夹。
        static func tree(from folders: [MailFolder]) -> [FolderNode] {
            let paths = Set(folders.map(\.path))
            let grouped = Dictionary(grouping: folders) { folder -> String? in
                guard let parent = folder.parentPath, paths.contains(parent) else { return nil }
                return parent
            }
            func build(_ parent: String?) -> [FolderNode] {
                (grouped[parent] ?? []).sorted { lhs, rhs in
                    if lhs.role.sortOrder != rhs.role.sortOrder {
                        return lhs.role.sortOrder < rhs.role.sortOrder
                    }
                    let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                    return lhs.path < rhs.path
                }.map { folder in
                    let children = build(folder.path)
                    return FolderNode(folder: folder, children: children.isEmpty ? nil : children)
                }
            }
            return build(nil)
        }
    }

    /// 平铺与树形共用排序，避免出现子文件夹后系统文件夹顺序改变。
    var folderTree: [FolderNode] {
        FolderNode.tree(from: sidebarFolders)
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        if !presentationLoaded {
            presentationLoaded = true
            let revision = presentationRevision
            do {
                if let stored = try await hub.makeProductPreferencesService(for: space)?.load(MailListPresentation.self, key: "mail.list.presentation") {
                    try stored.validate()
                    if presentationRevision == revision { listPresentation = stored }
                }
            } catch { report(error) }
        }
        if hasLoaded {
            if let id = selectedMessageId, body != nil, inlineImages == nil { inlineImages = makeInlineImages(messageID: id) }
            return
        }
        hasLoaded = true
        await reloadAccounts()
        await reloadSavedSearches()
    }

    func updateListPresentation(_ value: MailListPresentation) async {
        let previous = listPresentation, token = UUID()
        presentationRevision = token
        do {
            try value.validate()
            listPresentation = value
            if previous.order != value.order {
                refreshGeneration += 1; messagePageCursor = nil; hasMoreMessages = false
                messagePageLimit = Self.messagePageSize
            }
            guard let preferences = hub.makeProductPreferencesService(for: space) else { throw MailSearchError.unavailable }
            try await preferences.save(value, key: "mail.list.presentation")
            guard presentationRevision == token else { return }
            if previous.order != value.order { await reloadMessages() }
        } catch {
            guard presentationRevision == token else { return }
            listPresentation = previous; report(error)
            if previous.order != value.order { await reloadMessages() }
        }
    }

    func reloadAccounts() async {
        guard let accountService = hub.makeMailAccountService(for: space) else { return }
        let generation = refreshGeneration
        do {
            let loaded = try await accountService.getAll()
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            accounts = loaded
            if let context = importBatchContext, !loaded.contains(where: { $0.id == context.accountID }) {
                importBatchContext = nil
                if isImportBatch { searchScope = .folder; listFilter = .init() }
            }
            if let selectedAccountId, !accounts.contains(where: { $0.id == selectedAccountId }) {
                self.selectedAccountId = nil
            }
            if selectedAccountId == nil {
                selectedAccountId = accounts.first?.id
            }
            await reloadFolders()
        } catch {
            report(error)
        }
    }

    func selectAccount(_ id: UUID?) async {
        guard selectedAccountId != id || isUnifiedInbox || isImportBatch else { return }
        if isUnifiedInbox || isImportBatch { searchScope = .folder; listFilter = .init() }
        importBatchContext = nil
        sourceNavigationID = UUID(); sourceMessageID = nil
        selectedAccountId = id
        messagePageLimit = Self.messagePageSize
        selectedFolderId = nil
        selectedMessageId = nil
        selectedMessageIDs = []
        messages = []
        cancelBodyLoad()
        clearBody()
        await reloadFolders()
    }

    func selectFolder(_ id: UUID?) async {
        guard selectedFolderId != id || isUnifiedInbox || isImportBatch else { return }
        if isUnifiedInbox || isImportBatch { searchScope = .folder; listFilter = .init() }
        importBatchContext = nil
        sourceNavigationID = UUID(); sourceMessageID = nil
        selectedFolderId = id
        messagePageLimit = Self.messagePageSize
        selectedMessageId = nil
        selectedMessageIDs = []
        cancelBodyLoad()
        clearBody()
        await reloadMessages()
    }

    /// 选中邮件：立即作废上一个正文请求，再发起新请求。
    ///
    /// 令牌在**选择时**分配（而不是任务启动时）：并发选择下任务可能还没开始执行，
    /// 若那时才分配令牌，两次选择可能拿到同一个值，核对就失效了。
    func selectMessage(_ id: UUID?, updateSelection: Bool = true) async {
        if updateSelection { selectedMessageIDs = Set([id].compactMap { $0 }) }
        sourceNavigationID = UUID()
        guard selectedMessageId != id else { return }
        if let previous = openedUnreadID, previous == selectedMessageId, listFilter.unreadOnly, !selectedMessageIDs.contains(previous) {
            messages.removeAll { $0.id == previous && $0.isRead }
        }
        openedUnreadID = nil
        selectedMessageId = id
        cancelBodyLoad()
        clearBody()
        guard let id else { return }
        let token = bodyRequestToken
        if let message = currentMessage, !message.isRead {
            if listFilter.unreadOnly { openedUnreadID = id }
            await markOpened(message)
        }
        guard selectedMessageId == id, bodyRequestToken == token else { return }
        if isConversationVisible { refreshConversation(keepingLoaded: false); return }
        // 放在独立任务里：让「取消上一次」在新请求发出前生效
        bodyTask = Task { [weak self] in
            await self?.loadBody(messageId: id, token: token)
        }
        await bodyTask?.value
    }

    func markOpened(_ message: MailMessage) async {
        guard !message.isRead, let mail = hub.makeMailService(for: space) else { return }
        let generation = readGeneration
        do {
            guard try await mail.markOpened(message), generation == readGeneration, !Task.isCancelled else { return }
            if message.uid < MailService.localUIDFloor, let sync = makeSyncService() {
                let folderID = message.folderId
                readWritebacks[folderID]?.cancel()
                readWritebacks[folderID] = Task { [weak self] in
                    defer { if !Task.isCancelled { self?.readWritebacks[folderID] = nil } }
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        try await sync.flushOpenedFolder(message)
                    } catch is CancellationError { }
                    catch { HubLogger.shared.warning("Mail read flag remains queued: \(HubLogger.safeErrorSummary(error))") }
                }
            }
            await reloadFolders()
        } catch is CancellationError { }
        catch { if generation == readGeneration { report(error) } }
    }

    func setSelection(_ ids: Set<UUID>) {
        selectedMessageIDs = ids
        Task {
            guard selectedMessageIDs == ids else { return }
            await selectMessage(ids.count == 1 ? ids.first : nil, updateSelection: false)
        }
    }

    func updateListFilter(_ filter: MailListFilter, scope: MailSearchScope? = nil) async {
        let next = scope ?? searchScope
        guard next != .importBatch || importBatchContext != nil else { return }
        guard filter != listFilter || next != searchScope else { return }
        sourceNavigationID = UUID()
        listFilter = filter; searchScope = next
        messagePageLimit = Self.messagePageSize
        sourceMessageID = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        messages = []; messagePageCursor = nil; hasMoreMessages = false
        selectedMessageIDs = []; selectedMessageId = nil
        cancelBodyLoad(); clearBody()
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        await reloadMessages()
    }

    @discardableResult
    func performBatch(ids: Set<UUID>, action: MailBatchAction, moveReview: MailMoveReview? = nil) -> Bool {
        guard !isPerformingBatch, !ids.isEmpty, let service = hub.makeMailSyncService(for: space) else { return false }
        let operation = UUID()
        batchOperationID = operation; isPerformingBatch = true
        batchAction = action; batchResult = nil; operationUndoReview = nil; batchProgress = (0, ids.count)
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }
        batchTask = Task { [weak self] in
            let result = await service.applyBatch(messageIDs: ordered, action: action, moveReview: moveReview) { [weak self] done, total in
                await self?.updateBatchProgress(operation: operation, done: done, total: total)
            }
            guard let self, self.batchOperationID == operation else { return }
            if case .move(let folderID) = action, !result.succeeded.isEmpty {
                await Task { @MainActor in await self.rememberMoveDestination(folderID) }.value
            }
            guard self.batchOperationID == operation else { return }
            self.batchResult = result
            // Keep the operation busy until menus see the committed folder ownership.
            // Refresh even when cancellation left a partial success receipt.
            await Task { @MainActor in await self.reloadFolders() }.value
            guard self.batchOperationID == operation else { return }
            self.isPerformingBatch = false; self.batchTask = nil
        }
        return true
    }

    private func updateBatchProgress(operation: UUID, done: Int, total: Int) {
        guard batchOperationID == operation else { return }
        batchProgress = (done, total)
    }

    func cancelBatch() { batchTask?.cancel() }
    func dismissBatchResult() { batchResult = nil }
    func dismissOperationUndo() { operationUndoReview = nil }

    func prepareOperationUndo() {
        guard !isPerformingBatch, let receipt = batchResult?.undoReceipt,
              let mail = hub.makeMailService(for: space) else { return }
        let operation = UUID(); batchOperationID = operation
        isPerformingBatch = true; batchProgress = (0, receipt.count)
        batchTask = Task { [weak self] in
            do {
                let review = try await mail.previewOperationUndo(receipt)
                try Task.checkCancellation()
                guard let self, self.batchOperationID == operation else { return }
                if review.count > 0 { self.operationUndoReview = review }
                else { self.errorText = L.string("mail.batch.undo.unavailable") }
            } catch is CancellationError { }
            catch { if let self, self.batchOperationID == operation { self.report(error) } }
            if let self, self.batchOperationID == operation { self.isPerformingBatch = false; self.batchTask = nil }
        }
    }

    func confirmOperationUndo(_ review: MailOperationUndoReview) {
        guard !isPerformingBatch, batchResult?.undoReceipt?.id == review.receiptID,
              let service = hub.makeMailSyncService(for: space) else { return }
        operationUndoReview = nil
        let operation = UUID(); batchOperationID = operation
        isPerformingBatch = true; batchProgress = (0, review.count); batchAction = nil
        batchTask = Task { [weak self] in
            let result = await service.undoBatch(review) { [weak self] done, total in
                await self?.updateBatchProgress(operation: operation, done: done, total: total)
            }
            guard let self, self.batchOperationID == operation else { return }
            self.batchResult = result
            await Task { @MainActor in await self.reloadFolders() }.value
            guard self.batchOperationID == operation else { return }
            self.isPerformingBatch = false; self.batchTask = nil
        }
    }

    func revealBatchSuccess() async {
        guard !isPerformingBatch, let id = batchResult?.succeeded.first else { return }
        _ = await openSearchSource(id, isCurrent: { self.hub.spaceStore.current == self.space })
    }
    func showMissingFolderError() { errorText = L.string("mail.folder.missingTarget") }

    func retryBatchFlags() {
        guard let action = batchAction, action.allowsDirectRetry, let result = batchResult else { return }
        performBatch(ids: Set(result.failures.map(\.messageID) + result.unprocessed), action: action)
    }

    func markFolderRead(_ folderID: UUID) async {
        guard !isPerformingBatch, let mail = hub.makeMailService(for: space) else { return }
        let navigation = sourceNavigationID
        do {
            let ids = try await mail.messageIDs(folderId: folderID, matching: .init(unreadOnly: true))
            guard navigation == sourceNavigationID, !Task.isCancelled else { return }
            performBatch(ids: Set(ids), action: .read(true))
        } catch { report(error) }
    }

    func syncFolder(_ folderID: UUID) {
        guard !isSyncing, let folder = folders.first(where: { $0.id == folderID }),
              let service = hub.makeMailSyncService(for: space) else { return }
        runSyncOperation { _ = try await service.syncFolder(accountId: folder.accountId, folderId: folderID) }
    }

    private func runSyncOperation(_ operation: @MainActor @escaping () async throws -> Void) {
        let id = UUID()
        syncOperationID = id; isSyncing = true
        syncTask = Task {
            do { try await operation() }
            catch is CancellationError { }
            catch { if syncOperationID == id { report(error) } }
            guard syncOperationID == id else { return }
            syncTask = nil; syncOperationID = nil; isSyncing = false
            await reloadFolders()
        }
    }

    @discardableResult
    func openImportBatch(archiveID: UUID, batchID: UUID, isCurrent: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        let ticket = UUID(); sourceNavigationID = ticket
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            guard let mail = hub.makeMailService(for: space), let owners = hub.makeMailAccountService(for: space) else { throw MailImportError.changed }
            let context = try await mail.importBatchContext(batchID: batchID, archiveID: archiveID)
            let loadedAccounts = try await owners.getAll(), loadedFolders = try await mail.allFolders()
            let preferences = try await mail.folderPreferences(), searches = try await mail.savedSearches()
            guard sourceNavigationID == ticket, refreshGeneration == generation, !Task.isCancelled, isCurrent() else { return false }
            cancelBodyLoad(); clearBody()
            hasLoaded = true; accounts = loadedAccounts; folders = loadedFolders
            folderPreferences = preferences; savedSearches = searches
            selectedAccountId = archiveID; selectedFolderId = nil
            importBatchContext = context; searchScope = .importBatch; listFilter = .init()
            selectedMessageId = nil; selectedMessageIDs = []; sourceMessageID = nil
            messagePageLimit = Self.messagePageSize; messagePageCursor = nil; messages = []
            await reloadMessages()
            guard sourceNavigationID == ticket, !Task.isCancelled, isCurrent() else { return false }
            if let first = messages.first { await selectMessage(first.id) }
            return !Task.isCancelled && isCurrent() && importBatchContext == context && isImportBatch
        } catch {
            if sourceNavigationID == ticket, !Task.isCancelled, isCurrent() { report(error) }
            return false
        }
    }

    /// Resolve the saved record before changing account/folder. The optional
    /// pinned row is separate from the pagination cursor, so opening old mail
    /// cannot skip the intervening pages. Search itself never calls this method.
    @discardableResult
    func openSearchSource(_ id: UUID, reference: MailSourceReference? = nil, isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        let ticket = UUID(); sourceNavigationID = ticket
        refreshGeneration += 1
        let generation = refreshGeneration
        hasLoaded = true
        do {
            guard let mail = hub.makeMailService(for: space),
                  let accountService = hub.makeMailAccountService(for: space) else { throw SpaceSearchError.unavailable }
            let target: MailMessage
            if let reference {
                guard reference.messageID == id else { throw MailSourceReferenceError.invalid }
                target = try await mail.resolveSourceReference(reference, in: space)
            } else {
                guard let found = try await mail.message(id: id) else { throw SpaceSearchError.missing }
                target = found
            }
            let loadedAccounts = try await accountService.getAll()
            let loadedFolders = try await mail.allFolders()
            guard sourceNavigationID == ticket, refreshGeneration == generation, !Task.isCancelled, isCurrent() else { return false }
            guard loadedAccounts.contains(where: { $0.id == target.accountId }),
                  loadedFolders.contains(where: { $0.id == target.folderId && $0.accountId == target.accountId && !$0.isContainer }) else { throw SpaceSearchError.missing }
            cancelBodyLoad(); clearBody()
            accounts = loadedAccounts; folders = loadedFolders
            selectedAccountId = target.accountId; selectedFolderId = target.folderId
            listFilter = .init(); searchScope = .folder
            importBatchContext = nil
            selectedMessageId = nil; sourceMessageID = id
            selectedMessageIDs = []; messagePageLimit = Self.messagePageSize
            messages = []; messagePageCursor = nil
            await reloadMessages()
            guard sourceNavigationID == ticket, !Task.isCancelled, isCurrent(), messages.contains(where: { $0.id == id }) else { return false }
            if let reference { _ = try await mail.resolveSourceReference(reference, in: space) }
            await selectMessage(id)
            return !Task.isCancelled && isCurrent() && currentMessage?.id == id && currentMessage?.accountId == target.accountId && searchScope == .folder
        } catch {
            if sourceNavigationID == ticket, !Task.isCancelled, isCurrent() { report(error) }
            return false
        }
    }

    func reloadFolders() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        guard let mail = hub.makeMailService(for: space), let accountId = selectedAccountId else {
            folders = []
            folderPreferences = []
            messages = []
            return
        }
        do {
            let loaded = try await mail.allFolders()
            let preferences = try await mail.folderPreferences()
            guard generation == refreshGeneration, accountId == selectedAccountId else { return }
            folders = loaded
            folderPreferences = preferences
            if let selectedFolderId, !visibleFolders.contains(where: { $0.id == selectedFolderId }) {
                self.selectedFolderId = nil
            }
            if selectedFolderId == nil {
                // 默认落在收件箱；没有收件箱时取第一个可邮件文件夹（容器不可选）
                selectedFolderId = visibleFolders.first { $0.role == .inbox && !$0.isContainer }?.id
                    ?? visibleFolders.first { !$0.isContainer }?.id
            }
            await reloadMessages()
        } catch {
            guard generation == refreshGeneration else { return }
            report(error)
        }
    }

    func reloadMessages() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        guard let mail = hub.makeMailService(for: space), let location = queryLocation else {
            messages = []
            coverage = nil
            hasMoreMessages = false
            return
        }
        coverage = nil
        do {
            let page = try await mail.messagePage(
                in: location,
                before: nil,
                limit: messagePageLimit,
                matching: listFilter, order: listPresentation.order
            )
            let loaded = page.messages
            let loadedCoverage: MailSyncCoverage?
            if case .folder(let id) = location { loadedCoverage = try await mail.coverage(folderID: id) } else { loadedCoverage = nil }
            let unread = try await mail.messageCount(in: .inbox, matching: .init(unreadOnly: true))
            let reading = listFilter.unreadOnly && selectedMessageId == openedUnreadID ? currentMessage : nil
            let pinID = reading?.id ?? sourceMessageID
            let pinned: MailMessage?
            if let pinID, !loaded.contains(where: { $0.id == pinID }) {
                pinned = try await mail.message(id: pinID)
            } else { pinned = nil }
            // 快速切换文件夹时旧请求可能后返回：过期世代直接丢弃，不写 UI
            guard generation == refreshGeneration, location == queryLocation else { return }
            let readingIndex = reading.flatMap { item in messages.firstIndex { $0.id == item.id } }
            messages = loaded
            pinnedListID = nil
            unifiedInboxUnreadCount = unread
            if let pinned, let reading, let readingIndex, selectedMessageId == reading.id,
               pinned.folderId == reading.folderId, pinned.accountId == reading.accountId {
                messages.insert(pinned, at: min(readingIndex, messages.count)); pinnedListID = pinned.id
            } else if let pinned, pinned.id == sourceMessageID, matchesLocation(pinned, location) {
                messages.append(pinned); pinnedListID = pinned.id
            }
            messagePageCursor = page.cursor
            coverage = loadedCoverage
            selectedMessageIDs.formIntersection(Set(messages.map(\.id)))
            // 满一页才认为可能还有下一页；不足一页即到底，避免多余的「加载更多」
            hasMoreMessages = loaded.count == messagePageLimit
            if let selectedMessageId, !messages.contains(where: { $0.id == selectedMessageId }) {
                self.selectedMessageId = nil
                clearBody()
            }
            if !conversationMessages.isEmpty || isLoadingConversation { refreshConversation() }
        } catch {
            guard generation == refreshGeneration else { return }
            report(error)
        }
    }

    /// 续载下一页（游标锚定在末条，避免同步插入/删除造成位移漏读或重复）。
    func loadMoreMessages() async {
        // 与首屏用同一世代：翻页途中切了文件夹，旧页不得追加到新列表
        let generation = refreshGeneration
        guard hasMoreMessages, !isLoadingMore,
              let mail = hub.makeMailService(for: space),
              let location = queryLocation,
              let cursor = messagePageCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await mail.messagePage(
                in: location,
                before: cursor,
                limit: Self.messagePageSize,
                matching: listFilter, order: listPresentation.order
            )
            let page = result.messages
            guard generation == refreshGeneration, location == queryLocation else { return }
            // 去重追加：同步可能在翻页期间把同一条重新写入
            let pinned = pinnedListID.flatMap { id in messages.first { $0.id == id } }
            if let pinnedListID { messages.removeAll { $0.id == pinnedListID } }
            let existing = Set(messages.map(\.id))
            messages.append(contentsOf: page.filter { !existing.contains($0.id) })
            if let pinned, !messages.contains(where: { $0.id == pinned.id }) { messages.append(pinned) }
            else { pinnedListID = nil }
            messagePageCursor = result.cursor
            messagePageLimit += Self.messagePageSize
            hasMoreMessages = page.count == Self.messagePageSize
        } catch {
            guard generation == refreshGeneration else { return }
            report(error)
        }
    }

    /// 刷新已投递但未归档的草稿（进入邮箱页与发送失败后调用）。
    func reloadDeliveredDrafts() async {
        guard let mail = hub.makeMailService(for: space), let accountId = selectedAccountId else {
            deliveredDrafts = []
            return
        }
        deliveredDrafts = (try? await mail.deliveredDrafts(accountId: accountId)) ?? []
    }

    /// 丢弃一封已投递草稿的本地残留（投递凭证只用于提示，确认后即可清理）。
    func discardDeliveredDraft(id: UUID) async {
        guard let mail = hub.makeMailService(for: space) else { return }
        do {
            try await mail.deleteDraft(id: id)
            await reloadDeliveredDrafts()
        } catch {
            report(error)
        }
    }

    // MARK: - Sync

    /// 启动账号同步（不阻塞调用方：同步可能很长，取消入口必须可用）。
    func startSync() {
        guard syncTask == nil, !isSyncing else { return }
        let unified = isUnifiedInbox
        isUnifiedSync = unified
        let operation = UUID()
        syncOperationID = operation
        syncTask = Task { [weak self] in
            if unified { await self?.syncUnifiedInbox(operation: operation) }
            else { await self?.syncCurrentAccount(operation: operation) }
            if self?.syncOperationID == operation {
                self?.syncTask = nil
                self?.syncOperationID = nil
            }
        }
    }

    private func syncUnifiedInbox(operation: UUID) async {
        let targets = accounts.filter { $0.isEnabled && !$0.isLocalArchive }.map(\.id)
        guard !targets.isEmpty, let service = makeSyncService() else { return }
        isSyncing = true; unifiedSyncFailures = []; syncProgress = (0, targets.count)
        defer { if syncOperationID == operation { isSyncing = false; syncProgress = (0, 0) } }
        for (index, accountID) in targets.enumerated() {
            guard syncOperationID == operation, !Task.isCancelled else { break }
            do { _ = try await service.syncAccount(accountId: accountID, onlyRole: .inbox) }
            catch is CancellationError { break }
            catch {
                guard syncOperationID == operation, !Task.isCancelled else { return }
                unifiedSyncFailures.append(accountID)
            }
            guard syncOperationID == operation else { return }
            syncProgress = (index + 1, targets.count)
            await reloadFolders()
        }
        if !unifiedSyncFailures.isEmpty, syncOperationID == operation {
            let failed = unifiedSyncFailures.compactMap { id in accounts.first { $0.id == id } }
                .map { $0.displayName.isEmpty ? $0.emailAddress : $0.displayName }.joined(separator: ", ")
            errorText = L.format("mail.inbox.syncFailures", unifiedSyncFailures.count, failed)
        }
    }

    func loadEarlierMail() { startCoverageAction(rebuild: false) }
    func rebuildCurrentFolder() { startCoverageAction(rebuild: true) }

    private func startCoverageAction(rebuild: Bool) {
        guard syncTask == nil, !isSyncing, let accountID = selectedAccountId, let folderID = selectedFolderId,
              let service = hub.makeMailSyncService(for: space) else { return }
        let operation = UUID()
        syncOperationID = operation
        isSyncing = true
        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                if rebuild { _ = try await service.rebuildFolderCache(accountId: accountID, folderId: folderID) }
                else { _ = try await service.loadEarlier(accountId: accountID, folderId: folderID) }
            } catch is CancellationError {
                // Committed batches remain available after cancellation.
            } catch { if self.syncOperationID == operation { self.report(error) } }
            guard self.syncOperationID == operation else { return }
            self.isSyncing = false
            self.syncTask = nil
            self.syncOperationID = nil
            await self.reloadFolders()
        }
    }

    private func syncCurrentAccount(operation: UUID) async {
        guard let syncService = hub.makeMailSyncService(for: space), let accountId = selectedAccountId else { return }
        isSyncing = true
        syncProgress = (0, 0)
        defer {
            if syncOperationID == operation {
                isSyncing = false
                syncProgress = (0, 0)
            }
        }
        do {
            _ = try await syncService.syncAccount(accountId: accountId) { [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.syncOperationID == operation else { return }
                    self.syncProgress = (done, total)
                    // 每完成一个文件夹即刷新：首屏不等全部文件夹跑完，
                    // 收件箱（排第一）同步完邮件立即可见
                    if done > 0 { await self.reloadFolders() }
                }
            }
            guard syncOperationID == operation else { return }
            await reloadFolders()
        } catch is CancellationError {
            // 用户取消：已写入的批次保留，游标可续传，不是错误
            HubLogger.shared.info("Mail sync cancelled by the user")
            guard syncOperationID == operation else { return }
            await reloadFolders()
        } catch {
            guard syncOperationID == operation else { return }
            report(error)
            // 失败也要刷新：本轮已成功落库的邮件应立即可见，不能因后面的文件夹失败
            // 而整批不显示。原始同步错误仍经 report 保留（不吞掉）。
            await reloadFolders()
        }
    }

    /// 取消正在进行的同步（批次之间生效，已写入的批次保留）。
    func cancelSync() {
        syncTask?.cancel()
    }

    /// 按需正文：本地已就绪时直接读缓存，否则经同步服务拉取。
    ///
    /// 结果写回前必须核对「令牌未过期且当前选中的仍是本次请求的邮件」，否则慢请求
    /// 会把 A 的正文写到 B 的标题下（内容错配）。
    func loadBody(messageId: UUID, token: Int) async {
        guard let mail = hub.makeMailService(for: space) else { return }
        let cached = try? await mail.message(id: messageId)
        guard token == bodyRequestToken, selectedMessageId == messageId else { return }
        if cached?.bodyState == .ready {
            let loadedBody = try? await mail.body(messageId: messageId)
            let loadedAttachments = (try? await mail.attachments(messageId: messageId)) ?? []
            guard token == bodyRequestToken, selectedMessageId == messageId else { return }
            if let loadedBody {
                body = loadedBody
                attachments = loadedAttachments
                inlineImages = makeInlineImages(messageID: messageId)
                return
            }
        }

        guard let syncService = makeSyncService() else { return }
        isLoadingBody = true
        defer {
            if token == bodyRequestToken { isLoadingBody = false }
        }
        do {
            let loaded = try await syncService.loadBody(messageId: messageId)
            let loadedAttachments = try await mail.attachments(messageId: messageId)
            guard token == bodyRequestToken, selectedMessageId == messageId else { return }
            body = loaded
            attachments = loadedAttachments
            inlineImages = makeInlineImages(messageID: messageId)
            await reloadMessages()
        } catch is CancellationError {
            // 选择已改变：丢弃本次结果，不报错
        } catch {
            guard token == bodyRequestToken else { return }
            report(error)
        }
    }

    private func makeInlineImages(messageID: UUID) -> MailInlineImageSource {
        let source = MailInlineImageSource(hub: hub, space: space, messageID: messageID)
        let sourceID = source.id
        source.onAttachmentsRefreshed = { [weak self] parts in
            guard let self, self.selectedMessageId == messageID, self.inlineImages?.id == sourceID else { return }
            self.attachments = parts
        }
        return source
    }

    func retryBody() async {
        guard let id = selectedMessageId, let service = hub.makeMailService(for: space) else { return }
        try? await service.setBodyState(messageId: id, state: .failed)
        bodyRequestToken += 1
        await loadBody(messageId: id, token: bodyRequestToken)
    }

    func downloadAttachment(_ attachment: MailAttachment, source: MailMessage? = nil) async -> URL? {
        let expected = source ?? messages.first { $0.id == attachment.messageId }
        let url = await attachmentQueue.request(attachment, source: expected)
        guard !Task.isCancelled else { return nil }
        if url != nil, selectedMessageId == attachment.messageId {
            do { attachments = try await hub.makeMailService(for: space)?.attachments(messageId: attachment.messageId) ?? [] }
            catch { report(error) }
        }
        return url
    }

    func reloadEditableDrafts() async {
        guard let accountID = selectedAccountId, let service = hub.makeMailService(for: space) else { editableDrafts = []; lockedDrafts = []; return }
        do {
            let drafts = try await service.drafts(accountId: accountID)
            guard accountID == selectedAccountId else { return }
            lockedDrafts = drafts.filter { $0.deliveredAt != nil || ($0.deliveryState != .none && $0.deliveryState != .prepared) }
            editableDrafts = drafts.filter { $0.deliveredAt == nil && ($0.deliveryState == .none || $0.deliveryState == .prepared) }
        } catch {
            guard accountID == selectedAccountId else { return }
            lockedDrafts = []; editableDrafts = []; report(error)
        }
    }

    // MARK: - Flags

    func toggleRead(_ message: MailMessage) async {
        guard performBatch(ids: [message.id], action: .read(!message.isRead)) else { return }
        await batchTask?.value
    }

    func toggleStar(_ message: MailMessage) async {
        guard performBatch(ids: [message.id], action: .star(!message.isStarred)) else { return }
        await batchTask?.value
    }

    // MARK: - Compose

    /// 当前账号可用的发件人展示（名称 + 地址）。
    var senderDescription: String {
        guard let account = composeAccount else { return "" }
        let address = account.emailAddress.isEmpty ? account.username : account.emailAddress
        return MailAddress(name: account.displayName, address: address).display
    }

    func senderDescription(accountID: UUID) -> String {
        guard let account = accounts.first(where: { $0.id == accountID && !$0.isLocalArchive }) else { return "" }
        return MailAddress(name: account.displayName, address: account.emailAddress.isEmpty ? account.username : account.emailAddress).display
    }

    /// 新写草稿；无选中账号时为 nil。
    func newDraft(for message: MailMessage? = nil) -> MailDraft? {
        let source = message.flatMap { original in accounts.first { $0.id == original.accountId && !$0.isLocalArchive } }
        guard let account = source ?? composeAccount else { return nil }
        return MailDraft(accountId: account.id, composeKind: .new)
    }

    var composeAccount: MailAccount? {
        if let currentAccount, !currentAccount.isLocalArchive { return currentAccount }
        return accounts.first { !$0.isLocalArchive && $0.isEnabled && !$0.smtpHost.isEmpty }
    }

    var canSync: Bool {
        isUnifiedInbox ? accounts.contains { $0.isEnabled && !$0.isLocalArchive } : (currentAccount.map { !$0.isLocalArchive } ?? false)
    }

    func showMissingSender() { errorText = L.string("mail.import.senderRequired") }

    /// 回复草稿：固定记录原邮件身份，收件人优先 `Reply-To`，主题加前缀。
    ///
    /// 引用原文与 AI 上下文都由撰写窗口按 `sourceMessageId` 读取——不再依赖详情页
    /// 当前加载的正文，因此主窗口切换选中项不会让回复读到别的邮件。
    func replyDraft(for message: MailMessage) -> MailDraft {
        MailDraft(
            accountId: accounts.first(where: { $0.id == message.accountId && !$0.isLocalArchive })?.id ?? composeAccount?.id ?? message.accountId,
            to: message.replyRecipients,
            subject: Self.prefixed(message.subject, prefix: L.string("mail.compose.replyPrefix")),
            composeKind: .reply,
            sourceMessageId: message.id,
            inReplyTo: message.messageId,
            references: Self.referenceChain(message)
        )
    }

    func replyAllDraft(for message: MailMessage) -> MailDraft {
        var draft = replyDraft(for: message)
        let account = accounts.first { $0.id == draft.accountId }
        let recipients = message.replyAllRecipients(excluding: Set([account?.emailAddress, account?.username].compactMap { $0 }))
        draft.to = recipients.to; draft.cc = recipients.cc
        return draft
    }

    /// 转发草稿：收件人留空，主题加前缀，正文引用原文（由窗口按来源读取）。
    func forwardDraft(for message: MailMessage) -> MailDraft {
        MailDraft(
            accountId: accounts.first(where: { $0.id == message.accountId && !$0.isLocalArchive })?.id ?? composeAccount?.id ?? message.accountId,
            subject: Self.prefixed(message.subject, prefix: L.string("mail.compose.forwardPrefix")),
            composeKind: .forward,
            sourceMessageId: message.id
        )
    }

    /// 删除邮件：远端删除成功后才删本地（失败保留，可重试）。
    func deleteMessage(_ message: MailMessage) async {
        guard let syncService = hub.makeMailSyncService(for: space) else { return }
        do {
            try await syncService.deleteMessage(messageId: message.id)
            deselectIfCurrent(message.id)
            await reloadMessages()
        } catch MailSyncError.deletionWouldAffectOthers {
            // 同文件夹还有别的待删邮件：不冒连带删除的风险，提示用户先处理
            errorText = L.string("mail.error.deleteBlockedByOthers")
            HubLogger.shared.warning("Mail delete aborted: other messages are marked deleted in the folder")
        } catch {
            report(error)
        }
    }

    /// 移动邮件到指定文件夹：远端 MOVE 成功后才改本地归属。
    func moveMessage(_ message: MailMessage, toFolderId folderId: UUID) async {
        guard performBatch(ids: [message.id], action: .move(folderId)) else { return }
        await batchTask?.value
    }

    // MARK: - Account Management

    func saveAccount(_ account: MailAccount, password: String?) async -> Bool {
        guard let accountService = hub.makeMailAccountService(for: space) else { return false }
        do {
            try await accountService.save(account, password: password)
            selectedAccountId = account.id
            await reloadAccounts()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteAccount(_ id: UUID) async {
        guard let accountService = hub.makeMailAccountService(for: space) else { return }
        do {
            try await accountService.delete(id: id)
            await reloadAccounts()
        } catch {
            report(error)
        }
    }

    /// 连接测试：IMAP 登录 + SMTP 连通性（供账号配置 Sheet 使用）。
    func testConnection(account: MailAccount, password: String) async -> Result<MailConnectionProbe, Error> {
        guard let accountService = hub.makeMailAccountService(for: space) else {
            return .failure(MailSyncError.accountNotFound)
        }
        // 编辑账号时密码框留空表示「沿用已保存的密码」，此处同样回落到 Keychain，
        // 否则测试会拿空密码发起认证、必然失败
        let effective = password.isEmpty ? (accountService.password(for: account.id) ?? "") : password
        return await accountService.testConnection(account: account, password: effective)
    }

    func clearError() {
        errorText = pendingErrors.isEmpty ? nil : pendingErrors.removeFirst()
    }

    // MARK: - Private

    private func clearBody() {
        focusedConversationMessageID = nil
        conversationTask?.cancel(); conversationTask = nil; conversationGeneration = UUID()
        conversationMessages = []; conversationCursor = nil; conversationPageLimit = 50; conversationHasMore = false; isLoadingConversation = false; conversationError = nil
        inlineImages?.cancelPending(); inlineImages = nil
        body = nil
        attachments = []
    }

    /// 作废并取消进行中的正文加载（切换选中项时调用）。
    private func cancelBodyLoad() {
        bodyRequestToken += 1
        bodyTask?.cancel()
        bodyTask = nil
        isLoadingBody = false
    }

    /// 当前选中邮件被删/移走后清空详情栏。
    private func deselectIfCurrent(_ messageId: UUID) {
        guard selectedMessageId == messageId else { return }
        selectedMessageId = nil
        clearBody()
    }

    /// 主题加前缀（已带同前缀时不重复叠加）。
    private static func prefixed(_ subject: String, prefix: String) -> String {
        subject.hasPrefix(prefix) ? subject : prefix + subject
    }

    /// 回复使用的 `References` 链：原邮件的 References + 被回复邮件 ID，去重并限制长度。
    ///
    /// 旧邮件缺失 `References`（尚未拉取正文）时只保留被回复邮件 ID，不影响正常回复。
    private static func referenceChain(_ message: MailMessage) -> String? {
        var ids: [String] = []
        if let references = message.references { ids.append(contentsOf: tokens(in: references)) }
        if let own = message.messageId, !own.isEmpty { ids.append(own) }

        var seen = Set<String>()
        var chain = ""
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            let candidate = chain.isEmpty ? id : chain + " " + id
            // 长度上限：References 过长对线程识别无益，且会放大请求头
            if candidate.count > 2000 { break }
            chain = candidate
        }
        return chain.isEmpty ? nil : chain
    }

    /// 从 `References` 头中提取 Message-ID 令牌（`<...>`）。
    private static func tokens(in references: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        for character in references {
            if character == "<" {
                inToken = true
                current = "<"
            } else if character == ">", inToken {
                current.append(character)
                tokens.append(current)
                current = ""
                inToken = false
            } else if inToken {
                current.append(character)
            }
        }
        return tokens
    }

    private func report(_ error: Error) {
        let text = MailErrorText.message(for: error)
        if errorText == nil { errorText = text }
        else if errorText != text && !pendingErrors.contains(text) { pendingErrors.append(text) }
        HubLogger.shared.warning("Mail UI operation failed: \(HubLogger.safeErrorSummary(error))")
    }
}

// MARK: - Display Helpers

extension MailFolderRole {
    /// 语义角色的本地化键。
    var labelKey: String {
        switch self {
        case .inbox: return "mail.folder.inbox"
        case .sent: return "mail.folder.sent"
        case .drafts: return "mail.folder.drafts"
        case .trash: return "mail.folder.trash"
        case .junk: return "mail.folder.junk"
        case .archive: return "mail.folder.archive"
        case .other: return "mail.folder.other"
        }
    }

    /// 侧栏排序权重（系统文件夹在前）。
    var sortOrder: Int {
        switch self {
        case .inbox: return 0
        case .drafts: return 1
        case .sent: return 2
        case .archive: return 3
        case .junk: return 4
        case .trash: return 5
        case .other: return 6
        }
    }
}

extension MailFolder {
    /// 展示名：语义角色优先本地化，其余用服务器文件夹名。
    @MainActor
    var displayName: String {
        role == .other ? name : L.string(role.labelKey)
    }
}

extension MailSecurity {
    var labelKey: String {
        switch self {
        case .none: return "mail.security.none"
        case .startTLS: return "mail.security.startTLS"
        case .tls: return "mail.security.tls"
        }
    }
}
