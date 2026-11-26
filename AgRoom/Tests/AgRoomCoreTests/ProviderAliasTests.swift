import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Provider aliases")
struct ProviderAliasTests {
    private func config(alias: String = "") -> LLMProviderConfig {
        LLMProviderConfig(name: "Fixture provider", endpoint: "https://provider-alias.invalid/v1/chat/completions",
                          model: "raw-model-v9", alias: alias)
    }

    @Test("Aliases use complete characters, stay within 20 characters and take precedence in chat labels")
    func limitsAndDisplay() {
        for character in ["a", "深", "👨‍👩‍👧‍👦", "e\u{301}"] {
            let expected = String(repeating: character, count: LLMProviderConfig.maxAliasLength)
            var provider = config(alias: expected + character)
            #expect(provider.alias == expected && provider.alias.count == 20)
            #expect(provider.chatDisplayName == expected && provider.model == "raw-model-v9")
            provider.alias = expected + character
            #expect(provider.alias == expected)
        }
        var provider = config(alias: "  快速\n模型  ")
        #expect(provider.alias == "快速 模型" && provider.chatDisplayName == "快速 模型")
        provider.alias = " \n\t "
        #expect(provider.alias.isEmpty && provider.chatDisplayName == "Fixture provider · raw-model-v9")
        provider.model = ""
        #expect(provider.chatDisplayName == provider.name)
    }

    @Test("Legacy JSON defaults to no alias, and decoding enforces the same character limit")
    func jsonCompatibility() throws {
        let original = config(alias: "My model")
        #expect(try JSONDecoder().decode(LLMProviderConfig.self, from: JSONEncoder().encode(original)) == original)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "alias")
        let legacy = try JSONDecoder().decode(LLMProviderConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.alias.isEmpty && legacy.id == original.id && legacy.createdAt == original.createdAt)
        object["alias"] = String(repeating: "🧑🏽‍💻", count: 21)
        let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.alias == String(repeating: "🧑🏽‍💻", count: 20) && decoded.model == original.model)
    }

    @Test("The global migration preserves existing providers; aliases survive reopen and can be cleared")
    func migrationAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-alias-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("global.sqlite").path
        let database = try DatabaseQueue(path: path)
        let original = config()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_llm_providers") { db in
            try db.execute(sql: """
                CREATE TABLE llm_providers (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, endpoint TEXT NOT NULL,
                    model TEXT NOT NULL DEFAULT '', isEnabled BOOLEAN NOT NULL DEFAULT 1, createdAt DATETIME NOT NULL
                )
                """)
        }
        try migrator.migrate(database)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO llm_providers(id,name,endpoint,model,isEnabled,createdAt) VALUES(?,?,?,?,?,?)",
                arguments: [original.id.uuidString, original.name, original.endpoint, original.model, original.isEnabled, original.createdAt])
        }
        try DatabaseBootstrap.prepareGlobal(database)
        try DatabaseBootstrap.prepareGlobal(database)
        let service = ProviderConfigService(databaseQueue: database)
        var saved = try #require(try await service.getAll().first)
        #expect(saved.alias.isEmpty && saved.id == original.id && saved.model == original.model)
        let createdAt = saved.createdAt
        saved.alias = "研究用模型"; saved.isEnabled = false
        try await service.save(saved, apiKey: nil)
        let reopened = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareGlobal(reopened)
        let restored = try #require(try await ProviderConfigService(databaseQueue: reopened).getAll().first)
        #expect(restored == saved && restored.createdAt == createdAt && restored.chatDisplayName == "研究用模型")
        saved.alias = ""
        try await service.save(saved, apiKey: nil)
        let cleared = try #require(try await ProviderConfigService(databaseQueue: reopened).getAll().first)
        #expect(cleared.alias.isEmpty && cleared.chatDisplayName == "Fixture provider · raw-model-v9")
    }

    @Test("Provider aliases never replace the actual model in ordinary or streaming requests")
    func actualModelRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AliasModelProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = CloudProvider(config: config(alias: "Friendly display name"), apiKey: "synthetic", session: session)
        #expect(try await provider.generate(prompt: "Synthetic") == "Synthetic answer")
        let reply = try await provider.chatStream(messages: [.init(role: .user, text: "Synthetic")], tools: [], config: .default) { _ in }
        #expect(reply.text == "Synthetic answer")
    }
}

private final class AliasModelProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "provider-alias.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        #expect(object["model"] as? String == "raw-model-v9")
        #expect(object["alias"] == nil)
        let streaming = object["stream"] as? Bool == true
        let body = streaming
            ? "data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            : #"{"choices":[{"message":{"content":"Synthetic answer"},"finish_reason":"stop"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
