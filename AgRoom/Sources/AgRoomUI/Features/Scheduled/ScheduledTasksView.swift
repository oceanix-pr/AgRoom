import SwiftUI
import AppKit
import AgRoomCore

// MARK: - Scheduled Tasks View

/// 定时任务页：左侧任务定义，右侧触发信息、指令、运行记录与手动操作。
/// P0a 只支持只读 Agent 任务；没有运行数据时展示真实空态。
@MainActor
public struct ScheduledTasksView: View {
    let hub: Hub
    private let space: AppSpace
    private let source: ProductRoute?
    private let observeHostServices: Bool

    @AppStorage(DispatcherSettings.scheduledTasksEnabledKey) private var scheduledEnabled = false
    @State private var center = ScheduledTaskCenter.shared
    @State private var tasks: [ScheduledTask] = []
    @State private var selectedTaskID: UUID?
    @State private var runs: [ScheduledRun] = []
    @State private var expandedRunIDs: Set<UUID> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var editorRequest: EditorRequest?
    @State private var taskPendingDeletion: ScheduledTask?
    @State private var isDeleting = false
    @State private var modelPrice: ProductModelPrice?

    private struct EditorRequest: Identifiable {
        let id: UUID
        let task: ScheduledTask
        let isNew: Bool
    }

    private enum UIError: Error {
        case databaseUnavailable
        case notFound
    }

    public init(hub: Hub) {
        self.init(hub: hub, source: nil)
    }

    init(hub: Hub, source: ProductRoute?, observeHostServices: Bool = true, center: ScheduledTaskCenter = .shared) {
        self.hub = hub; self.space = hub.spaceStore.current
        self.source = source?.space == hub.spaceStore.current ? source : nil
        self.observeHostServices = observeHostServices
        self._center = State(initialValue: center)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !scheduledEnabled {
                disabledBanner
                Divider()
            }
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 300)
                Divider()
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: source?.id) {
            if let requested = source?.taskID { selectedTaskID = requested }
            await load()
            if !Task.isCancelled, let requested = source?.taskID {
                if tasks.contains(where: { $0.id == requested }) {
                    selectedTaskID = requested
                    if let runID = source?.runID { expandedRunIDs.insert(runID) }
                    await loadRuns()
                } else { selectedTaskID = nil; show(L.string("product.tasks.source_unavailable")) }
            }
            if !Task.isCancelled, hub.spaceStore.current == space, let draft = source?.scheduledDraft, draft.space == space {
                if tasks.contains(where: { $0.id == draft.task.id }) { selectedTaskID = draft.task.id; await loadRuns() }
                else { editorRequest = EditorRequest(id: draft.task.id, task: draft.task, isNew: true) }
            }
            if observeHostServices { center.refreshNow() }
        }
        .task(id: selectedTaskID) {
            await loadRuns()
        }
        .onChange(of: center.revision) { _, _ in
            Task { await load() }
        }
        .onChange(of: scheduledEnabled) { _, value in
            if observeHostServices { center.schedulingSettingChanged(to: value) }
            Task { await load() }
        }
        .sheet(item: $editorRequest) { request in
            ScheduledTaskEditor(
                original: request.task,
                isNew: request.isNew, space: space, masterEnabled: scheduledEnabled, price: modelPrice,
                isCurrent: { hub.spaceStore.current == space },
                onSave: { task in try await save(task, isNew: request.isNew) }
            )
        }
        .confirmationDialog(
            L.string("scheduled.delete_confirm.title"),
            isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L.string("common.delete"), role: .destructive) {
                if let task = taskPendingDeletion { delete(task) }
                taskPendingDeletion = nil
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            if let task = taskPendingDeletion {
                Text(L.format("scheduled.delete_confirm.message", task.name))
            }
        }
        .alert(L.string("common.error"), isPresented: $showError) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L.string("nav.scheduled"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Button {
                    newTask()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(L.string("scheduled.new"))
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L.string("scheduled.refresh"))
                .disabled(isLoading)
            }
            .padding(.horizontal, 12)
            .columnHeader()

            Divider()

            if tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(tasks) { task in
                            taskRow(task)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ContentUnavailableView {
                Label(L.string("scheduled.empty"), systemImage: "calendar.badge.clock")
            } description: {
                Text(L.string("scheduled.empty.desc"))
            }
            Button(L.string("scheduled.new")) {
                newTask()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        let isSelected = selectedTaskID == task.id
        return Button {
            selectedTaskID = task.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(task.enabled ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(task.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(scheduleSummary(task.schedule))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let next = task.nextFireAt, task.enabled {
                        Text(L.format("scheduled.next_short", next.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
                    } else if !task.enabled {
                        Text(L.string("scheduled.disabled"))
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    if center.activeTaskIDs(in: space).contains(task.id) {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .primary)
        .contextMenu {
            Button(L.string("scheduled.run_now")) { runNow(task) }
                .disabled(!scheduledEnabled || center.isRunning(taskID: task.id, space: space))
            Button(L.string("common.edit")) { edit(task) }
            Divider()
            Button(L.string("common.delete"), role: .destructive) {
                taskPendingDeletion = task
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailColumn: some View {
        if let task = selectedTask {
            taskDetail(task)
        } else {
            ContentUnavailableView {
                Label(L.string("scheduled.empty"), systemImage: "calendar.badge.clock")
            } description: {
                Text(L.string("scheduled.empty.desc"))
            }
        }
    }

    private var selectedTask: ScheduledTask? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    private func taskDetail(_ task: ScheduledTask) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(task)
                    promptCard(task)
                    historyCard
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .task(id: "\(source?.id.uuidString ?? ""):\(runs.contains { $0.id == source?.runID })") {
                guard let id = source?.runID, source?.taskID == task.id, runs.contains(where: { $0.id == id }) else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func header(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(scheduleSummary(task.schedule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle(L.string("scheduled.enabled"), isOn: Binding(
                    get: { task.enabled },
                    set: { updateEnabled(task, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isDeleting)
            }

            HStack(spacing: 8) {
                StatusBadge(
                    text: lastRunText(task),
                    color: statusColor(task.lastRunStatus)
                )
                if center.activeTaskIDs(in: space).contains(task.id) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(L.string("scheduled.running"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if center.hasPendingResult(taskID: task.id, space: space) {
                    Button(L.string("scheduled.result.retry_save")) { Task { await center.retrySaving(taskID: task.id, space: space); await load() } }
                        .disabled(center.isSavingResult(taskID: task.id, space: space))
                } else if center.activeTaskIDs(in: space).contains(task.id) {
                    Button(L.string("scheduled.stop")) {
                        center.cancel(taskID: task.id, space: space)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        runNow(task)
                    } label: {
                        Label(L.string("scheduled.run_now"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!scheduledEnabled || !task.isProfileSupported)
                }
                Button(L.string("common.edit")) { edit(task) }
                    .buttonStyle(.bordered)
                Button(L.string("common.delete"), role: .destructive) {
                    taskPendingDeletion = task
                }
                .buttonStyle(.bordered)
                .disabled(isDeleting)
            }

            HStack(spacing: 16) {
                Label(
                    L.format("scheduled.next_run_value", nextRunText(task)),
                    systemImage: "calendar.badge.clock"
                )
                Label(
                    L.format("scheduled.last_run_value", lastRunValue(task)),
                    systemImage: "clock.arrow.circlepath"
                )
                Label(task.schedule.timeZoneIdentifier, systemImage: "globe")
                Label(
                    L.format(
                        "scheduled.capability.summary",
                        ScheduledCapabilityProfile.maxSteps,
                        ScheduledCapabilityProfile.maxOutputTokens,
                        Int(ScheduledCapabilityProfile.wallClockSeconds)
                    ),
                    systemImage: "lock.shield"
                )
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(L.format("scheduled.budget.summary", task.effectiveOptions.budget.maxTokens,
                task.effectiveOptions.budget.maxToolCalls, task.effectiveOptions.budget.seconds)).font(.caption)
            if task.effectiveOptions.notifyOnlyOnChange { Text(L.string("scheduled.comparison.policy")).font(.caption).foregroundStyle(.secondary) }
            if center.hasPendingResult(taskID: task.id, space: space) { Text(L.string("scheduled.result.unsaved")).font(.caption).foregroundStyle(.orange) }
            Text(L.string("scheduled.misfire.help")).font(.caption).foregroundStyle(.secondary)
            Text(L.string("scheduled.app_running_note"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .meetCard()
    }

    private func promptCard(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.string("scheduled.prompt"))
                .font(.headline)
            Text(task.prompt)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .meetCard()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.string("scheduled.history"))
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    Task { await loadRuns() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L.string("scheduled.refresh"))
            }
            if runs.isEmpty {
                Text(L.string("scheduled.history.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(runs) { run in
                    runRow(run)
                        .id(run.id)
                    if run.id != runs.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .meetCard()
    }

    private func runRow(_ run: ScheduledRun) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedRunIDs.contains(run.id) }, set: { expanded in
            if expanded { expandedRunIDs.insert(run.id) } else { expandedRunIDs.remove(run.id) }
        })) {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = run.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let output = run.outputText, !output.isEmpty {
                    MarkdownView(text: output, documentID: run.id.uuidString, sourceContext: .scoped(to: space))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = run.errorText, !error.isEmpty {
                    Text(ScheduledResultText.error(run) ?? error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !run.toolNames.isEmpty {
                    Text(run.toolNames.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                ScheduledRunInfoView(hub: hub, space: space, run: run)
                if run.isTerminal, !(run.outputText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScheduledResultActionsView(hub: hub, space: space, run: run) {
                        ProductRoute.open(space: space, page: "chat", draft: $0)
                    }.id(run.id)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                StatusBadge(text: runStatusText(run.status), color: statusColor(run.status))
                Text(triggerText(run.trigger))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let started = run.startedAt {
                    Text(started.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if let duration = run.durationMs {
                    Text(String(format: "%.1fs", Double(duration) / 1000))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var disabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(L.string("scheduled.disabled.banner"))
                .font(.caption)
            Spacer(minLength: 0)
            Button(L.string("scheduled.open_settings")) {
                ProductRoute.open(space: space, page: HubNavItem.settings.rawValue)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Data

    private func load() async {
        guard let taskStore = hub.makeScheduledTaskStore(for: space) else {
            show(L.string("scheduled.error.database_unavailable"))
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await taskStore.all()
            guard !Task.isCancelled else { return }
            tasks = loaded
            let prices = try await hub.makeProductPreferencesService(for: space)?.load([ProductModelPrice].self, key: "model-prices") ?? []
            let providers = try await hub.providerService?.getAll().filter(\.isEnabled) ?? []
            let preferred = UserDefaults.standard.string(forKey: "agroom.chat.providerId").flatMap(UUID.init(uuidString:))
            let provider = providers.first { $0.id == preferred } ?? providers.first
            guard !Task.isCancelled, hub.spaceStore.current == space else { return }
            modelPrice = provider.flatMap { selected in prices.first { $0.model == selected.model && $0.applies(to: selected) } }
            if let selectedTaskID, loaded.contains(where: { $0.id == selectedTaskID }) {
                // 保留当前选择
            } else {
                selectedTaskID = source?.taskID == nil ? loaded.first?.id : nil
            }
            await loadRuns()
        } catch {
            show(L.string("scheduled.error.load_failed"))
            HubLogger.shared.error("Scheduled task load failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    private func loadRuns() async {
        guard let selectedTaskID, let runStore = hub.makeScheduledRunStore(for: space) else {
            runs = []
            return
        }
        do {
            var loaded = try await runStore.runs(taskID: selectedTaskID, limit: 50)
            if source?.taskID == selectedTaskID, let id = source?.runID, !loaded.contains(where: { $0.id == id }),
               let older = try await runStore.run(id: id), older.taskID == selectedTaskID { loaded.append(older) }
            guard !Task.isCancelled, self.selectedTaskID == selectedTaskID else { return }
            runs = loaded
            if source?.taskID == selectedTaskID, let id = source?.runID, !loaded.contains(where: { $0.id == id }) {
                show(L.string("product.tasks.source_unavailable"))
            }
        } catch {
            guard self.selectedTaskID == selectedTaskID, !Task.isCancelled else { return }
            runs = []
            HubLogger.shared.error("Scheduled run load failed: \(HubLogger.safeErrorSummary(error))")
        }
    }

    private func save(_ task: ScheduledTask, isNew: Bool) async throws {
        guard hub.spaceStore.current == space, !Task.isCancelled else { throw ScheduledExperienceError.changed }
        guard let store = hub.makeScheduledTaskStore(for: space) else {
            throw UIError.databaseUnavailable
        }
        if isNew {
            try await store.insert(task)
        } else {
            try await store.update(task)
            guard try await store.task(id: task.id) != nil else {
                throw UIError.notFound
            }
        }
        selectedTaskID = task.id
        await load()
        if observeHostServices { center.refreshNow() }
    }

    private func updateEnabled(_ task: ScheduledTask, enabled: Bool) {
        Task {
            guard let store = hub.makeScheduledTaskStore(for: space) else {
                show(L.string("scheduled.error.database_unavailable"))
                return
            }
            do {
                try await store.setEnabled(id: task.id, enabled: enabled, recalculateAt: Date())
                await load()
                center.refreshNow()
            } catch {
                show(error is ScheduledTaskValidationError ? L.errorDescription(error) : L.string("scheduled.error.toggle_failed"))
                await load()
            }
        }
    }

    private func delete(_ task: ScheduledTask) {
        isDeleting = true
        center.cancel(taskID: task.id, space: space)
        Task {
            defer { isDeleting = false }
            guard let store = hub.makeScheduledTaskStore(for: space) else {
                show(L.string("scheduled.error.database_unavailable"))
                return
            }
            do {
                try await store.delete(id: task.id)
                selectedTaskID = nil
                await load()
                center.refreshNow()
            } catch {
                show(L.string("scheduled.error.delete_failed"))
            }
        }
    }

    private func runNow(_ task: ScheduledTask) {
        Task {
            do {
                try await center.runNow(taskID: task.id, space: space)
                await load()
            } catch {
                show(centerErrorText(error))
            }
        }
    }

    private func newTask() {
        let now = Date()
        let task = ScheduledTask(
            name: "",
            enabled: true,
            prompt: "",
            schedule: ScheduledTaskSchedule(
                rule: .daily(hour: 9, minute: 0),
                timeZoneIdentifier: TimeZone.current.identifier
            ),
            createdAt: now,
            updatedAt: now
        )
        editorRequest = EditorRequest(id: task.id, task: task, isNew: true)
    }

    private func edit(_ task: ScheduledTask) {
        editorRequest = EditorRequest(id: task.id, task: task, isNew: false)
    }

    // MARK: - Text

    private func show(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func centerErrorText(_ error: Error) -> String {
        guard let error = error as? ScheduledTaskCenterError else {
            return L.string("scheduled.error.start_failed")
        }
        switch error {
        case .disabled: return L.string("scheduled.error.disabled")
        case .busy: return L.string("scheduled.error.busy")
        case .notFound: return L.string("scheduled.error.not_found")
        case .databaseUnavailable: return L.string("scheduled.error.database_unavailable")
        case .unsupportedProfile: return L.string("scheduled.error.unsupported_profile")
        case .startFailed: return L.string("scheduled.error.start_failed")
        }
    }

    private func scheduleSummary(_ schedule: ScheduledTaskSchedule) -> String {
        switch schedule.rule {
        case .once(let date):
            return L.format("scheduled.summary.once", date.formatted(date: .abbreviated, time: .shortened))
        case .daily(let hour, let minute):
            return L.format("scheduled.summary.daily", timeText(hour: hour, minute: minute))
        case .weekly(let weekdays, let hour, let minute):
            let days = weekdays.sorted().map { L.string("scheduled.weekday.\($0)") }
                .joined(separator: L.string("scheduled.weekday.separator"))
            return L.format("scheduled.summary.weekly", days, timeText(hour: hour, minute: minute))
        case .interval(let minutes, _):
            return L.format("scheduled.summary.interval", minutes)
        }
    }

    private func timeText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private func nextRunText(_ task: ScheduledTask) -> String {
        guard let next = task.nextFireAt, task.enabled else {
            return L.string("scheduled.no_next_run")
        }
        return next.formatted(date: .abbreviated, time: .shortened)
    }

    private func lastRunText(_ task: ScheduledTask) -> String {
        guard let status = task.lastRunStatus else {
            return L.string("scheduled.never_run")
        }
        return runStatusText(status)
    }

    private func lastRunValue(_ task: ScheduledTask) -> String {
        guard let date = task.lastRunAt else {
            return L.string("scheduled.never_run")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func runStatusText(_ status: ScheduledRunStatus) -> String {
        L.string("scheduled.status.\(status.rawValue)")
    }

    private func triggerText(_ trigger: ScheduledRunTrigger) -> String {
        L.string("scheduled.trigger.\(trigger.rawValue)")
    }

    private func statusColor(_ status: ScheduledRunStatus?) -> Color {
        guard let status else { return .secondary }
        switch status {
        case .succeeded: return .green
        case .failed: return .red
        case .missed: return .orange
        case .skipped, .cancelled, .interrupted: return .secondary
        case .pending, .running: return .blue
        }
    }
}

// MARK: - Editor

@MainActor
struct ScheduledTaskEditor: View {
    let original: ScheduledTask
    let isNew: Bool
    let space: AppSpace
    let masterEnabled: Bool
    let price: ProductModelPrice?
    let isCurrent: @MainActor () -> Bool
    let onSave: @MainActor (ScheduledTask) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduledTask
    @State private var kind: RuleKind
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var intervalMinutes: Int
    @State private var intervalAnchor: Date
    @State private var onceDate: Date
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var options: ScheduledTaskOptions
    @State private var zoneIdentifier: String
    @State private var editorTimeZone: TimeZone

    private enum RuleKind: String, CaseIterable, Identifiable {
        case daily
        case weekly
        case interval
        case once

        var id: String { rawValue }
    }

    init(
        original: ScheduledTask,
        isNew: Bool, space: AppSpace, masterEnabled: Bool, price: ProductModelPrice? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        onSave: @escaping @MainActor (ScheduledTask) async throws -> Void
    ) {
        self.original = original
        self.isNew = isNew; self.space = space; self.masterEnabled = masterEnabled; self.price = price; self.isCurrent = isCurrent
        self.onSave = onSave
        _options = State(initialValue: original.effectiveOptions)
        _zoneIdentifier = State(initialValue: original.schedule.timeZoneIdentifier)
        _editorTimeZone = State(initialValue: original.schedule.timeZone)
        _draft = State(initialValue: original)

        var kind: RuleKind = .daily
        var time = Self.makeTime(hour: 9, minute: 0, zone: original.schedule.timeZone)
        var weekdays: Set<Int> = [1, 2, 3, 4, 5]
        var intervalMinutes = 60
        var intervalAnchor = Date()
        var onceDate = Date().addingTimeInterval(3_600)
        switch original.schedule.rule {
        case .once(let date):
            kind = .once
            onceDate = date
        case .daily(let hour, let minute):
            kind = .daily
            time = Self.makeTime(hour: hour, minute: minute, zone: original.schedule.timeZone)
        case .weekly(let days, let hour, let minute):
            kind = .weekly
            weekdays = Set(days)
            time = Self.makeTime(hour: hour, minute: minute, zone: original.schedule.timeZone)
        case .interval(let minutes, let anchor):
            kind = .interval
            intervalMinutes = minutes
            intervalAnchor = anchor
        }
        _kind = State(initialValue: kind)
        _time = State(initialValue: time)
        _weekdays = State(initialValue: weekdays)
        _intervalMinutes = State(initialValue: intervalMinutes)
        _intervalAnchor = State(initialValue: intervalAnchor)
        _onceDate = State(initialValue: onceDate)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string(isNew ? "scheduled.editor.title.new" : "scheduled.editor.title.edit"))
                    .font(.headline)
                Spacer()
                Text(L.string(space.nameKey)).foregroundStyle(space.tint)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 5) {
                Text(L.format("scheduled.next_run_value", nextPreviewText) + " · " + zoneIdentifier)
                if options.budget.isValid {
                    Text(L.format("scheduled.budget.summary", options.budget.maxTokens, options.budget.maxToolCalls, options.budget.seconds))
                } else { Text(L.string("scheduled.budget.range")).foregroundStyle(.orange) }
                Text(L.string("scheduled.app_running_note"))
                if !masterEnabled { Text(L.string("scheduled.disabled.banner")).foregroundStyle(.orange) }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 10)
            Divider()

            Form {
                Section {
                    TextField(L.string("scheduled.editor.name_placeholder"), text: $draft.name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.string("scheduled.editor.prompt"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draft.prompt)
                            .font(.system(size: 13))
                            .frame(minHeight: 130)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }

                Section {
                    Picker(L.string("scheduled.editor.schedule"), selection: $kind) {
                        ForEach(RuleKind.allCases) { kind in
                            Text(L.string("scheduled.editor.\(kind.rawValue)")).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .daily:
                        DatePicker(
                            L.string("scheduled.editor.time"),
                            selection: $time,
                            displayedComponents: .hourAndMinute
                        )
                    case .weekly:
                        DatePicker(
                            L.string("scheduled.editor.time"),
                            selection: $time,
                            displayedComponents: .hourAndMinute
                        )
                        HStack(spacing: 5) {
                            ForEach(1...7, id: \.self) { day in
                                Button {
                                    if weekdays.contains(day) {
                                        weekdays.remove(day)
                                    } else {
                                        weekdays.insert(day)
                                    }
                                } label: {
                                    Text(L.string("scheduled.weekday.\(day)"))
                                        .font(.caption)
                                        .frame(width: 30, height: 26)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(weekdays.contains(day)
                                                      ? Color.accentColor.opacity(0.2)
                                                      : Color.secondary.opacity(0.1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer(minLength: 0)
                        }
                    case .interval:
                        Stepper(
                            L.format("scheduled.editor.interval_value", intervalMinutes),
                            value: $intervalMinutes,
                            in: 5...1_440,
                            step: 5
                        )
                    case .once:
                        DatePicker(
                            L.string("scheduled.editor.once_at"),
                            selection: $onceDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }

                    TextField(L.string("scheduled.editor.timezone.label"), text: $zoneIdentifier)
                    Text(L.format("scheduled.editor.timezone", zoneIdentifier))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L.string("product.budget.title")) {
                    TextField(L.string("product.budget.tokens"), value: $options.budget.maxTokens, format: .number)
                    TextField(L.string("product.budget.tools"), value: $options.budget.maxToolCalls, format: .number)
                    TextField(L.string("scheduled.budget.seconds"), value: $options.budget.seconds, format: .number)
                    Text(L.string("scheduled.budget.range")).font(.caption).foregroundStyle(.secondary)
                    if options.budget.isValid, let price, price.isValid {
                        let estimate = Double(options.budget.maxTokens) * max(price.inputPerMillion, price.outputPerMillion) / 1_000_000
                        Text(L.format("product.budget.price", price.currency + " " + String(format: "%.4f", estimate)))
                    } else { Text(L.string("product.budget.price.unknown")).font(.caption) }
                    Text(L.string("scheduled.price.help")).font(.caption).foregroundStyle(.secondary)
                }

                Section(L.string("scheduled.comparison.title")) {
                    Toggle(L.string("scheduled.comparison.enabled"), isOn: $options.notifyOnlyOnChange)
                    if options.notifyOnlyOnChange {
                        TextField(L.string("scheduled.comparison.criterion"), text: $options.comparisonInstructions, axis: .vertical).lineLimit(2...5)
                        Text(L.string("scheduled.comparison.policy")).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(L.string("scheduled.editor.enabled"), isOn: $draft.enabled)
                    Toggle(
                        L.string(options.notifyOnlyOnChange ? "scheduled.editor.notify_changed" : "scheduled.editor.notify_success"),
                        isOn: $draft.notificationPolicy.notifyOnSuccess
                    )
                    Toggle(
                        L.string("scheduled.editor.notify_failure"),
                        isOn: $draft.notificationPolicy.notifyOnFailure
                    )
                    Toggle(
                        L.string("scheduled.editor.notify_missed"),
                        isOn: $draft.notificationPolicy.notifyOnMissed
                    )
                    Text(L.format(
                        "scheduled.editor.profile_note",
                        ScheduledCapabilityProfile.maxSteps,
                        ScheduledCapabilityProfile.maxOutputTokens,
                        Int(ScheduledCapabilityProfile.wallClockSeconds)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(L.string("scheduled.editor.review")) {
                    Text(L.string(space.nameKey)).bold()
                    if let next = ScheduleCalculator.nextFireDate(for: buildSchedule(), after: Date()), draft.enabled {
                        Text(L.format("scheduled.next_run_value", next.formatted(date: .abbreviated, time: .shortened)))
                    } else { Text(L.string("scheduled.no_next_run")) }
                    Text(L.string("scheduled.misfire.help"))
                    Text(L.string("scheduled.app_running_note"))
                    if !masterEnabled { Text(L.string("scheduled.disabled.banner")).foregroundStyle(.orange) }
                    Text(L.string("scheduled.draft.confirm.help"))
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .environment(\.timeZone, editorTimeZone)
            .disabled(isSaving)
            .onChange(of: zoneIdentifier) { _, next in
                guard let zone = TimeZone(identifier: next), zone != editorTimeZone else { return }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = editorTimeZone
                let parts = calendar.dateComponents([.hour,.minute], from: time)
                time = Self.makeTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0, zone: zone)
                editorTimeZone = zone
            }

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSaving)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(L.string("scheduled.draft.confirm"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(16)
        }
        .frame(width: 680, height: 720)
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        guard !isSaving, isCurrent(), !Task.isCancelled else { return }
        isSaving = true
        defer { isSaving = false }

        var candidate = draft
        candidate.schedule = buildSchedule()
        candidate.options = options
        candidate.updatedAt = Date()
        candidate.nextFireAt = candidate.enabled
            ? ScheduleCalculator.nextFireDate(for: candidate.schedule, after: Date())
            : nil

        if let validation = candidate.validate() {
            if validation == .onceInPast && !candidate.enabled {
                // 已停用的一次任务允许保留历史日期；启用时才要求未来时间。
            } else {
                errorMessage = localized(validation)
                return
            }
        }
        if candidate.enabled && candidate.nextFireAt == nil {
            errorMessage = L.string("scheduled.error.once_in_past")
            return
        }

        do {
            try await onSave(candidate)
            dismiss()
        } catch {
            errorMessage = L.string("scheduled.error.save_failed")
        }
    }

    private func buildSchedule() -> ScheduledTaskSchedule {
        let rule: ScheduledTaskSchedule.ScheduledRule
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = editorTimeZone
        switch kind {
        case .daily:
            let components = calendar.dateComponents([.hour, .minute], from: time)
            rule = .daily(hour: components.hour ?? 9, minute: components.minute ?? 0)
        case .weekly:
            let components = calendar.dateComponents([.hour, .minute], from: time)
            rule = .weekly(
                weekdays: weekdays.sorted(),
                hour: components.hour ?? 9,
                minute: components.minute ?? 0
            )
        case .interval:
            rule = .interval(minutes: intervalMinutes, anchor: intervalAnchor)
        case .once:
            rule = .once(onceDate)
        }
        return ScheduledTaskSchedule(
            rule: rule,
            timeZoneIdentifier: zoneIdentifier
        )
    }

    private var nextPreviewText: String {
        guard draft.enabled, let next = ScheduleCalculator.nextFireDate(for: buildSchedule(), after: Date()) else { return L.string("scheduled.no_next_run") }
        let formatter = DateFormatter(); formatter.timeZone = editorTimeZone
        formatter.locale = Locale(identifier: LanguageManager.shared.activeLanguageCode)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: next)
    }

    private static func makeTime(hour: Int, minute: Int, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func localized(_ error: ScheduledTaskValidationError) -> String {
        L.string("scheduled.error." + error.code)
    }
}
