import SwiftUI
import AgRoomCore

struct ProductMetricsSection: View {
    let service: ProductPreferencesService?
    var isCurrent: @MainActor () -> Bool = { true }
    @State private var summary: ProductMetricsSummary?
    @State private var error: String?
    @State private var confirmingClear = false
    @State private var loading = false
    @State private var clearing = false
    @State private var visible = true
    @State private var loadID = UUID()

    var body: some View {
        Section {
            if let summary {
                if let since = summary.measuredSince {
                    LabeledContent(L.string("product.metrics.since")) { Text(since, format: .dateTime.year().month().day().hour().minute()) }
                }
                LabeledContent(L.string("product.metrics.first"), value: summary.firstResultSeconds.map { String(format: "%.0f s", $0) } ?? L.string("usage.unreported"))
                LabeledContent(L.string("product.metrics.tasks"), value: "\(summary.tasksCompleted) / \(summary.tasksStarted)")
                LabeledContent(L.string("product.metrics.reuse"), value: "\(summary.reusedArtifactTasks) / \(summary.tasksWithArtifacts)")
                LabeledContent(L.string("product.metrics.interventions"), value: summary.manualInterventions.formatted())
                LabeledContent(L.string("product.metrics.restore"), value: "\(summary.restoresVerified) / \(summary.restoresAttempted)")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if loading || clearing { ProgressView().controlSize(.small) }
            HStack {
                Button(L.string("common.refresh")) { Task { await load() } }.disabled(loading || clearing || !isCurrent())
                clearButton
            }.buttonStyle(.bordered)
        } header: { Text(L.string("product.metrics.title")) }
        footer: { Text(L.string("product.metrics.help")) }
        .task { await load() }
        .onAppear { visible = true }
        .onDisappear { visible = false; loadID = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: ProductTaskRunStore.didChange)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: ProductPreferencesService.didChange)) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .agroomSpaceRestored)) { _ in Task { await load() } }
    }

    private var clearButton: some View {
        Button(L.string("product.metrics.clear"), role: .destructive) { confirmingClear = true }
        .disabled(service == nil || clearing || !isCurrent())
        .alert(L.string("product.metrics.clear"), isPresented: $confirmingClear) {
            Button(L.string("product.metrics.clear"), role: .destructive) {
                Task {
                    guard visible, isCurrent(), !clearing, let service else { return }
                    clearing = true; loadID = UUID()
                    defer { clearing = false }
                    do {
                        try await service.clearMetrics()
                        await load()
                    } catch { if visible, isCurrent() { self.error = L.string("error.database") } }
                }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.metrics.clear.help")) }
    }

    private func load() async {
        guard visible, isCurrent() else { return }
        let ticket = UUID(); loadID = ticket; loading = true
        defer { if loadID == ticket { loading = false } }
        guard let service else { error = L.string("product.metrics.unavailable"); return }
        do {
            let value = try await service.metrics()
            guard visible, isCurrent(), loadID == ticket, !Task.isCancelled else { return }
            summary = value; error = nil
        } catch { if visible, isCurrent(), loadID == ticket { self.error = L.string("error.database") } }
    }
}
