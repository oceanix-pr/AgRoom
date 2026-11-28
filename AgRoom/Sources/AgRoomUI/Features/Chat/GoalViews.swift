import SwiftUI
import AgRoomCore

struct GoalEditorPresentation: Identifiable {
    let id = UUID()
    let sessionID: UUID?
    let definition: GoalDefinition
    var existing: ExecutionGoal? = nil
    var draftID: UUID? = nil
}

@MainActor enum GoalSetupInput {
    /// Keep the full objective intact; only the display title is shortened.
    static func makeDefinition(title: String = "", objective: String, criteria: String = "", constraints: String = "",
                               requireChecks: Bool = false) -> GoalDefinition {
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let automaticName = String((objective.components(separatedBy: .newlines).first ?? objective).prefix(60))
        var checks = criteria.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { GoalCriterion(text: $0) }
        if checks.isEmpty { checks = [GoalCriterion(text: L.string("goal.criteria.default"))] }
        if requireChecks { checks.append(GoalCriterion(kind: .executionCheck, text: "execution_check")) }
        return .init(title: name.isEmpty ? automaticName : name, objective: objective, criteria: checks,
                     constraints: constraints)
    }
}

struct GoalComposerNotice: View {
    let hasAttachments: Bool
    let objectiveIsTooLong: Bool
    let submitting: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(L.string("goal.composer.mode"), systemImage: "target").font(.caption.bold())
                Text(L.string("goal.composer.help")).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if submitting { ProgressView().controlSize(.small) }
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).disabled(submitting)
                    .accessibilityLabel(L.string("goal.composer.cancel"))
            }
            if hasAttachments {
                Text(L.string("goal.composer.attachments")).font(.caption).foregroundStyle(.orange)
            }
            if objectiveIsTooLong {
                Text(L.string("goal.composer.tooLong")).font(.caption).foregroundStyle(.orange)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("chat.goal.notice")
    }
}

struct GoalSetupSheet: View {
    let context: GoalEditorPresentation
    let space: AppSpace
    let workspaceName: String
    let permissionMode: PermissionMode
    let onCommit: @MainActor (GoalDefinition) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var objective: String
    @State private var criteria: String
    @State private var constraints: String
    @State private var requireChecks: Bool
    @State private var saving = false
    @State private var showAdvanced: Bool
    @FocusState private var objectiveFocused: Bool

    init(context: GoalEditorPresentation, space: AppSpace, workspaceName: String, permissionMode: PermissionMode,
         onCommit: @escaping @MainActor (GoalDefinition) async -> Bool) {
        self.context = context; self.space = space; self.workspaceName = workspaceName
        self.permissionMode = permissionMode; self.onCommit = onCommit
        let value = context.definition
        _title = State(initialValue: value.title); _objective = State(initialValue: value.objective)
        _criteria = State(initialValue: value.criteria.filter { $0.kind == .manual }.map(\.text).joined(separator: "\n"))
        _constraints = State(initialValue: value.constraints)
        _requireChecks = State(initialValue: value.criteria.contains { $0.kind == .executionCheck })
        _showAdvanced = State(initialValue: context.existing != nil)
    }
    private var definition: GoalDefinition {
        if context.existing != nil {
            return context.definition
        }
        return GoalSetupInput.makeDefinition(title: title, objective: objective, criteria: criteria, constraints: constraints,
                                   requireChecks: requireChecks)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string(context.existing == nil ? "goal.setup" : "goal.resume")).font(.title2.bold())
            Text(L.string("goal.scope.help")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Label(L.string(space.nameKey), systemImage: "square.stack.3d.up")
                Label(workspaceName, systemImage: "folder")
                Text(L.string("chat.permission.preset." + permissionMode.rawValue))
            }.font(.caption)
            if let goal = context.existing {
                Text(L.format("goal.usage", goal.spentTokens, goal.toolCalls, goal.attemptCount)).font(.caption)
                if goal.usageIsIncomplete == true { Text(L.string("goal.usage.incomplete")).font(.caption).foregroundStyle(.secondary) }
                Text(L.string("goal.resume.help")).font(.callout).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L.string("goal.objective.prompt")).font(.headline)
                    TextEditor(text: $objective)
                        .font(.body).frame(minHeight: 110, maxHeight: 150)
                        .padding(6).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(L.string("goal.objective"))
                        .accessibilityIdentifier("goal.setup.objective")
                        .focused($objectiveFocused)
                        .disabled(context.existing != nil)
                    Text(L.string("goal.objective.help")).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(L.string("goal.advanced"), isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            Form {
                                TextField(L.string("goal.name.optional"), text: $title)
                                LabeledContent(L.string("goal.criteria")) { TextEditor(text: $criteria).frame(height: 90) }
                                Toggle(L.string("goal.execution_check"), isOn: $requireChecks)
                                Text(L.string("goal.criteria.help")).font(.caption).foregroundStyle(.secondary)
                                TextField(L.string("goal.constraints"), text: $constraints, axis: .vertical).lineLimit(2...4)
                            }.disabled(context.existing != nil)
                            Text(L.string("goal.runtime.help")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }
            }.disabled(saving)
            Text(L.string("goal.start.help")).font(.caption).foregroundStyle(.secondary)
            if !definition.isValid && !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L.string("goal.error.invalid")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(L.string(context.existing == nil ? "goal.start" : "goal.resume")) {
                    let approvedDefinition = definition
                    saving = true
                    Task { if await onCommit(approvedDefinition) { dismiss() }; saving = false }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || !definition.isValid)
                    .accessibilityIdentifier("goal.setup.commit")
            }
        }.padding(20).frame(width: 620, height: 560).interactiveDismissDisabled(saving)
            .task { objectiveFocused = context.existing == nil }
    }
}

struct GoalProgressCard: View {
    let goal: ExecutionGoal
    let busy: Bool
    let savePending: Bool
    let onPause: () -> Void
    let onCancel: () -> Void
    let onResume: () -> Void
    let onReview: (Set<UUID>) -> Void
    let onRetrySave: () -> Void
    var onOpenResult: () -> Void = {}
    @State private var expanded = false
    @State private var passed: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(goal.definition.title, systemImage: "target").font(.headline).lineLimit(1)
                Text(L.string("goal.status." + goal.status.rawValue)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(L.format("goal.progress", goal.passedCount, goal.definition.criteria.count)).font(.caption)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.plain).accessibilityLabel(L.string("goal.details"))
            }
            Text(L.format("goal.usage", goal.spentTokens, goal.toolCalls, goal.attemptCount))
                .font(.caption).foregroundStyle(.secondary)
            if goal.usageIsIncomplete == true { Text(L.string("goal.usage.incomplete")).font(.caption).foregroundStyle(.secondary) }
            if savePending { Text(L.string("goal.save_pending")).font(.caption).foregroundStyle(.orange) }
            else if let reason = goal.stopReason, reason != .modelFinished {
                Text(L.string("goal.reason." + reason.rawValue)).font(.caption).foregroundStyle(.secondary)
            }
            if expanded {
                Text(goal.definition.objective).font(.callout).textSelection(.enabled)
                if let progress = goal.progress { Text(progress.summary).font(.caption).textSelection(.enabled) }
                if let progress = goal.progress, !progress.nextActions.isEmpty {
                    ForEach(Array(progress.nextActions.enumerated()), id: \.offset) { _, action in
                        Text(action).font(.caption).textSelection(.enabled)
                    }
                }
                ForEach(goal.definition.criteria) { criterion in
                    if criterion.kind == .manual && !busy && !goal.status.isTerminal && goal.latestRunID != nil && !savePending {
                        Toggle(criterion.text, isOn: Binding(get: { passed.contains(criterion.id) }, set: {
                            if $0 { passed.insert(criterion.id) } else { passed.remove(criterion.id) }
                        })).toggleStyle(.checkbox)
                    } else {
                        Label(criterion.kind == .executionCheck ? L.string("goal.execution_check") : criterion.text,
                            systemImage: criterion.verdict == .passed ? "checkmark.circle.fill" : (criterion.verdict == .failed ? "xmark.circle" : "circle"))
                            .font(.caption)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }.controlSize(.small)
        }.padding(12).background(Color.accentColor.opacity(0.06))
            .onChange(of: goal.revision, initial: true) { _, _ in
                passed = Set(goal.definition.criteria.filter { $0.kind == .manual && $0.verdict == .passed }.map(\.id))
                if goal.status == .awaitingReview { expanded = true }
            }
    }

    @ViewBuilder private var actions: some View {
        if savePending { Button(L.string("goal.retry_save"), action: onRetrySave) }
        else if !goal.status.isTerminal {
            if busy { Button(L.string("goal.pause"), action: onPause) }
            else {
                if expanded && goal.latestRunID != nil {
                    Button(L.string("goal.review")) { onReview(passed) }.buttonStyle(.borderedProminent)
                }
                Button(L.string("goal.resume"), action: onResume)
            }
            Button(L.string("goal.cancel"), role: .destructive, action: onCancel)
        }
        if goal.latestRunID != nil { Button(L.string("goal.result"), action: onOpenResult) }
    }
}

struct GoalsPanel: View {
    let store: GoalStore
    var includeHidden = false
    let onOpen: (ExecutionGoal) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var goals: [ExecutionGoal] = []
    @State private var loading = false
    @State private var more = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("goal.library")).font(.title2.bold())
                Text(L.string(store.space.nameKey)).foregroundStyle(store.space.tint)
                Spacer()
                Button(L.string("common.refresh")) { Task { await load(reset: true) } }.disabled(loading)
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L.string("goal.library.help")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(goals) { goal in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(goal.definition.title, systemImage: "target").font(.headline)
                                Spacer()
                                Text(L.string("goal.status." + goal.status.rawValue)).font(.caption)
                            }
                            Text(L.format("goal.progress", goal.passedCount, goal.definition.criteria.count)).font(.caption)
                            Button(L.string("goal.open")) { onOpen(goal) }
                        }
                        Divider()
                    }
                    if goals.isEmpty && !loading { Text(L.string("goal.empty")).foregroundStyle(.secondary).padding() }
                    if more { Button(L.string("product.tasks.more")) { Task { await load(reset: false) } }.disabled(loading) }
                }
            }
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(width: 640, height: 520).task { await load(reset: true) }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }; loading = true
        defer { loading = false }
        do {
            let page = try await store.list(limit: 40, before: reset ? nil : goals.last, includeHidden: includeHidden)
            guard !Task.isCancelled else { return }
            if reset { goals = page } else { goals += page }
            more = page.count == 40; error = nil
        } catch { if !Task.isCancelled { self.error = L.errorDescription(error) } }
    }
}
