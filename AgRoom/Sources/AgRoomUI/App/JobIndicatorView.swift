import SwiftUI
import AgRoomCore

/// The indicator always opens the same task center, including conversations waiting for input.
struct JobIndicatorView: View {
    let hub: Hub
    @Bindable var model: ChatViewModel
    @State private var jobs: [BackgroundJob] = []
    @State private var showingTasks = false
    @State private var clearedFailureIDs: Set<String> = []
    @State private var historyRevision = 0

    private struct FailureLookup: Equatable {
        let ids: Set<String>
        let revision: Int
    }

    private var scopedJobs: [BackgroundJob] { jobs.filter { $0.space == model.space } }
    private var activeCount: Int {
        scopedJobs.filter(\.isActive).count + model.sessions.filter { model.isSessionRunning($0.id) }.count
    }
    private var failedRunIDs: Set<String> {
        var ids = Set(scopedJobs.filter { $0.state == .failed }.map { "job:" + $0.id.uuidString })
        for session in model.sessions {
            guard let last = session.messages.last, last.role == .error else { continue }
            ids.insert("chat:" + ProductTaskRunStore.displayedRunID(for: last, in: session.id).uuidString)
        }
        return ids
    }
    var body: some View {
        let failures = failedRunIDs
        let needsAttention = !failures.isSubset(of: clearedFailureIDs)
            || !(DaemonSupervisor.shared.recoverySessionIds[model.space] ?? []).isEmpty
            || scopedJobs.contains { $0.state == .awaitingSave }
            || model.sessions.contains { $0.pendingConfirmation != nil || $0.pendingQuestion != nil }
        return Button { showingTasks = true } label: {
            HStack(spacing: 4) {
                if activeCount > 0 { ProgressView().controlSize(.mini) }
                else { Image(systemName: needsAttention ? "exclamationmark.circle" : "checklist") }
                Text(activeCount > 0 ? "\(activeCount)" : L.string("product.tasks")).font(.caption)
            }
            .foregroundStyle(needsAttention ? .orange : .primary)
        }
        .help(L.string("product.tasks"))
        .sheet(isPresented: $showingTasks) { TaskCenterPanel(hub: hub, model: model).id(model.space) }
        .task { for await snapshot in JobCenter.shared.stream(space: model.space) { jobs = snapshot } }
        .onReceive(NotificationCenter.default.publisher(for: ProductTaskCenterStore.didChange)) { _ in historyRevision &+= 1 }
        .task(id: FailureLookup(ids: failures, revision: historyRevision)) {
            guard !failures.isEmpty, let store = hub.makeTaskCenterStore(for: model.space) else {
                clearedFailureIDs = []
                return
            }
            let cleared = (try? await store.clearedHistoryIDs(among: failures)) ?? []
            if !Task.isCancelled { clearedFailureIDs = cleared }
        }
    }
}
