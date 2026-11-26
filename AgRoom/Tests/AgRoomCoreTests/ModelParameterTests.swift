import Foundation
import Testing
import GRDB
@testable import AgRoomCore

struct ModelParameterTests {
    private func fixture() async throws -> (DatabaseQueue, ProviderConfigService, LLMProviderConfig) {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareGlobal(queue)
        let providers = ProviderConfigService(databaseQueue: queue)
        let provider = LLMProviderConfig(name: "Fixture", endpoint: "https://openrouter.ai/api/v1/chat/completions", model: "lab/model")
        try await providers.save(provider, apiKey: nil)
        return (queue, providers, provider)
    }

    @Test func preferencesAreSharedAcrossWorkflowsAndSeparatedByProviderModelAndEndpoint() async throws {
        let (queue, providers, provider) = try await fixture()
        let service = ModelParameterService(databaseQueue: queue)
        let preferences = ModelParameterPreferences(maxTokens: 12345, temperature: 0.4, maxSteps: 27, historyWindow: 45, contextTokenBudget: 128_000)
        try await service.save(preferences, provider: provider, mode: .chat)
        #expect(try await service.load(provider: provider, mode: .chat).preferences == preferences)
        #expect(try await service.load(provider: provider, mode: .coding).preferences == preferences)
        var otherModel = provider; otherModel.model = "lab/other"
        #expect(try await service.load(provider: otherModel, mode: .chat).preferences == .init())
        var otherEndpoint = provider; otherEndpoint.endpoint = "https://example.com/v1/chat/completions"
        try await providers.save(otherEndpoint, apiKey: nil)
        #expect(try await service.load(provider: otherEndpoint, mode: .chat).preferences == .init())
        await #expect(throws: ModelParameterService.ParameterError.self) {
            try await service.save(preferences, provider: provider, mode: .chat)
        }
        let second = LLMProviderConfig(name: "Second", endpoint: provider.endpoint, model: provider.model)
        try await providers.save(second, apiKey: nil)
        #expect(try await service.load(provider: second, mode: .chat).preferences == .init())
    }

    @Test func legacyPreferencesHaveStablePrecedenceAndAreRetained() async throws {
        let (queue, _, provider) = try await fixture()
        let service = ModelParameterService(databaseQueue: queue)
        let chat = ModelParameterPreferences(maxTokens: 7_000, maxSteps: 25)
        let coding = ModelParameterPreferences(maxTokens: 15_000, maxSteps: 50)
        let endpoint = ModelParameterService.endpointIdentity(provider)
        let codingData = try JSONEncoder().encode(coding), chatData = try JSONEncoder().encode(chat)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO model_parameter_preferences VALUES(?,?,?,?,?)",
                arguments: [provider.id.uuidString, endpoint, provider.model, "coding", codingData])
        }
        #expect(try await service.load(provider: provider, mode: .chat).preferences == coding)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO model_parameter_preferences VALUES(?,?,?,?,?)",
                arguments: [provider.id.uuidString, endpoint, provider.model, "chat", chatData])
        }
        #expect(try await service.load(provider: provider, mode: .coding).preferences == chat)
        try await service.setReasoningEffort(.deep, provider: provider, mode: .coding)
        var shared = chat; shared.reasoningEffort = .deep
        #expect(try await service.load(provider: provider, mode: .chat).preferences == shared)
        #expect(try await service.load(provider: provider, mode: .coding).preferences == shared)
        #expect(try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM model_parameter_preferences")
        } == 3)
        let automatic = ModelParameterPreferences().resolved(mode: .coding, capabilities: nil)
        let frozen = try JSONDecoder().decode(ResolvedModelParameters.self, from: JSONEncoder().encode(automatic))
        #expect(frozen.workflowMode == .coding && frozen.maxSteps == 60)
    }

    @Test func refreshPreservesManualChoicesAndReasoningUpdatesPreserveOtherFields() async throws {
        let (queue, _, provider) = try await fixture()
        let response = Data(#"{"data":{"id":"lab/model","endpoints":[{"status":0,"context_length":32768,"max_completion_tokens":4096,"supported_parameters":["temperature","reasoning"]}]}}"#.utf8)
        let service = ModelParameterService(databaseQueue: queue, fetch: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return response
        })
        let preferences = ModelParameterPreferences(maxTokens: 16000, temperature: 0.3, maxSteps: 35, contextTokenBudget: 128_000)
        try await service.save(preferences, provider: provider, mode: .chat)
        let caps = try await service.refresh(provider: provider, force: true)
        #expect(caps?.outputTokens == 4096)
        #expect(try await service.load(provider: provider, mode: .chat).preferences == preferences)
        let runtime = try await service.resolve(provider: provider, mode: .chat)
        #expect(runtime.config.maxTokens == 4096)
        #expect(runtime.maxSteps == 35)
        #expect(runtime.contextTokenBudget == 32768 - 4096 - 256)
        try await service.setReasoningEffort(.deep, provider: provider, mode: .chat)
        let updated = try await service.load(provider: provider, mode: .chat).preferences
        #expect(updated.maxTokens == 16000)
        #expect(updated.temperature == 0.3)
        #expect(updated.reasoningEffort == .deep)
        #expect(updated.contextTokenBudget == 128_000)
    }

    @Test func refreshFailureRetainsCachedLimits() async throws {
        let (queue, _, provider) = try await fixture()
        let response = Data(#"{"data":{"id":"lab/model","endpoints":[{"max_completion_tokens":4096,"context_length":32000}]}}"#.utf8)
        let successful = ModelParameterService(databaseQueue: queue, fetch: { _ in response })
        _ = try await successful.refresh(provider: provider, force: true)
        let failing = ModelParameterService(databaseQueue: queue, fetch: { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await failing.refresh(provider: provider, force: true); Issue.record("Expected refresh failure") }
        catch {}
        #expect(try await failing.load(provider: provider, mode: .chat).capabilities?.outputTokens == 4096)
    }

    @Test func nativeMetadataKeepsContextAndOutputSeparate() throws {
        let data = Data(#"{"data":[{"id":"model","context_window":1048576,"max_output_tokens":65536,"effort":{"supported_levels":["low","high","max"]},"temperature":{"min":0.1,"max":1.0}}]}"#.utf8)
        let capabilities = try #require(try ModelParameterService.parse(data, model: "model", openRouter: false, at: Date()))
        #expect(capabilities.contextTokens == 1_048_576)
        #expect(capabilities.outputTokens == 65_536)
        #expect(capabilities.reasoningEfforts == ["low", "high", "max"])
        #expect(capabilities.temperatureRange == 0.1...1.0)
        let unknown = try ModelParameterService.parse(Data(#"{"data":[{"id":"model"}]}"#.utf8), model: "model", openRouter: false, at: Date())
        #expect(unknown?.outputTokens == nil)
        #expect(unknown?.contextTokens == nil)
    }

    @Test func configuredQwenWindowWinsAndKimiRespectsManualOrSmallBudgets() throws {
        let model = "Qwen/Qwen3.6-35B-A3B"
        let data = Data(#"{"data":[{"id":"Qwen/Qwen3.6-35B-A3B","max_model_len":8192,"context_length":262144,"owned_by":"vllm","input_modalities":["text","image"]}]}"#.utf8)
        let caps = try #require(try ModelParameterService.parse(data, model: model, openRouter: false, at: Date()))
        #expect(caps.contextTokens == 8192 && caps.supportsChatTemplate == true && caps.inputModalities == ["text", "image"])
        let local = ModelReasoningProfile(endpoint: "http://localhost:8000/v1", model: model, capabilities: caps)
        #expect(local.choices == [.standard, .off, .deep])
        let kimi = LLMProviderConfig(name: "fixture", endpoint: "https://api.moonshot.cn/v1", model: "kimi-k3.1-pro")
        #expect(ModelParameterPreferences().resolved(mode: .chat, capabilities: nil, provider: kimi).config.maxTokens == 16_384)
        #expect(ModelParameterPreferences(maxTokens: 1024).resolved(mode: .chat, capabilities: nil, provider: kimi).config.maxTokens == 1024)
        let small = ModelParameterPreferences().resolved(mode: .chat, capabilities: .init(contextTokens: 8192), provider: kimi)
        #expect(small.config.maxTokens == 2048 && small.contextTokenBudget == 5888)
    }

    @Test func automaticRoutingUsesIntersectionAndUnknownEndpointsStayUnknown() throws {
        let data = Data(#"{"data":{"id":"model","endpoints":[{"status":0,"context_length":262144,"max_completion_tokens":65536,"supported_parameters":["temperature","reasoning"]},{"status":0,"context_length":128000,"max_completion_tokens":32768,"supported_parameters":["reasoning"]},{"status":1,"context_length":1000,"max_completion_tokens":100}]}}"#.utf8)
        let result = try #require(try ModelParameterService.parse(data, model: "model", openRouter: true, at: Date()))
        #expect(result.outputTokens == 32768)
        #expect(result.contextTokens == 128000)
        #expect(result.supportsTemperature == false)
        #expect(result.conservativeRouting)
        let incomplete = Data(#"{"data":{"id":"model","endpoints":[{"max_completion_tokens":65536},{}]}}"#.utf8)
        #expect(try ModelParameterService.parse(incomplete, model: "model", openRouter: true, at: Date())?.outputTokens == nil)
    }

    @Test func catalogsNeverApplyOfficialLimitsToAnUnknownRelay() throws {
        let data = Data(#"{"deepseek":{"models":{"model":{"temperature":false,"reasoning":true,"limit":{"context":128000,"output":8192}}}}}"#.utf8)
        var provider = LLMProviderConfig(name: "DeepSeek", endpoint: "https://api.deepseek.com/v1/chat/completions", model: "model")
        #expect(try ModelParameterService.parseCatalog(data, provider: provider, at: Date())?.outputTokens == 8192)
        provider.endpoint = "https://relay.example/v1/chat/completions"
        #expect(try ModelParameterService.parseCatalog(data, provider: provider, at: Date()) == nil)
    }

    @Test func automaticRepliesUseTheKnownModelMaximumAndPreserveWorkflowFallbacks() throws {
        let caps = ModelCapabilities(contextTokens: 1_000_000, outputTokens: 300_000)
        let chat = ModelParameterPreferences().resolved(mode: .chat, capabilities: caps)
        let coding = ModelParameterPreferences().resolved(mode: .coding, capabilities: caps)
        #expect(chat.config.maxTokens == 300_000)
        #expect(coding.config.maxTokens == 300_000)
        #expect(ModelParameterPreferences().resolved(mode: .chat, capabilities: nil).config.maxTokens == 8_192)
        #expect(ModelParameterPreferences().resolved(mode: .coding, capabilities: nil).config.maxTokens == 16_384)
        let large = ModelParameterPreferences().resolved(mode: .chat, capabilities: .init(outputTokens: 2_000_000))
        #expect(large.config.maxTokens == ModelParameterPreferences.outputTokenRange.upperBound)
        #expect(chat.contextTokenBudget == 256_000)
        #expect(coding.contextTokenBudget == 256_000)
        #expect(chat.config.temperatureIsAutomatic == true)
        #expect(chat.config.reasoningEffort == nil)
        let decoded = try JSONDecoder().decode(ResolvedModelParameters.self, from: JSONEncoder().encode(coding))
        #expect(decoded == coding)
        let legacy = try JSONDecoder().decode(LLMConfig.self, from: Data(#"{"modelName":"model","maxTokens":2048,"temperature":0.7}"#.utf8))
        #expect(legacy.modelCapabilities == nil)
        #expect(legacy.temperatureIsAutomatic == nil)
        #expect(legacy.automaticOutputReserve == nil && legacy.reservedOutputTokens == 2048)
    }

    @Test func contextBudgetReservesOutputAndUnknownCapabilitiesRemainBounded() throws {
        let preferences = ModelParameterPreferences(maxTokens: 16_384, contextTokenBudget: 128_000)
        let small = preferences.resolved(mode: .coding, capabilities: .init(contextTokens: 100_000, outputTokens: 32_768))
        #expect(small.contextTokenBudget == 100_000 - 16_384 - 256)
        #expect(preferences.resolved(mode: .coding, capabilities: nil).contextTokenBudget == 128_000)
        #expect(ModelParameterPreferences().resolved(mode: .coding, capabilities: nil).contextTokenBudget == 256_000)
        #expect(!ModelParameterPreferences(contextTokenBudget: 4095).isValid)
        #expect(!ModelParameterPreferences(contextTokenBudget: 1_048_577).isValid)
        let smallUnknownOutput = ModelParameterPreferences().resolved(mode: .coding, capabilities: .init(contextTokens: 8192))
        #expect(smallUnknownOutput.config.maxTokens == 2048)
        #expect(smallUnknownOutput.contextTokenBudget == 8192 - 2048 - 256)

        let oldPreferences = try JSONDecoder().decode(ModelParameterPreferences.self, from: Data(#"{"maxTokens":4096}"#.utf8))
        #expect(oldPreferences.contextTokenBudget == nil)
        var frozen = preferences.resolved(mode: .coding, capabilities: nil)
        frozen.providerID = UUID(); frozen.endpoint = "https://fixture.invalid/v1"
        let data = try JSONEncoder().encode(frozen)
        #expect(try JSONDecoder().decode(ResolvedModelParameters.self, from: data) == frozen)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "contextTokenBudget")
        let decoded = try JSONDecoder().decode(ResolvedModelParameters.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.contextTokenBudget == 60_000)
        #expect(decoded.providerID == frozen.providerID && decoded.endpoint == frozen.endpoint)
    }

    @Test func requestGuardAccountsForToolSchemasAndRemainingContext() async throws {
        let provider = CloudProvider(config: .init(name: "Fixture", endpoint: "https://example.com/v1/chat/completions", model: "model"), apiKey: "")
        let tools = [ToolDefinition(name: "test", description: String(repeating: "description ", count: 100), parametersSchemaJSON: #"{"type":"object","properties":{}}"#)]
        let messages = [EngineMessage(role: .system, text: "system"), EngineMessage(role: .user, text: "input")]
        let estimate = TokenEstimator.estimate(messages: messages, tools: tools)
        var config = LLMConfig(maxTokens: 16384, temperature: 1.8, reasoningEffort: .deep)
        config.reasoningBudget = 8192
        config.modelCapabilities = ModelCapabilities(contextTokens: estimate + 256 + 2000, outputTokens: 8192,
            supportsTemperature: false, reasoningEfforts: ["low", "max"], supportsReasoningBudget: true)
        let prepared = try await provider.prepareConfiguration(config, messages: messages, tools: tools)
        #expect(prepared.maxTokens == 2000)
        #expect(prepared.reasoningBudget == 1999)
        #expect(prepared.reasoningLevel == "max")
        let request = try provider.buildChatRequest(messages: messages, tools: tools, config: prepared, stream: false)
        let requestData = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: requestData)
        let body = try #require(object as? [String: Any])
        #expect(body["temperature"] == nil)
        #expect(body["max_tokens"] as? Int == 2000)
        config.modelCapabilities?.contextTokens = estimate
        await #expect(throws: LLMError.self) { try await provider.prepareConfiguration(config, messages: messages, tools: tools) }
    }

    @Test func historyIsSelectedByProfileAndTokenBudget() {
        let profile = ModelParameterPreferences(historyWindow: 2).resolved(mode: .chat, capabilities: .init(contextTokens: 100000))
        let messages = (0..<5).map { EngineMessage(role: .user, text: "message \($0)") }
        #expect(profile.history(messages).map(\.text) == ["message 3", "message 4"])
        let small = ModelParameterPreferences().resolved(mode: .chat, capabilities: .init(contextTokens: 8192, outputTokens: 4096))
        let engine = DispatcherEngine(tools: [], systemPrompt: "brief", config: small.config, modelParameterSnapshot: small)
        #expect(engine.preparedHistory(messages, userMessage: "follow up").count == 5)
        #expect(engine.preparedHistory(messages, userMessage: String(repeating: "长", count: 6000)).isEmpty)
    }

    @Test func globalMigrationAndPreferencesSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("global.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareGlobal(queue)
        let providers = ProviderConfigService(databaseQueue: queue)
        let provider = LLMProviderConfig(name: "Fixture", endpoint: "https://openrouter.ai/api/v1/chat/completions", model: "lab/model")
        try await providers.save(provider, apiKey: nil)
        let preference = ModelParameterPreferences(maxTokens: 4096, temperature: 0.5, reasoningEffort: .fast, historyWindow: 15, contextTokenBudget: 128_000)
        try await providers.modelParameters.save(preference, provider: provider, mode: .coding)
        let reopened = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareGlobal(reopened)
        try DatabaseBootstrap.prepareGlobal(reopened)
        #expect(try await ModelParameterService(databaseQueue: reopened).load(provider: provider, mode: .coding).preferences == preference)
        #expect(try await ModelParameterService(databaseQueue: reopened).load(provider: provider, mode: .chat).preferences == preference)
    }

    @Test func independentAgentsKeepTheParentModeAndUseTheirOwnModelPreferences() async throws {
        let (queue, _, provider) = try await fixture()
        let service = ModelParameterService(databaseQueue: queue)
        var target = provider; target.model = "lab/specialist"
        try await service.save(.init(maxTokens: 3072, temperature: 0.25, subagentSteps: 12), provider: target, mode: .coding)
        let main = CloudProvider(config: .init(name: "Main", endpoint: "https://main.example/v1/chat/completions", model: "main"),
            apiKey: "", parameterMode: .coding)
        let resolver = AgentProviderResolver(configurations: [provider]) { selected, recorder in
            CloudProvider(config: selected, apiKey: "", usageRecorder: recorder, parameterService: service)
        }
        let agent = Agent(name: "Specialist", modelName: target.model, providerID: provider.id)
        let routed = try resolver.resolve(agent, inheriting: main)
        #expect(routed.parameterMode == .coding)
        let parameters = try await routed.modelParameters(mode: routed.parameterMode, modelName: agent.modelName)
        #expect(parameters.config.modelName == target.model)
        #expect(parameters.config.maxTokens == 3072)
        #expect(parameters.config.temperature == 0.25)
        #expect(parameters.subagentSteps == 12)
    }

    @Test func historyAccountsForActualToolsAndPreservesSignedPrefixes() {
        let tool = ToolDefinition(name: "tool", description: String(repeating: "schema ", count: 1000), parametersSchemaJSON: "{}")
        let caps = ModelCapabilities(contextTokens: 12000, outputTokens: 4096)
        var parameters = ModelParameterPreferences(maxTokens: 4096, historyWindow: 30).resolved(mode: .chat, capabilities: caps)
        parameters.historyTokenBudget = 10000
        let engine = DispatcherEngine(tools: [ParameterHistoryTool(definition: tool)], systemPrompt: String(repeating: "system ", count: 1000),
            config: parameters.config, modelParameterSnapshot: parameters)
        let messages = (0..<20).map { EngineMessage(role: .user, text: String(repeating: "history ", count: 500) + String($0)) }
        let prepared = engine.preparedHistory(messages, userMessage: "input")
        #expect(prepared.count < parameters.history(messages).count)
        #expect(prepared.last?.text == messages.last?.text)
        let signed = EngineMessage(role: .assistant, text: "signed", continuation: EngineContinuation(anthropicBlocksJSON: #"[{"type":"thinking","thinking":"plan","signature":"opaque"}]"#))
        #expect(engine.preparedHistory([signed] + messages, userMessage: "input").count == messages.count + 1)
    }

    @Test func initialHistoryFitsTheLocalBudgetEvenWithUnknownModelCapacity() {
        let parameters = ModelParameterPreferences(contextTokenBudget: 4096).resolved(mode: .coding, capabilities: nil)
        let tool = ToolDefinition(name: "tool", description: String(repeating: "schema ", count: 500), parametersSchemaJSON: "{}")
        let engine = DispatcherEngine(tools: [ParameterHistoryTool(definition: tool)], systemPrompt: String(repeating: "system ", count: 500),
            config: parameters.config, modelParameterSnapshot: parameters)
        let messages = (0..<10).map { EngineMessage(role: .user, text: String(repeating: "history ", count: 500) + String($0)) }
        let prepared = engine.preparedHistory(messages, userMessage: "input")
        #expect(prepared.count < parameters.history(messages).count)
        #expect(prepared.last?.text == messages.last?.text)
    }

    @Test func frozenProviderSelectionDoesNotFollowTheComposerOrChangedEndpoint() async throws {
        let (queue, providers, provider) = try await fixture()
        let snapshot = try await ModelParameterService(databaseQueue: queue).resolve(provider: provider, mode: .coding)
        #expect(try await providers.provider(matching: snapshot, usageRecorder: nil, mode: .coding)?.providerID == provider.id)
        var changed = provider; changed.model = "lab/replacement"
        try await providers.save(changed, apiKey: nil)
        #expect(try await providers.provider(matching: snapshot, usageRecorder: nil, mode: .coding) == nil)
    }
}

private struct ParameterHistoryTool: DispatcherTool {
    let definition: ToolDefinition
    let requiresConfirmation = false
    func execute(argumentsJSON: String) async throws -> String { "unused" }
}
