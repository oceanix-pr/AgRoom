import Foundation
import CoreFoundation
import GRDB

/// Only global provider metadata/preferences live here. The immutable queue serializes storage;
/// network work and callbacks never execute inside a lock or database transaction.
public final class ModelParameterService: @unchecked Sendable {
    public enum ParameterError: Error, Sendable { case invalidPreferences, providerChanged, invalidMetadata }
    public struct Snapshot: Equatable, Sendable {
        public var preferences: ModelParameterPreferences
        public var capabilities: ModelCapabilities?
    }
    private let queue: DatabaseQueue
    private let fetch: @Sendable (URLRequest) async throws -> Data
    static let maximumBytes = 16 * 1024 * 1024
    public static let didChange = Notification.Name("agroom.modelParameters.changed")
    private static let sharedPreferenceKey = "automatic"

    public init(databaseQueue: DatabaseQueue) {
        queue = databaseQueue
        fetch = Self.fetchMetadata
    }

    init(databaseQueue: DatabaseQueue, fetch: @escaping @Sendable (URLRequest) async throws -> Data) {
        queue = databaseQueue; self.fetch = fetch
    }

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS model_parameter_preferences (
              providerID TEXT NOT NULL REFERENCES llm_providers(id) ON DELETE CASCADE,
              endpoint TEXT NOT NULL, model TEXT NOT NULL, mode TEXT NOT NULL, payload BLOB NOT NULL,
              PRIMARY KEY(providerID, endpoint, model, mode));
            CREATE TABLE IF NOT EXISTS model_capabilities (
              providerID TEXT NOT NULL REFERENCES llm_providers(id) ON DELETE CASCADE,
              endpoint TEXT NOT NULL, model TEXT NOT NULL, payload BLOB, attemptedAt DOUBLE NOT NULL,
              PRIMARY KEY(providerID, endpoint, model));
            """)
    }

    public static func endpointIdentity(_ provider: LLMProviderConfig) -> String {
        CloudProvider.normalizedEndpoint(provider.endpoint)
    }

    public func load(provider: LLMProviderConfig, mode: ChatMode) async throws -> Snapshot {
        let endpoint = Self.endpointIdentity(provider)
        return try await queue.read { db in
            let preferences = try Self.preferenceData(provider: provider, endpoint: endpoint, db: db)
            let capabilities = try Data.fetchOne(db, sql: "SELECT payload FROM model_capabilities WHERE providerID=? AND endpoint=? AND model=?",
                arguments: [provider.id.uuidString, endpoint, provider.model])
            return Snapshot(preferences: try preferences.map { try JSONDecoder().decode(ModelParameterPreferences.self, from: $0) } ?? .init(),
                capabilities: try capabilities.map { try JSONDecoder().decode(ModelCapabilities.self, from: $0) })
        }
    }

    public func save(_ preferences: ModelParameterPreferences, provider: LLMProviderConfig, mode: ChatMode) async throws {
        guard preferences.isValid else { throw ParameterError.invalidPreferences }
        let data = try JSONEncoder().encode(preferences), endpoint = Self.endpointIdentity(provider)
        try await queue.write { db in
            try Self.requireCurrent(provider, db: db)
            try db.execute(sql: "INSERT INTO model_parameter_preferences(providerID,endpoint,model,mode,payload) VALUES(?,?,?,?,?) ON CONFLICT(providerID,endpoint,model,mode) DO UPDATE SET payload=excluded.payload",
                arguments: [provider.id.uuidString, endpoint, provider.model, Self.sharedPreferenceKey, data])
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func resolve(provider: LLMProviderConfig, mode: ChatMode, refreshIfNeeded: Bool = false) async throws -> ResolvedModelParameters {
        if refreshIfNeeded {
            do { _ = try await refresh(provider: provider) }
            catch is CancellationError { throw CancellationError() }
            catch { HubLogger.shared.debug("Model metadata unavailable; retaining cached limits") }
        }
        let snapshot = try await load(provider: provider, mode: mode)
        var result = snapshot.preferences.resolved(mode: mode, capabilities: snapshot.capabilities, provider: provider)
        result.config.modelName = provider.model
        result.providerID = provider.id; result.endpoint = Self.endpointIdentity(provider)
        return result
    }

    public func setReasoningEffort(_ effort: ReasoningEffort, provider: LLMProviderConfig, mode: ChatMode) async throws {
        let endpoint = Self.endpointIdentity(provider)
        try await queue.write { db in
            try Self.requireCurrent(provider, db: db)
            let data = try Self.preferenceData(provider: provider, endpoint: endpoint, db: db)
            var preferences = try data.map { try JSONDecoder().decode(ModelParameterPreferences.self, from: $0) } ?? .init()
            preferences.reasoningEffort = effort == .standard ? nil : effort
            let updated = try JSONEncoder().encode(preferences)
            try db.execute(sql: "INSERT INTO model_parameter_preferences(providerID,endpoint,model,mode,payload) VALUES(?,?,?,?,?) ON CONFLICT(providerID,endpoint,model,mode) DO UPDATE SET payload=excluded.payload",
                arguments: [provider.id.uuidString, endpoint, provider.model, Self.sharedPreferenceKey, updated])
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// One preference set per model. Deterministically retain legacy chat values, or coding
    /// values when no chat row exists. Old rows remain available for rollback; frozen runs
    /// carry their resolved parameters instead of rereading preferences.
    private static func preferenceData(provider: LLMProviderConfig, endpoint: String, db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: """
            SELECT payload FROM model_parameter_preferences
            WHERE providerID=? AND endpoint=? AND model=? AND mode IN ('automatic','chat','coding')
            ORDER BY CASE mode WHEN 'automatic' THEN 0 WHEN 'chat' THEN 1 ELSE 2 END LIMIT 1
            """, arguments: [provider.id.uuidString, endpoint, provider.model])
    }

    /// Refresh metadata only; never invokes inference or rewrites user preferences.
    @discardableResult public func refresh(provider: LLMProviderConfig, force: Bool = false, at date: Date = Date()) async throws -> ModelCapabilities? {
        let endpoint = Self.endpointIdentity(provider)
        let existing = try await load(provider: provider, mode: .chat).capabilities
        if !force, let existing, date.timeIntervalSince(existing.fetchedAt) < 86_400 { return existing }
        let shouldFetch = try await queue.write { db in
            try Self.requireCurrent(provider, db: db)
            let attempted = try Double.fetchOne(db, sql: "SELECT attemptedAt FROM model_capabilities WHERE providerID=? AND endpoint=? AND model=?",
                arguments: [provider.id.uuidString, endpoint, provider.model])
            if !force, let attempted, date.timeIntervalSince1970 - attempted < 900 { return false }
            try db.execute(sql: "INSERT INTO model_capabilities(providerID,endpoint,model,attemptedAt) VALUES(?,?,?,?) ON CONFLICT(providerID,endpoint,model) DO UPDATE SET attemptedAt=excluded.attemptedAt",
                arguments: [provider.id.uuidString, endpoint, provider.model, date.timeIntervalSince1970])
            return true
        }
        guard shouldFetch else { return existing }
        try Task.checkCancellation()
        let base = ModelPricingService.endpointBase(provider.endpoint)
        var capability: ModelCapabilities?
        var primaryError: (any Error)?
        do {
            let request = try Self.metadataRequest(provider: provider)
            let data = try await fetch(request)
            guard data.count <= Self.maximumBytes else { throw LLMError.responseTooLarge }
            capability = try Self.parse(data, model: provider.model,
                openRouter: base == "https://openrouter.ai/api/v1", at: date)
        } catch is CancellationError { throw CancellationError() }
        catch { primaryError = error }
        if let base, base != "https://openrouter.ai/api/v1",
           capability?.contextTokens == nil || capability?.outputTokens == nil || capability?.supportsTemperature == nil {
            do {
                let data = try await fetch(URLRequest(url: URL(string: "https://models.dev/api.json")!))
                guard data.count <= Self.maximumBytes else { throw LLMError.responseTooLarge }
                if let reference = try Self.parseCatalog(data, provider: provider, at: date) {
                    capability = capability.map { $0.fillingUnknown(with: reference) } ?? reference
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if primaryError == nil { primaryError = error } }
        }
        try Task.checkCancellation()
        guard let capability else {
            if let primaryError { throw primaryError }
            // A successful model list with no capability fields is explicitly unknown.
            return existing
        }
        let data = try JSONEncoder().encode(capability)
        try await queue.write { db in
            try Self.requireCurrent(provider, db: db)
            try db.execute(sql: "UPDATE model_capabilities SET payload=? WHERE providerID=? AND endpoint=? AND model=?",
                arguments: [data, provider.id.uuidString, endpoint, provider.model])
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return capability
    }

    private static func requireCurrent(_ provider: LLMProviderConfig, db: Database) throws {
        guard let endpoint = try String.fetchOne(db, sql: "SELECT endpoint FROM llm_providers WHERE id=?", arguments: [provider.id.uuidString]),
              CloudProvider.normalizedEndpoint(endpoint) == endpointIdentity(provider) else { throw ParameterError.providerChanged }
    }

    static func metadataRequest(provider: LLMProviderConfig) throws -> URLRequest {
        try EndpointSafety.validate(provider.endpoint)
        let url: URL
        if ModelPricingService.endpointBase(provider.endpoint) == "https://openrouter.ai/api/v1" {
            let components = provider.model.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ParameterError.invalidMetadata }
            var value = URL(string: "https://openrouter.ai/api/v1/models")!
            for component in components { value.appendPathComponent(String(component)) }
            value.appendPathComponent("endpoints"); url = value
        } else {
            url = try CloudProvider.modelsURL(for: endpointIdentity(provider), isAnthropic: provider.isAnthropic)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only the configured endpoint receives its own credential; public catalogs never do.
        if ModelPricingService.endpointBase(provider.endpoint) != "https://openrouter.ai/api/v1",
           let key = KeychainService.loadAPIKey(for: provider.id), !key.isEmpty {
            request.setValue(provider.isAnthropic ? key : "Bearer \(key)", forHTTPHeaderField: provider.isAnthropic ? "x-api-key" : "Authorization")
        }
        if provider.isAnthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        return request
    }

    private static func fetchMetadata(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ModelMetadataRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw ParameterError.invalidMetadata }
        guard response.expectedContentLength <= maximumBytes else { throw LLMError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw LLMError.responseTooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return data
    }

    static func parse(_ data: Data, model: String, openRouter: Bool, at date: Date) throws -> ModelCapabilities? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParameterError.invalidMetadata }
        if openRouter {
            guard let item = root["data"] as? [String: Any], item["id"] as? String == model,
                  let endpoints = item["endpoints"] as? [[String: Any]] else { throw ParameterError.invalidMetadata }
            let active = endpoints.filter { ($0["status"] as? Int ?? 0) == 0 }
            guard !active.isEmpty else { return nil }
            let entries = active.map { parseItem($0, source: .openRouter, at: date) }
            // Automatic routing may pick any active endpoint. Do not present a union's maximum as safe.
            var result = ModelCapabilities(conservativeRouting: true, source: .openRouter, fetchedAt: date)
            if entries.allSatisfy({ $0.contextTokens != nil }) { result.contextTokens = entries.compactMap(\.contextTokens).min() }
            if entries.allSatisfy({ $0.outputTokens != nil }) { result.outputTokens = entries.compactMap(\.outputTokens).min() }
            if entries.allSatisfy({ $0.supportsTemperature != nil }) { result.supportsTemperature = entries.allSatisfy { $0.supportsTemperature == true } }
            if entries.allSatisfy({ $0.supportsReasoning != nil }) { result.supportsReasoning = entries.allSatisfy { $0.supportsReasoning == true } }
            if entries.allSatisfy({ $0.supportedParameters != nil }) {
                result.supportedParameters = entries.dropFirst().reduce(Set(entries[0].supportedParameters ?? [])) { $0.intersection($1.supportedParameters ?? []) }.sorted()
            }
            return result
        }
        guard let items = root["data"] as? [[String: Any]] else { throw ParameterError.invalidMetadata }
        guard let item = items.first(where: { $0["id"] as? String == model }) else { return nil }
        return parseItem(item, source: .provider, at: date)
    }

    private static func parseItem(_ item: [String: Any], source: ModelCapabilities.Source, at date: Date) -> ModelCapabilities {
        let limits = item["limit"] as? [String: Any] ?? [:]
        let parameters = item["supported_parameters"] as? [String]
        let efforts = item["effort"] as? [String: Any]
        let reasoning = item["reasoning"] as? [String: Any]
        let temperature = item["temperature"] as? [String: Any]
        var result = ModelCapabilities(
            contextTokens: [item["max_model_len"], item["context_window"], item["context_length"], item["max_input_tokens"], limits["context"]].compactMap(count).min(),
            outputTokens: count(item["max_output_tokens"] ?? item["max_completion_tokens"] ?? item["max_tokens"] ?? limits["output"]),
            supportsTemperature: (item["temperature"] as? Bool) ?? parameters.map { $0.contains("temperature") },
            temperatureMinimum: number(temperature?["min"]), temperatureMaximum: number(temperature?["max"]),
            supportsReasoning: (item["reasoning"] as? Bool) ?? (efforts != nil ? true : parameters.map {
                !Set($0).isDisjoint(with: ["reasoning", "reasoning_effort", "thinking", "enable_thinking", "chat_template_kwargs"])
            }),
            reasoningEfforts: cleanEfforts((efforts?["supported_levels"] as? [String]) ?? (reasoning?["supported_efforts"] as? [String])),
            supportsReasoningBudget: reasoning?["supports_max_tokens"] as? Bool, supportedParameters: parameters,
            source: source, fetchedAt: date)
        result.inputModalities = item["input_modalities"] as? [String] ?? (item["modalities"] as? [String: Any])?["input"] as? [String]
        let owner = (item["owned_by"] as? String)?.lowercased() ?? ""
        if source == .provider, ["vllm", "sglang"].contains(owner) || parameters?.contains("chat_template_kwargs") == true {
            result.supportsChatTemplate = true
        }
        return result
    }

    static func parseCatalog(_ data: Data, provider: LLMProviderConfig, at date: Date) throws -> ModelCapabilities? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = ModelPricingService.endpointBase(provider.endpoint),
              let entry = ModelPricingService.catalogProvider(in: root, base: base),
              let models = entry["models"] as? [String: Any], let item = models[provider.model] as? [String: Any] else { return nil }
        let result = parseItem(item, source: .modelsDev, at: date)
        return result.hasLimits ? result : nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func cleanEfforts(_ values: [String]?) -> [String]? {
        values.map { values in Array(values.prefix(16)).filter {
            !$0.isEmpty && $0.utf8.count <= 32 && $0.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }
        } }
    }
    private static func count(_ value: Any?) -> Int? {
        guard let value = number(value), value > 0, value <= 10_000_000, value.rounded() == value else { return nil }
        return Int(value)
    }
}

private final class ModelMetadataRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url, next = request.url
        let allowed = original?.scheme == next?.scheme && original?.host == next?.host && original?.port == next?.port
        completionHandler(allowed ? request : nil)
    }
}
