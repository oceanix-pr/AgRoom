import AppKit
import Combine
import SwiftUI
import AgRoomCore

enum TaskArtifactFormatting {
    @MainActor static func size(_ bytes: Int64) -> String {
        guard bytes >= 1024 else { return L.format("product.artifact.bytes", Int(bytes)) }
        var value = Double(bytes) / 1024, unit = "KiB"
        for next in ["MiB", "GiB", "TiB", "PiB", "EiB"] where value >= 1024 { value /= 1024; unit = next }
        return String(format: "%.1f %@", value, unit)
    }
    @MainActor static func error(_ error: Error) -> String {
        if error is TaskArtifactError || error is MaintenanceError { return L.errorDescription(error) }
        return L.string("product.artifact.error.storage")
    }
}

struct ArtifactLibraryView: View {
    let store: TaskArtifactStore
    var includeHidden = false
    var roots: (TaskArtifactVersion) -> [URL] = { _ in [] }
    var onOpenSource: (TaskArtifactVersion) -> Void = { _ in }
    var onUse: (TaskArtifactVersion) -> Void = { _ in }
    var onContinue: (TaskArtifact, URL, TaskArtifactVersion) -> Void = { _, _, _ in }
    var initialVersionID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var filter = TaskArtifactContentFilter.all
    @State private var items: [TaskArtifactVersion] = []
    @State private var next: TaskArtifactLibraryPage.Cursor?
    @State private var selectedID: UUID?
    @State private var selectedVersion: TaskArtifactVersion?
    @State private var summary: TaskArtifactLibrarySummary?
    @State private var cache: TaskArtifactCacheSummary?
    @State private var generation = UUID()
    @State private var visible = false
    @State private var loading = false
    @State private var mutating = false
    @State private var removing: TaskArtifact?
    @State private var clearingCache = false
    @State private var pruned = false
    @State private var appliedInitialVersion = false
    @State private var sourceAvailable: [UUID: Bool] = [:]
    @State private var errorText: String?
    private var key: String { "\(store.space.rawValue):\(filter.rawValue):\(includeHidden):\(search)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("product.artifact.library")).font(.title2.bold())
                Text(L.string(store.space.nameKey)).foregroundStyle(store.space.tint)
                Spacer()
                Button(L.string("common.refresh")) { Task { await load(reset: true) } }.disabled(loading || mutating)
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let summary {
                Text(L.format("product.artifact.library.summary", summary.versions, summary.retainedVersions, TaskArtifactFormatting.size(summary.retainedBytes)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(L.string("product.artifact.library.search"), text: $search)
                    .accessibilityIdentifier("product.artifact.library.search")
                Picker(L.string("product.artifact.library.filter"), selection: $filter) {
                    ForEach(TaskArtifactContentFilter.allCases, id: \.self) { value in
                        Text(L.string("product.artifact.library.filter." + value.rawValue)).tag(value)
                    }
                }.frame(width: 220)
            }.disabled(mutating)
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { record in
                            Button { selectedID = record.id; selectedVersion = nil } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(record.artifact.name).font(.headline).lineLimit(2)
                                        Spacer()
                                        Text(L.format("product.artifact.version", record.artifact.version ?? 1)).font(.caption)
                                    }
                                    Text(record.artifact.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    HStack {
                                        if let date = record.artifact.createdAt { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                                        Spacer()
                                        Image(systemName: record.artifact.contentRetained == true ? "doc.fill" : "link")
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedID == record.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityIdentifier("product.artifact.library.select." + record.id.uuidString)
                        }
                        if next != nil {
                            Button(L.string("product.artifact.more")) { Task { await load(reset: false) } }.disabled(loading || mutating)
                        }
                        if items.isEmpty && !loading { Text(L.string("product.artifact.library.empty")).foregroundStyle(.secondary).padding() }
                    }.padding(.trailing, 6)
                }.frame(minWidth: 230, idealWidth: 290, maxWidth: 350)
                ScrollView {
                    if let record = selectedVersion ?? items.first(where: { $0.id == selectedID }) {
                        VStack(alignment: .leading, spacing: 12) {
                            TaskArtifactsView(artifacts: [record.artifact], roots: roots(record), store: store,
                                onUse: { _ in onUse(record) }, onContinueSnapshot: { artifact, url in onContinue(artifact, url, record) },
                                onSelectVersion: { version in selectedVersion = version; selectedID = version.id }, onContinue: { _ in })
                                .id(record.id.uuidString + ":" + String(record.artifact.contentRetained == true))
                            Text(record.artifact.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                            if sourceAvailable[record.id] == true {
                                Button(L.string("product.tasks.open_source")) { openSource(record) }
                            } else { Text(L.string("product.artifact.library.source_missing")).font(.caption).foregroundStyle(.secondary) }
                            if record.artifact.contentRetained == true {
                                Button(L.string("product.artifact.library.remove"), role: .destructive) { removing = record.artifact }
                                    .disabled(mutating).accessibilityIdentifier("product.artifact.library.remove")
                            }
                        }.padding(.leading, 8)
                            .task(id: record.id) {
                                do {
                                    let found = try await store.sourceSessionExists(for: record)
                                    guard visible, !Task.isCancelled else { return }
                                    sourceAvailable[record.id] = found
                                } catch { if visible, !Task.isCancelled { errorText = TaskArtifactFormatting.error(error) } }
                            }
                    } else { Text(L.string("product.artifact.library.select")).foregroundStyle(.secondary).padding(30) }
                }.frame(minWidth: 390)
            }
            HStack {
                if loading || mutating { ProgressView().controlSize(.small) }
                if let cache { Text(L.format("product.artifact.library.cache_summary", cache.files, TaskArtifactFormatting.size(cache.bytes))).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L.string("product.artifact.library.clear_cache")) { clearingCache = true }.disabled(mutating || loading)
            }
            Text(L.string("product.artifact.library.help")).font(.caption).foregroundStyle(.secondary)
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).frame(width: 880, height: 650)
        .onAppear { visible = true }
        .onDisappear { visible = false; generation = UUID() }
        .task(id: key) {
            do { try await Task.sleep(for: .milliseconds(180)); await load(reset: true) } catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: TaskArtifactStore.didChange).receive(on: RunLoop.main)) { notification in
            guard notification.object as? String == store.space.rawValue, !mutating, !loading, items.count <= 40 else { return }
            Task { await load(reset: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agroomSpaceRestored).receive(on: RunLoop.main)) { _ in
            Task { await load(reset: true) }
        }
        .confirmationDialog(L.string("product.artifact.library.remove"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L.string("product.artifact.library.remove"), role: .destructive) {
                guard let artifact = removing else { return }
                removing = nil
                mutate { try await store.removeRetainedContents([artifact]) }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.artifact.library.remove_help")) }
        .confirmationDialog(L.string("product.artifact.library.clear_cache"), isPresented: $clearingCache) {
            Button(L.string("product.artifact.library.clear_cache"), role: .destructive) { mutate { try await store.clearPreviewCache() } }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.artifact.library.cache_help")) }
    }

    private func load(reset: Bool) async {
        guard visible else { return }
        let ticket = UUID(); generation = ticket; loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let page = try await store.libraryPage(search: search, filter: filter, before: reset ? nil : next, includeHidden: includeHidden)
            let initial: TaskArtifactVersion?
            if !appliedInitialVersion, let initialVersionID { initial = try await store.version(id: initialVersionID, includeHidden: includeHidden) }
            else { initial = nil }
            let retainedSelection: TaskArtifactVersion?
            if reset, let selectedVersion { retainedSelection = try await store.version(id: selectedVersion.id, includeHidden: includeHidden) }
            else { retainedSelection = nil }
            let summary = try await store.librarySummary()
            var cache: TaskArtifactCacheSummary?
            var cacheError: String?
            if reset && !pruned {
                pruned = true
                do { try await store.pruneOrphanedPreviews() }
                catch TaskArtifactError.previewInUse { /* Active previews stay pinned. */ }
                catch { cacheError = TaskArtifactFormatting.error(error) }
            }
            do { cache = try await store.previewCacheSummary() }
            catch { cacheError = TaskArtifactFormatting.error(error) }
            guard visible, generation == ticket, !Task.isCancelled else { return }
            if reset { items = page.items; selectedVersion = retainedSelection }
            else { let existing = Set(items.map(\.id)); items += page.items.filter { !existing.contains($0.id) } }
            next = page.next; self.summary = summary; self.cache = cache
            if !appliedInitialVersion {
                appliedInitialVersion = true
                if let initial { selectedVersion = initial; selectedID = initial.id }
                else if initialVersionID != nil { cacheError = L.string("product.artifact.error.unavailable") }
            }
            if selectedID == nil || (selectedVersion == nil && !items.contains(where: { $0.id == selectedID })) { selectedID = items.first?.id }
            errorText = cacheError
        } catch {
            guard visible, generation == ticket, !Task.isCancelled else { return }
            errorText = TaskArtifactFormatting.error(error)
        }
    }

    private func mutate(_ operation: @escaping @Sendable () async throws -> Void) {
        guard visible, !mutating else { return }
        mutating = true; errorText = nil
        Task {
            let failure: String?
            do { try await operation(); failure = nil }
            catch { failure = TaskArtifactFormatting.error(error) }
            guard visible else { return }
            mutating = false
            await load(reset: true)
            if let failure { errorText = failure }
        }
    }

    private func openSource(_ record: TaskArtifactVersion) {
        Task {
            do {
                let found = try await store.sourceSessionExists(for: record)
                guard visible, selectedID == record.id, !Task.isCancelled else { return }
                guard found else { sourceAvailable[record.id] = false; errorText = L.string("product.artifact.library.source_missing"); return }
                onOpenSource(record)
            } catch { if visible { errorText = TaskArtifactFormatting.error(error) } }
        }
    }
}
