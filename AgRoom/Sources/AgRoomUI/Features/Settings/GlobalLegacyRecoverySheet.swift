import AppKit
import SwiftUI
import AgRoomCore

/// Explicit all-app maintenance for legacy Daemon evidence whose space cannot
/// be proven. Space-scoped task pages only show a neutral blocking signal.
struct GlobalLegacyRecoverySheet: View {
    let store: DaemonHandoffStore

    private struct ListedEvidence: Identifiable {
        let number: Int
        let evidence: DaemonHandoffStore.QuarantinedEvidence
        var id: String { evidence.id }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var evidence: [DaemonHandoffStore.QuarantinedEvidence] = []
    @State private var inspectedIDs: Set<String> = []
    @State private var hasBlockingEvidence = false
    @State private var loading = false
    @State private var visible = true
    @State private var loadGeneration = UUID()
    @State private var errorText: String?
    @State private var inspecting: DaemonHandoffStore.QuarantinedEvidence?
    @State private var abandoning: DaemonHandoffStore.QuarantinedEvidence?
    private var listedEvidence: [ListedEvidence] {
        evidence.enumerated().map { ListedEvidence(number: $0.offset + 1, evidence: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L.string("settings.legacy_evidence.title"), systemImage: "externaldrive.badge.exclamationmark")
                    .font(.title2.bold())
                Spacer()
                Button(L.string("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(L.string("settings.legacy_evidence.scope"))
                .font(.callout)
                .foregroundStyle(.orange)
            Text(L.string("settings.legacy_evidence.help"))
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(listedEvidence) { listed in
                        let item = listed.evidence
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L.format("settings.legacy_evidence.item", listed.number),
                                  systemImage: "doc.text.magnifyingglass")
                                .font(.headline)
                            HStack {
                                Button(L.string("product.recovery.global.open")) {
                                    inspecting = item
                                }
                                Button(L.string("product.recovery.abandon"), role: .destructive) {
                                    abandoning = item
                                }
                                .disabled(!inspectedIDs.contains(item.id))
                            }
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if evidence.isEmpty && !loading {
                        Text(L.string(hasBlockingEvidence
                            ? "settings.legacy_evidence.unavailable"
                            : "settings.legacy_evidence.empty"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 16)
                    }
                }
            }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button(L.string("common.refresh")) { Task { await load() } }
                    .disabled(loading)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 650, minHeight: 400, idealHeight: 520)
        .task { await load() }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            loadGeneration = UUID()
            loading = false
            inspectedIDs.removeAll()
        }
        .confirmationDialog(L.string("settings.legacy_evidence.inspect_title"),
                            isPresented: Binding(get: { inspecting != nil },
                                                 set: { if !$0 { inspecting = nil } })) {
            Button(L.string("product.recovery.global.open")) {
                guard let item = inspecting else { return }
                inspecting = nil
                Task { await openCopy(item) }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("settings.legacy_evidence.inspect_help")) }
        .confirmationDialog(L.string("product.recovery.abandon"),
                            isPresented: Binding(get: { abandoning != nil },
                                                 set: { if !$0 { abandoning = nil } })) {
            Button(L.string("product.recovery.abandon"), role: .destructive) {
                guard let item = abandoning, inspectedIDs.contains(item.id) else { return }
                abandoning = nil
                let ticket = loadGeneration
                Task {
                    let resolved = await Task.detached { store.abandonUnattributedEvidence(item) }.value
                    guard visible, loadGeneration == ticket else { return }
                    if let refreshedTicket = await load(), visible,
                       loadGeneration == refreshedTicket, !resolved {
                        errorText = L.string("product.recovery.failed")
                    }
                }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("settings.legacy_evidence.abandon_help")) }
    }

    @discardableResult
    private func load() async -> UUID? {
        let ticket = UUID()
        loadGeneration = ticket
        loading = true
        let result = await Task.detached { [store] in
            (store.unattributedLegacyEvidence(), store.ownershipSnapshot().hasUnattributedQuarantine)
        }.value
        guard visible, !Task.isCancelled, loadGeneration == ticket else { return nil }
        evidence = result.0
        hasBlockingEvidence = result.1
        inspectedIDs.removeAll()
        errorText = nil
        loading = false
        return ticket
    }

    private func openCopy(_ item: DaemonHandoffStore.QuarantinedEvidence) async {
        let ticket = loadGeneration
        let copy = await Task.detached { [store] in store.inspectionCopy(of: item, in: nil) }.value
        guard visible, !Task.isCancelled, loadGeneration == ticket else { return }
        guard let copy else {
            if let refreshedTicket = await load(), visible, !Task.isCancelled,
               loadGeneration == refreshedTicket {
                errorText = L.string("product.recovery.inspect_failed")
            }
            return
        }
        inspectedIDs.insert(item.id)
        NSWorkspace.shared.activateFileViewerSelecting([copy])
    }
}
