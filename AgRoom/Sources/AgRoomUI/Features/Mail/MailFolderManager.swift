import Foundation
import Observation
import SwiftUI
import AgRoomCore

enum MailFolderManagerAction { case manage, createChild, rename, delete }

@MainActor
enum MailFolderEditAvailability {
    static func reason(folder: MailFolder?, folders: [MailFolder], account: MailAccount?, busy: Bool) -> String? {
        if busy { return L.string("mail.folder.edit.busy") }
        guard let account, let folder, folder.accountId == account.id else { return L.string("mail.folder.edit.select") }
        if !account.isLocalArchive && !account.isEnabled { return L.string("mail.error.accountDisabled") }
        var paths: Set<String> = [folder.path], changed = true
        while changed {
            changed = false
            for child in folders where child.accountId == account.id && child.parentPath.map(paths.contains) == true {
                if paths.insert(child.path).inserted { changed = true }
            }
        }
        if folders.contains(where: { $0.accountId == account.id && paths.contains($0.path) && ($0.role != .other || $0.path.caseInsensitiveCompare("INBOX") == .orderedSame) }) {
            return L.string("mail.folder.edit.error.protectedFolder")
        }
        return nil
    }
}

@MainActor @Observable
final class MailFolderEditDraft: Identifiable {
    let id = UUID()
    let kind: MailFolderMutationKind
    let folderID: UUID?
    let parentID: UUID?
    var name: String
    fileprivate(set) var review: MailFolderOperationReview?
    fileprivate(set) var error: String?
    init(kind: MailFolderMutationKind, folderID: UUID? = nil, parentID: UUID? = nil, name: String = "") {
        self.kind = kind; self.folderID = folderID; self.parentID = parentID; self.name = name
    }
}

@MainActor @Observable
final class MailFolderManagerModel: Identifiable {
    let id = UUID()
    let accountID: UUID
    let space: AppSpace
    private let hub: Hub
    private let externalBusy: @MainActor () -> Bool
    private let onChanged: @MainActor () async -> Void
    private let initialAction: MailFolderManagerAction
    private var initialActionConsumed = false
    private var isActive = true
    private var operationTask: Task<Void, Never>?
    private var operationTicket = UUID()
    private var operationEditorID: UUID?
    private var loadTicket = UUID()
    var makeOperations: @MainActor () -> MailFolderOperationService?
    private(set) var account: MailAccount?
    private(set) var folders: [MailFolder] = []
    private(set) var preferences: [MailFolderPreference] = []
    private(set) var history: [MailFolderMutationRecord] = []
    private(set) var pending: MailFolderMutationRecord?
    private(set) var editor: MailFolderEditDraft?
    private(set) var recovery: MailFolderRecoveryReview?
    private(set) var result: MailFolderMutationRecord?
    private(set) var error: String?
    private(set) var historyError: String?
    private(set) var isBusy = false
    private(set) var isLoading = false
    private(set) var progress = (done: 0, total: 0)
    private(set) var activityKey = "mail.folder.edit.checking"
    var selectedID: UUID?
    var query = "" { didSet { if let selectedID, !filteredFolders.contains(where: { $0.id == selectedID }) { self.selectedID = nil } } }
    var resetAcknowledged = false

    init(hub: Hub, space: AppSpace, accountID: UUID, folderID: UUID? = nil, initialAction: MailFolderManagerAction = .manage,
         externalBusy: @escaping @MainActor () -> Bool = { false }, onChanged: @escaping @MainActor () async -> Void = {}) {
        self.hub = hub; self.space = space; self.accountID = accountID; selectedID = folderID; self.initialAction = initialAction
        self.externalBusy = externalBusy; self.onChanged = onChanged
        makeOperations = { hub.makeMailSyncService(for: space)?.folderOperations() }
    }

    var accountTitle: String { account.map { $0.displayName.isEmpty ? ($0.emailAddress.isEmpty ? $0.username : $0.emailAddress) : $0.displayName } ?? "" }
    var selected: MailFolder? { folders.first { $0.id == selectedID } }
    var visibility: MailFolderSidebarState { .init(folders: folders, preferences: preferences) }
    func path(_ folder: MailFolder) -> String { MailFolderPath.display(folder, isLocalArchive: account?.isLocalArchive == true) }
    var filteredFolders: [MailFolder] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return folders.filter { folder in terms.allSatisfy { folder.displayName.localizedStandardContains($0) || path(folder).localizedStandardContains($0) } }
            .sorted { path($0).localizedStandardCompare(path($1)) == .orderedAscending }
    }
    var busy: Bool { isBusy || isLoading }
    var commitBlocked: Bool { !isActive || busy || externalBusy() || pending != nil }
    var createReason: String? {
        if !isActive { return L.string("mail.folder.edit.error.unavailable") }
        if busy || externalBusy() { return L.string("mail.folder.edit.busy") }
        if pending != nil { return L.string("mail.folder.edit.error.pending") }
        guard let account else { return L.string("mail.folder.edit.error.unavailable") }
        return !account.isLocalArchive && !account.isEnabled ? L.string("mail.error.accountDisabled") : nil
    }
    var editReason: String? {
        createReason ?? MailFolderEditAvailability.reason(folder: selected, folders: folders, account: account, busy: false)
    }
    var childReason: String? {
        if let reason = createReason { return reason }
        guard let selected else { return L.string("mail.folder.edit.select") }
        return account?.isLocalArchive == false && (selected.delimiter?.isEmpty ?? true) ? L.string("mail.folder.edit.error.hierarchy") : nil
    }

    func load() async {
        guard isActive, !Task.isCancelled else { return }
        let ticket = UUID(); loadTicket = ticket; isLoading = true
        defer { if loadTicket == ticket { isLoading = false } }
        do {
            guard let accounts = hub.makeMailAccountService(for: space), let mail = hub.makeMailService(for: space),
                  let loadedAccount = try await accounts.account(id: accountID) else { throw MailFolderMutationError.unavailable }
            let loadedFolders = try await mail.folders(accountId: accountID), prefs = try await mail.folderPreferences()
            guard isActive, loadTicket == ticket, !Task.isCancelled else { return }
            account = loadedAccount; folders = loadedFolders
            let ids = Set(loadedFolders.map(\.id)); preferences = prefs.filter { ids.contains($0.folderID) }
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            do {
                let current = try await mail.pendingFolderMutation(accountID: accountID)
                let recent = try await mail.folderMutationHistory(accountID: accountID, limit: 10)
                guard isActive, loadTicket == ticket, !Task.isCancelled else { return }
                pending = current; history = recent; historyError = nil
            } catch { if isActive, loadTicket == ticket { historyError = MailErrorText.message(for: error) } }
            if !initialActionConsumed {
                initialActionConsumed = true
                // The initial route opens only after cached account/folder identity
                // is known. Destructive routes still stop at their review page.
                isLoading = false
                switch initialAction {
                case .manage: break
                case .createChild: openCreate(parentID: selectedID)
                case .rename: openRename()
                case .delete: openDelete()
                }
            }
        } catch {
            guard isActive, loadTicket == ticket, !Task.isCancelled else { return }
            account = nil; folders = []; selectedID = nil; self.error = MailErrorText.message(for: error)
        }
    }

    func openCreate(parentID: UUID?) {
        guard (parentID == nil ? createReason : childReason) == nil else { return }
        editor = .init(kind: .create, parentID: parentID); error = nil; result = nil
    }
    func openRename() {
        guard editReason == nil, let selected else { return }
        editor = .init(kind: .rename, folderID: selected.id, name: selected.name); error = nil; result = nil
    }
    func openDelete() {
        guard editReason == nil, let selected else { return }
        editor = .init(kind: .delete, folderID: selected.id); error = nil; result = nil
        prepareEditor()
    }
    func prepareEditor() {
        guard let editor, let expected = account else { return }
        let name = editor.name, kind = editor.kind, folder = editor.folderID, parent = editor.parentID
        run(editorID: editor.id, activity: "mail.folder.edit.checking") { service, progress in
            let review = try await service.review(accountID: self.accountID, kind: kind, folderID: folder, parentID: parent, name: name, progress: progress)
            guard MailService.sameFolderMutationAccount(expected, review.mutation.account) else { throw MailFolderMutationError.changed }
            return .preview(editor.id, review)
        }
    }
    func editAgain() { guard !busy else { return }; editor?.review = nil; editor?.error = nil }
    func executeEditor() {
        guard let editor, let review = editor.review else { return }
        guard !commitBlocked else { editor.error = pending == nil ? L.string("mail.folder.edit.busy") : L.string("mail.folder.edit.error.pending"); return }
        run(editorID: editor.id, activity: "mail.folder.edit.executing", changesData: true) { service, progress in
            .mutation(try await service.execute(review, progress: progress))
        }
    }
    func dismissEditor() {
        if operationEditorID == editor?.id { cancelOperation() }
        editor = nil
    }
    func inspectPending() {
        run(activity: "mail.folder.edit.checking") { service, _ in .recovery(try await service.inspectPending(accountID: self.accountID)) }
    }
    func inspectFromEditor() { guard !busy else { return }; editor = nil; inspectPending() }
    func finishRecovery() {
        guard let recovery, recovery.disposition != .resetCache || resetAcknowledged else { return }
        let reset = recovery.disposition == .resetCache && resetAcknowledged
        run(activity: "mail.folder.edit.executing", changesData: true) { service, _ in
            .mutation(try await service.finishRecovery(recovery, resetCacheConfirmed: reset))
        }
    }
    func dismissRecovery() { cancelOperation(); recovery = nil; resetAcknowledged = false }
    func refresh() {
        run(editorID: editor?.id, activity: "mail.folder.edit.refreshing", changesData: true) { service, _ in
            try await service.refresh(accountID: self.accountID); return .reloaded
        }
    }
    func syncSelected() {
        guard let selected, account?.isLocalArchive == false else { return }
        var paths: Set<String> = [selected.path], changed = true
        while changed {
            changed = false
            for folder in folders where folder.parentPath.map(paths.contains) == true { if paths.insert(folder.path).inserted { changed = true } }
        }
        let targets = folders.filter { paths.contains($0.path) && !$0.isContainer }
        guard !targets.isEmpty else { return }
        run(editorID: editor?.id, activity: "mail.folder.edit.refreshing", changesData: true) { _, progress in
            guard let service = self.hub.makeMailSyncService(for: self.space) else { throw MailFolderMutationError.unavailable }
            for (index, folder) in targets.enumerated() {
                try Task.checkCancellation()
                _ = try await service.syncFolder(accountId: self.accountID, folderId: folder.id)
                await progress(index + 1, targets.count)
            }
            return .reloaded
        }
    }
    func setHidden(_ hidden: Bool, folderID: UUID) {
        run(activity: "mail.folder.edit.saving", changesData: true) { _, _ in
            guard let mail = self.hub.makeMailService(for: self.space) else { throw MailFolderMutationError.unavailable }
            try await mail.setFolderHidden(hidden, folderID: folderID); return .reloaded
        }
    }
    func setFavorite(_ favorite: Bool, folderID: UUID) {
        run(activity: "mail.folder.edit.saving", changesData: true) { _, _ in
            guard let mail = self.hub.makeMailService(for: self.space) else { throw MailFolderMutationError.unavailable }
            try await mail.setFolderFavorite(favorite, folderID: folderID); return .reloaded
        }
    }
    func cancelOperation() {
        operationTicket = UUID(); operationTask?.cancel(); operationTask = nil; operationEditorID = nil
        isBusy = false; progress = (0, 0)
    }
    func cancelPendingWork() { isActive = false; loadTicket = UUID(); cancelOperation() }

    private enum Outcome { case preview(UUID, MailFolderOperationReview), mutation(MailFolderMutationRecord), recovery(MailFolderRecoveryReview), reloaded }
    private func run(editorID: UUID? = nil, activity: String, changesData: Bool = false,
                     operation: @escaping @MainActor (MailFolderOperationService, @escaping @Sendable (Int, Int) async -> Void) async throws -> Outcome) {
        guard isActive, !busy else { return }
        let ticket = UUID(); operationTicket = ticket; operationEditorID = editorID
        isBusy = true; activityKey = activity; progress = (0, 0); error = nil; editor?.error = nil
        operationTask = Task { [weak self] in
            guard let self, self.operationTicket == ticket, !Task.isCancelled else { return }
            var outcome: Outcome?, failure: Error?
            do {
                guard let service = self.makeOperations() else { throw MailFolderMutationError.unavailable }
                outcome = try await operation(service) { [weak self] done, total in await self?.updateProgress(ticket, done: done, total: total) }
            } catch { failure = error }
            if changesData { await Task { @MainActor in await self.onChanged() }.value }
            guard self.isActive, self.operationTicket == ticket else { return }
            self.operationEditorID = nil
            if let outcome {
                switch outcome {
                case .preview(let id, let review): if self.editor?.id == id { self.editor?.review = review }
                case .mutation(let record): self.result = record; self.editor = nil; self.recovery = nil; self.resetAcknowledged = false
                case .recovery(let review): self.recovery = review; self.resetAcknowledged = false
                case .reloaded: self.editor?.review = nil
                }
            }
            if let failure, !(failure is CancellationError) {
                if self.editor != nil { self.editor?.error = MailErrorText.message(for: failure); self.editor?.review = nil }
                else { self.error = MailErrorText.message(for: failure) }
            }
            await self.load()
            guard self.operationTicket == ticket else { return }
            if case .mutation(let record)? = outcome, record.mutation.kind == .create, self.folders.contains(where: { $0.id == record.mutation.rootID }) {
                self.query = ""; self.selectedID = record.mutation.rootID
            }
            self.isBusy = false; self.operationTask = nil
        }
    }
    private func updateProgress(_ ticket: UUID, done: Int, total: Int) { if operationTicket == ticket { progress = (done, total) } }
}

struct MailFolderManagerView: View {
    @Bindable var model: MailFolderManagerModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.string("mail.folder.edit.manage")).font(.headline)
                    Text(model.accountTitle).font(.subheadline).textSelection(.enabled)
                }
                Spacer()
                Button(L.string("common.close")) { model.cancelPendingWork(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let editor = model.editor { editorContent(editor) }
            else if let recovery = model.recovery { recoveryContent(recovery) }
            else { managementContent }
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L.string(model.activityKey)).font(.caption)
                    if model.progress.total > 0 { Text(L.format("mail.folder.edit.progress", model.progress.done, model.progress.total)).font(.caption).monospacedDigit() }
                    Spacer()
                    if model.isBusy { Button(L.string("common.cancel")) { model.cancelOperation() } }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).frame(width: 740, height: 650).background(Color(nsColor: .windowBackgroundColor))
            .task { await model.load() }.onDisappear { model.cancelPendingWork() }
    }

    private var managementContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.string(model.account?.isLocalArchive == true ? "mail.folder.edit.localHint" : "mail.folder.edit.remoteHint")).font(.caption).foregroundStyle(.secondary)
            if let pending = model.pending {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.string("mail.folder.edit.error.pending")).font(.caption)
                        Text(L.string("mail.folder.edit.state." + pending.state.rawValue)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L.string("mail.folder.edit.inspect")) { model.inspectPending() }.disabled(model.busy)
                }.padding(10).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Menu {
                    Button(L.string("mail.folder.edit.newRoot")) { model.openCreate(parentID: nil) }
                    Button(L.string("mail.folder.edit.newChild")) { model.openCreate(parentID: model.selectedID) }.disabled(model.childReason != nil)
                } label: { Text(L.string("mail.folder.edit.new")) } primaryAction: { model.openCreate(parentID: nil) }
                    .disabled(model.createReason != nil).help(model.createReason ?? L.string("mail.folder.edit.new"))
                Button(L.string("mail.folder.edit.rename")) { model.openRename() }.disabled(model.editReason != nil).help(model.editReason ?? L.string("mail.folder.edit.rename"))
                Button(L.string("mail.folder.edit.delete")) { model.openDelete() }.disabled(model.editReason != nil).help(model.editReason ?? L.string("mail.folder.edit.delete"))
                Spacer()
                Button(L.string("mail.folder.edit.refresh")) { model.refresh() }.disabled(model.busy || model.pending != nil)
                Button(L.string("mail.folder.edit.sync")) { model.syncSelected() }
                    .disabled(model.busy || model.pending != nil || model.account?.isLocalArchive != false || model.selected == nil)
                    .help(L.string("mail.folder.edit.syncHint"))
            }
            if let reason = model.editReason ?? model.createReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            TextField(L.string("mail.move.search"), text: $model.query).textFieldStyle(.roundedBorder).disabled(model.busy)
            List(selection: $model.selectedID) {
                ForEach(model.filteredFolders) { folder in
                    Button { model.selectedID = folder.id } label: {
                        HStack {
                            Image(systemName: folder.isContainer ? "folder" : "tray")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.displayName).lineLimit(1)
                                Text(model.path(folder)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if model.preferences.contains(where: { $0.folderID == folder.id && $0.isFavorite }) { Image(systemName: "star.fill").foregroundStyle(.secondary) }
                            if model.visibility.hidden.contains(folder.id) { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                            if !folder.isContainer { Text(L.format("mail.folder.edit.knownCount", folder.totalCount)).font(.caption).foregroundStyle(.secondary) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).tag(folder.id).help(model.path(folder))
                }
            }.listStyle(.inset).disabled(model.busy)
            if let folder = model.selected {
                HStack(spacing: 18) {
                    Toggle(L.string("mail.folder.favorites"), isOn: Binding(get: { model.preferences.contains { $0.folderID == folder.id && $0.isFavorite } }, set: { model.setFavorite($0, folderID: folder.id) }))
                        .disabled(folder.isContainer || model.busy)
                    Toggle(L.string("mail.folder.hidden"), isOn: Binding(get: { model.visibility.explicit.contains(folder.id) }, set: { model.setHidden($0, folderID: folder.id) })).disabled(model.busy)
                    if let parentID = model.visibility.hiddenAncestor[folder.id], let parent = model.folders.first(where: { $0.id == parentID }) {
                        Button(L.format("mail.folder.showParent", model.path(parent))) { model.setHidden(false, folderID: parentID) }.disabled(model.busy).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.toggleStyle(.checkbox).font(.caption)
            }
            if let result = model.result { Text(L.format("mail.folder.edit.result", result.completedFolderIDs.count, result.mutation.completionIDs.count - result.completedFolderIDs.count)).font(.caption) }
            if !model.history.isEmpty {
                DisclosureGroup(L.string("mail.folder.edit.history")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.history) { record in
                                let kind = L.string("mail.folder.edit.kind." + record.mutation.kind.rawValue)
                                let state = L.string("mail.folder.edit.state." + record.state.rawValue)
                                let folder = record.mutation.before.last ?? record.mutation.after.first
                                let path = folder.map { model.path($0) } ?? ""
                                Text([kind, state, path].joined(separator: " · "))
                                    .font(.caption).lineLimit(2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 90)
                }
            }
            if let error = model.historyError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func editorContent(_ editor: MailFolderEditDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.folder.edit.kind." + editor.kind.rawValue)).font(.headline)
            if let review = editor.review {
                Text(L.format("mail.folder.edit.scope", review.mutation.kind == .create ? 1 : review.mutation.before.count, review.mutation.cachedMessageCount)).font(.subheadline)
                if let count = review.serverMessageCount, review.mutation.kind != .create {
                    Text(L.format("mail.folder.edit.serverCount", count)).font(.caption).foregroundStyle(.secondary)
                }
                pathReview(review.mutation)
                Text(L.string("mail.folder.edit.confirmHint." + (editor.kind == .delete && review.mutation.account.isLocalArchive ? "deleteLocal" : editor.kind.rawValue)))
                    .font(.caption).foregroundStyle(editor.kind == .delete ? Color.red : Color.secondary)
                Spacer(minLength: 0)
                HStack {
                    Button(L.string("common.cancel")) { model.dismissEditor() }.disabled(model.busy)
                    if editor.kind != .delete { Button(L.string("mail.folder.edit.changeName")) { model.editAgain() }.disabled(model.busy) }
                    Spacer()
                    Button(L.string("mail.folder.edit.confirm." + editor.kind.rawValue), role: editor.kind == .delete ? .destructive : nil) { model.executeEditor() }
                        .keyboardShortcut(.defaultAction).disabled(model.commitBlocked)
                }
            } else {
                if editor.kind != .delete {
                    TextField(L.string("mail.folder.edit.name"), text: Binding(get: { editor.name }, set: { editor.name = $0 })).textFieldStyle(.roundedBorder).disabled(model.busy)
                    if let id = editor.parentID ?? editor.folderID, let folder = model.folders.first(where: { $0.id == id }) {
                        Text(model.path(folder)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else { Text(L.string("mail.folder.edit.newRoot")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                HStack {
                    Button(L.string("common.cancel")) { model.dismissEditor() }.disabled(model.busy)
                    Button(L.string("mail.folder.edit.refresh")) { model.refresh() }.disabled(model.busy || model.pending != nil)
                    if model.account?.isLocalArchive == false {
                        Button(L.string("mail.folder.edit.sync")) { model.syncSelected() }.disabled(model.busy || model.pending != nil || model.selected == nil)
                    }
                    Spacer()
                    Button(L.string("mail.folder.edit.preview")) { model.prepareEditor() }.keyboardShortcut(.defaultAction)
                        .disabled(model.busy || model.pending != nil || (editor.kind != .delete && editor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                if model.pending != nil { Button(L.string("mail.folder.edit.inspect")) { model.inspectFromEditor() }.disabled(model.busy) }
            }
            if let error = editor.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func pathReview(_ mutation: MailFolderMutation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(mutation.kind == .create ? mutation.after : mutation.before) { folder in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.path(folder)).textSelection(.enabled)
                        if mutation.kind == .rename, let target = mutation.after.first(where: { $0.id == folder.id }) {
                            Text(L.format("mail.move.to", model.path(target))).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.frame(maxHeight: .infinity).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func recoveryContent(_ review: MailFolderRecoveryReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.folder.edit.inspect")).font(.headline)
            Text(L.string("mail.folder.edit.recovery." + review.disposition.rawValue)).font(.callout)
            pathReview(review.record.mutation)
            if review.disposition == .resetCache {
                Text(L.format("mail.folder.edit.resetHint", review.resetMessageCount)).font(.caption).foregroundStyle(.red)
                Toggle(L.string("mail.folder.edit.resetAcknowledge"), isOn: $model.resetAcknowledged).toggleStyle(.checkbox).disabled(model.busy)
            }
            HStack {
                Button(L.string("common.cancel")) { model.dismissRecovery() }.disabled(model.busy)
                Button(L.string("mail.folder.edit.inspectAgain")) { model.inspectPending() }.disabled(model.busy)
                Spacer()
                if review.disposition != .unavailable {
                    Button(L.string("mail.folder.edit.recoverConfirm." + review.disposition.rawValue), role: review.disposition == .resetCache ? .destructive : nil) { model.finishRecovery() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.busy || (review.disposition == .resetCache && !model.resetAcknowledged))
                }
            }
        }
    }
}
