import Foundation
import Observation
import SwiftUI
import AgRoomCore

/// Ancestor visibility uses actual same-account parent links, never a name prefix
/// (Projects must not hide Projects-old). Cycles in damaged metadata terminate.
struct MailFolderSidebarState {
    let explicit: Set<UUID>
    let hidden: Set<UUID>
    let hiddenAncestor: [UUID: UUID]

    init(folders: [MailFolder], preferences: [MailFolderPreference]) {
        explicit = Set(preferences.filter(\.isHidden).map(\.folderID))
        let owners = Dictionary(grouping: folders, by: \.accountId).mapValues { Dictionary($0.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }) }
        var hidden = explicit, ancestors: [UUID: UUID] = [:]
        for folder in folders {
            var path = folder.parentPath, visited: Set<UUID> = [folder.id]
            while let parentPath = path, let parent = owners[folder.accountId]?[parentPath], visited.insert(parent.id).inserted {
                if explicit.contains(parent.id) { hidden.insert(folder.id); ancestors[folder.id] = parent.id; break }
                path = parent.parentPath
            }
        }
        self.hidden = hidden; hiddenAncestor = ancestors
    }
}

@MainActor @Observable
final class MailMovePickerModel: Identifiable {
    let id = UUID()
    let messageIDs: Set<UUID>
    private let hub: Hub
    private let space: AppSpace
    private let onMove: @MainActor (MailMoveReview, UUID) -> Bool
    private let preferredID: UUID?
    private var task: Task<Void, Never>?
    private var commitTask: Task<Bool, Never>?
    private var generation = UUID()
    private var isActive = false
    private(set) var review: MailMoveReview?
    private(set) var preferences: [MailFolderPreference] = []
    private(set) var hiddenFolderIDs: Set<UUID> = []
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    var selectedID: UUID?
    var query = "" {
        didSet { if let selectedID, !filtered.contains(where: { $0.id == selectedID }) { self.selectedID = nil } }
    }
    var busy: Bool { isLoading || isSubmitting }

    init(hub: Hub, space: AppSpace, messageIDs: Set<UUID>, preferredID: UUID? = nil, onMove: @escaping @MainActor (MailMoveReview, UUID) -> Bool) {
        self.hub = hub; self.space = space; self.messageIDs = messageIDs; self.onMove = onMove
        self.preferredID = preferredID
    }

    func path(_ folder: MailFolder) -> String { MailFolderPath.display(folder, isLocalArchive: review?.account.isLocalArchive == true) }
    var accountTitle: String { review.map { $0.account.displayName.isEmpty ? $0.account.emailAddress : $0.account.displayName } ?? "" }
    var sourcePaths: String { review?.sources.map(path).joined(separator: " · ") ?? "" }
    var filtered: [MailFolder] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return (review?.destinations ?? []).filter { folder in
            terms.allSatisfy { folder.displayName.localizedStandardContains($0) || path(folder).localizedStandardContains($0) }
        }.sorted { path($0).localizedStandardCompare(path($1)) == .orderedAscending }
    }
    var preferred: [MailFolder] {
        let eligible = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        let recent = preferences.filter { $0.lastMovedAt != nil }.sorted {
            if $0.lastMovedAt != $1.lastMovedAt { return ($0.lastMovedAt ?? .distantPast) > ($1.lastMovedAt ?? .distantPast) }
            return $0.folderID.uuidString < $1.folderID.uuidString
        }.compactMap { eligible[$0.folderID] }
        let used = Set(recent.map(\.id)), favorites = Set(preferences.filter(\.isFavorite).map(\.folderID))
        return recent + filtered.filter { favorites.contains($0.id) && !used.contains($0.id) }
    }
    var remaining: [MailFolder] { let used = Set(preferred.map(\.id)); return filtered.filter { !used.contains($0.id) } }
    var selected: MailFolder? { filtered.first { $0.id == selectedID } }
    func isHidden(_ folder: MailFolder) -> Bool {
        hiddenFolderIDs.contains(folder.id)
    }

    func load() async {
        guard !busy, !Task.isCancelled else { return }
        cancel(); isActive = true; isLoading = true; error = nil; review = nil; selectedID = nil
        let token = generation
        let work = Task {
            defer { if generation == token { isLoading = false; task = nil } }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailMoveReviewError.unavailable }
                let loaded = try await mail.reviewMove(messageIDs: Array(messageIDs))
                let prefs = try await mail.folderPreferences()
                try Task.checkCancellation()
                guard generation == token else { return }
                review = loaded; preferences = prefs
                if let preferredID, loaded.destinations.contains(where: { $0.id == preferredID }) { selectedID = preferredID }
                hiddenFolderIDs = MailFolderSidebarState(folders: loaded.folders, preferences: prefs).hidden
            } catch is CancellationError { }
            catch { if generation == token { self.error = MailErrorText.message(for: error) } }
        }
        task = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    func submit() async -> Bool {
        guard isActive, !busy, !Task.isCancelled, let review, let selected else { return false }
        isSubmitting = true; error = nil
        let token = generation
        let work = Task {
            defer { if generation == token { isSubmitting = false; commitTask = nil } }
            do {
                guard let mail = hub.makeMailService(for: space) else { throw MailMoveReviewError.unavailable }
                try await mail.validateMove(review, destinationID: selected.id)
                try Task.checkCancellation()
                guard generation == token else { return false }
                guard onMove(review, selected.id) else { throw MailMoveReviewError.changed }
                return true
            } catch is CancellationError { return false }
            catch { if generation == token { self.error = MailErrorText.message(for: error) }; return false }
        }
        commitTask = work
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    func cancel() {
        isActive = false; generation = UUID(); task?.cancel(); task = nil; commitTask?.cancel(); commitTask = nil
        isLoading = false; isSubmitting = false
    }
}

struct MailMovePicker: View {
    @Bindable var model: MailMovePickerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.move.title")).font(.headline)
            Text(L.format("mail.move.selection", model.messageIDs.count, model.accountTitle)).font(.subheadline)
            if !model.sourcePaths.isEmpty {
                Text(L.format("mail.move.from", model.sourcePaths)).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.sourcePaths)
            }
            TextField(L.string("mail.move.search"), text: $model.query).textFieldStyle(.roundedBorder).disabled(model.busy || model.review == nil)
            if model.review != nil {
                if model.filtered.isEmpty {
                    ContentUnavailableView.search(text: model.query).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedID) {
                        if !model.preferred.isEmpty { Section(L.string("mail.folder.preferredTargets")) { ForEach(model.preferred) { row($0) } } }
                        if !model.remaining.isEmpty { Section(L.string("mail.folder.all")) { ForEach(model.remaining) { row($0) } } }
                    }.listStyle(.inset).disabled(model.busy)
                }
            } else { Spacer(); if model.isLoading { ProgressView().frame(maxWidth: .infinity) }; Spacer() }
            if let selected = model.selected { Text(L.format("mail.move.to", model.path(selected))).font(.caption).lineLimit(2).help(model.path(selected)) }
            Text(L.string("mail.move.hiddenHint")).font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L.string("common.cancel")) { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.string("mail.action.move")) { Task { if await model.submit() { dismiss() } } }
                    .keyboardShortcut(.defaultAction).disabled(model.busy || model.selected == nil)
            }
        }.padding(20).frame(width: 540, height: 510).background(Color(nsColor: .windowBackgroundColor))
            .task { await model.load() }.onDisappear { model.cancel() }
    }

    private func row(_ folder: MailFolder) -> some View {
        Button { model.selectedID = folder.id } label: {
            HStack {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.displayName).lineLimit(1)
                    Text(model.path(folder)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                if model.isHidden(folder) { Image(systemName: "eye.slash").foregroundStyle(.secondary).help(L.string("mail.folder.hidden")) }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(model.path(folder)).tag(folder.id)
            .accessibilityAddTraits(model.selectedID == folder.id ? [.isSelected] : [])
    }
}
