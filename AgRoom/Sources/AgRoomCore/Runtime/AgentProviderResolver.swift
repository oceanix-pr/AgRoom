import Foundation

public enum AgentModelError: Error, LocalizedError, Sendable {
    case providerUnavailable

    public var errorDescription: String? {
        "This agent's provider is unavailable. Enable it or choose another provider in Agents."
    }
}

/// Per-run configuration snapshot. Both delegation paths use the same routing;
/// credentials remain in Keychain and usage remains bound to the originating space.
public struct AgentProviderResolver: Sendable {
    private let configurations: [LLMProviderConfig]
    private let makeProvider: @Sendable (LLMProviderConfig, ProviderUsageRecorder?) -> CloudProvider

    public init(configurations: [LLMProviderConfig], parameterService: ModelParameterService? = nil) {
        self.init(configurations: configurations) { config, recorder in
            CloudProvider(config: config, apiKey: KeychainService.loadAPIKey(for: config.id) ?? "", usageRecorder: recorder, parameterService: parameterService)
        }
    }

    init(configurations: [LLMProviderConfig], makeProvider: @escaping @Sendable (LLMProviderConfig, ProviderUsageRecorder?) -> CloudProvider) {
        self.configurations = configurations
        self.makeProvider = makeProvider
    }

    public func resolve(_ agent: Agent, inheriting provider: CloudProvider) throws -> CloudProvider {
        guard let id = agent.providerID else { return provider }
        guard let config = configurations.first(where: { $0.id == id && $0.isEnabled }),
              !config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !agent.modelName.isEmpty else {
            throw AgentModelError.providerUnavailable
        }
        try EndpointSafety.validate(config.endpoint)
        return makeProvider(config, provider.usageRecorder).withParameterMode(provider.parameterMode)
    }

    static func resolve(_ agent: Agent, inheriting provider: CloudProvider, using resolver: Self?) throws -> CloudProvider {
        if let resolver { return try resolver.resolve(agent, inheriting: provider) }
        guard agent.providerID == nil else { throw AgentModelError.providerUnavailable }
        return provider
    }
}
