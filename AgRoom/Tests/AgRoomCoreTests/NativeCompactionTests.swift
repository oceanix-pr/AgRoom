import Foundation
import Testing
@testable import AgRoomCore

struct NativeCompactionTests {
    private struct Probe: DispatcherTool {
        let requiresConfirmation = false
        var sideEffectClass: ToolSideEffectClass { .readOnly }
        var definition: ToolDefinition { .init(name: "probe", description: "Read fixture", parametersSchemaJSON: #"{"type":"object","properties":{}}"#) }
        func execute(argumentsJSON: String) async throws -> String { "Current evidence" }
    }

    private func provider(endpoint: String = "https://api.openai.com/v1/responses", model: String = "gpt-5.4",
                          replies: [String] = []) -> (CloudProvider, String) {
        let id = UUID().uuidString
        CompatibilityProtocol.register(id, replies: replies.map { .init(body: $0) })
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CompatibilityProtocol.self]
        session.httpAdditionalHeaders = ["X-AgRoom-Test-Fixture": id]
        return (CloudProvider(config: .init(name: "fixture", endpoint: endpoint, model: model), apiKey: "fixture",
            session: URLSession(configuration: session)), id)
    }

    private func response(_ output: [[String: Any]], truncated: Bool = false) throws -> String {
        var body: [String: Any] = ["status": truncated ? "incomplete" : "completed", "output": output,
            "usage": ["input_tokens": 10, "output_tokens": 3]]
        if truncated { body["incomplete_details"] = ["reason": "max_output_tokens"] }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject:
            ["type": truncated ? "response.incomplete" : "response.completed", "response": body]), as: UTF8.self) + "\n\n"
    }
    private func message(_ text: String) -> [String: Any] {
        ["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]
    }
    private func object(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }

    @Test("Native compaction is opt-in per frozen config and restricted to supported official Responses")
    func requestGates() throws {
        for (endpoint, model, expected) in [
            ("https://api.openai.com/v1/responses", "gpt-5.4", true),
            ("https://api.openai.com/v1/responses", "gpt-5.3-codex", true),
            ("https://api.openai.com/v1/chat/completions", "gpt-6.1-terra", true),
            ("https://api.openai.com/v1/responses", "gpt-5", false),
            ("https://relay.invalid/v1/responses", "gpt-5.4", false),
            ("http://127.0.0.1:1234/v1/responses", "gpt-5.4", false)
        ] {
            let (p, id) = provider(endpoint: endpoint, model: model)
            defer { CompatibilityProtocol.remove(id) }
            var config = LLMConfig.default
            let legacy = try object(try #require(p.buildChatRequest(messages: [], tools: [], config: config, stream: true).httpBody))
            #expect(legacy["context_management"] == nil)
            config.nativeCompactionThreshold = 12_000
            let body = try object(try #require(p.buildChatRequest(messages: [], tools: [], config: config, stream: true).httpBody))
            #expect((body["context_management"] != nil) == expected)
            #expect(body["store"] as? Bool == false)
            if expected { #expect((body["context_management"] as? [[String: Any]])?.first?["compact_threshold"] as? Int == 12_000) }
        }
        #expect(ModelParameterPreferences().resolved(mode: .coding, capabilities: nil).config.nativeCompactionThreshold != nil)
        #expect(ModelParameterPreferences().resolved(mode: .chat, capabilities: nil).config.nativeCompactionThreshold == nil)
        #expect(ModelParameterPreferences(nativeCompactionEnabled: false).resolved(mode: .coding, capabilities: nil).config.nativeCompactionThreshold == nil)
        let legacy = try JSONDecoder().decode(LLMConfig.self, from: Data(#"{"modelName":"","maxTokens":2048,"temperature":0.7}"#.utf8))
        #expect(legacy.nativeCompactionThreshold == nil && legacy.requestToolChoiceNone == nil)
    }

    @Test("Pruning preserves canonical order, constraints, call pairing and legacy user data")
    func canonicalWindow() throws {
        let raw = #"[{"type":"reasoning","encrypted_content":"prior"},{"type":"compaction","encrypted_content":"opaque"},{"type":"function_call","call_id":"c","name":"probe","arguments":"{}"}]"#
        let canonical = EngineMessage(role: .assistant, text: "", toolCalls: [.init(id: "c", name: "probe", argumentsJSON: "{}")],
            continuation: .init(responsesItemsJSON: raw))
        let input: [EngineMessage] = [.init(role: .system, text: "Rules"), .init(role: .user, text: "Old request"),
            .init(role: .assistant, text: "Old plan"), .init(role: .user, text: "Current constraint"), canonical,
            .init(role: .toolResult, text: "Evidence", toolCallId: "c")]
        let result = try #require(ResponsesContextWindow.prune(input, pinnedUserDigest: ResponsesContextWindow.digest("Current constraint")))
        #expect(result.map(\.text) == ["Rules", "Current constraint", "", "Evidence"])
        #expect(result[2].continuation?.responsesItemsJSON == raw)
        #expect(result[2].toolCalls.first?.id == result[3].toolCallId)
        #expect(ResponsesContextWindow.prune(result, pinnedUserDigest: ResponsesContextWindow.digest("Current constraint")) == nil)
        #expect(ResponsesContextWindow.prune(input, pinnedUserDigest: nil)?.filter { $0.role == .user }.count == 2)
        var reasoningOnly = input
        reasoningOnly[4].continuation = .init(responsesItemsJSON: #"[{"type":"reasoning","encrypted_content":"opaque"}]"#)
        #expect(ResponsesContextWindow.prune(reasoningOnly, pinnedUserDigest: nil) == nil)
    }

    @Test("Server compaction prunes old evidence, preserves opaque output, and never resets accounting on restore")
    func engineWindowAndRestore() async throws {
        let canonical: [[String: Any]] = [["type": "compaction", "encrypted_content": "opaque-compaction-state"],
            ["type": "function_call", "call_id": "current", "name": "probe", "arguments": "{}", "status": "completed"]]
        let (p, id) = provider(replies: [try response(canonical), try response([message("Done")]), try response([message("Resumed")])])
        defer { CompatibilityProtocol.remove(id) }
        var config = LLMConfig.default; config.nativeCompactionThreshold = 20_000
        let engine = DispatcherEngine(provider: p, tools: [Probe()], systemPrompt: "Keep permissions", config: config, contextTokenBudget: 8_000)
        _ = try await engine.run(userMessage: "Keep acceptance constraints", history: [
            .init(role: .user, text: "Obsolete request"), .init(role: .assistant, text: "Obsolete plan"),
            .init(role: .assistant, text: "", toolCalls: [.init(id: "old", name: "probe", argumentsJSON: "{}")]),
            .init(role: .toolResult, text: "Obsolete evidence", toolCallId: "old")])
        let requests = try CompatibilityProtocol.requests(id).map { try object($0.body) }
        #expect(requests.count == 2)
        #expect((requests.first?["context_management"] as? [[String: Any]])?.first?["compact_threshold"] as? Int == 4_000)
        let second = try #require(requests.last?["input"] as? [[String: Any]])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: second), as: UTF8.self)
        #expect(!encoded.contains("Obsolete"))
        #expect(encoded.contains("Keep permissions") && encoded.contains("Keep acceptance constraints"))
        let blob = try #require(second.first { $0["type"] as? String == "compaction" })
        #expect(blob["encrypted_content"] as? String == "opaque-compaction-state")
        #expect(second.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "current" })
        #expect(try JSONSerialization.data(withJSONObject: Array(second.filter { ["compaction", "function_call"].contains($0["type"] as? String ?? "") }), options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]))
        let snapshot = try JSONDecoder().decode(EngineRunSnapshot.self, from: JSONEncoder().encode(engine.takeSnapshot()))
        #expect(snapshot.totalTokens == 26 && snapshot.contextReport?.nativeCompactions == 1)
        #expect(snapshot.pinnedUserDigest != nil && snapshot.signedToolFace != nil)
        let resumed = DispatcherEngine(provider: p, tools: [Probe()], systemPrompt: "Keep permissions", config: config, contextTokenBudget: 8_000)
        _ = try await resumed.run(fromSnapshot: snapshot)
        #expect(resumed.takeSnapshot().totalTokens == 39)
        #expect(resumed.takeSnapshot().stepsUsed > snapshot.stepsUsed)
        #expect(resumed.requestReport.nativeCompactions == 1)
    }

    @Test("Truncated signed answers replay each canonical output once while disabling tools")
    func continuationReplay() async throws {
        let (p, id) = provider(replies: try ["Part one", " and two", " and three"].enumerated().map { index, text in
            try response([["type": "reasoning", "encrypted_content": "opaque-\(index)"], message(text)], truncated: index < 2)
        })
        defer { CompatibilityProtocol.remove(id) }
        let engine = DispatcherEngine(provider: p, tools: [Probe()], systemPrompt: "Rules")
        _ = try await engine.run(userMessage: "Answer", history: [])
        let requests = try CompatibilityProtocol.requests(id).map { try object($0.body) }
        #expect(requests.count == 3)
        #expect(requests.dropFirst().allSatisfy { $0["tool_choice"] as? String == "none" && $0["tools"] != nil })
        let input = try #require(requests.last?["input"] as? [[String: Any]])
        #expect(input.filter { $0["type"] as? String == "reasoning" }.count == 2)
        let messages = input.filter { $0["type"] as? String == "message" }
        #expect(messages.count == 2)
        #expect((messages.last?["content"] as? [[String: Any]])?.first?["text"] as? String == " and two")
        #expect(engine.takeSnapshot().totalTokens == 39)
    }

    @Test("A malformed opaque compaction item fails closed")
    func malformedCompaction() async throws {
        let (p, id) = provider(replies: [try response([["type": "compaction"]])])
        defer { CompatibilityProtocol.remove(id) }
        await #expect(throws: LLMError.self) { try await p.chatStream(messages: [], tools: [], config: .default, onDelta: { _ in }) }
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }
}
