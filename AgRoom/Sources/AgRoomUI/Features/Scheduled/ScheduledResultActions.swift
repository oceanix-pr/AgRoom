import Observation
import SwiftUI
import AgRoomCore

@MainActor
enum ScheduledResultText {
    static func source(_ run: ScheduledRun) -> String {
        let date = run.finishedAt ?? run.startedAt ?? run.scheduledFor
        let heading = L.format("scheduled.result.source", run.taskName,
            date?.formatted(date: .abbreviated, time: .shortened) ?? L.string("usage.unreported"))
        let status = L.string("scheduled.status." + run.status.rawValue)
        return heading + "\n" + status + (error(run).map { "\n" + $0 } ?? "") + "\n\n" +
            (run.experience?.outputTruncated == true ? L.string("scheduled.result.truncated") + "\n\n" : "") + (run.outputText ?? "")
    }
    static func draft(_ run: ScheduledRun, report: Bool) -> String {
        L.string(report ? "scheduled.result.report.prompt" : "scheduled.result.follow.prompt") + "\n\n" +
            source(run).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
    }
    static func error(_ run: ScheduledRun) -> String? {
        guard let code = run.errorCode else { return run.errorText }
        if code == "recovery_required" { return L.string("product.completion.review") }
        if code == "invalid_options" || code == "unsupported_profile" { return L.string("scheduled.error." + code) }
        let key = "scheduled.run.error." + code, translated = L.string(key)
        return translated == key ? run.errorText : translated
    }
}

@MainActor @Observable
final class ScheduledResultActionsModel {
    let run: ScheduledRun
    let space: AppSpace
    let store: ScheduledRunStore?
    let knowledge: KnowledgeService?
    private let isCurrent: @MainActor () -> Bool
    private var visible = true
    private(set) var saved = false
    var errorText: String?
    init(run: ScheduledRun, space: AppSpace, store: ScheduledRunStore?, knowledge: KnowledgeService?, isCurrent: @escaping @MainActor () -> Bool) {
        self.run = run; self.space = space; self.store = store; self.knowledge = knowledge; self.isCurrent = isCurrent
    }
    private func checked() async throws -> ScheduledRun {
        guard visible, !Task.isCancelled, isCurrent(), let store else { throw ScheduledExperienceError.changed }
        let value = try await store.reference(run)
        guard visible, !Task.isCancelled, isCurrent() else { throw ScheduledExperienceError.changed }
        return value
    }
    func draft(report: Bool) async throws -> String { ScheduledResultText.draft(try await checked(), report: report) }
    func prepareKnowledge() async throws -> KnowledgeItem {
        let value = try await checked()
        return KnowledgeItem(title: value.taskName, content: ScheduledResultText.source(value))
    }
    func saveKnowledge(_ item: KnowledgeItem) async throws {
        guard !saved, let knowledge else { throw ScheduledExperienceError.changed }
        _ = try await checked()
        try await knowledge.save(item)
        saved = true
    }
    func activate() { visible = true }
    func close() { visible = false }
}

struct ScheduledResultActionsView: View {
    @State private var model: ScheduledResultActionsModel
    var onDraft: @MainActor (String) -> Void
    @State private var pending: Task<Void, Never>?
    @State private var knowledgeDraft: KnowledgeItem?
    init(hub: Hub, space: AppSpace, run: ScheduledRun, onDraft: @escaping @MainActor (String) -> Void) {
        self.init(model: .init(run: run, space: space, store: hub.makeScheduledRunStore(for: space),
            knowledge: hub.makeKnowledgeService(for: space), isCurrent: { hub.spaceStore.current == space }), onDraft: onDraft)
    }
    init(model: ScheduledResultActionsModel, onDraft: @escaping @MainActor (String) -> Void) {
        _model = State(initialValue: model); self.onDraft = onDraft
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }.controlSize(.small).disabled(pending != nil)
            if model.saved { Label(L.string("scheduled.result.knowledge.saved"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
            if let error = model.errorText { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(item: $knowledgeDraft) { draft in
            KnowledgeFormSheet(item: draft, sourceContext: .scoped(to: model.space), isNewDraft: true) { try await model.saveKnowledge($0) }
        }
        .onAppear { model.activate() }
        .onDisappear { model.close(); pending?.cancel(); pending = nil }
    }
    @ViewBuilder private var buttons: some View {
        Button(L.string("scheduled.result.follow")) { makeDraft(report: false) }
        Button(L.string("scheduled.result.report")) { makeDraft(report: true) }
        Button(L.string("scheduled.result.knowledge")) {
            pending = Task {
                defer { pending = nil }
                do { knowledgeDraft = try await model.prepareKnowledge() }
                catch { model.errorText = L.errorDescription(error) }
            }
        }.disabled(model.saved)
    }
    private func makeDraft(report: Bool) {
        pending = Task {
            defer { pending = nil }
            do { onDraft(try await model.draft(report: report)) }
            catch { model.errorText = L.errorDescription(error) }
        }
    }
}

struct ScheduledRunInfoView: View {
    let hub: Hub
    let space: AppSpace
    let run: ScheduledRun
    @State private var prices: [ProductModelPrice] = []
    @State private var prior: ScheduledRun?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let details = run.experience {
                Text(L.format("scheduled.budget.summary", details.budget.maxTokens, details.budget.maxToolCalls, details.budget.seconds))
                if let spent = details.budgetSpentTokens { Text(L.format("scheduled.budget.spent", spent)).foregroundStyle(.secondary) }
                if details.outputTruncated { Text(L.string("scheduled.result.truncated")).foregroundStyle(.orange) }
                if let comparison = details.comparisonState {
                    Text(L.string("scheduled.comparison." + comparison.rawValue)).foregroundStyle(comparison == .changed ? Color.orange : .secondary)
                    if let value = details.comparisonValue {
                        DisclosureGroup(L.string("scheduled.comparison.values")) {
                            if details.baselineRunID != nil {
                                Text(L.string("scheduled.comparison.previous")).bold()
                                Text(prior?.experience?.comparisonValue ?? L.string("scheduled.comparison.previous.missing")).textSelection(.enabled)
                            }
                            Text(L.string("scheduled.comparison.current")).bold()
                            Text(value).textSelection(.enabled)
                        }
                    }
                }
            }
            if run.experience?.usageKnown == true {
                Text(L.format("scheduled.run.usage", run.inputTokens, run.outputTokens, run.toolCallCount))
            } else {
                Text(L.string("usage.unreported"))
                if run.inputTokens > 0 || run.outputTokens > 0 { Text(L.format("scheduled.usage.partial", run.inputTokens, run.outputTokens)) }
            }
            if let details = run.experience, details.usageKnown,
               let price = prices.first(where: { $0.providerID == details.providerID && $0.model == details.model }),
               let estimate = price.estimate(input: run.inputTokens, output: run.outputTokens) {
                Text(L.format("scheduled.price.estimate", price.currency + " " + String(format: "%.4f", estimate)))
            } else { Text(L.string("scheduled.price.unknown")) }
        }.font(.caption).foregroundStyle(.secondary)
        .task(id: run.id) {
            do {
                let values = try await hub.makeProductPreferencesService(for: space)?.load([ProductModelPrice].self, key: "model-prices") ?? []
                let providers = try await hub.providerService?.getAll() ?? []
                let baseline: ScheduledRun?
                if let id = run.experience?.baselineRunID { baseline = try await hub.makeScheduledRunStore(for: space)?.run(id: id) }
                else { baseline = nil }
                guard !Task.isCancelled, hub.spaceStore.current == space else { return }
                prices = values.filter { price in
                    providers.first(where: { $0.id == price.providerID }).map { price.applies(to: $0) } != false
                }
                prior = baseline
            } catch { /* Estimates remain unknown when configuration cannot be read. */ }
        }
    }
}

struct ScheduledDraftCards: View {
    let message: ChatMessage
    let space: AppSpace
    var body: some View {
        let drafts = (message.trace ?? []).filter { $0.toolName == "schedule_draft" && $0.succeeded }
            .compactMap { try? ScheduledTaskDraft.read($0.resultFull ?? $0.resultPreview, space: space) }
        ForEach(drafts) { draft in
            VStack(alignment: .leading, spacing: 8) {
                Label(draft.task.name, systemImage: "calendar.badge.plus").font(.headline)
                Text(L.string("scheduled.draft.inert")).font(.caption).foregroundStyle(.secondary)
                Button(L.string("scheduled.draft.preview")) {
                    ProductRoute.post(.init(space: space, page: "scheduled", scheduledDraft: draft))
                }.buttonStyle(.bordered)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}
