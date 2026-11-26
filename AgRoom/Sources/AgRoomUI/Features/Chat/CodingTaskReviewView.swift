import SwiftUI
import AgRoomCore

struct CodingTaskReviewView: View {
    let store: CodingTaskStore
    let space: AppSpace
    let sessionID: UUID
    let workspace: ChatWorkspace
    private var root: URL { workspace.url }
    let allowsRestore: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var state: CodingTaskState?
    @State private var entries: [CodingReviewEntry] = []
    @State private var selectedPath: String?
    @State private var service: CodingTaskReviewService?
    @State private var error: String?
    @State private var loading = true
    @State private var currentVerification = false
    @State private var restoring = false
    @State private var showFullFiles = false
    @State private var pendingRestore: CodingReviewEntry?

    private var selected: CodingReviewEntry? { entries.first { $0.path == selectedPath } ?? entries.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("coding.review.title")).font(.headline)
                Spacer()
                Button(L.string("coding.review.refresh")) { Task { await load() } }.disabled(loading || restoring)
                Button(L.string("common.close")) { dismiss() }
            }
            Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if loading { ProgressView() }
            if let verification = state?.verification {
                Label(L.string("coding.action." + verification.action) + " · " + L.string(currentVerification ? "coding.completion.passed" : "coding.completion.recorded"),
                    systemImage: currentVerification ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                // 历史通过不代表当前版本；每个文件的变化状态单独展示。
            }
            if entries.isEmpty, !loading {
                ContentUnavailableView(L.string("coding.review.empty"), systemImage: "doc.text.magnifyingglass")
            } else {
                HSplitView {
                    List(entries, selection: $selectedPath) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                            Text(entry.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }.tag(entry.path)
                    }.frame(minWidth: 180, idealWidth: 240)
                    if let selected {
                        VStack(alignment: .leading, spacing: 8) {
                            if !selected.matchesRecordedVersion {
                                Label(L.string("coding.review.userChanged"), systemImage: "person.crop.circle.badge.exclamationmark")
                                    .foregroundStyle(.orange).font(.caption)
                            }
                            Toggle(L.string("coding.review.full"), isOn: $showFullFiles).toggleStyle(.checkbox)
                            if let diff = selected.diff, !showFullFiles {
                                ScrollView([.horizontal, .vertical]) { DiffTextView(diff: diff).padding(8) }
                            } else {
                                HSplitView {
                                    sourcePane(selected.before, title: L.string("coding.review.before"))
                                    sourcePane(selected.after, title: L.string("coding.review.after"))
                                }
                            }
                            Button(L.string("coding.review.restore")) { pendingRestore = selected }
                                .disabled(!allowsRestore || !selected.canRestore || restoring || loading)
                        }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 960, minHeight: 500, idealHeight: 640)
        .task { await load() }
        .confirmationDialog(L.string("coding.review.restoreConfirm"), isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        ), titleVisibility: .visible) {
            Button(L.string("coding.review.restore"), role: .destructive) {
                if let entry = pendingRestore { Task { await restore(entry) } }
                pendingRestore = nil
            }
            Button(L.string("common.cancel"), role: .cancel) { pendingRestore = nil }
        } message: { Text(pendingRestore?.path ?? "") }
    }

    private func sourcePane(_ text: String, title: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        do {
            let fileService = FileAreaService.standard.scoped(to: workspace.folderURLs)
            let service = try CodingTaskReviewService(store: store, service: fileService, space: space, root: root, sessionID: sessionID)
            let result = try await service.load()
            self.service = service; state = result.0; entries = result.1; currentVerification = result.2; error = nil
        } catch {
            self.error = L.string("coding.review.loadFailed")
        }
    }

    @MainActor private func restore(_ entry: CodingReviewEntry) async {
        guard allowsRestore, let service, let digest = entry.digest else { return }
        restoring = true
        defer { restoring = false }
        do {
            try await service.restore(path: entry.path, expectedDigest: digest, space: space)
            await load()
        } catch {
            self.error = L.string("coding.review.restoreFailed")
        }
    }
}
