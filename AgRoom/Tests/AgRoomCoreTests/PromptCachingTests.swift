import Foundation
import Testing
@testable import AgRoomCore

@Suite("Prompt caching and bounded context")
struct PromptCachingTests {
    private func body(endpoint: String, model: String, policy: PromptCachePolicy? = .automatic,
                      space: AppSpace? = .work) throws -> [String: Any] {
        let provider = CloudProvider(config: .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Fixture", endpoint: endpoint, model: model), apiKey: "fixture")
        var config = LLMConfig(modelName: model)
        config.promptCachePolicy = policy
        return try ProviderRequestContext.$current.withValue(.init(space: space)) {
            let request = try provider.buildChatRequest(messages: [.init(role: .system, text: "stable rules"),
                .init(role: .system, text: "project context"), .init(role: .user, text: "private task")],
                tools: [], config: config, stream: false)
            let data = try #require(request.httpBody)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    @Test("Cache fields follow official endpoint and model capabilities without changing privacy mode")
    func officialEndpointPolicies() throws {
        let modern = try body(endpoint: "https://api.openai.com/v1/responses", model: "gpt-5.6")
        #expect((modern["prompt_cache_options"] as? [String: String]) == ["mode": "implicit", "ttl": "30m"])
        #expect(modern["store"] as? Bool == false)
        let input = try #require(modern["input"] as? [[String: Any]])
        #expect(input[0]["role"] as? String == "developer")
        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content[0]["prompt_cache_breakpoint"] is [String: Any])
        #expect((input.last?["content"] as? [[String: Any]])?.first?["prompt_cache_breakpoint"] == nil)
        let legacy = try body(endpoint: "https://api.openai.com/v1/responses", model: "gpt-5.4")
        #expect(legacy["prompt_cache_options"] == nil)
        #expect(legacy["prompt_cache_key"] != nil)
        let otherSpace = try body(endpoint: "https://api.openai.com/v1/responses", model: "gpt-5.6", space: .personal)
        #expect(modern["prompt_cache_key"] as? String != otherSpace["prompt_cache_key"] as? String)
        let claude = try body(endpoint: "https://api.anthropic.com/v1/messages", model: "claude-sonnet-4-6")
        #expect((claude["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        #expect(claude["prompt_cache_options"] == nil)
    }

    @Test("Provider default, old snapshots, unknown spaces and relays receive no new cache controls")
    func conservativeCachePolicy() throws {
        for endpoint in ["https://relay.invalid/v1/responses", "https://relay.invalid/v1/messages", "http://localhost/v1/chat/completions"] {
            let result = try body(endpoint: endpoint, model: "gpt-5.6")
            #expect(result["prompt_cache_options"] == nil && result["cache_control"] == nil && result["prompt_cache_key"] == nil)
        }
        let policies: [PromptCachePolicy?] = [nil, .providerDefault]
        for policy in policies {
            let result = try body(endpoint: "https://api.openai.com/v1/responses", model: "gpt-5.6", policy: policy)
            #expect(result["prompt_cache_options"] == nil && result["prompt_cache_key"] == nil)
        }
        #expect(try body(endpoint: "https://api.openai.com/v1/responses", model: "gpt-5.6", space: nil)["prompt_cache_options"] == nil)
        #expect(ModelParameterPreferences().resolved(mode: .coding, capabilities: nil).config.promptCachePolicy == .automatic)
        #expect(ModelParameterPreferences().resolved(mode: .chat, capabilities: nil).config.promptCachePolicy == .providerDefault)
        let old = try JSONDecoder().decode(ModelParameterPreferences.self, from: Data("{}".utf8))
        #expect(old.promptCachePolicy == nil)
    }

    @Test("Relevant memory and preferred skills fit independent budgets and omit disabled entries")
    func boundedSelection() {
        let relevant = MemoryItem(content: "Swift 严格并发项目使用 actor 管理状态", category: .decision)
        let preference = MemoryItem(content: "优先给出中文说明", category: .preference)
        let unrelated = MemoryItem(content: "holiday " + String(repeating: "x", count: 50_000), category: .fact)
        let disabled = MemoryItem(content: "Swift 并发 hidden", isEnabled: false)
        let selected = PromptContextSelection.memories([unrelated, disabled, relevant, preference], query: "Swift 并发问题")
        #expect(Set(selected.map(\.id)) == [relevant.id, preference.id])
        #expect(selected.reduce(0) { $0 + TokenEstimator.estimate($1.content) + 12 } <= 1_200)
        var skills = (0..<200).map { Skill(name: "fixture-\($0)", description: String(repeating: "description ", count: 100)) }
        skills.append(Skill(name: "swift-project", alias: "Swift 编程", description: "Swift concurrency"))
        skills.append(Skill(name: "unavailable", description: "Swift", isEnabled: false))
        let chosen = PromptContextSelection.skills(skills, query: "Swift", preferred: ["swift-project"])
        #expect(chosen.first?.name == "swift-project")
        #expect(chosen.count <= 8 && !chosen.contains { $0.name == "unavailable" })
        #expect(chosen.reduce(0) { $0 + TokenEstimator.estimate($1.name + $1.alias + $1.description) + 12 } <= 900)
    }

    @Test("Separating project context does not misclassify history or double-count opaque output")
    func contextBreakdown() {
        let messages: [EngineMessage] = [.init(role: .system, text: "static rules"), .init(role: .system, text: "project rules"),
            .init(role: .user, text: "historical input"), .init(role: .user, text: "current input"),
            .init(role: .assistant, text: "do not count visible twice", continuation: .init(responsesItemsJSON: "[]"))]
        let breakdown = TokenEstimator.breakdown(messages: messages, tools: [], historyMessageCount: 1)
        #expect(breakdown.history == TokenEstimator.estimate("historical input"))
        #expect(breakdown.conversation == TokenEstimator.estimate("current input"))
        #expect(breakdown.total == TokenEstimator.estimate(messages: messages))
    }
}
