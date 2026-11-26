import SwiftUI
import AgRoomCore

struct NativeAppRestoreDraft: Identifiable {
    let id = UUID()
    let backup: NativeAppBackup
}

struct NativeAppDataRestoreSheet: View {
    let backup: NativeAppBackup
    let store: NativeAppStore
    let space: AppSpace
    let onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plan: NativeAppDataRestorePlan?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L.string("apps.data.restore"), systemImage: "externaldrive.badge.timemachine").font(.title2)
            Text(backup.definition.text(backup.definition.manifest.nameKey, language: LanguageManager.shared.activeLanguageCode)).font(.headline)
            Text(L.string(space.nameKey)).foregroundStyle(space.tint)
            Text(L.format("apps.data.contents", backup.recordCount, backup.fileCount))
            Text(L.string("apps.data.restore.description")).foregroundStyle(.secondary)
            Text(L.string("apps.data.shared.excluded")).font(.caption).foregroundStyle(.secondary)
            if let plan {
                if plan.previousFingerprint != nil {
                    if plan.currentDataIsUnreadable {
                        Text(L.string("apps.data.damaged")).foregroundStyle(.orange)
                    } else {
                        Text(L.format("apps.data.replace", plan.existingRecordCount, plan.existingFileCount))
                            .foregroundStyle(.orange)
                        Text(L.string("apps.data.recovery.description")).font(.caption).foregroundStyle(.secondary)
                    }
                } else { Text(L.string("apps.data.new")).font(.callout) }
            }
            if !backup.isInstalled { Text(L.string("apps.data.retained")).font(.callout).foregroundStyle(.secondary) }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button(L.string("common.retry")) { Task { await inspect() } }.disabled(busy)
            }
            Spacer()
            HStack {
                if busy || (plan == nil && error == nil) { ProgressView().controlSize(.small) }
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(L.string("apps.data.restore.confirm")) { restore() }
                    .buttonStyle(.borderedProminent).disabled(plan == nil || busy)
            }
        }.padding(24).frame(width: 620, height: 430)
        .interactiveDismissDisabled(busy)
        .task { await inspect() }
    }

    private func inspect() async {
        error = nil; plan = nil
        do {
            guard await NativeAppWindowCoordinator.shared.flush(space: space, id: backup.definition.id) else { throw NativeAppError(.storage) }
            let plan = try await store.inspectRestore(backup, space: space)
            guard !Task.isCancelled else { return }
            self.plan = plan
        } catch { if !Task.isCancelled { self.error = L.errorDescription(error) } }
    }

    private func restore() {
        guard let plan, !busy else { return }
        busy = true
        Task {
            do {
                try await NativeAppWindowCoordinator.shared.pauseForDataChange(space: space, id: backup.definition.id)
                try await store.restore(backup, space: space, replacing: plan.previousFingerprint)
                NativeAppWindowCoordinator.shared.discard(space: space, id: backup.definition.id)
                onRestore(); dismiss()
            } catch {
                NativeAppWindowCoordinator.shared.resume(space: space, id: backup.definition.id)
                self.error = L.errorDescription(error); self.plan = nil; busy = false
            }
        }
    }
}
