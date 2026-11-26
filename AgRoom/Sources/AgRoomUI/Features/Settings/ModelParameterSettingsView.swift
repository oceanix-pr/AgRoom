import SwiftUI
import AgRoomCore

@MainActor extension ModelReasoningProfile {
    func label(for effort: ReasoningEffort) -> String {
        if effort == .standard {
            guard let defaultLevel else { return L.string("model.parameters.provider_default") }
            return L.format("model.parameters.provider_default_level", Self.levelLabel(defaultLevel))
        }
        if effort == .deep && isThinkingSwitch { return L.string("model.reasoning.on") }
        if effort == .fast || effort == .deep { return L.string("chat.reasoning." + effort.rawValue) }
        return Self.levelLabel(effort.rawValue)
    }

    static func levelLabel(_ level: String) -> String {
        switch level {
        case "standard": L.string("model.parameters.provider_default")
        case "fast", "deep": L.string("chat.reasoning." + level)
        case "on", "off", "low", "medium", "high", "xhigh", "max": L.string("model.reasoning." + level)
        default: level
        }
    }
}

/// Edits shared preferences for one exact provider/model; workflows choose automatic defaults.
struct ModelParameterSettingsView: View {
    let providers: [LLMProviderConfig]
    let service: ModelParameterService
    @State private var providerID = UserDefaults.standard.string(forKey: "agroom.chat.providerId") ?? ""
    private let mode: ChatMode = .chat
    @State private var preferences = ModelParameterPreferences()
    @State private var capabilities: ModelCapabilities?
    @State private var loading = false
    @State private var refreshing = false
    @State private var readyKey: String?
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?

    private var provider: LLMProviderConfig? { providers.first { $0.id.uuidString == providerID } ?? providers.first }
    private var selectionKey: String {
        guard let provider else { return "" }
        return provider.id.uuidString + ":" + ModelParameterService.endpointIdentity(provider) + ":" + provider.model + ":" + mode.rawValue
    }
    private var resolved: ResolvedModelParameters { preferences.resolved(mode: mode, capabilities: capabilities, provider: provider) }
    private var reasoning: ModelReasoningProfile {
        ModelReasoningProfile(endpoint: provider?.endpoint ?? "", model: provider?.model ?? "",
            capabilities: capabilities, useQwenChatTemplate: preferences.useQwenChatTemplate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if providers.isEmpty {
                Text(L.string("model.parameters.add_provider")).foregroundStyle(.secondary)
            } else {
                Picker(L.string("model.parameters.model"), selection: Binding(get: { provider?.id.uuidString ?? "" }, set: { providerID = $0 })) {
                    ForEach(providers) { value in Text(value.chatDisplayName).tag(value.id.uuidString) }
                }
                if loading { ProgressView().controlSize(.small) }
                if let provider, CloudProvider.isImageGenerationModel(provider.model) {
                    Text(L.string("model.parameters.image_hint")).foregroundStyle(.secondary)
                    Text(L.string("chat.image.budget_hint")).font(.caption).foregroundStyle(.secondary)
                } else {
                    parameterFields.disabled(readyKey != selectionKey)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                Text(L.string("model.parameters.scope")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: selectionKey) { await loadSelection() }
    }

    private var parameterFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.string("model.parameters.capabilities")).font(.headline)
                Spacer()
                Button { Task { await refresh(force: true) } } label: {
                    Label(L.string("model.parameters.refresh"), systemImage: "arrow.clockwise")
                }.disabled(refreshing)
                if refreshing { ProgressView().controlSize(.small) }
            }
            LabeledContent(L.string("model.parameters.context"), value: limit(capabilities?.contextTokens))
            LabeledContent(L.string("model.parameters.output_limit"), value: limit(capabilities?.outputTokens))
            if let modalities = reasoning.inputModalities {
                let labels = modalities.map { $0 == "text" ? L.string("notes.text") : ($0 == "image" ? L.string("md.image") : $0) }
                LabeledContent(L.string("model.parameters.inputs"), value: labels.joined(separator: ", "))
            }
            if capabilities?.conservativeRouting == true {
                Text(L.string("model.parameters.routing")).font(.caption).foregroundStyle(.secondary)
            }
            if let capabilities {
                HStack {
                    Text(L.string("model.parameters.source." + capabilities.source.rawValue))
                    Text(capabilities.fetchedAt, format: .dateTime.year().month().day().hour().minute())
                }.font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(L.string("model.parameters.context_section")).font(.headline)
            Toggle(L.string("model.parameters.auto_context"), isOn: Binding(get: { preferences.contextTokenBudget == nil }, set: { automatic in
                update { $0.contextTokenBudget = automatic ? nil : max(ModelParameterPreferences.contextTokenBudgetRange.lowerBound, resolved.contextTokenBudget) }
            }))
            .accessibilityIdentifier("model.parameters.auto_context")
            numberField("model.parameters.context_budget", value: Binding(get: { preferences.contextTokenBudget ?? resolved.contextTokenBudget }, set: { value in
                update { $0.contextTokenBudget = value }
            })).disabled(preferences.contextTokenBudget == nil)
            Text(L.format("model.parameters.effective_context", resolved.contextTokenBudget)).font(.caption).foregroundStyle(.secondary)
            Text(L.string("model.parameters.context_help")).font(.caption).foregroundStyle(.secondary)
            Picker(L.string("model.parameters.prompt_cache"), selection: Binding(get: {
                preferences.promptCachePolicy ?? (mode == .coding ? .automatic : .providerDefault)
            }, set: { value in update { $0.promptCachePolicy = value } })) {
                Text(L.string("model.parameters.prompt_cache.automatic")).tag(PromptCachePolicy.automatic)
                Text(L.string("model.parameters.prompt_cache.providerDefault")).tag(PromptCachePolicy.providerDefault)
            }
            Text(L.string("model.parameters.prompt_cache.help")).font(.caption).foregroundStyle(.secondary)
            Toggle(L.string("model.parameters.native_compaction"), isOn: Binding(get: {
                preferences.nativeCompactionEnabled ?? (mode == .coding)
            }, set: { value in update { $0.nativeCompactionEnabled = value } }))
            Text(L.string("model.parameters.native_compaction.help")).font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle(L.string("model.parameters.auto_output"), isOn: Binding(get: { preferences.maxTokens == nil }, set: { automatic in
                update { $0.maxTokens = automatic ? nil : max(ModelParameterPreferences.outputTokenRange.lowerBound, resolved.config.maxTokens) }
            }))
            numberField("settings.dispatcher.maxTokens", value: Binding(get: { preferences.maxTokens ?? resolved.config.maxTokens }, set: { value in
                update { $0.maxTokens = value }
            })).disabled(preferences.maxTokens == nil)
            Text(L.format("model.parameters.effective_output", resolved.config.maxTokens)).font(.caption).foregroundStyle(.secondary)
            if capabilities?.supportsTemperature == false || reasoning.usesProviderTemperature(at: preferences.reasoningEffort) {
                Text(L.string("model.parameters.temperature_unsupported")).foregroundStyle(.secondary)
            } else {
                Toggle(L.string("model.parameters.auto_temperature"), isOn: Binding(get: { preferences.temperature == nil }, set: { automatic in
                    update { $0.temperature = automatic ? nil : resolved.config.temperature }
                }))
                HStack {
                    Text(L.string("settings.dispatcher.temperature"))
                    let range = capabilities?.temperatureRange ?? 0...2
                    if range.lowerBound < range.upperBound {
                        Slider(value: Binding(get: { resolved.config.temperature }, set: { value in update { $0.temperature = value } }),
                               in: range, step: 0.1)
                            .disabled(preferences.temperature == nil)
                    } else {
                        Text(range.lowerBound, format: .number.precision(.fractionLength(1)))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(preferences.temperature.map { _ in String(format: "%.1f", resolved.config.temperature) } ?? L.string("model.parameters.auto"))
                        .monospacedDigit().frame(minWidth: 60, alignment: .trailing)
                }
                if capabilities?.temperatureMinimum == nil || capabilities?.temperatureMaximum == nil {
                    Text(L.string("model.parameters.temperature_unknown")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if reasoning.offersChatTemplateSetting {
                Picker(L.string("model.qwen.control"), selection: Binding(get: { preferences.useQwenChatTemplate }, set: { value in
                    update { $0.useQwenChatTemplate = value }
                })) {
                    Text(L.string("model.parameters.auto")).tag(Bool?.none)
                    Text("vLLM / SGLang").tag(Bool?.some(true))
                    Text(L.string("model.qwen.compatible")).tag(Bool?.some(false))
                }
            }
            Picker(L.string("model.parameters.reasoning"), selection: Binding(get: { reasoning.selection(preferences.reasoningEffort) }, set: { value in
                update { $0.reasoningEffort = value == .standard ? nil : value }
            })) {
                ForEach(reasoning.choices, id: \.self) { value in Text(reasoning.label(for: value)).tag(value) }
            }.disabled(capabilities?.supportsReasoning == false)
            if let efforts = capabilities?.reasoningEfforts, !efforts.isEmpty {
                LabeledContent(L.string("model.parameters.reasoning_levels"), value: efforts.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if capabilities?.supportsReasoningBudget == true {
                Toggle(L.string("model.parameters.auto_reasoning_budget"), isOn: Binding(get: { preferences.reasoningBudget == nil }, set: { automatic in
                    update { $0.reasoningBudget = automatic ? nil : min(8192, max(1024, resolved.config.maxTokens - 1)) }
                }))
                if preferences.reasoningBudget != nil {
                    numberField("model.parameters.reasoning_budget", value: Binding(get: { preferences.reasoningBudget ?? 8192 }, set: { value in
                        update { $0.reasoningBudget = value }
                    }))
                }
            }
            Divider()
            Text(L.string("model.parameters.execution")).font(.headline)
            numberField("settings.dispatcher.maxSteps", value: Binding(get: { preferences.maxSteps ?? resolved.maxSteps }, set: { value in update { $0.maxSteps = value } }))
            numberField("settings.dispatcher.subagentSteps", value: Binding(get: { preferences.subagentSteps ?? resolved.subagentSteps }, set: { value in update { $0.subagentSteps = value } }))
            numberField("settings.dispatcher.history", value: Binding(get: { preferences.historyWindow ?? resolved.historyWindow }, set: { value in update { $0.historyWindow = value } }))
            Text(L.string("model.parameters.execution_help")).font(.caption).foregroundStyle(.secondary)
            Button(L.string("model.parameters.reset")) { update { $0 = .init() } }
                .buttonStyle(.link)
        }
    }

    private func limit(_ value: Int?) -> String { value.map { $0.formatted() } ?? L.string("model.parameters.unknown") }

    private func numberField(_ key: String, value: Binding<Int>) -> some View {
        HStack {
            Text(L.string(key)); Spacer()
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 140)
                .accessibilityIdentifier(key)
        }
    }

    private func update(_ change: (inout ModelParameterPreferences) -> Void) {
        guard readyKey == selectionKey, let provider else { return }
        change(&preferences)
        guard preferences.isValid else { error = L.string("model.parameters.invalid"); return }
        let snapshot = preferences, selectedMode = mode, key = selectionKey, previous = saveTask
        error = nil
        // Serialize saves, including across selection changes. Refresh never writes preferences.
        saveTask = Task {
            await previous?.value
            do { try await service.save(snapshot, provider: provider, mode: selectedMode) }
            catch { if key == selectionKey { self.error = L.string("model.parameters.save_failed") } }
        }
    }

    private func loadSelection() async {
        guard let provider else { return }
        let key = selectionKey, selectedMode = mode, pendingSave = saveTask
        readyKey = nil; loading = true; capabilities = nil; error = nil
        await pendingSave?.value
        do {
            let snapshot = try await service.load(provider: provider, mode: selectedMode)
            guard !Task.isCancelled, key == selectionKey else { return }
            preferences = snapshot.preferences; capabilities = snapshot.capabilities
            readyKey = key; loading = false
            await refresh(force: false)
        } catch {
            guard !Task.isCancelled, key == selectionKey else { return }
            loading = false; self.error = L.string("model.parameters.load_failed")
        }
    }

    private func refresh(force: Bool) async {
        guard let provider else { return }
        let key = selectionKey
        refreshing = true
        defer { if key == selectionKey { refreshing = false } }
        do {
            let result = try await service.refresh(provider: provider, force: force)
            guard !Task.isCancelled, key == selectionKey else { return }
            capabilities = result
        } catch {
            guard !Task.isCancelled, key == selectionKey else { return }
            self.error = L.string("model.parameters.refresh_failed")
        }
    }
}
