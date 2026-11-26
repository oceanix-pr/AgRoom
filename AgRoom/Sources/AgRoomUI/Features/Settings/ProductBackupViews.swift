import SwiftUI
import AgRoomCore

struct ProductBackupUIError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum ProductBackupPresentation {
    static func coverage(_ items: [BackupCoverageItem]) -> String {
        items.map { item in
            L.format("product.backup.coverage.row", L.string("product.backup.kind." + item.kind), item.records, item.files)
        }.joined(separator: "\n")
    }
    static func warnings(_ warnings: [BackupWarning]) -> String {
        warnings.map { L.string("product.backup.warning." + $0.rawValue) }.joined(separator: "\n")
    }
}

struct ProductBackupRestorePreview: View {
    let plan: RestorePlan
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.string("settings.backup.restore_confirm.title")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ProductBackupPresentation.coverage(plan.coverage)).textSelection(.enabled)
                    Text(L.string("product.backup.restore.behavior")).font(.callout).foregroundStyle(.secondary)
                    if !plan.conflictingSkills.isEmpty {
                        Text(L.format("settings.backup.inspect.conflicts", plan.conflictingSkills.count))
                    }
                    if !plan.conflictingApps.isEmpty { Text(L.format("product.backup.apps_conflict", plan.conflictingApps.count)) }
                    if !plan.omittedPaths.isEmpty {
                        Text(L.string("product.backup.omissions")).font(.headline)
                        Text(plan.omittedPaths.prefix(50).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                        if plan.omittedPaths.count > 50 { Text(L.format("product.backup.omissions.more", plan.omittedPaths.count - 50)).font(.caption) }
                    }
                    if plan.spaceMismatch {
                        Text(L.format("settings.backup.inspect.crossSpace", plan.manifest.space)).foregroundStyle(.orange)
                    }
                    if plan.integrityUnverified { Text(L.string("settings.backup.inspect.unverified")).foregroundStyle(.orange) }
                    if !plan.warnings.isEmpty { Text(ProductBackupPresentation.warnings(plan.warnings)).foregroundStyle(.orange) }
                    if !plan.corruptSections.isEmpty { Text(L.string("product.backup.error.preflight")).foregroundStyle(.red) }
                    Text(L.string("product.backup.excluded")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L.string("common.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L.string("settings.backup.restore_confirm.confirm"), role: .destructive, action: confirm)
                    .disabled(!plan.corruptSections.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560, height: 570)
    }
}

struct ProductRestorePointsSection: View {
    let service: BackupService?
    let space: AppSpace
    @State private var points: [BackupRestorePoint] = []
    @State private var selected: BackupRestorePoint?
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        Section {
            if points.isEmpty { Text(L.string("product.backup.points.empty")).foregroundStyle(.secondary) }
            ForEach(points) { point in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.createdAt, format: .dateTime.year().month().day().hour().minute())
                        Text(L.format("product.backup.points.summary", point.sessions, point.memories, point.skills, point.files))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L.string("product.backup.points.undo"), role: .destructive) { selected = point }.disabled(busy)
                }
            }
            HStack {
                Button(L.string("apps.refresh")) { Task { await load() } }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        } header: { Text(L.string("product.backup.points.title")) }
        footer: { Text(L.string("product.backup.points.help")) }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .agroomSpaceRestored)) { note in
            guard note.object as? String == space.rawValue else { return }
            Task { await load() }
        }
        .confirmationDialog(L.string("product.backup.points.undo"), isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                if let selected {
                    Button(L.string("product.backup.points.undo"), role: .destructive) {
                        self.selected = nil
                        Task { await undo(selected) }
                    }
                }
                Button(L.string("common.cancel"), role: .cancel) { selected = nil }
        } message: { Text(L.string("product.backup.points.confirm")) }
    }

    private func load() async {
        guard let service, !busy else { return }
        do { points = try await service.restorePoints() }
        catch { status = L.errorDescription(error) }
    }

    private func undo(_ point: BackupRestorePoint) async {
        guard let service, !busy else { return }
        busy = true
        do {
            try await service.undoRestorePoint(id: point.id)
            status = L.string("product.backup.points.done")
        } catch let error as BackupError { status = L.errorDescription(error) }
        catch { status = L.string("product.backup.points.changed") }
        busy = false
        await load()
    }
}
