import SwiftUI
import AppKit
import AgRoomCore

// MARK: - Mail View

/// 邮箱页：三栏布局（邮箱/文件夹 · 邮件列表 · 邮件详情），栏宽可拖拽并记忆。
/// 视图模型由 RootView 按空间持有，切换页签/空间不丢状态。
struct MailView: View {
    let hub: Hub
    @State private var viewModel: MailViewModel

    /// 栏宽记忆：显示宽度在拖动期间只改这里，拖动结束才写偏好。
    /// 布局回调里写观察态（`@State` / `@AppStorage` / `@Observable`）会把窗口带进
    /// 约束更新环并 abort，理由与崩溃栈见 `SplitColumnWidth`。
    @State private var folderColumnWidth: Double
    @State private var listColumnWidth: Double
    private static let folderColumnWidthKey = "mail.layout.folderColumnWidth"
    private static let listColumnWidthKey = "mail.layout.listColumnWidth"

    /// 账号配置 Sheet（`account == nil` 表示新增）
    @State private var accountSheet: AccountSheetTarget?
    @State private var transferRequest: MailTransferRequest?
    @State private var importModel: MailImportModel?
    @State private var sourceRequest: MailSourceRequest?
    @State private var movePicker: MailMovePickerModel?
    @State private var folderManager: MailFolderManagerModel?
    @State private var presetManager: MailComposePresetManager?
    @State private var referenceError: String?
    @State private var finderDrag: MailFinderDragModel?
    /// 待删除的账号（确认后再删除）
    @State private var accountPendingDeletion: MailAccount?
    /// 待删除的邮件（确认后再删除）
    @State private var pendingDeletion: MailDeletionRequest?
    private var conversationVisible: Bool { viewModel.isConversationVisible }
    @State private var showFilters = false
    @State private var showAttachmentQueue = false
    @State private var showAutoSync = false
    @State private var unreadOnly = false
    @State private var starredOnly = false
    @State private var attachmentsOnly = false
    @State private var sender = ""
    @State private var recipient = ""
    @State private var attachmentName = ""
    @State private var includeBody = true
    @State private var searchScope: MailSearchScope = .folder
    @State private var minimumKB = 0
    @State private var maximumKB = 0
    @State private var showSaveSearch = false
    @State private var savedSearchName = ""
    @State private var searchToDelete: MailSavedSearch?
    @State private var searchBeingEdited: MailSavedSearch?
    @State private var replaceSavedConditions = false
    @State private var afterEnabled = false
    @State private var beforeEnabled = false
    @State private var afterDate = Date()
    @State private var beforeDate = Date()
    /// 工具栏搜索词：过滤所选范围内的本机邮件。
    @Environment(\.globalSearchText) private var searchText
    @Environment(\.setGlobalSearch) private var setSearchText

    init(hub: Hub, viewModel: MailViewModel) {
        self.hub = hub
        self._viewModel = State(initialValue: viewModel)
        let filter = viewModel.listFilter
        self._searchScope = State(initialValue: viewModel.searchScope)
        self._unreadOnly = State(initialValue: filter.unreadOnly); self._starredOnly = State(initialValue: filter.starredOnly)
        self._attachmentsOnly = State(initialValue: filter.attachmentsOnly); self._includeBody = State(initialValue: filter.includeBody)
        self._sender = State(initialValue: filter.sender); self._recipient = State(initialValue: filter.recipient)
        self._attachmentName = State(initialValue: filter.attachmentName)
        self._minimumKB = State(initialValue: (filter.minBytes ?? 0) / 1024); self._maximumKB = State(initialValue: (filter.maxBytes ?? 0) / 1024)
        self._afterEnabled = State(initialValue: filter.after != nil); self._beforeEnabled = State(initialValue: filter.before != nil)
        self._afterDate = State(initialValue: filter.after ?? Date())
        self._beforeDate = State(initialValue: filter.before.flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) } ?? Date())
        self._folderColumnWidth = State(
            initialValue: SplitColumnWidth.snapshot(
                key: Self.folderColumnWidthKey, defaultValue: 220, range: 180...340
            )
        )
        self._listColumnWidth = State(
            initialValue: SplitColumnWidth.snapshot(
                key: Self.listColumnWidthKey, defaultValue: 340, range: 260...460
            )
        )
    }

    var body: some View {
        Group {
            if viewModel.accounts.isEmpty {
                emptyState
            } else {
                columns
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            openImport(urls)
            return true
        }
        .task {
            await viewModel.loadIfNeeded()
            // 进入邮箱页先取一次「已投递但未归档」的残留记录
            await viewModel.reloadDeliveredDrafts()
        }
        .toolbar { toolbarContent }
        .focusedValue(\.mailMenuActions, mailMenuActions)
        .task(id: SearchInput(filter: currentFilter, scope: searchScope)) { await viewModel.updateListFilter(currentFilter, scope: searchScope) }
        .onChange(of: SearchInput(filter: viewModel.listFilter, scope: viewModel.searchScope)) { _, input in
            reflectSearch(input.filter, scope: input.scope)
        }
        .sheet(isPresented: $showSaveSearch) {
            MailSavedSearchEditor(isEditing: searchBeingEdited != nil, name: $savedSearchName, replaceConditions: $replaceSavedConditions,
                error: viewModel.searchSaveError, onCancel: { showSaveSearch = false }, onSave: {
                    let filter = currentFilter, scope = searchScope, name = savedSearchName
                    let previous = searchBeingEdited, replace = replaceSavedConditions
                    Task { if await viewModel.saveSearch(name: name, filter: filter, scope: scope, replacing: previous, updateConditions: replace) { showSaveSearch = false; savedSearchName = ""; searchBeingEdited = nil } }
                })
        }
        .alert(L.string("mail.search.saved.delete"), isPresented: Binding(get: { searchToDelete != nil }, set: { if !$0 { searchToDelete = nil } }), presenting: searchToDelete) { saved in
            Button(L.string("common.delete"), role: .destructive) { searchToDelete = nil; Task { await viewModel.deleteSearch(saved) } }
            Button(L.string("common.cancel"), role: .cancel) { searchToDelete = nil }
        } message: { saved in Text(L.format("mail.search.saved.deleteConfirm", saved.name)) }
        .sheet(item: $transferRequest) { request in
            MailTransferView(model: MailTransferModel(request: request, hub: hub, space: viewModel.sourceSpace))
        }
        .sheet(item: $importModel) { model in
            MailImportView(model: model)
        }
        .sheet(item: $sourceRequest) { request in
            MailSourceView(model: MailSourceModel(request: request, hub: hub, space: viewModel.sourceSpace))
        }
        .sheet(item: $movePicker) { model in MailMovePicker(model: model) }
        .alert(L.string("mail.batch.undo.title"), isPresented: Binding(get: { viewModel.operationUndoReview != nil },
            set: { if !$0 { viewModel.dismissOperationUndo() } }), presenting: viewModel.operationUndoReview) { review in
            Button(L.string("mail.batch.undo.confirm")) { viewModel.confirmOperationUndo(review) }
            Button(L.string("common.cancel"), role: .cancel) { viewModel.dismissOperationUndo() }
        } message: { review in
            Text(undoReviewDescription(review))
        }
        .sheet(item: $folderManager) { model in MailFolderManagerView(model: model) }
        .sheet(item: $presetManager) { model in MailComposePresetManagerView(model: model) }
        .sheet(item: $finderDrag) { model in MailFinderDragView(model: model) }
        .alert(L.string("mail.reference.title"), isPresented: Binding(get: { referenceError != nil }, set: { if !$0 { referenceError = nil } })) {
            Button(L.string("common.close"), role: .cancel) { referenceError = nil }
        } message: { Text(referenceError ?? "") }
        .onChange(of: hub.spaceStore.current) { _, space in
            if space != viewModel.sourceSpace {
                finderDrag?.close(); finderDrag = nil
                presetManager?.close(); presetManager = nil
                movePicker?.cancel(); movePicker = nil; folderManager?.cancelPendingWork(); folderManager = nil
            }
        }
        .onDisappear { movePicker?.cancel(); movePicker = nil; folderManager?.cancelPendingWork(); folderManager = nil; presetManager?.close(); presetManager = nil; finderDrag?.close(); finderDrag = nil }
        .task(id: viewModel.selectedAccountId) { await viewModel.reloadEditableDrafts() }
        .sheet(item: $accountSheet) { target in
            MailAccountConfigView(
                account: target.account,
                hasStoredPassword: target.hasStoredPassword,
                onTest: { account, password in
                    await viewModel.testConnection(account: account, password: password)
                },
                onSave: { account, password in
                    await viewModel.saveAccount(account, password: password)
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .mailDataChanged)) { _ in
            // 撰写窗口独立存在：发送/保存草稿后据此刷新列表与草稿菜单
            Task {
                await viewModel.reloadMessages()
                await viewModel.reloadEditableDrafts()
                await viewModel.reloadDeliveredDrafts()
            }
        }
        .alert(
            L.string("common.error"),
            isPresented: Binding(
                get: { viewModel.errorText != nil },
                set: { if !$0 { viewModel.clearError() } }
            ),
            presenting: viewModel.errorText
        ) { _ in
            Button(L.string("common.ok"), role: .cancel) { viewModel.clearError() }
        } message: { text in
            Text(text)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L.string("mail.account.none.title"), systemImage: "envelope.badge")
        } description: {
            Text(L.string("mail.account.none.desc"))
        } actions: {
            Button(L.string("mail.account.add")) {
                accountSheet = AccountSheetTarget(account: nil, hasStoredPassword: false)
            }
            Button(L.string("mail.import.title")) { openImport() }
        }
    }

    // MARK: - Columns

    private var columns: some View {
        VStack(spacing: 0) {
            deliveredDraftNotice
            batchStatus
            if viewModel.searchScope == .folder, let folder = viewModel.currentFolder, viewModel.folderVisibility.hidden.contains(folder.id) {
                HStack {
                    Label(L.string("mail.folder.currentHidden"), systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !viewModel.showHiddenFolders { Button(L.string("mail.folder.showHidden")) { viewModel.showHiddenFolders = true } }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            if viewModel.isUnifiedInbox {
                Text(L.string("mail.inbox.hint")).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
            }
            if viewModel.isImportBatch, let context = viewModel.importBatchContext {
                HStack {
                    Text(L.format("mail.import.batchScope", AppDate.string(from: context.createdAt))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L.string("mail.import.leaveBatch")) { Task { await viewModel.selectAccount(context.accountID) } }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            // 三栏常驻（可拖拽分隔）：邮箱/文件夹 · 邮件列表 · 邮件详情。
            // 空间不足时只压缩显示，拖动结束才写偏好
            GeometryReader { geo in
                let layout = SplitWidths.resolve(
                    available: Double(geo.size.width),
                    dividers: 2,
                    columns: [
                        SplitWidths.Column(width: folderColumnWidth, range: 180...340),
                        SplitWidths.Column(width: listColumnWidth, range: 260...460),
                        SplitWidths.Column(width: 0, range: 320...(.infinity), flexible: true)
                    ]
                )
                HStack(spacing: 0) {
                    folderColumn
                        .frame(width: CGFloat(layout[0]))

                    SplitDivider(
                        columnWidth: $folderColumnWidth,
                        range: 180...340,
                        persistKey: Self.folderColumnWidthKey,
                        direction: 1
                    )

                    VStack(spacing: 0) {
                        listControls
                        MailMessageListView(
                            messages: viewModel.messages,
                            selectedMessageIDs: viewModel.selectedMessageIDs,
                            hasMore: viewModel.hasMoreMessages,
                            isLoadingMore: viewModel.isLoadingMore,
                            onSelect: { viewModel.focusConversationMessage(nil); viewModel.setSelection($0) },
                            onToggleStar: { message in Task { await viewModel.toggleStar(message) } },
                            onLoadMore: { Task { await viewModel.loadMoreMessages() } },
                            contextMenu: { ids in AnyView(messageActions(ids: ids)) },
                            onDelete: { ids in
                                requestDeletion(viewModel.readerActionIDs.isEmpty ? ids : viewModel.readerActionIDs)
                            },
                            isFiltered: currentFilter != MailListFilter(),
                            sourceLabels: viewModel.sourceLabels, presentation: viewModel.listPresentation,
                            query: viewModel.listFilter.query, senderQuery: viewModel.listFilter.sender,
                            onReopen: { message in Task { await viewModel.markOpened(message) } }
                        )
                        .simultaneousGesture(TapGesture().onEnded { _ in viewModel.focusConversationMessage(nil) })
                    }
                    .frame(width: CGFloat(layout[1]))

                    SplitDivider(
                        columnWidth: $listColumnWidth,
                        range: 260...460,
                        persistKey: Self.listColumnWidthKey,
                        direction: 1
                    )

                    Group {
                        if viewModel.selectedMessageIDs.count > 1 {
                            ContentUnavailableView {
                                Label(L.format("mail.selection.title", viewModel.selectedMessageIDs.count), systemImage: "envelope.stack")
                            } description: {
                                Text(L.string("mail.selection.description"))
                            } actions: {
                                Menu(L.string("mail.selection.actions")) { messageActions(ids: viewModel.selectedMessageIDs) }
                            }
                        } else {
                            VStack(spacing: 0) {
                                if let anchor = viewModel.currentMessage {
                                    HStack {
                                        Button(L.string(conversationVisible ? "mail.conversation.single" : "mail.conversation.open")) { viewModel.setConversationVisible(!conversationVisible) }
                                        Spacer()
                                        if conversationVisible { Text(L.format("mail.conversation.loaded", viewModel.conversationMessages.count)).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(10)
                                    Divider()
                                    if conversationVisible {
                                        MailConversationView(hub: hub, space: viewModel.sourceSpace, anchorID: anchor.id,
                                            messages: viewModel.conversationMessages, isLoading: viewModel.isLoadingConversation,
                                            hasMore: viewModel.conversationHasMore, error: viewModel.conversationError,
                                            onMore: { viewModel.loadMoreConversation() }, onRefresh: { viewModel.refreshConversation() },
                                            onFocus: { viewModel.focusConversationMessage($0) },
                                            onExpand: { message in Task { await viewModel.markOpened(message) } },
                                            onLoaded: { viewModel.refreshConversation() }, focusedID: viewModel.focusedConversationMessageID,
                                            sourceLabel: { viewModel.sourceDescription(for: $0) },
                                            detail: { AnyView(messageDetail($0)) }, actions: { AnyView(messageActions(ids: [$0])) })
                                    } else { messageDetail(rootReaderContent) }
                                } else { messageDetail(rootReaderContent) }
                            }
                            .task(id: viewModel.selectedMessageId) { if conversationVisible { viewModel.refreshConversation(keepingLoaded: false) } }
                            .onChange(of: viewModel.selectedMessageIDs) { _, _ in viewModel.focusConversationMessage(nil) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(viewModel.isPerformingBatch)
                }
            }
        }
        .alert(
            L.string("mail.account.delete_confirm.title"),
            isPresented: Binding(
                get: { accountPendingDeletion != nil },
                set: { if !$0 { accountPendingDeletion = nil } }
            ),
            presenting: accountPendingDeletion
        ) { account in
            Button(L.string("common.delete"), role: .destructive) {
                let id = account.id
                accountPendingDeletion = nil
                Task { await viewModel.deleteAccount(id) }
            }
            Button(L.string("common.cancel"), role: .cancel) { accountPendingDeletion = nil }
        } message: { account in
            Text(L.format(account.isLocalArchive ? "mail.import.deleteConfirm" : "mail.account.delete_confirm.message", accountTitle(account)))
        }
        .alert(
            L.string(pendingDeletion?.permanent == true ? "mail.action.permanentDelete" : "mail.action.trash"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { request in
            Button(L.string(request.permanent ? "mail.action.permanentDelete" : "mail.action.trash"), role: .destructive) {
                pendingDeletion = nil
                viewModel.performBatch(ids: request.ids, action: request.permanent ? .permanentlyDelete : .moveToRole(.trash))
            }
            Button(L.string("common.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: { request in
            Text(L.format(request.permanent ? "mail.batch.delete.confirm" : "mail.batch.trash.confirm", request.ids.count))
        }
    }

    private var rootReaderContent: MailReaderContent {
        .init(message: viewModel.currentMessage, body: viewModel.body, attachments: viewModel.attachments,
              downloading: viewModel.downloadingAttachments, isLoading: viewModel.isLoadingBody,
              inlineImages: viewModel.inlineImages, onDownload: { await viewModel.downloadAttachment($0) },
              onRetry: { Task { await viewModel.retryBody() } })
    }

    private func messageDetail(_ content: MailReaderContent) -> some View {
        MailMessageDetailView(
            message: content.message,
            mailBody: content.body,
            attachments: content.attachments,
            downloadingAttachments: content.downloading.union(viewModel.attachmentQueue.pendingIDs),
            onDownload: { await viewModel.downloadAttachment($0, source: content.message) },
            onRetryBody: content.onRetry,
            isLoadingBody: content.isLoading,
            moveTargets: content.message.map { viewModel.moveTargets(for: [$0.id]) } ?? [],
            onToggleRead: { message in Task { await viewModel.toggleRead(message) } },
            onToggleStar: { message in Task { await viewModel.toggleStar(message) } },
            onReply: { message in
                openCompose(viewModel.replyDraft(for: message))
            },
            onAIReply: { message in
                openCompose(viewModel.replyDraft(for: message), showAIPanel: true)
            },
            onForward: { message in
                openCompose(viewModel.forwardDraft(for: message))
            },
            onDelete: { message in requestDeletion([message.id]) },
            onMove: { message, folderId in
                Task { await viewModel.moveMessage(message, toFolderId: folderId) }
            },
            deleteTitleKey: content.message.map { viewModel.folder(for: $0)?.role == .trash } == true ? "mail.action.permanentDelete" : "mail.action.trash",
            sourceDescription: content.message.map { viewModel.sourceDescription(for: $0) },
            preferredMoveTargets: content.message.map { viewModel.preferredMoveTargets(for: [$0.id]) } ?? [],
            inlineImages: content.inlineImages,
            onReplyAll: { message in openCompose(viewModel.replyAllDraft(for: message)) },
            onSaveAttachments: { attachments in
                guard let messageID = attachments.first?.messageId else { return }
                transferRequest = .init(content: .attachments(messageID, attachments.map(\.id)))
            },
            onComposeTo: { address in
                if var draft = viewModel.newDraft(for: content.message) { draft.to = [address]; openCompose(draft) }
            },
            onSearchAddress: { sender = $0 },
            onChooseMove: { message in openMovePicker([message.id]) },
            moveDisabledReason: content.message.flatMap { viewModel.moveBlockReason([$0.id]) },
            deleteDisabledReason: content.message.flatMap { viewModel.deleteBlockReason([$0.id]) },
            actionsDisabled: viewModel.isPerformingBatch,
            attachmentsAreLocalOnly: content.message.map { message in
                message.uid >= MailService.localUIDFloor || viewModel.accounts.first { $0.id == message.accountId }?.isLocalArchive == true
            } ?? false,
            searchQuery: viewModel.listFilter.query,
            onEnqueue: { attachment in Task { _ = await viewModel.downloadAttachment(attachment, source: content.message) } }
        )
    }

    // MARK: - Folder Column

    private var folderColumn: some View {
        VStack(spacing: 0) {
            accountHeader
            Divider()
            Button { Task { await viewModel.openUnifiedInbox() } } label: {
                HStack {
                    Image(systemName: "tray.2")
                    Text(L.string("mail.search.range.inbox")).lineLimit(1)
                    Spacer(minLength: 4)
                    if viewModel.unifiedInboxUnreadCount > 0 { Text(String(viewModel.unifiedInboxUnreadCount)).monospacedDigit() }
                }.contentShape(Rectangle()).padding(8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.isUnifiedInbox ? Color.accentColor : Color.primary)
            .background(viewModel.isUnifiedInbox ? Color.accentColor.opacity(0.12) : .clear)
            .accessibilityAddTraits(viewModel.isUnifiedInbox ? [.isSelected] : [])
            Divider()
            List(selection: folderSelection) {
                if !viewModel.favoriteFolders.isEmpty {
                    Section(L.string("mail.folder.favorites")) {
                        ForEach(viewModel.favoriteFolders) { folder in
                            folderRow(folder).tag(folder.id as UUID?)
                                .contextMenu { folderContextActions(folder) }
                        }
                    }
                }
              Section(L.string("mail.folder.all")) {
                OutlineGroup(viewModel.folderTree, children: \.children) { node in
                    folderRow(node.folder)
                        .tag(node.isContainer ? nil : node.folder.id as UUID?)
                        .contextMenu { folderContextActions(node.folder) }
                }
              }
            }
            .listStyle(.inset)
            if viewModel.hasHiddenFolders || viewModel.showHiddenFolders {
                Toggle(L.string("mail.folder.showHidden"), isOn: $viewModel.showHiddenFolders)
                    .toggleStyle(.checkbox).font(.caption).padding(10).help(L.string("mail.folder.hideHint"))
            }
            Divider()
            if viewModel.canSync, viewModel.searchScope == .folder, let folder = viewModel.currentFolder {
                MailCoverageBar(folderName: folder.displayName, coverage: viewModel.coverage, isSyncing: viewModel.isSyncing,
                    onEarlier: { viewModel.loadEarlierMail() }, onRebuild: { viewModel.rebuildCurrentFolder() })
                    .id(folder.id)
            }
            Button { openFolderManager() } label: {
                Label(L.string("mail.folder.edit.manage"), systemImage: "folder")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(10)
            }
            .buttonStyle(.plain).disabled(viewModel.currentAccount == nil)
            .accessibilityLabel(L.string("mail.folder.edit.manage"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func folderContextActions(_ folder: MailFolder) -> some View {
        let visibility = viewModel.folderVisibility
        let account = viewModel.accounts.first { $0.id == folder.accountId }
        let busy = viewModel.isPerformingBatch || (viewModel.isSyncing && account?.isLocalArchive != true)
        let editReason = MailFolderEditAvailability.reason(folder: folder, folders: viewModel.folders, account: account, busy: busy)
        Menu(L.string("mail.folder.edit.manage")) {
            Button(L.string("mail.folder.edit.newChild")) { openFolderManager(folder, action: .createChild) }
                .disabled(busy || (account?.isLocalArchive == false && (folder.delimiter?.isEmpty ?? true)))
            Button(L.string("mail.folder.edit.rename")) { openFolderManager(folder, action: .rename) }.disabled(editReason != nil)
            Button(L.string("mail.folder.edit.delete"), role: .destructive) { openFolderManager(folder, action: .delete) }.disabled(editReason != nil)
            if let editReason { Text(editReason).font(.caption).foregroundStyle(.secondary) }
            Divider()
            Button(L.string("mail.folder.edit.open")) { openFolderManager(folder) }
        }
        Divider()
        Button(L.string(visibility.explicit.contains(folder.id) ? "mail.folder.show" : "mail.folder.hide")) {
            Task { await viewModel.setHidden(!visibility.explicit.contains(folder.id), folderID: folder.id) }
        }.help(L.string("mail.folder.hideHint"))
        if let parentID = visibility.hiddenAncestor[folder.id], let parent = viewModel.folders.first(where: { $0.id == parentID }) {
            Button(L.format("mail.folder.showParent", viewModel.folderPath(parent))) {
                Task { await viewModel.setHidden(false, folderID: parentID) }
            }
        }
        Divider()
        if !folder.isContainer {
            Button(L.string(viewModel.favoriteFolderIDs.contains(folder.id) ? "mail.folder.unfavorite" : "mail.folder.favorite")) {
                let favorite = !viewModel.favoriteFolderIDs.contains(folder.id)
                Task { await viewModel.setFavorite(favorite, folderID: folder.id) }
            }
            Divider()
            if viewModel.currentAccount?.isLocalArchive == false {
                Button(L.string("mail.folder.sync")) { viewModel.syncFolder(folder.id) }.disabled(viewModel.isSyncing)
            }
            Button(L.string("mail.folder.markRead")) { Task { await viewModel.markFolderRead(folder.id) } }.disabled(viewModel.isPerformingBatch)
            Button(L.string("mail.export.folderAction")) {
                Task {
                    if let ids = await viewModel.exportIDs(folderID: folder.id) { transferRequest = .init(content: .messages(ids), scope: .folder(folder.displayName)) }
                }
            }
            Button(L.string("mail.export.folderTreeAction")) {
                Task {
                    if let ids = await viewModel.exportIDs(folderID: folder.id, includingDescendants: true) {
                        transferRequest = .init(content: .messages(ids), scope: .folderTree(folder.displayName))
                    }
                }
            }
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(viewModel.accounts) { account in
                    Button(accountMenuItemTitle(account)) {
                        Task { await viewModel.selectAccount(account.id) }
                    }
                }
                Divider()
                Button(L.string("mail.account.add")) {
                    accountSheet = AccountSheetTarget(account: nil, hasStoredPassword: false)
                }
                Button(L.string("mail.import.title")) { openImport() }
                if viewModel.currentAccount != nil { Button(L.string("mail.folder.edit.manage")) { openFolderManager() } }
                if let current = viewModel.currentAccount, !current.isLocalArchive {
                    Button(L.string("mail.account.edit")) {
                        accountSheet = AccountSheetTarget(
                            account: current,
                            hasStoredPassword: hub.makeMailAccountService()?.hasPassword(for: current.id) ?? false
                        )
                    }
                    Divider()
                    Button(L.string("mail.account.delete"), role: .destructive) {
                        accountPendingDeletion = current
                    }
                }
                if let current = viewModel.currentAccount, current.isLocalArchive {
                    Button(L.string("mail.import.deleteArchive"), role: .destructive) { accountPendingDeletion = current }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.currentAccount?.isLocalArchive == true ? "archivebox" : "envelope")
                    Text(accountTitle(viewModel.currentAccount))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 15, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .help(L.string("mail.account.switch"))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    /// 菜单项标题：当前账号加勾选前缀（macOS 菜单里勾选态最直观）
    private func accountMenuItemTitle(_ account: MailAccount) -> String {
        account.id == viewModel.selectedAccountId
            ? "✓ " + accountTitle(account)
            : accountTitle(account)
    }

    private func folderRow(_ folder: MailFolder) -> some View {
        HStack(spacing: 7) {
            Image(systemName: folderIcon(folder.role))
                .font(.system(size: 14))
                .foregroundStyle(folder.isContainer ? .tertiary : .secondary)
                .frame(width: 20)
            Text(folder.displayName)
                .font(.system(size: 15))
                .lineLimit(1)
                .foregroundStyle(folder.isContainer ? .secondary : .primary)
            Spacer(minLength: 4)
            if viewModel.folderVisibility.hidden.contains(folder.id) {
                Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary).help(L.string("mail.folder.hidden"))
            }
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(viewModel.folderPath(folder))
        // 容器节点不可选（\Noselect），选中会让中栏展示空消息列表
        .opacity(folder.isContainer ? 0.6 : 1)
    }

    private var folderSelection: Binding<UUID?> {
        Binding(
            get: { viewModel.isUnifiedInbox || viewModel.isImportBatch ? nil : viewModel.selectedFolderId },
            set: { id in Task { await viewModel.selectFolder(id) } }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { openImport() } label: { Label(L.string("mail.import.title"), systemImage: "square.and.arrow.down") }
            Menu {
                Button(L.string("mail.export.selected")) {
                    transferRequest = .init(content: .messages(viewModel.selectedMessageIDs.sorted { $0.uuidString < $1.uuidString }))
                }.disabled(viewModel.selectedMessageIDs.isEmpty)
                Button(L.string("mail.export.allResults")) {
                    let scope = viewModel.searchScope
                    Task { if let ids = await viewModel.exportSearchIDs() { transferRequest = .init(content: .messages(ids), scope: .query(scope)) } }
                }.disabled(viewModel.messages.isEmpty)
            } label: { Label(L.string("mail.export.title"), systemImage: "square.and.arrow.up") }
                .disabled(viewModel.isPerformingBatch)
            Menu {
                if viewModel.editableDrafts.isEmpty { Text(L.string("product.mail.drafts.empty")) }
                ForEach(viewModel.editableDrafts) { draft in
                    Button(draft.subject.isEmpty ? L.string("mail.noSubject") : draft.subject) {
                        openCompose(draft)
                    }
                }
                if !viewModel.lockedDrafts.isEmpty {
                    Divider()
                    Text(L.string("product.mail.verifyDelivery"))
                    ForEach(viewModel.lockedDrafts) { draft in
                        Button(draft.subject.isEmpty ? L.string("mail.noSubject") : draft.subject) {
                            openCompose(draft)
                        }
                    }
                }
            } label: { Label(L.string("product.mail.drafts"), systemImage: "doc.text") }

            Button {
                guard let draft = viewModel.newDraft() else { return }
                openCompose(draft)
            } label: {
                Label(L.string("mail.action.compose"), systemImage: "square.and.pencil")
            }
            .disabled(viewModel.composeAccount == nil)
            .help(L.string("mail.action.compose"))

            if viewModel.isSyncing {
                // 同步可能很久（首次同步大账号）：显示逐文件夹进度并可取消
                ProgressView()
                    .controlSize(.small)
                    .help(syncProgressText)
                if viewModel.syncProgress.total > 0 {
                    Text(syncProgressText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Button {
                    viewModel.cancelSync()
                } label: {
                    Label(L.string("common.cancel"), systemImage: "stop.circle")
                }
                .help(L.string("mail.sync.cancel"))
            } else {
                Button {
                    viewModel.startSync()
                } label: {
                    Label(L.string("mail.sync.refresh"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!viewModel.canSync)
                .help(L.string("mail.sync.refresh"))
            }
        }
    }

    // MARK: - Helpers

    /// 已投递但本地未归档的草稿提示。
    ///
    /// 这类残留是「投递成功 + 本地落库失败」的证据：必须让用户看到明确结论，
    /// 而不是把它当成一封可以再发一次的普通草稿（重发会重复投递）。
    @ViewBuilder
    private var deliveredDraftNotice: some View {
        if let draft = viewModel.deliveredDrafts.first {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "paperplane.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.string("mail.deliveredPending.title"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(L.format(
                        "mail.deliveredPending.message",
                        draft.subject.isEmpty ? L.string("mail.compose.subject.empty") : draft.subject
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // 核实入口：投递时间 / 收件人 / Message-ID，供用户到服务器「已发送」比对
                    if let deliveredAt = draft.deliveredAt {
                        Text(L.format("mail.deliveredPending.sentAt", AppDate.string(from: deliveredAt)))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if !draft.to.isEmpty {
                        Text(L.format(
                            "mail.deliveredPending.recipients",
                            draft.to.map(\.address).joined(separator: ", ")
                        ))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    }
                    if let messageId = draft.deliveredMessageId {
                        Text(L.format("mail.deliveredPending.messageId", messageId))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                Button(L.string("mail.deliveredPending.dismiss")) {
                    Task { await viewModel.discardDeliveredDraft(id: draft.id) }
                }
                .font(.system(size: 10))
                .help(L.string("mail.deliveredPending.dismiss.help"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    /// 同步进度文案（已完成 / 总数）。
    private var syncProgressText: String {
        let progress = viewModel.syncProgress
        guard progress.total > 0 else { return L.string("mail.sync.syncing") }
        return L.format(viewModel.isUnifiedSync ? "mail.inbox.syncProgress" : "mail.sync.progress", progress.done, progress.total)
    }

    /// 可移动目标：当前账号下的可邮件文件夹，排除邮件自身所在文件夹与容器节点。
    private var moveTargets: [MailFolder] {
        guard let message = viewModel.currentMessage else { return [] }
        return viewModel.folders.filter { $0.accountId == message.accountId && $0.id != message.folderId && !$0.isContainer }
    }

    private var currentFilter: MailListFilter {
        .init(query: searchText, unreadOnly: unreadOnly, starredOnly: starredOnly,
              attachmentsOnly: attachmentsOnly, sender: sender,
              after: afterEnabled ? Calendar.current.startOfDay(for: afterDate) : nil,
              before: beforeEnabled ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: beforeDate)) : nil,
              includeBody: includeBody, recipient: recipient, attachmentName: attachmentName,
              minBytes: minimumKB > 0 ? min(minimumKB, Int.max / 1024) * 1024 : nil,
              maxBytes: maximumKB > 0 ? min(maximumKB, Int.max / 1024) * 1024 : nil)
    }

    /// 仅统计浮层中的附加条件；搜索词和列表范围由各自入口呈现。
    private var activeFilterCount: Int {
        let filter = currentFilter
        return [filter.unreadOnly, filter.starredOnly, filter.attachmentsOnly, !filter.includeBody,
                !filter.sender.isEmpty, !filter.recipient.isEmpty, !filter.attachmentName.isEmpty,
                filter.minBytes != nil, filter.maxBytes != nil, filter.after != nil, filter.before != nil]
            .filter { $0 }.count
    }

    private var listControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { showFilters.toggle() } label: {
                    HStack(spacing: 5) {
                        Label(L.string("mail.filter"), systemImage: activeFilterCount > 0
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        if activeFilterCount > 0 {
                            Text(String(activeFilterCount)).font(MeetTypography.caption).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    .frame(minHeight: 22).fixedSize()
                }
                    .buttonStyle(.bordered).tint(activeFilterCount > 0 || showFilters ? .accentColor : .secondary)
                    .help(L.string("mail.filter.title"))
                    .accessibilityLabel(L.string("mail.filter.title"))
                    .accessibilityValue(L.format("mail.filter.activeCount", activeFilterCount))
                    .accessibilityIdentifier("mail.filters")
                    .popover(isPresented: $showFilters, arrowEdge: .bottom) { filterForm }
                ViewThatFits(in: .horizontal) {
                    savedSearchMenu(compact: false).fixedSize()
                    savedSearchMenu(compact: true).fixedSize()
                }
                Spacer(minLength: 0)
                Button { showAttachmentQueue.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: viewModel.attachmentQueue.hasFailures ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.circle")
                        if viewModel.attachmentQueue.activeCount > 0 { Text(String(viewModel.attachmentQueue.activeCount)) }
                    }.foregroundStyle(viewModel.attachmentQueue.hasFailures ? Color.orange : Color.secondary)
                        .frame(minWidth: 24, minHeight: 28)
                }.help(L.string("mail.downloads.title")).accessibilityLabel(L.string("mail.downloads.title"))
                    .buttonStyle(.borderless).fixedSize()
                    .popover(isPresented: $showAttachmentQueue) { MailAttachmentQueueView(model: viewModel.attachmentQueue) }
                Button { showAutoSync.toggle() } label: {
                    Image(systemName: viewModel.autoSync.isSyncing ? "arrow.triangle.2.circlepath" : "clock.arrow.circlepath")
                        .frame(width: 24, height: 28)
                }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(L.string("mail.autoSync.title")).accessibilityLabel(L.string("mail.autoSync.title"))
                    .popover(isPresented: $showAutoSync) { MailAutoSyncSettingsView(model: viewModel.autoSync) }
                Menu {
                    Picker(L.string("mail.list.order"), selection: presentationBinding(\.order)) {
                        ForEach(MailListOrder.allCases, id: \.self) { Text(L.string("mail.list.order." + $0.rawValue)).tag($0) }
                    }
                    Picker(L.string("mail.list.snippetLines"), selection: presentationBinding(\.snippetLines)) {
                        ForEach(0...4, id: \.self) { Text(L.format("mail.list.lines", $0)).tag($0) }
                    }
                    Picker(L.string("mail.list.density"), selection: presentationBinding(\.density)) {
                        ForEach(MailListDensity.allCases, id: \.self) { Text(L.string("mail.list.density." + $0.rawValue)).tag($0) }
                    }
                    Divider()
                    Button(L.string("mail.presets.manage")) { presetManager = .init(hub: hub, space: viewModel.sourceSpace) }
                } label: { Image(systemName: "list.bullet.rectangle").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary).accessibilityLabel(L.string("mail.list.presentation"))
                    .help(L.string("mail.list.presentation")).disabled(viewModel.isPerformingBatch)
            }
            HStack(spacing: 6) {
                Text(L.string("mail.search.range." + searchScope.rawValue))
                    .lineLimit(1).truncationMode(.tail)
                    .help(L.string("mail.search.scope"))
                Spacer(minLength: 0)
                if !viewModel.selectedMessageIDs.isEmpty {
                    Menu { messageActions(ids: viewModel.selectedMessageIDs) } label: {
                        Text(L.format("mail.selection.count", viewModel.selectedMessageIDs.count))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(viewModel.isPerformingBatch)
                } else if activeFilterCount > 0 {
                    Button(L.string("mail.filter.reset"), action: resetFilters)
                        .buttonStyle(.borderless).help(L.string("mail.filter.reset"))
                }
            }
            .font(MeetTypography.caption).foregroundStyle(.secondary)
        }
        .font(MeetTypography.secondary).controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func savedSearchMenu(compact: Bool) -> some View {
        Menu {
            if viewModel.savedSearches.isEmpty {
                Text(L.string("mail.search.saved.empty"))
            }
            ForEach(viewModel.savedSearches) { saved in Button(saved.name) { applySavedSearch(saved) } }
            Divider()
            Button(L.string("mail.search.saved.save")) { viewModel.clearSearchSaveError(); searchBeingEdited = nil; replaceSavedConditions = false; savedSearchName = ""; showSaveSearch = true }
            Menu(L.string("mail.search.saved.manage")) {
                ForEach(viewModel.savedSearches) { saved in
                    Menu(saved.name) {
                        Button(L.string("mail.search.saved.edit")) { viewModel.clearSearchSaveError(); searchBeingEdited = saved; replaceSavedConditions = false; savedSearchName = saved.name; showSaveSearch = true }
                        Button(L.string("mail.search.saved.delete"), role: .destructive) { searchToDelete = saved }
                    }
                }
            }.disabled(viewModel.savedSearches.isEmpty)
        } label: {
            if compact {
                Image(systemName: "bookmark").frame(minHeight: 28)
            } else {
                Label(L.string("mail.search.saved.title"), systemImage: "bookmark")
                    .labelStyle(.titleAndIcon).frame(minHeight: 28)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).foregroundStyle(.secondary)
        .help(L.string("mail.search.saved.title")).accessibilityLabel(L.string("mail.search.saved.title"))
        .accessibilityIdentifier("mail.savedFilters")
    }

    private func presentationBinding<Value>(_ key: WritableKeyPath<MailListPresentation, Value>) -> Binding<Value> {
        Binding(get: { viewModel.listPresentation[keyPath: key] }, set: { value in
            var presentation = viewModel.listPresentation; presentation[keyPath: key] = value
            Task { await viewModel.updateListPresentation(presentation) }
        })
    }

    private var filterForm: some View {
        MailFilterPopover(availableScopes: viewModel.availableSearchScopes, scope: $searchScope,
            includeBody: $includeBody, unreadOnly: $unreadOnly, starredOnly: $starredOnly,
            attachmentsOnly: $attachmentsOnly, sender: $sender, recipient: $recipient,
            attachmentName: $attachmentName, minimumKB: $minimumKB, maximumKB: $maximumKB,
            afterEnabled: $afterEnabled, beforeEnabled: $beforeEnabled, afterDate: $afterDate, beforeDate: $beforeDate,
            activeCount: activeFilterCount, onReset: resetFilters, onDone: { showFilters = false })
    }

    private func resetFilters() {
        unreadOnly = false; starredOnly = false; attachmentsOnly = false
        sender = ""; recipient = ""; attachmentName = ""; minimumKB = 0; maximumKB = 0
        includeBody = true; afterEnabled = false; beforeEnabled = false
    }

    @ViewBuilder
    private func messageActions(ids: Set<UUID>) -> some View {
        if !ids.isEmpty {
            let read = viewModel.readTargets(true, in: ids)
            let unread = viewModel.readTargets(false, in: ids)
            let star = viewModel.starTargets(true, in: ids)
            let unstar = viewModel.starTargets(false, in: ids)
            let archiveReason = viewModel.roleBlockReason(.archive, ids: ids)
            let moveReason = viewModel.moveBlockReason(ids)
            let deleteReason = viewModel.deleteBlockReason(ids)
            let inTrash = viewModel.allInTrash(ids)
            let restoreReason = inTrash ? viewModel.roleBlockReason(.inbox, ids: ids) : nil
            let archiveTitle = menuActionTitle("mail.action.archive", count: ids.count, selection: ids.count)
            let moveTitle = menuActionTitle("mail.move.title", count: ids.count, selection: ids.count)
            let restoreTitle = menuActionTitle("mail.action.restoreInbox", count: ids.count, selection: ids.count)
            let deleteKey = inTrash ? "mail.action.permanentDelete" : "mail.action.trash"
            let deleteTitle = menuActionTitle(deleteKey, count: ids.count, selection: ids.count)
            let unavailable = unavailableGroups([(moveTitle, moveReason), (archiveTitle, archiveReason),
                (restoreTitle, restoreReason), (deleteTitle, deleteReason)])
            if ids.count > 1 {
                Text(L.format("mail.selection.count", ids.count))
                Divider()
            }
            Group {
                if ids.count == 1, let id = ids.first, let message = viewModel.messageForActions(id) {
                    Button(L.string("mail.action.reply")) { openCompose(viewModel.replyDraft(for: message)) }
                    Button(L.string("mail.action.replyAll")) { openCompose(viewModel.replyAllDraft(for: message)) }
                    Button(L.string("mail.action.forward")) { openCompose(viewModel.forwardDraft(for: message)) }
                    if viewModel.searchScope != .folder || viewModel.selectedFolderId != message.folderId {
                        Button(L.string("mail.action.showInFolder")) { Task { await viewModel.openSearchSource(id, isCurrent: { true }) } }
                    }
                    Divider()
                }
                if !read.isEmpty { Button(menuActionTitle("mail.action.markRead", count: read.count, selection: ids.count)) { viewModel.performBatch(ids: read, action: .read(true)) } }
                if !unread.isEmpty { Button(menuActionTitle("mail.action.markUnread", count: unread.count, selection: ids.count)) { viewModel.performBatch(ids: unread, action: .read(false)) } }
                if !star.isEmpty { Button(menuActionTitle("mail.action.star", count: star.count, selection: ids.count)) { viewModel.performBatch(ids: star, action: .star(true)) } }
                if !unstar.isEmpty { Button(menuActionTitle("mail.action.unstar", count: unstar.count, selection: ids.count)) { viewModel.performBatch(ids: unstar, action: .star(false)) } }
                Divider()
                Button(moveTitle) { openMovePicker(ids) }
                    .disabled(moveReason != nil).help(moveReason ?? moveTitle)
                if !viewModel.preferredMoveTargets(for: ids).isEmpty {
                    Menu(L.string("mail.move.quickTargets")) {
                        ForEach(Array(viewModel.preferredMoveTargets(for: ids).prefix(5))) { folder in
                            Button(MailFolderPath.display(folder, isLocalArchive: viewModel.accounts.first { $0.id == folder.accountId }?.isLocalArchive == true)) {
                                openMovePicker(ids, preferredID: folder.id)
                            }
                        }
                    }.disabled(moveReason != nil).help(moveReason ?? moveTitle)
                }
                Button(archiveTitle) { viewModel.performBatch(ids: ids, action: .moveToRole(.archive)) }
                    .disabled(archiveReason != nil).help(archiveReason ?? archiveTitle)
                if inTrash {
                    Button(restoreTitle) { viewModel.performBatch(ids: ids, action: .moveToRole(.inbox)) }
                        .disabled(restoreReason != nil).help(restoreReason ?? restoreTitle)
                }
                Button(deleteTitle, role: .destructive) {
                    requestDeletion(ids)
                }.disabled(deleteReason != nil).help(deleteReason ?? deleteTitle)
                Divider()
                Button(menuActionTitle("mail.export.title", count: ids.count, selection: ids.count)) {
                    transferRequest = .init(content: .messages(ids.sorted { $0.uuidString < $1.uuidString }))
                }
                if ids.count == 1, let id = ids.first, let message = viewModel.messageForActions(id) {
                    messageMoreActions(message)
                }
            }
            .disabled(viewModel.isPerformingBatch)
            if !unavailable.isEmpty {
                Menu(L.string("mail.action.unavailable.title")) {
                    ForEach(unavailable) { group in
                        Section {
                            Text(group.reason)
                        } header: { Text(group.actions.joined(separator: " · ")) }
                    }
                }
            }
        }
    }

    private func messageMoreActions(_ message: MailMessage) -> some View {
        Menu(L.string("mail.action.more")) {
            Button(L.string("mail.drag.title")) { finderDrag = .init(message: message, hub: hub, space: viewModel.sourceSpace) }
            Button(L.string("mail.action.aiReply")) { openCompose(viewModel.replyDraft(for: message), showAIPanel: true) }
            Divider()
            Menu(L.string("mail.action.copy")) {
                Button(L.string("mail.copy.sender")) { copy(message.fromAddress) }
                Button(L.string("mail.copy.subject")) { copy(message.subject) }
                if let messageID = message.messageId { Button(L.string("mail.copy.messageID")) { copy(messageID) } }
                Button(L.string("mail.reference.copy")) {
                    let space = viewModel.sourceSpace
                    Task {
                        do {
                            let reference = MailSourceReference(message: message, space: space)
                            guard let mail = hub.makeMailService(for: space) else { throw MailSourceReferenceError.missing }
                            _ = try await mail.resolveSourceReference(reference, in: space)
                            guard hub.spaceStore.current == space, !Task.isCancelled else { return }
                            copy(reference.url.absoluteString)
                        } catch { if hub.spaceStore.current == space { referenceError = MailErrorText.message(for: error) } }
                    }
                }
            }
            Button(L.string("mail.search.sender")) { sender = message.fromAddress }
            if viewModel.searchScope == .folder && viewModel.selectedFolderId == message.folderId {
                Button(L.string("mail.action.showInFolder")) { Task { await viewModel.openSearchSource(message.id, isCurrent: { true }) } }
            }
            Divider()
            Button(L.string("mail.source.headers")) { sourceRequest = .init(messageID: message.id, headersOnly: true) }
            Button(L.string("mail.source.original")) { sourceRequest = .init(messageID: message.id, headersOnly: false) }
        }
    }

    private struct UnavailableMenuGroup: Identifiable {
        var id: String { reason }
        let reason: String
        var actions: [String]
    }

    private func unavailableGroups(_ issues: [(String, String?)]) -> [UnavailableMenuGroup] {
        issues.reduce(into: []) { groups, issue in
            guard let reason = issue.1 else { return }
            if let index = groups.firstIndex(where: { $0.reason == reason }) { groups[index].actions.append(issue.0) }
            else { groups.append(.init(reason: reason, actions: [issue.0])) }
        }
    }

    private func menuActionTitle(_ key: String, count: Int, selection: Int) -> String {
        selection > 1 ? L.format("mail.action.affectedCount", L.string(key), count) : L.string(key)
    }

    private var mailMenuActions: MailMenuActions {
        let message = viewModel.readerActionMessage
        let ids = viewModel.readerActionIDs
        let busy = viewModel.isPerformingBatch
        return MailMenuActions(
            compose: viewModel.composeAccount == nil ? nil : { if let draft = viewModel.newDraft() { openCompose(draft) } },
            reply: message == nil || busy ? nil : { if let message { openCompose(viewModel.replyDraft(for: message)) } },
            replyAll: message == nil || busy ? nil : { if let message { openCompose(viewModel.replyAllDraft(for: message)) } },
            forward: message == nil || busy ? nil : { if let message { openCompose(viewModel.forwardDraft(for: message)) } },
            archive: viewModel.roleBlockReason(.archive, ids: ids) != nil ? nil : { viewModel.performBatch(ids: ids, action: .moveToRole(.archive)) },
            trash: viewModel.deleteBlockReason(ids) != nil ? nil : { requestDeletion(ids) },
            sync: viewModel.isSyncing || !viewModel.canSync ? nil : { viewModel.startSync() },
            export: ids.isEmpty || busy ? nil : { transferRequest = .init(content: .messages(ids.sorted { $0.uuidString < $1.uuidString })) },
            importMail: { openImport() },
            trashTitleKey: viewModel.allInTrash(ids) ? "mail.action.permanentDelete" : "mail.action.trash",
            move: viewModel.moveBlockReason(ids) == nil ? { openMovePicker(ids) } : nil,
            archiveUnavailableReason: viewModel.roleBlockReason(.archive, ids: ids),
            trashUnavailableReason: viewModel.deleteBlockReason(ids),
            moveUnavailableReason: viewModel.moveBlockReason(ids),
            manageFolders: viewModel.currentAccount == nil ? nil : { openFolderManager() }
        )
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        guard !ids.isEmpty, !viewModel.isPerformingBatch else { return }
        let permanent = viewModel.allInTrash(ids)
        guard permanent || viewModel.hasTarget(.trash, ids: ids) else { viewModel.showMissingFolderError(); return }
        pendingDeletion = MailDeletionRequest(ids: ids, permanent: permanent)
    }

    private func applySavedSearch(_ saved: MailSavedSearch) {
        Task { _ = await viewModel.applySearch(saved) }
    }

    private func reflectSearch(_ filter: MailListFilter, scope: MailSearchScope) {
            if filter.query != searchText { setSearchText(filter.query) }
            searchScope = scope
            unreadOnly = filter.unreadOnly; starredOnly = filter.starredOnly; attachmentsOnly = filter.attachmentsOnly
            sender = filter.sender; recipient = filter.recipient; attachmentName = filter.attachmentName; includeBody = filter.includeBody
            minimumKB = (filter.minBytes ?? 0) / 1024; maximumKB = (filter.maxBytes ?? 0) / 1024
            afterEnabled = filter.after != nil; beforeEnabled = filter.before != nil
            if let date = filter.after { afterDate = date }
            if let date = filter.before { beforeDate = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private var batchStatus: some View {
        if viewModel.isPerformingBatch {
            HStack {
                ProgressView().controlSize(.small)
                Text(L.format("mail.batch.progress", viewModel.batchProgress.done, viewModel.batchProgress.total))
                Spacer()
                Button(L.string("common.cancel")) { viewModel.cancelBatch() }
            }.padding(8)
        } else if let result = viewModel.batchResult {
            HStack {
                Text(L.format("mail.batch.result", result.succeeded.count, result.failures.count, result.unprocessed.count))
                if !result.failures.isEmpty {
                    Menu(L.string("mail.batch.details")) {
                        ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                            Text(MailErrorText.message(for: failure.error))
                        }
                        if viewModel.batchAction?.allowsDirectRetry != true { Text(L.string("mail.batch.verify")) }
                    }
                }
                Spacer()
                if !result.succeeded.isEmpty {
                    Button(L.string("mail.batch.reveal")) { Task { await viewModel.revealBatchSuccess() } }
                }
                if result.undoReceipt != nil {
                    Button(L.string("mail.batch.undo.title")) { viewModel.prepareOperationUndo() }
                }
                if viewModel.batchAction?.allowsDirectRetry == true && (!result.failures.isEmpty || !result.unprocessed.isEmpty) {
                    Button(L.string("mail.batch.retry")) { viewModel.retryBatchFlags() }
                }
                Button(L.string("common.close")) { viewModel.dismissBatchResult() }
            }.font(MeetTypography.caption).padding(8)
        }
    }

    /// 打开独立撰写窗口：窗口固定绑定当前空间与账号，与主窗口选中项解耦。
    ///
    /// 同一草稿再次打开只会激活已有窗口（去重由协调器按 `(space, draftID)` 完成）。
    private func openImport(_ urls: [URL] = []) {
        let model = MailImportModel(hub: hub, space: viewModel.sourceSpace,
            archiveID: viewModel.currentAccount?.isLocalArchive == true ? viewModel.selectedAccountId : nil)
        model.onImported = { [weak model] id in
            await viewModel.reloadAccounts()
            if let batch = model?.batch {
                await viewModel.openImportBatch(archiveID: id, batchID: batch.id, isCurrent: { hub.spaceStore.current == viewModel.sourceSpace })
            }
        }
        model.onRevealMessage = { id in
            guard await viewModel.openSearchSource(id, isCurrent: { hub.spaceStore.current == viewModel.sourceSpace }) else { return false }
            importModel = nil; return true
        }
        model.onRevealBatch = { context in
            guard await viewModel.openImportBatch(archiveID: context.accountID, batchID: context.id,
                isCurrent: { hub.spaceStore.current == viewModel.sourceSpace }) else { return false }
            importModel = nil; return true
        }
        if !urls.isEmpty { model.readFiles(urls) }
        importModel = model
    }

    private func undoChangeDescription(_ change: MailOperationUndoReview.Change) -> String {
        switch change.action {
        case .read(let value): L.string(value ? "mail.action.markRead" : "mail.action.markUnread")
        case .star(let value): L.string(value ? "mail.action.star" : "mail.action.unstar")
        case .move: L.format("mail.move.to", change.destination ?? "")
        case .moveToRole(let role): L.string(role.labelKey)
        case .permanentlyDelete: L.string("mail.action.permanentDelete")
        }
    }

    private func undoReviewDescription(_ review: MailOperationUndoReview) -> String {
        var lines = [L.format("mail.batch.undo.message", review.count, review.skipped)]
        lines += review.changes.prefix(5).map { String($0.title.prefix(160)) + " · " + undoChangeDescription($0) }
        if review.count > 5 { lines.append(L.format("mail.batch.undo.more", review.count - 5)) }
        return lines.joined(separator: "\n\n")
    }

    private func openMovePicker(_ ids: Set<UUID>, preferredID: UUID? = nil) {
        guard viewModel.moveBlockReason(ids) == nil else { return }
        movePicker = MailMovePickerModel(hub: hub, space: viewModel.sourceSpace, messageIDs: ids, preferredID: preferredID) { review, destination in
            guard hub.spaceStore.current == viewModel.sourceSpace, !viewModel.isPerformingBatch else { return false }
            return viewModel.performBatch(ids: Set(review.messages.map(\.id)), action: .move(destination), moveReview: review)
        }
    }

    private func openFolderManager(_ folder: MailFolder? = nil, action: MailFolderManagerAction = .manage) {
        guard hub.spaceStore.current == viewModel.sourceSpace,
              let accountID = folder?.accountId ?? viewModel.selectedAccountId,
              let account = viewModel.accounts.first(where: { $0.id == accountID }) else { return }
        folderManager = MailFolderManagerModel(hub: hub, space: viewModel.sourceSpace, accountID: accountID,
            folderID: folder?.id ?? viewModel.selectedFolderId, initialAction: action,
            externalBusy: { viewModel.isPerformingBatch || (viewModel.isSyncing && !account.isLocalArchive) },
            onChanged: { await viewModel.reloadFolders() })
    }

    private func openCompose(_ draft: MailDraft, showAIPanel: Bool = false) {
        guard viewModel.accounts.contains(where: { $0.id == draft.accountId && !$0.isLocalArchive }) else {
            viewModel.showMissingSender(); return
        }
        MailComposeWindowCoordinator.shared.open(
            draft: draft,
            space: viewModel.sourceSpace,
            hub: hub,
            fromDescription: viewModel.senderDescription(accountID: draft.accountId),
            showAIPanel: showAIPanel
        )
    }

    private func accountTitle(_ account: MailAccount?) -> String {
        guard let account else { return L.string("mail.account.add") }
        if !account.displayName.isEmpty { return account.displayName }
        if !account.emailAddress.isEmpty { return account.emailAddress }
        return account.username
    }

    private func folderIcon(_ role: MailFolderRole) -> String {
        switch role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc.text"
        case .trash: return "trash"
        case .junk: return "exclamationmark.octagon"
        case .archive: return "archivebox"
        case .other: return "folder"
        }
    }
}

// MARK: - Account Sheet Target

/// Sheet 目标：同时承载「新增（account == nil）」与「编辑」两种入口。
private struct AccountSheetTarget: Identifiable {
    let id = UUID()
    let account: MailAccount?
    let hasStoredPassword: Bool
}

private struct MailDeletionRequest {
    let ids: Set<UUID>
    let permanent: Bool
}

private struct SearchInput: Equatable {
    let filter: MailListFilter
    let scope: MailSearchScope
}

struct MailSavedSearchEditor: View {
    let isEditing: Bool
    @Binding var name: String
    @Binding var replaceConditions: Bool
    let error: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string(isEditing ? "mail.search.saved.edit" : "mail.search.saved.save")).font(.headline)
            TextField(L.string("mail.search.saved.name"), text: $name)
            if isEditing {
                Toggle(L.string("mail.search.saved.replaceConditions"), isOn: $replaceConditions)
                Text(L.string("mail.search.saved.editHint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L.string("common.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L.string("common.save"), action: onSave)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360)
    }
}
