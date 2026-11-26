import SwiftUI
import AgRoomCore

/// Chat and task history share this result presentation. The library still opens
/// a single selected artifact with its version, preview and export controls.
struct TaskResultArtifactsView: View {
    let artifacts: [TaskArtifact]
    let roots: [URL]
    let store: TaskArtifactStore?
    let undoScope: TaskArtifactEditScope?
    let canConfirmUndo: (TaskArtifactEditScope) -> Bool
    let onUse: (TaskArtifact) -> Void
    let onContinueSnapshot: (TaskArtifact, URL) -> Void
    let onContinue: (TaskArtifact) -> Void

    var body: some View {
        let groups = TaskArtifactGroup.collect(artifacts)
        let edits = groups.filter { $0.newest.change != nil }
        let others = groups.filter { $0.newest.change == nil }
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            if !edits.isEmpty {
                EditedFilesCard(groups: edits, roots: roots, store: store, undoScope: undoScope, canConfirmUndo: canConfirmUndo) { selection in
                    artifactDetails(edits, startingAt: selection, mixedResult: !others.isEmpty)
                        .padding(MeetSpacing.lg)
                        .frame(minWidth: 600, idealWidth: 920, minHeight: 400, idealHeight: 600)
                }
                .id(edits.map { $0.newest.id })
            }
            if !others.isEmpty {
                artifactDetails(others, mixedResult: !edits.isEmpty)
            }
        }.frame(maxWidth: MeetLayout.artifactListMaxWidth, alignment: .leading)
    }

    private func artifactDetails(_ groups: [TaskArtifactGroup], startingAt selection: TaskArtifactGroup.ID? = nil, mixedResult: Bool) -> some View {
        TaskArtifactsView(artifacts: groups.flatMap { $0.revisions.reversed() }, roots: roots, store: store,
            reviewStart: selection, fullResultForExport: mixedResult ? artifacts : nil,
            onUse: onUse, onContinueSnapshot: onContinueSnapshot, onContinue: onContinue)
    }
}

private struct EditLineCounts {
    let added: Int
    let removed: Int

    init?(_ comparison: TaskArtifactComparison) {
        guard !comparison.interleaved, let added = comparison.added, let removed = comparison.removed else { return nil }
        self.added = added
        self.removed = removed
    }

    init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }
}

private struct EditedFilesCard<Review: View>: View {
    private struct UndoStatusRequest: Equatable {
        let scope: TaskArtifactEditScope?
        let refresh: Int
    }
    let groups: [TaskArtifactGroup]
    let roots: [URL]
    let store: TaskArtifactStore?
    let undoScope: TaskArtifactEditScope?
    let canConfirmUndo: (TaskArtifactEditScope) -> Bool
    @ViewBuilder let review: (TaskArtifactGroup.ID) -> Review
    @State private var reviewing: TaskArtifactGroup?
    @State private var counts: [TaskArtifactGroup.ID: EditLineCounts] = [:]
    @State private var countsLoaded = false
    @State private var refresh = 0
    @State private var undoStatus = TaskArtifactUndoStatus.unavailable
    @State private var confirmingScope: TaskArtifactEditScope?
    @State private var undoing = false
    @State private var errorMessage: String?

    private var title: String {
        groups.count == 1 ? L.string("product.edits.one") : L.format("product.edits.count", groups.count)
    }

    var body: some View {
        let paths = TaskArtifactGroup.displayPaths(groups, roots: roots)
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { heading.fixedSize(); Spacer(minLength: MeetSpacing.sm); actions.fixedSize() }
                VStack(alignment: .leading, spacing: MeetSpacing.sm) { heading; actions }
            }.padding(MeetSpacing.md)
            Divider()
            ForEach(groups) { group in
                Button { reviewing = group } label: {
                    HStack(spacing: MeetSpacing.sm) {
                        pathText(paths[group.id] ?? group.id.path)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: MeetSpacing.xs)
                        lineCounts(counts[group.id])
                    }
                    .font(MeetTypography.control)
                    .padding(.horizontal, MeetSpacing.sm).padding(.vertical, MeetSpacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .accessibilityLabel(paths[group.id] ?? group.id.path)
                .accessibilityValue(counts[group.id].map { L.format("product.edits.lines", $0.added, $0.removed) }
                    ?? L.string(countsLoaded ? "product.edits.counts.unavailable" : "product.edits.counting"))
                .help(group.id.path)
            }
            if let errorMessage {
                Text(errorMessage).font(MeetTypography.secondary).foregroundStyle(.red).textSelection(.enabled)
                    .padding(MeetSpacing.sm)
            }
        }
        .meetCard()
        .sheet(item: $reviewing) { group in review(group.id) }
        .alert(L.string("product.edits.confirm"), isPresented: Binding(
            get: { confirmingScope != nil }, set: { if !$0 { confirmingScope = nil } }
        ), presenting: confirmingScope) { scope in
            Button(L.string("common.cancel"), role: .cancel) {}
            Button(L.string("product.edits.undo"), role: .destructive) { Task { await undo(scope) } }
        } message: { _ in Text(L.format("product.edits.confirm.body", groups.count)) }
        .task(id: refresh) { await loadCounts() }
        .task(id: UndoStatusRequest(scope: undoScope, refresh: refresh)) { await loadUndoStatus() }
        .onReceive(NotificationCenter.default.publisher(for: TaskArtifactStore.didChange)) { notification in
            guard notification.object as? String == store?.space.rawValue else { return }
            refresh += 1
        }
    }

    private var heading: some View {
        HStack(spacing: MeetSpacing.md) {
            Image(systemName: "doc.badge.ellipsis").font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: MeetRadius.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(MeetTypography.listTitle)
                if countsLoaded, counts.count < groups.count {
                    Text(L.string("product.edits.counts.unavailable")).font(MeetTypography.secondary).foregroundStyle(.secondary)
                } else {
                    let total = countsLoaded ? EditLineCounts(added: counts.values.reduce(0) { $0 + $1.added },
                        removed: counts.values.reduce(0) { $0 + $1.removed }) : nil
                    lineCounts(total).font(MeetTypography.secondary)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: MeetSpacing.md) {
            if undoing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    if let undoScope { confirmingScope = undoScope }
                } label: {
                    Label(L.string(undoStatus == .undone ? "product.edits.undone" : "product.edits.undo"),
                        systemImage: undoStatus == .undone ? "checkmark" : "arrow.uturn.backward")
                }
                .buttonStyle(.plain).disabled(undoScope == nil || undoStatus != .available)
                .help(L.string(undoStatus == .unavailable || undoScope == nil ? "product.edits.undo.unavailable" : "product.edits.undo.help"))
            }
            Button(L.string("product.edits.review")) { reviewing = groups.first }.buttonStyle(.bordered)
        }.font(MeetTypography.control)
    }

    private func pathText(_ path: String) -> Text {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        var directory = AttributedString(path[..<nameStart])
        directory.foregroundColor = .secondary
        var name = AttributedString(path[nameStart...])
        name.foregroundColor = .primary
        return Text(directory + name)
    }

    @ViewBuilder private func lineCounts(_ counts: EditLineCounts?) -> some View {
        if let counts {
            HStack(spacing: 4) {
                Text(verbatim: "+\(counts.added)").foregroundStyle(.green)
                Text(verbatim: "−\(counts.removed)").foregroundStyle(.red)
            }.monospacedDigit().fixedSize().accessibilityElement(children: .ignore)
                .accessibilityLabel(L.format("product.edits.lines", counts.added, counts.removed))
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
                .accessibilityLabel(L.string(countsLoaded ? "product.edits.counts.unavailable" : "product.edits.counting"))
        }
    }

    private func loadCounts() async {
        var result: [TaskArtifactGroup.ID: EditLineCounts] = [:]
        if let store {
            for group in groups {
                guard !Task.isCancelled else { return }
                if let comparison = try? await store.comparison(of: group.newest) {
                    result[group.id] = EditLineCounts(comparison)
                }
            }
        }
        guard !Task.isCancelled else { return }
        counts = result
        countsLoaded = true
    }

    private func loadUndoStatus() async {
        guard let store, let undoScope else { undoStatus = .unavailable; return }
        let status = try? await store.undoStatus(for: groups.map(\.newest), scope: undoScope)
        if !Task.isCancelled { undoStatus = status ?? .unavailable }
    }

    private func undo(_ confirmed: TaskArtifactEditScope) async {
        guard !undoing, let store, confirmed == undoScope, canConfirmUndo(confirmed) else {
            errorMessage = L.string("product.edits.undo.unavailable")
            return
        }
        undoing = true
        errorMessage = nil
        defer { undoing = false }
        do {
            try await store.undoEdits(groups.map(\.newest), scope: confirmed)
        } catch TaskArtifactUndoError.changed(let path) {
            errorMessage = L.format("product.edits.undo.changed", path)
        } catch TaskArtifactUndoError.interrupted(let path, let completed) {
            errorMessage = L.format("product.edits.undo.interrupted", completed, path)
        } catch {
            errorMessage = L.string("product.edits.undo.failed")
        }
        await loadUndoStatus()
    }
}
