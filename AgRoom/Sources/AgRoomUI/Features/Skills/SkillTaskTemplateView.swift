import SwiftUI
import AgRoomCore

@MainActor @Observable
final class SkillTaskTemplateModel {
    let template: SkillTaskTemplate
    private let store: SkillStore?
    private let space: AppSpace
    private let isCurrent: @MainActor () -> Bool
    private let makeExecutor: @MainActor () -> PythonExecutor
    private var visible = true
    private var generation = UUID()
    private(set) var installedName: String?
    private(set) var busy = false
    private(set) var result: SkillValidationRecord?
    private(set) var sampleMatches = false
    var error: String?

    init(template: SkillTaskTemplate, store: SkillStore?, space: AppSpace, isCurrent: @escaping @MainActor () -> Bool,
         makeExecutor: (@MainActor () -> PythonExecutor)? = nil) {
        self.template = template; self.store = store; self.space = space; self.isCurrent = isCurrent
        self.makeExecutor = makeExecutor ?? { PythonExecutor(space: space, workspaceName: "scenario-trial") }
    }
    var canInstall: Bool { visible && !busy && installedName == nil && isCurrent() && store?.space == space }
    var canRun: Bool { visible && !busy && installedName != nil && isCurrent() && store?.space == space }
    func install() async -> String? {
        guard canInstall, let store else { return nil }
        busy = true; defer { busy = false }
        let ticket = generation
        let template = template, alias = L.string(template.titleKey), description = L.string(template.summaryKey)
        do {
            let name = try await Task.detached { try template.install(in: store, alias: alias, description: description) }.value
            guard visible, generation == ticket, isCurrent(), !Task.isCancelled else { return nil }
            installedName = name; error = nil; return name
        } catch { if visible, generation == ticket, isCurrent() { self.error = L.errorDescription(error) }; return nil }
    }
    func run() async {
        guard canRun, let store, let installedName else { return }
        busy = true; result = nil; sampleMatches = false; error = nil
        let ticket = generation
        defer { busy = false }
        let record = await SkillValidationService(store: store, executor: makeExecutor()).smokeTest(name: installedName, relativePath: "scripts/main.py")
        guard visible, generation == ticket, isCurrent(), !Task.isCancelled else { return }
        result = record
        sampleMatches = record.wasExecuted && record.scripts.count == 1 && template.matchesSampleOutput(record.scripts[0].message)
    }
    func appear() { visible = true }
    func close() { visible = false; generation = UUID() }
}

struct SkillTaskTemplateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SkillTaskTemplateModel
    @State private var pending: Task<Void,Never>?
    @State private var confirmingRun = false
    let onInstalled: (String) -> Void
    init(hub: Hub, space: AppSpace, template: SkillTaskTemplate, onInstalled: @escaping (String) -> Void) {
        _model = State(initialValue: SkillTaskTemplateModel(template: template, store: hub.makeSkillStore(for: space), space: space,
            isCurrent: { hub.spaceStore.current == space })); self.onInstalled = onInstalled
    }
    init(model: SkillTaskTemplateModel, onInstalled: @escaping (String) -> Void = { _ in }) { _model = State(initialValue: model); self.onInstalled = onInstalled }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string(model.template.titleKey)).font(.title2.bold())
            Text(L.string(model.template.summaryKey)).foregroundStyle(.secondary)
            Text(L.string("scenario.skill.help")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L.string("scenario.input")).font(.headline)
                    code(model.template.sampleInput)
                    Text(L.string("scenario.expected")).font(.headline)
                    code(model.template.expectedOutput)
                    Text(L.string(model.template.criteriaKey)).font(.callout)
                    DisclosureGroup(L.string("scenario.package")) {
                        code(model.template.instructions)
                        code(model.template.script)
                    }
                    if let result = model.result {
                        Label(L.string(model.sampleMatches ? "scenario.sample.passed" : "scenario.sample.unverified"),
                            systemImage: model.sampleMatches ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(model.sampleMatches ? .green : .orange)
                        Text(L.string("scenario.sample.help")).font(.caption).foregroundStyle(.secondary)
                        if result.outcome == .runtimeUnavailable { Text(L.string("skills.validation.runtime_unavailable")) }
                        else if result.outcome == .timedOut { Text(L.string("skills.validation.timed_out")) }
                        else if result.outcome == .failed { Text(L.string("skills.validation.failed")) }
                        ForEach(result.scripts) { item in code(item.message) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
            if let name = model.installedName { Text(L.format("scenario.installed", name)).font(.caption).textSelection(.enabled) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(L.string("scenario.sample.run")) { confirmingRun = true }.disabled(!model.canRun)
                Button(L.string("scenario.skill.install")) {
                    pending = Task { if let name = await model.install() { onInstalled(name) }; pending = nil }
                }.buttonStyle(.borderedProminent).disabled(!model.canInstall)
            }
        }.padding(20).frame(width: 780, height: 730)
            .interactiveDismissDisabled(model.busy)
            .confirmationDialog(L.string("skills.validation.run.confirm.title"), isPresented: $confirmingRun, titleVisibility: .visible) {
                Button(L.string("skills.validation.run.confirm.action"), role: .destructive) { pending = Task { await model.run(); pending = nil } }
                Button(L.string("common.cancel"), role: .cancel) {}
            } message: { Text(L.string("skills.validation.run.confirm.message")) }
            .onAppear { model.appear() }
            .onDisappear { model.close(); pending?.cancel(); pending = nil }
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
