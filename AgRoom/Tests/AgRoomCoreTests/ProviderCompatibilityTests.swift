import Foundation
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

struct ProviderCompatibilityTests {
    private let tool = ToolDefinition(name: "probe", description: "Read fixture",
        parametersSchemaJSON: #"{"type":"object","properties":{"optional":{"type":"string"}},"additionalProperties":false}"#)

    private func provider(endpoint: String, model: String, replies: [CompatibilityProtocol.Reply] = []) -> (CloudProvider, String) {
        let id = UUID().uuidString
        CompatibilityProtocol.register(id, replies: replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompatibilityProtocol.self]
        config.httpAdditionalHeaders = ["X-AgRoom-Test-Fixture": id]
        return (CloudProvider(config: .init(name: "fixture", endpoint: endpoint, model: model), apiKey: "fixture-key",
                              session: URLSession(configuration: config)), id)
    }

    @Test("The exact endpoint and model determine the available controls and the actual payload")
    func modelEffortMatrix() throws {
        for model in ["gpt-6.2-sol", "gpt-6.2-astra"] {
            let (cloud, id) = provider(endpoint: "https://api.openai.com/v1", model: model)
            defer { CompatibilityProtocol.remove(id) }
            let profile = cloud.reasoningProfile(.default)
            #expect(profile.choices == [.standard, .low, .medium, .high, .xhigh, .max])
            for effort in profile.choices {
                let config = LLMConfig(reasoningEffort: effort)
                let body = try object(cloud.buildChatRequest(messages: [], tools: [tool], config: config, stream: false).httpBody!)
                #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == (effort == .standard ? nil : effort.rawValue))
                #expect(body["temperature"] == nil && body["store"] as? Bool == false)
            }
        }
        for model in ["deepseek-flash", "deepseek-v4-pro", "kimi-k3", "kimi-k3.1-pro"] {
            let kimi = model.hasPrefix("kimi-")
            let (cloud, id) = provider(endpoint: kimi ? "https://api.moonshot.cn/v1" : "https://api.deepseek.com/v1", model: model)
            defer { CompatibilityProtocol.remove(id) }
            let profile = cloud.reasoningProfile(.default)
            #expect(profile.choices == (kimi ? [.standard, .low, .high, .max] : [.standard, .off, .low, .high, .max]))
            for effort in profile.choices {
                let body = try object(cloud.buildChatRequest(messages: [], tools: [tool], config: .init(reasoningEffort: effort), stream: false).httpBody!)
                #expect(body["reasoning_effort"] as? String == ([.off, .standard].contains(effort) ? nil : effort.rawValue))
                let toggle = (body["thinking"] as? [String: String])?["type"]
                #expect(toggle == (kimi || effort == .standard ? nil : (effort == .off ? "disabled" : "enabled")))
                if kimi || effort != .off { #expect(body["temperature"] == nil) }
            }
        }
    }

    @Test("Qwen preserves the deployment's reasoning format only on a confirmed template endpoint")
    func qwenDeployment() async throws {
        let model = "Qwen/Qwen3.6-35B-A3B"
        let (local, id) = provider(endpoint: "http://127.0.0.1:9080/v1", model: model, replies: [
            .init(body: #"data: {"choices":[{"delta":{"reasoning":"plan","content":"done"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n")
        ])
        defer { CompatibilityProtocol.remove(id) }
        var config = LLMConfig(reasoningEffort: .deep)
        var body = try object(local.buildChatRequest(messages: [], tools: [], config: config, stream: false).httpBody!)
        #expect(body["chat_template_kwargs"] == nil && body["enable_thinking"] == nil && body["reasoning_effort"] == nil)
        config.useQwenChatTemplate = true
        let reply = try await local.chatStream(messages: [.init(role: .user, text: "q")], tools: [], config: config, onDelta: { _ in })
        let history: [EngineMessage] = [.init(role: .user, text: "q"), .init(role: .assistant, text: reply.text, continuation: reply.continuation),
                                       .init(role: .user, text: "q2")]
        body = try object(local.buildChatRequest(messages: history, tools: [], config: config, stream: false).httpBody!)
        #expect(body["chat_template_kwargs"] as? [String: Bool] == ["enable_thinking": true, "preserve_thinking": true])
        #expect((body["messages"] as? [[String: Any]])?[1]["reasoning"] as? String == "plan")
        config.reasoningEffort = .off
        body = try object(local.buildChatRequest(messages: history, tools: [], config: config, stream: false).httpBody!)
        #expect(body["chat_template_kwargs"] as? [String: Bool] == ["enable_thinking": false])
        let (dash, dashID) = provider(endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: model)
        defer { CompatibilityProtocol.remove(dashID) }
        let dashBody = try object(dash.buildChatRequest(messages: [], tools: [], config: config, stream: false).httpBody!)
        #expect(dashBody["enable_thinking"] as? Bool == false && dashBody["chat_template_kwargs"] == nil)
    }

    @Test("Image inputs respect the configured model's declared or official input types")
    func imageInputTypes() async throws {
        let messages = [EngineMessage(role: .user, text: "describe", images: [.init(data: Data([1]), mimeType: "image/png")])]
        let (pro, id) = provider(endpoint: "https://api.deepseek.com/v1", model: "deepseek-v4-pro")
        defer { CompatibilityProtocol.remove(id) }
        do {
            _ = try await pro.chat(messages: messages, tools: [], config: .default)
            Issue.record("Known text-only input must be rejected before HTTP")
        } catch LLMError.imageUnsupported {}
        #expect(CompatibilityProtocol.requests(id).isEmpty)
        var config = LLMConfig(modelName: "deepseek-flash")
        _ = try await pro.prepareConfiguration(config, messages: messages, tools: [])
        var metadata = ModelCapabilities()
        metadata.inputModalities = ["text"]
        config.modelCapabilities = metadata
        await #expect(throws: LLMError.self) { try await pro.prepareConfiguration(config, messages: messages, tools: []) }
    }

    @Test("Follow-up requests reuse actual tool results without executing historical calls", arguments: [true, false])
    func savedToolTurn(_ responses: Bool) async throws {
        let call = #"data: {"choices":[{"delta":{"reasoning_content":"choose","tool_calls":[{"index":0,"id":"call_one","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n"
        let answer = #"data: {"choices":[{"delta":{"reasoning_content":"sum","content":"你好"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        let last = responses ? responseSSE(Self.answer) : answer
        let (p, id) = provider(endpoint: responses ? "https://api.openai.com/v1" : "https://api.deepseek.com/v1",
            model: responses ? "gpt-6.2-sol" : "deepseek-flash", replies: [
                .init(body: responses ? responseSSE(Self.toolAnswer) : call), .init(body: last), .init(body: last), .init(body: last)])
        defer { CompatibilityProtocol.remove(id) }
        let count = InvocationCounter(), sessionID = UUID()
        func engine(space: AppSpace = .work, session: UUID? = nil, prompt: String = "stable rules") -> DispatcherEngine {
            DispatcherEngine(provider: p, tools: [Probe(confirms: false, calls: count)], systemPrompt: prompt,
                             executionContext: .init(space: space, sessionID: session ?? sessionID, permissionPolicy: nil))
        }
        let first = engine()
        let question = ChatMessage(role: .user, content: "read the fixture")
        guard case .finished(let text, _, _, _, _, _, _) = try await first.run(userMessage: question.content, history: []) else {
            Issue.record("Expected a completed fixture turn"); return
        }
        let stored = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONEncoder().encode(first.takeSnapshot()))
        var assistant = ChatMessage(role: .assistant, content: text)
        assistant.providerTurn = try #require(stored.completedProviderTurn?.bound(to: text))
        var conversation = [question, assistant]
        func projected(_ messages: [ChatMessage]) throws -> [EngineMessage] {
            let saved = try JSONDecoder().decode([ChatMessage].self, from: JSONEncoder().encode(messages))
            return CodingHistory.messages(saved, limit: 30, tokenBudget: 12_000)
        }
        let second = engine()
        guard case .finished(let followup, _, _, _, _, _, _) = try await second.run(userMessage: "summarize", history: projected(conversation)) else {
            Issue.record("Expected a follow-up"); return
        }
        var simple = ChatMessage(role: .assistant, content: followup)
        simple.providerTurn = try #require(second.completedProviderTurn?.bound(to: followup))
        conversation += [.init(role: .user, content: "summarize"), simple]
        let third = engine()
        _ = try await third.run(userMessage: "continue", history: projected(conversation))
        let requests = CompatibilityProtocol.requests(id)
        #expect(requests.count == 4)
        #expect(third.requestReport.requestOutputLimit == LLMConfig.default.maxTokens)
        #expect(third.requestReport.requestReasoningLevel == (responses ? "standard" : "high"))
        #expect(await count.value == (responses ? 2 : 1))
        let body = try object(try #require(requests.last).body)
        if responses {
            let input = try #require(body["input"] as? [[String: Any]])
            #expect(input.contains { $0["encrypted_content"] as? String == "opaque-fixture" })
            #expect(input.filter { $0["type"] as? String == "function_call_output" }.count == 2)
        } else {
            let items = try #require(body["messages"] as? [[String: Any]])
            #expect(items.filter { $0["role"] as? String == "assistant" }.compactMap { $0["reasoning_content"] as? String } == ["choose", "sum", "sum"])
            #expect(items.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "call_one" })
        }
        for other in [engine(space: .personal), engine(session: UUID())] {
            let safe = other.preparedHistory(try projected(conversation), userMessage: "different")
            #expect(safe.allSatisfy { $0.continuation == nil && $0.toolCalls.isEmpty && $0.role != .toolResult })
        }
        if responses {
            let changed = engine(prompt: "different policy").preparedHistory(try projected(conversation), userMessage: "new")
            #expect(changed.allSatisfy { $0.continuation == nil })
        }
        assistant.content = "edited answer"
        #expect(try engine().preparedHistory(projected([question, assistant]), userMessage: "new").allSatisfy { $0.continuation == nil })
    }

    @Test("Progress and final text are separated even when a relay omits the item-added event", arguments: [true, false])
    func outputPhases(_ announced: Bool) async throws {
        let progress = #"{"type":"message","id":"p","phase":"commentary","role":"assistant","content":[{"type":"output_text","text":"checking"}]}"#
        let final = #"{"type":"message","id":"f","phase":"final_answer","role":"assistant","content":[{"type":"output_text","text":"done"}]}"#
        func added(_ item: String) -> String { "data: {\"type\":\"response.output_item.added\",\"item\":" + item + "}\n\n" }
        let fragment = announced ? "check" : "checking"
        let events = (announced ? added(progress) : "") + #"data: {"type":"response.output_text.delta","item_id":"p","delta":"\#(fragment)"}"# + "\n\n"
            + (announced ? added(final) : "") + #"data: {"type":"response.output_text.delta","item_id":"f","delta":"done"}"# + "\n\n"
        let (p, id) = provider(endpoint: "https://api.openai.com/v1", model: "gpt-6.2-astra", replies: [
            .init(body: events + responseSSE("{\"status\":\"completed\",\"output\":[" + progress + "," + final + "]}")),
            .init(body: responseSSE("{\"status\":\"completed\",\"output\":[" + progress + "]}"))])
        defer { CompatibilityProtocol.remove(id) }
        let visible = GatewayTextBuffer(), activity = GatewayTextBuffer()
        let reply = try await p.chatStream(messages: [], tools: [tool], config: .default,
            onDelta: { visible.append($0) }, onReasoningDelta: { activity.append($0) })
        #expect(reply.text == "done" && visible.value == "done")
        #expect(reply.commentary == "checking" && activity.value == "checking")
        do {
            _ = try await p.chatStream(messages: [], tools: [tool], config: .default, onDelta: { _ in })
            Issue.record("Progress alone cannot finish a task")
        } catch LLMError.reasoningOnlyResponse {}
    }

    @Test("A long source keeps its tail constraint; a tool turn must fit as one unit")
    func boundedConversationReplay() throws {
        let origin = ProviderTurnHistory.Origin(space: .work, sessionID: UUID(), providerID: UUID(),
            endpointDigest: "fixture", model: "fixture", scopeDigest: "workspace")
        let source = String(repeating: "段落。", count: 700) + "验收码 Z-782"
        let question = ChatMessage(role: .user, content: source)
        let user = EngineMessage(role: .user, text: DispatcherEngine.wrap(source))
        let call = EngineMessage(role: .assistant, text: "", toolCalls: [.init(id: "x", name: "lookup", argumentsJSON: "{}")],
                                 continuation: .init(reasoningContent: "plan"))
        let result = EngineMessage(role: .toolResult, text: String(repeating: "事实", count: 900), toolCallId: "x")
        let answer = ChatReply(text: "Z-782", toolCalls: [], continuation: .init(reasoningContent: "summary"))
        func capture(_ request: [EngineMessage]) -> ProviderTurnHistory? {
            ProviderTurnHistory(origin: origin, request: request, pinnedUserDigest: ResponsesContextWindow.digest(user.text),
                                tools: [], reply: answer)
        }
        #expect(capture([user, call]) == nil)
        #expect(capture([user, call, result, result]) == nil)
        var message = ChatMessage(role: .assistant, content: answer.text)
        message.providerTurn = try #require(capture([user, call, result])?.bound(to: answer.text))
        let projected = CodingHistory.messages([question, message], limit: 8, tokenBudget: 8000)
        func resolve(budget: Int, binding: ProviderTurnHistory.Origin) -> [EngineMessage] {
            ConversationHistory.resolve(projected, origin: binding, rules: [], tools: [], tokenBudget: budget, requiresAssistantReasoning: true)
        }
        let complete = resolve(budget: 8000, binding: origin)
        #expect(complete.map(\.role) == [.user, .assistant, .toolResult, .assistant])
        #expect(complete.first?.text.contains("验收码 Z-782") == true)
        let lean = resolve(budget: 2500, binding: origin)
        #expect(lean.count == 2 && lean.allSatisfy { $0.toolCalls.isEmpty && $0.continuation == nil })
        #expect(lean.first?.text.hasSuffix("Z-782") == true && lean.last?.text.contains(answer.text) == true)
        for (endpoint, model, scope) in [("different", origin.model, origin.scopeDigest),
                                        (origin.endpointDigest, "different", origin.scopeDigest),
                                        (origin.endpointDigest, origin.model, "different")] {
            let binding = ProviderTurnHistory.Origin(space: origin.space, sessionID: origin.sessionID, providerID: origin.providerID,
                endpointDigest: endpoint, model: model, scopeDigest: scope)
            #expect(resolve(budget: 8000, binding: binding).allSatisfy { $0.continuation == nil && $0.role != .toolResult })
        }
    }

    @Test("A reused historical call ID cannot consume the answer to a live question")
    func reusedQuestionID() async throws {
        let arguments = #"{"prompt":"Choose","fields":[{"id":"answer","label":"Answer","type":"text"}]}"#
        let call = ToolCallRaw(id: "same-id", name: "ask_user", argumentsJSON: arguments)
        let wire = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": [["index": 0, "id": call.id,
            "function": ["name": call.name, "arguments": arguments]]]], "finish_reason": "tool_calls"]]])
        let (cloud, id) = provider(endpoint: "https://fixture.invalid/v1", model: "fixture",
            replies: [.init(body: "data: " + String(decoding: wire, as: UTF8.self) + "\n\ndata: [DONE]\n\n"), .init(body: Self.chatSSE)])
        defer { CompatibilityProtocol.remove(id) }
        let engine = DispatcherEngine(provider: cloud, tools: [AskUserTool()], systemPrompt: "rules")
        let history: [EngineMessage] = [.init(role: .user, text: "previous"), .init(role: .assistant, text: "", toolCalls: [call]),
            .init(role: .toolResult, text: "previous answer", toolCallId: call.id), .init(role: .assistant, text: "finished")]
        guard case .waitingForInput = try await engine.run(userMessage: "ask again", history: history) else {
            Issue.record("Expected the current question"); return
        }
        #expect(engine.takeSnapshot().isLiveTopLevelQuestion)
        guard case .finished = try await engine.resume(.answered(#"{"answer":"current answer"}"#)) else {
            Issue.record("Expected the current question to finish"); return
        }
        let body = try object(try #require(CompatibilityProtocol.requests(id).last).body)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let results = messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
        #expect(results.count == 2 && results.first == "previous answer" && results.last?.contains("current answer") == true)
        #expect(!engine.takeSnapshot().requiresManualToolRecovery)
    }

    @Test("Endpoint and model determine wire format without rewriting gateways", arguments: [
        ("https://api.openai.com/v1/chat/completions", "gpt-6.1-terra", "responses", "max_output_tokens"),
        ("https://api.openai.com/v1/chat/completions/", "gpt-6.1-terra", "responses", "max_output_tokens"),
        ("https://api.openai.com/v1/chat/completions", "gpt-6-astra", "responses", "max_output_tokens"),
        ("https://api.openai.com/v1/chat/completions", "gpt-5", "responses", "max_output_tokens"),
        ("https://api.openai.com/v1/chat/completions", "o3", "responses", "max_output_tokens"),
        ("https://api.openai.com/v1/chat/completions", "o1", "chat/completions", "max_completion_tokens"),
        ("https://api.openai.com/v1/chat/completions", "gpt-4o", "chat/completions", "max_tokens"),
        ("https://relay.invalid/prefix/v1/chat/completions", "gpt-6.1-terra", "chat/completions", "max_tokens"),
        ("https://relay.invalid/prefix/v1/responses", "gpt-6.1-terra", "responses", "max_output_tokens"),
        ("https://openrouter.ai/api/v1/chat/completions", "openai/gpt-6.1-terra", "chat/completions", "max_tokens"),
        ("http://127.0.0.1:1234/v1/chat/completions", "local-model", "chat/completions", "max_tokens"),
        ("https://api.deepseek.com/chat/completions", "deepseek-flash", "chat/completions", "max_tokens"),
        ("https://api.anthropic.com/v1/messages", "claude-sonnet-4-5", "messages", "max_tokens"),
        ("https://regional.anthropic.com/v1", "claude-sonnet-4-5", "messages", "max_tokens"),
        ("https://anthropic.com.invalid/v1", "fixture", "chat/completions", "max_tokens"),
        ("https://relay.invalid/prefix/v1/messages", "claude-sonnet-4-5", "messages", "max_tokens")
    ])
    func requestMatrix(_ row: (String, String, String, String)) throws {
        let (p, id) = provider(endpoint: row.0, model: row.1)
        defer { CompatibilityProtocol.remove(id) }
        let request = try p.buildChatRequest(messages: [.init(role: .user, text: "你好")], tools: [tool], config: .default, stream: true)
        let body = try object(request.httpBody!)
        #expect(request.url!.path.hasSuffix("/" + row.2))
        #expect(body[row.3] as? Int == 2048)
        #expect(["max_tokens", "max_completion_tokens", "max_output_tokens"].filter { body[$0] != nil }.count == 1)
        #expect(body["model"] as? String == row.1)
        let tools = try #require(body["tools"] as? [[String: Any]])
        if row.2 == "responses" {
            #expect(body["messages"] == nil && body["stream_options"] == nil)
            #expect(body["store"] as? Bool == false)
            #expect(tools[0]["name"] as? String == "probe")
            #expect(tools[0]["strict"] as? Bool == false)
            #expect((tools[0]["parameters"] as? [String: Any])?["additionalProperties"] as? Bool == false)
        } else if row.2 == "messages" {
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
            #expect(body["stream_options"] == nil)
        } else {
            #expect((tools[0]["function"] as? [String: Any])?["name"] as? String == "probe")
        }
    }

    @Test("Automatic reply limits reach the wire after accounting for the input and task budget", arguments: [
        (1_050_000, 128_000, nil), (8_192, 8_192, nil), (8_192, 8_192, 2_500)
    ] as [(Int, Int, Int?)])
    func automaticReplyLimit(_ limits: (Int, Int, Int?)) async throws {
        let (context, output, taskBudget) = limits
        let (cloud, id) = provider(endpoint: "https://api.openai.com/v1", model: "gpt-6.2-astra",
            replies: [.init(body: responseSSE(Self.answer))])
        defer { CompatibilityProtocol.remove(id) }
        let parameters = ModelParameterPreferences(reasoningEffort: .xhigh).resolved(mode: .chat,
            capabilities: .init(contextTokens: context, outputTokens: output))
        let ledger = ExecutionBudgetLedger(maxTokens: taskBudget, maxToolCalls: 1)
        let engine = DispatcherEngine(provider: cloud, tools: [], systemPrompt: "fixture", config: parameters.config,
            budgetLedger: ledger, modelParameterSnapshot: parameters)
        _ = try await engine.run(userMessage: "Prepare the order app.", history: [])
        let requests = CompatibilityProtocol.requests(id)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let body = try object(request.body)
        let input = engine.requestReport.estimatedTokens
        let allowed = min(output, context - input - 256, taskBudget.map { $0 - input } ?? Int.max)
        #expect(body["max_output_tokens"] as? Int == allowed)
        #expect(engine.requestReport.requestOutputLimit == allowed)
        #expect((body["reasoning"] as? [String: String])?["effort"] == "xhigh")
        #expect(await ledger.reserved == 0)
    }

    @Test("Larger automatic replies keep the selected Anthropic thinking budget")
    func automaticReplyPreservesThinking() throws {
        let (cloud, id) = provider(endpoint: "https://api.anthropic.com/v1/messages", model: "claude-sonnet-4-5")
        defer { CompatibilityProtocol.remove(id) }
        let parameters = ModelParameterPreferences(reasoningEffort: .deep).resolved(mode: .chat,
            capabilities: .init(contextTokens: 200_000, outputTokens: 64_000))
        let request = try cloud.buildChatRequest(messages: [.init(role: .user, text: "test")], tools: [], config: parameters.config, stream: true)
        let body = try object(try #require(request.httpBody))
        #expect(body["max_tokens"] as? Int == 64_000)
        #expect((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 4096)
    }

    @Test("Saved context budgets override the default while retaining explicit task ceilings")
    func configurableContextBudget() async throws {
        let (p, id) = provider(endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-6.1-terra",
                               replies: [.init(body: responseSSE(Self.answer))])
        defer { CompatibilityProtocol.remove(id) }
        let input = String(repeating: "a", count: 1_080_000)
        let caps = ModelCapabilities(contextTokens: 1_050_000, outputTokens: 128_000)
        let automatic = ModelParameterPreferences().resolved(mode: .coding, capabilities: caps)
        let blocked = DispatcherEngine(provider: p, tools: [], systemPrompt: "fixture", config: automatic.config,
            modelParameterSnapshot: automatic)
        do { _ = try await blocked.run(userMessage: input, history: []); Issue.record("Expected local context rejection") }
        catch LLMError.contextBudgetExceeded {}
        #expect(CompatibilityProtocol.requests(id).isEmpty)
        #expect(blocked.requestReport.estimatedTokens > 256_000)
        #expect(blocked.requestReport.contextTokenBudget == 256_000)
        #expect(blocked.requestReport.requestCount == 0)

        let manual = ModelParameterPreferences(contextTokenBudget: 512_000).resolved(mode: .coding, capabilities: caps)
        let frozen = try JSONDecoder().decode(ResolvedModelParameters.self, from: JSONEncoder().encode(manual))
        let engine = DispatcherEngine(provider: p, tools: [], systemPrompt: "fixture", config: frozen.config,
            modelParameterSnapshot: frozen)
        guard case .finished(let text, _, _, _, _, _, _) = try await engine.run(userMessage: input, history: []) else {
            Issue.record("Expected completion with the larger frozen budget"); return
        }
        #expect(text == "你好")
        #expect(engine.requestReport.contextTokenBudget == 512_000)
        #expect(engine.requestReport.requestCount == 1)
        #expect(CompatibilityProtocol.requests(id).count == 1)

        let taskLimited = DispatcherEngine(provider: p, tools: [], systemPrompt: "fixture", config: frozen.config,
            contextTokenBudget: 32_000, modelParameterSnapshot: frozen)
        do { _ = try await taskLimited.run(userMessage: input, history: []); Issue.record("Expected the task ceiling to stay in force") }
        catch LLMError.contextBudgetExceeded {}
        #expect(taskLimited.requestReport.contextTokenBudget == 32_000)
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("All generation entry points use the selected protocol", arguments: ["generate", "stream", "chat", "chatStream"], [true, false])
    func generationEntryPoints(_ entry: String, _ responses: Bool) async throws {
        let streaming = entry == "stream" || entry == "chatStream"
        let body = responses ? (streaming ? responseSSE(Self.answer) : Self.answer) :
            (streaming ? Self.chatSSE : Self.chatAnswer)
        let (p, id) = provider(endpoint: responses ? "https://api.openai.com/v1/chat/completions" : "https://legacy.invalid/v1/chat/completions",
                               model: responses ? "gpt-6.1-terra" : "gpt-4o", replies: [.init(body: body)])
        defer { CompatibilityProtocol.remove(id) }
        #expect(try await invoke(entry, provider: p, config: .default) == "你好")
        let request = try #require(CompatibilityProtocol.requests(id).first)
        let json = try object(request.body)
        #expect(request.url.path == (responses ? "/v1/responses" : "/v1/chat/completions"))
        #expect(json[responses ? "max_output_tokens" : "max_tokens"] as? Int == 2048)
        if entry == "generate" || entry == "stream" {
            let raw = String(decoding: request.body, as: UTF8.self)
            #expect(raw.contains("DATA provided by the user"))
            #expect(raw.contains("<<<内容开始>>>"))
        }
    }

    @Test("Rejected parameter names, temperatures and numeric bounds adapt independently", arguments: ["generate", "stream", "chat", "chatStream"])
    func compoundAdaptation(_ entry: String) async throws {
        let streaming = entry == "stream" || entry == "chatStream"
        var replies: [CompatibilityProtocol.Reply] = [
            .init(status: 400, body: #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","param":"max_tokens","code":"unsupported_parameter"}}"#),
            .init(status: 400, body: #"{"error":{"message":"Unsupported value: 'temperature' only supports its default value","param":"temperature"}}"#),
            .init(status: 400, body: #"{"error":{"message":"max_completion_tokens valid range is [1, 8192]"}}"#)
        ]
        if streaming { replies.append(.init(status: 400, body: #"{"error":{"message":"Unsupported parameter: 'stream_options'","param":"stream_options","code":"unsupported_parameter"}}"#)) }
        replies.append(.init(body: streaming ? Self.chatSSE : Self.chatAnswer))
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/chat/completions", model: "remote-model", replies: replies)
        defer { CompatibilityProtocol.remove(id) }
        #expect(try await invoke(entry, provider: p, config: .init(maxTokens: 20_000)) == "你好")
        let bodies = try CompatibilityProtocol.requests(id).map { try object($0.body) }
        #expect(bodies.count == (streaming ? 5 : 4))
        #expect(bodies[0]["max_tokens"] as? Int == 20_000)
        #expect(bodies[1]["max_completion_tokens"] as? Int == 20_000)
        #expect(bodies[2]["temperature"] == nil)
        #expect(bodies.last?["max_completion_tokens"] as? Int == 8192)
        if streaming { #expect(bodies.last?["stream_options"] == nil) }
    }

    @Test("Unsupported fields never become a numeric limit or silently disable tools")
    func unsupportedIsNotRange() async throws {
        let error = LLMError.networkError(statusCode: 400, message: "Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead.")
        #expect(CloudProvider.adaptedMaxTokensConfig(error: error, config: .init(maxTokens: 100_000)) == nil)
        #expect(!CloudProvider.isOutputLimitMessage("max_output_tokens is not supported"))
        let (p, id) = provider(endpoint: "https://relay.invalid/v1", model: "remote-model", replies: [
            .init(status: 400, body: #"{"error":{"message":"Unsupported parameter: 'tools'","param":"tools","code":"unsupported_parameter"}}"#)
        ])
        defer { CompatibilityProtocol.remove(id) }
        do {
            _ = try await p.chat(messages: [.init(role: .user, text: "read")], tools: [tool], config: .default)
            Issue.record("Unsupported tools must fail")
        } catch LLMError.unsupportedParameter(let parameter) { #expect(parameter == "tools") }
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("Contradictory gateways cannot cause parameter retry loops", arguments: [true, false])
    func adaptationIsBounded(_ quoted: Bool) async throws {
        let (p, id) = provider(endpoint: "https://relay.invalid/v1", model: "remote-model", replies: [
            .init(status: 400, body: quoted ? "Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead." : "Unsupported parameter: max_tokens. Use max_completion_tokens instead."),
            .init(status: 400, body: "Unsupported parameter: 'max_completion_tokens'. Use 'max_tokens' instead.")
        ])
        defer { CompatibilityProtocol.remove(id) }
        await #expect(throws: LLMError.self) { try await p.chat(messages: [], tools: [], config: .default) }
        #expect(CompatibilityProtocol.requests(id).count == 2)
    }

    @Test("Provider-specific thinking formats remain independent", arguments: [
        ("https://api.deepseek.com/chat/completions", "deepseek-flash", "thinking"),
        ("https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4.7", "thinking"),
        ("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen3.6-35b", "enable_thinking"),
        ("https://openrouter.ai/api/v1/chat/completions", "qwen/qwen3", "reasoning"),
        ("https://relay.invalid/v1/messages", "claude-sonnet-4-5", "thinking")
    ])
    func thinkingMatrix(_ row: (String, String, String)) throws {
        let (p, id) = provider(endpoint: row.0, model: row.1)
        defer { CompatibilityProtocol.remove(id) }
        let request = try p.buildChatRequest(messages: [], tools: [], config: .init(maxTokens: 8192, reasoningEffort: .deep), stream: false)
        let body = try object(request.httpBody!)
        #expect(body[row.2] != nil)
        if row.2 == "enable_thinking" { #expect(body[row.2] as? Bool == true) }
        if row.0.hasSuffix("/messages") { #expect(body["temperature"] == nil) }
    }

    @Test("Reasoning temperature rules honor none effort and model capabilities")
    func reasoningParameters() throws {
        for model in ["gpt-6.1-terra", "gpt-6-astra", "gpt-6.1-sol", "gpt-5", "o3"] {
            let (p, id) = provider(endpoint: "https://api.openai.com/v1", model: model)
            defer { CompatibilityProtocol.remove(id) }
            var config = LLMConfig(reasoningEffort: .deep)
            config.modelCapabilities = .init(supportsTemperature: true)
            #expect(try object(p.buildChatRequest(messages: [], tools: [], config: config, stream: false).httpBody!)["temperature"] == nil)
            config.reasoningEffort = .fast
            let body = try object(p.buildChatRequest(messages: [], tools: [], config: config, stream: false).httpBody!)
            let level = (body["reasoning"] as? [String: Any])?["effort"] as? String
            #expect(level == (model == "gpt-6.1-terra" ? "none" : (model == "gpt-5" ? "minimal" : "low")))
            #expect((body["temperature"] != nil) == (level == "none"))
        }
    }

    @Test("Responses tool calls replay encrypted reasoning, preserve IDs and survive snapshots")
    func toolRoundTrip() async throws {
        let (p, id) = provider(endpoint: "https://api.openai.com/v1", model: "gpt-6.1-terra", replies: [
            .init(body: responseSSE(Self.toolAnswer)), .init(body: Self.answer)
        ])
        defer { CompatibilityProtocol.remove(id) }
        let reply = try await p.chatStream(messages: [.init(role: .user, text: "read twice")], tools: [tool], config: .default, onDelta: { _ in })
        #expect(reply.toolCalls.map(\.id) == ["call_one", "call_two"])
        #expect(reply.reasoning == "plan")
        #expect(reply.continuation?.containsThinkingBlocks == true)
        #expect(reply.usage.input == 100 && reply.usage.output == 30 && reply.usage.reasoning == 20 && reply.usage.cacheRead == 50)
        let message = EngineMessage(role: .assistant, text: reply.text, toolCalls: reply.toolCalls, continuation: reply.continuation)
        let snapshot = EngineMessageSnapshot(message: message)
        let saved = try JSONDecoder().decode(EngineMessageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(saved.continuation == reply.continuation)
        let history: [EngineMessage] = [.init(role: .user, text: "read twice"), message,
            .init(role: .toolResult, text: "one", toolCallId: "call_one"), .init(role: .toolResult, text: "two", toolCallId: "call_two")]
        _ = try await p.chat(messages: history, tools: [tool], config: .default)
        let request = try #require(CompatibilityProtocol.requests(id).last)
        let input = try #require(try object(request.body)["input"] as? [[String: Any]])
        #expect(input.count == 6)
        #expect(input[1]["encrypted_content"] as? String == "opaque-fixture")
        #expect(input.filter { $0["type"] as? String == "function_call" }.compactMap { $0["call_id"] as? String } == ["call_one", "call_two"])
        #expect(input.suffix(2).compactMap { $0["call_id"] as? String } == ["call_one", "call_two"])
        let estimate = TokenEstimator.estimate(messages: [message])
        #expect(estimate == TokenEstimator.estimate(reply.continuation!.responsesItemsJSON!) + 8)
    }

    @Test("Responses streams reject EOF, failure and partial tool calls before execution", arguments: ["eof", "failed", "incomplete", "invalidArguments", "duplicateIDs", "invalidEvent"])
    func failClosed(_ kind: String) async throws {
        var body: String
        switch kind {
        case "invalidEvent": body = "data:{invalid\n\n"
        case "eof": body = #"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n"
        case "failed": body = #"data: {"type":"response.failed","response":{"status":"failed","error":{"message":"Unsupported parameter: 'max_tokens'"},"usage":{"input_tokens":5,"output_tokens":2}}}"# + "\n\n"
        default:
            var json = try object(Data(Self.toolAnswer.utf8))
            if kind == "incomplete" { json["status"] = "incomplete"; json["incomplete_details"] = ["reason": "max_output_tokens"] }
            var output = json["output"] as! [[String: Any]]
            if kind == "invalidArguments" { output[1]["arguments"] = "{" }
            if kind == "duplicateIDs" { output[2]["call_id"] = "call_one" }
            json["output"] = output
            body = responseSSE(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        }
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/responses", model: "fixture", replies: [.init(body: body)])
        defer { CompatibilityProtocol.remove(id) }
        await #expect(throws: LLMError.self) { try await p.chatStream(messages: [], tools: [tool], config: .default, onDelta: { _ in }) }
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("Chat streams retain tool calls in multiline events and gateway message snapshots",
          arguments: ["multiline", "message", "fragmentedName", "snapshotAfterDeltas", "finishWithoutDelta"])
    func chatGatewayToolCalls(_ format: String) async throws {
        let call = #"{"id":"call_one","type":"function","function":{"name":"probe","arguments":"{}"}}"#
        let delta = #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_one","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":null}]}"# + "\n\n"
        let finish = #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"# + "\n\n"
        let snapshot = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[" + call + "]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}\n\n"
        let body: String
        switch format {
        case "multiline":
            body = "event: message\n: keepalive\ndata: {\ndata: \"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[" + call.dropLast() + ",\"index\":0}]},\"finish_reason\":null}]\ndata: }\n\n" + finish
        case "message": body = snapshot
        case "snapshotAfterDeltas": body = delta + snapshot
        case "fragmentedName":
            body = delta.replacingOccurrences(of: "\"name\":\"probe\"", with: "\"name\":\"pro\"") +
                #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"be","arguments":""}}]},"finish_reason":null}]}"# + "\n\n" + finish
        default:
            body = delta + #"data: {"choices":[{"index":0,"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"# + "\n\n"
        }
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/chat/completions", model: "gpt-6-astra",
                               replies: [.init(body: body + "data: [DONE]\n\n")])
        defer { CompatibilityProtocol.remove(id) }
        let reply = try await p.chatStream(messages: [], tools: [tool], config: .default, onDelta: { _ in })
        #expect(reply.toolCalls == [.init(id: "call_one", name: "probe", argumentsJSON: "{}")])
        #expect(reply.finishReason == "tool_calls")
        #expect(!reply.hasToolCallFinishMismatch)
        #expect(reply.usage.input == 10 && reply.usage.output == 3)
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("Gateway snapshots preserve approval and execute each call once")
    func chatGatewayCallsKeepApproval() async throws {
        let body = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_write","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":null}]}"# + "\n\n" +
            #"data: {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_write","type":"function","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n"
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/chat/completions", model: "fixture",
                               replies: [.init(body: body), .init(body: Self.chatSSE)])
        defer { CompatibilityProtocol.remove(id) }
        let write = GatewayConfirmTool()
        let engine = DispatcherEngine(provider: p, tools: [write], systemPrompt: "fixture", maxSteps: 3)
        guard case .needsConfirmation = try await engine.run(userMessage: "write fixture", history: []) else {
            Issue.record("Expected approval before the gateway tool call executes"); return
        }
        #expect(write.count == 0)
        guard case .finished = try await engine.resume(approved: true) else {
            Issue.record("Expected completion after approval"); return
        }
        #expect(write.count == 1)
        let requests = CompatibilityProtocol.requests(id)
        #expect(requests.count == 2)
        let history = try #require(try object(requests[1].body)["messages"] as? [[String: Any]])
        let results = history.filter { $0["role"] as? String == "tool" }
        #expect(results.count == 1)
        #expect(results.first?["tool_call_id"] as? String == "call_write")
    }

    @Test("Gateway snapshots complete prefixes without duplicating text, reasoning or arguments",
          arguments: [("Preparing", " report"), ("👍", "🏽"), ("e", "\u{301}"), ("👩", "\u{200d}💻")])
    func chatGatewaySnapshotCompletesPrefixes(_ parts: (String, String)) async throws {
        let complete = parts.0 + parts.1
        let argumentPrefix = "{\"optional\":\"" + parts.0
        let arguments = argumentPrefix + parts.1 + "\"}"
        let first: [String: Any] = ["choices": [["delta": ["content": parts.0, "reasoning_content": "plan", "tool_calls": [
            ["index": 0, "id": "call_one", "function": ["name": "pro", "arguments": argumentPrefix]]
        ]]]]]
        let last: [String: Any] = ["choices": [["message": ["role": "assistant", "content": complete, "reasoning_content": "plan carefully", "tool_calls": [
            ["id": "call_one", "function": ["name": "probe", "arguments": arguments]]
        ]], "finish_reason": "tool_calls"]]]
        let frames = try [first, last, last].map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/chat/completions", model: "fixture",
                               replies: [.init(body: frames + "data: [DONE]\n\n")])
        defer { CompatibilityProtocol.remove(id) }
        let text = GatewayTextBuffer(), reasoning = GatewayTextBuffer()
        let reply = try await p.chatStream(messages: [], tools: [tool], config: .default,
            onDelta: { text.append($0) }, onReasoningDelta: { reasoning.append($0) })
        #expect(text.value == complete && reply.text == text.value)
        #expect(reasoning.value == "plan carefully" && reply.reasoning == reasoning.value)
        #expect(reply.continuation?.reasoningContent == reasoning.value)
        #expect(reply.toolCalls == [.init(id: "call_one", name: "probe", argumentsJSON: arguments)])
    }

    @Test("Multiline Chat events retain the total event size bound")
    func oversizedMultilineChatEventFails() async throws {
        let body = String(repeating: "data: " + String(repeating: " ", count: LLMResponseLimits.eventBytes / 4) + "\n", count: 5) + "\n"
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/chat/completions", model: "fixture", replies: [.init(body: body)])
        defer { CompatibilityProtocol.remove(id) }
        do { _ = try await p.chatStream(messages: [], tools: [tool], config: .default, onDelta: { _ in }); Issue.record("Expected event size rejection") }
        catch LLMError.responseTooLarge { }
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("Malformed Chat events and conflicting snapshots never authorize partial batches",
          arguments: ["invalidJSON", "missingName", "changedSnapshot", "missingID", "duplicateID", "invalidArray", "invalidFunction"])
    func malformedChatToolBatchesFailClosed(_ format: String) async throws {
        let first = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_one","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":null}]}"# + "\n\n"
        let broken: String
        switch format {
        case "invalidJSON": broken = "data: {invalid\n\n"
        case "missingName":
            broken = #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_two","function":{"arguments":"{}"}}]},"finish_reason":null}]}"# + "\n\n"
        case "changedSnapshot":
            broken = #"data: {"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"changed","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\n"
        case "missingID":
            broken = #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"probe","arguments":"{}"}}]},"finish_reason":null}]}"# + "\n\n"
        case "invalidArray":
            broken = #"data: {"choices":[{"delta":{"tool_calls":"broken"},"finish_reason":null}]}"# + "\n\n"
        case "invalidFunction":
            broken = #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_two","function":{"name":"probe","arguments":{"optional":"fixture"}}}]},"finish_reason":null}]}"# + "\n\n"
        default:
            broken = #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_one","function":{"name":"probe","arguments":"{}"}}]},"finish_reason":null}]}"# + "\n\n"
        }
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/chat/completions", model: "fixture", replies: [
            .init(body: first + broken + #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n")
        ])
        defer { CompatibilityProtocol.remove(id) }
        let write = GatewayConfirmTool()
        let engine = DispatcherEngine(provider: p, tools: [write], systemPrompt: "fixture", maxSteps: 3)
        do { _ = try await engine.run(userMessage: "write", history: []); Issue.record("Expected parsing failure before approval or execution") }
        catch LLMError.responseParsingFailed { }
        #expect(write.count == 0)
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    private final class GatewayConfirmTool: DispatcherTool, @unchecked Sendable {
        let definition = ToolDefinition(name: "probe", description: "Fixture write", parametersSchemaJSON: #"{"type":"object","properties":{}}"#)
        var requiresConfirmation: Bool { true }
        private let lock = NSLock()
        private var executions = 0
        var count: Int { lock.withLock { executions } }
        func execute(argumentsJSON: String) async throws -> String {
            lock.withLock { executions += 1 }
            return "written"
        }
    }

    private final class GatewayTextBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        var value: String { lock.withLock { text } }
        func append(_ value: String) { lock.withLock { text += value } }
    }

    @Test("Responses streaming supports parallel argument fragments and multi-line SSE")
    func parallelFragments() async throws {
        let chunks = [
            #"{"type":"response.reasoning_summary_text.delta","delta":"plan"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_one","delta":"{"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_two","delta":"{}"}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_one","delta":"}"}"#
        ].map { "data:" + $0 + "\n\n" }.joined()
        let terminal = "event: response.completed\ndata:{\ndata:\"type\":\"response.completed\",\ndata:\"response\":" + Self.toolAnswer + "\ndata:}\n\n"
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/responses", model: "fixture", replies: [.init(body: chunks + terminal)])
        defer { CompatibilityProtocol.remove(id) }
        let reply = try await p.chatStream(messages: [], tools: [tool], config: .default, onDelta: { _ in })
        #expect(reply.toolCalls.count == 2)
        #expect(reply.toolCalls.allSatisfy { $0.argumentsJSON == "{}" })
        #expect(reply.reasoning == "plan")
    }

    @Test("Responses numeric limits clamp without using Chat parameter names")
    func responsesLimit() async throws {
        let (p, id) = provider(endpoint: "https://api.openai.com/v1", model: "gpt-6.1-terra", replies: [
            .init(status: 400, body: #"{"error":{"message":"max_output_tokens valid range is [1, 8000]"}}"#), .init(body: Self.answer)
        ])
        defer { CompatibilityProtocol.remove(id) }
        _ = try await p.chat(messages: [], tools: [], config: .init(maxTokens: 100_000))
        #expect(try CompatibilityProtocol.requests(id).map { try object($0.body)["max_output_tokens"] as? Int } == [100_000, 8000])
    }

    @Test("Supported token parameters are read from metadata and old snapshots remain decodable")
    func metadataAndOldSnapshots() throws {
        let data = Data(#"{"data":[{"id":"fixture","supported_parameters":["max_completion_tokens"]}]}"#.utf8)
        let caps = try #require(try ModelParameterService.parse(data, model: "fixture", openRouter: false, at: Date()))
        let (p, id) = provider(endpoint: "https://relay.invalid/v1", model: "fixture")
        defer { CompatibilityProtocol.remove(id) }
        var config = LLMConfig()
        config.modelCapabilities = caps
        let body = try object(p.buildChatRequest(messages: [], tools: [], config: config, stream: false).httpBody!)
        #expect(body["max_completion_tokens"] as? Int == 2048)
        #expect(body["max_tokens"] == nil && body["temperature"] == nil)
        let old = Data(#"{"modelName":"fixture","maxTokens":2048,"temperature":0.7}"#.utf8)
        #expect(try JSONDecoder().decode(LLMConfig.self, from: old).requestMaxTokenParameter == nil)
        #expect(try JSONDecoder().decode(EngineContinuation.self, from: Data("{}".utf8)).responsesItemsJSON == nil)
        #expect(!LLMProviderConfig(name: "fixture", endpoint: "https://anthropic.com.attacker.invalid/v1/chat/completions", model: "fixture").isAnthropic)
    }

    @Test("Custom Anthropic endpoints work through all entry points with thinking enabled", arguments: ["generate", "stream", "chat", "chatStream"])
    func anthropicEntryPoints(_ entry: String) async throws {
        let streaming = entry == "stream" || entry == "chatStream"
        let json = #"{"content":[{"type":"thinking","thinking":"plan","signature":"opaque"},{"type":"text","text":"你好"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":3}}"#
        let sse = [
            #"""
event:message_start
data:{"type":"message_start","message":{"usage":{"input_tokens":10}}}

event:content_block_start
data:{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event:content_block_delta
data:{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}

event:content_block_stop
data:{"type":"content_block_stop","index":0}

event:message_delta
data:{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

event:message_stop
data:{"type":"message_stop"}
"""#
        ].joined() + "\n\n"
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/messages", model: "claude-fixture", replies: [.init(body: streaming ? sse : json)])
        defer { CompatibilityProtocol.remove(id) }
        #expect(try await invoke(entry, provider: p, config: .init(maxTokens: 8192, reasoningEffort: .deep)) == "你好")
        let body = try object(try #require(CompatibilityProtocol.requests(id).first).body)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(body["temperature"] == nil && body["max_tokens"] as? Int == 8192)
    }

    @Test("Responses engine tool loops preserve confirmation policy and checkpoint data", arguments: [false, true])
    func engineRoundTrip(_ confirms: Bool) async throws {
        let (p, id) = provider(endpoint: "https://api.openai.com/v1", model: "gpt-6.1-terra", replies: [
            .init(body: responseSSE(Self.toolAnswer)), .init(body: responseSSE(Self.answer))
        ])
        defer { CompatibilityProtocol.remove(id) }
        let calls = InvocationCounter()
        let engine = DispatcherEngine(provider: p, tools: [Probe(confirms: confirms, calls: calls)], systemPrompt: "fixture", maxSteps: 4)
        let outcome = try await engine.run(userMessage: "read twice", history: [])
        let restored = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONEncoder().encode(engine.takeSnapshot()))
        #expect(restored.messages.contains { $0.continuation?.responsesItemsJSON?.contains("opaque-fixture") == true })
        if confirms {
            guard case .needsConfirmation = outcome else { Issue.record("Responses calls must require the existing confirmation"); return }
            #expect(await calls.value == 0)
            #expect(CompatibilityProtocol.requests(id).count == 1)
        } else {
            guard case .finished = outcome else { Issue.record("Expected completed Responses tool loop"); return }
            #expect(await calls.value == 2)
            #expect(CompatibilityProtocol.requests(id).count == 2)
        }
    }

    @Test("Responses arguments are bounded before a terminal event can execute tools")
    func oversizedArguments() async throws {
        let delta = String(repeating: "x", count: LLMResponseLimits.argumentBytes + 1)
        let event = try JSONSerialization.data(withJSONObject: ["type": "response.function_call_arguments.delta", "item_id": "fc_one", "delta": delta])
        let (p, id) = provider(endpoint: "https://relay.invalid/v1/responses", model: "fixture", replies: [.init(body: "data:" + String(decoding: event, as: UTF8.self) + "\n\n")])
        defer { CompatibilityProtocol.remove(id) }
        do {
            _ = try await p.chatStream(messages: [], tools: [tool], config: .default, onDelta: { _ in })
            Issue.record("Oversized arguments must fail")
        } catch LLMError.responseTooLarge { }
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("Cancellation starts no request or adaptation")
    func cancellation() async throws {
        let (p, id) = provider(endpoint: "https://api.openai.com/v1", model: "gpt-6.1-terra")
        defer { CompatibilityProtocol.remove(id) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await p.chatStream(messages: [], tools: [], config: .default, onDelta: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(CompatibilityProtocol.requests(id).isEmpty)
    }

    @MainActor
    @Test("Unsupported parameter errors are localized and never described as out of range")
    func localizedParameterErrors() {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        var values = Set<String>()
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            let error = LLMError.unsupportedParameter(parameter: "max_tokens")
            let message = L.errorDescription(error)
            values.insert(message)
            #expect(message.contains("max_tokens"))
            #expect(!message.contains("越界") && !message.contains("调低") && !message.contains("調低"))
            #expect(!DispatcherEngine.isRetryable(error))
            #expect(L.errorDescription(LLMError.networkError(statusCode: 400, message: "Unsupported parameter: 'max_tokens'")) == message)
        }
        #expect(values.count == 3)
    }

    private actor InvocationCounter {
        var value = 0
        func increment() { value += 1 }
    }
    private struct Probe: DispatcherTool {
        let confirms: Bool
        let calls: InvocationCounter
        var requiresConfirmation: Bool { confirms }
        var sideEffectClass: ToolSideEffectClass { .readOnly }
        var definition: ToolDefinition { .init(name: "probe", description: "Fixture", parametersSchemaJSON: #"{"type":"object","properties":{}}"#) }
        func execute(argumentsJSON: String) async throws -> String { await calls.increment(); return "fixture" }
    }

    private func invoke(_ entry: String, provider: CloudProvider, config: LLMConfig) async throws -> String {
        switch entry {
        case "generate": return try await provider.generate(prompt: "你好", config: config)
        case "stream":
            var result = ""
            for try await chunk in try await provider.stream(prompt: "你好", config: config) { result += chunk }
            return result
        case "chat": return try await provider.chat(messages: [.init(role: .user, text: "你好")], tools: [], config: config).text
        default: return try await provider.chatStream(messages: [.init(role: .user, text: "你好")], tools: [], config: config, onDelta: { _ in }).text
        }
    }

    private func object(_ data: Data) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func responseSSE(_ body: String) -> String { "data: {\"type\":\"response.completed\",\"response\":" + body + "}\n\n" }
    private static let answer = #"{"status":"completed","output":[{"type":"message","id":"msg_fixture","role":"assistant","status":"completed","content":[{"type":"output_text","text":"你好","annotations":[]}]}],"usage":{"input_tokens":10,"output_tokens":3}}"#
    private static let chatAnswer = #"{"choices":[{"message":{"content":"你好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#
    private static let chatSSE = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    private static let toolAnswer = #"{"status":"completed","output":[{"id":"rs_fixture","type":"reasoning","summary":[{"type":"summary_text","text":"plan"}],"encrypted_content":"opaque-fixture"},{"id":"fc_one","type":"function_call","call_id":"call_one","name":"probe","arguments":"{}","status":"completed"},{"id":"fc_two","type":"function_call","call_id":"call_two","name":"probe","arguments":"{}","status":"completed"}],"usage":{"input_tokens":100,"output_tokens":30,"input_tokens_details":{"cached_tokens":50},"output_tokens_details":{"reasoning_tokens":20}}}"#
}

final class CompatibilityProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var body: String; var failure: URLError.Code? = nil }
    struct Request: Sendable { let url: URL; let body: Data }
    private struct Script { var replies: [Reply]; var requests: [Request] = [] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    static func register(_ id: String, replies: [Reply]) { lock.withLock { scripts[id] = .init(replies: replies) } }
    static func remove(_ id: String) { _ = lock.withLock { scripts.removeValue(forKey: id) } }
    static func requests(_ id: String) -> [Request] { lock.withLock { scripts[id]?.requests ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let reply: Reply? = Self.lock.withLock {
            guard let id = request.value(forHTTPHeaderField: "X-AgRoom-Test-Fixture"), var script = Self.scripts[id], let url = request.url else { return nil }
            script.requests.append(.init(url: url, body: data))
            let reply = script.replies.isEmpty ? nil : script.replies.removeFirst()
            Self.scripts[id] = script
            return reply
        }
        guard let reply, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
