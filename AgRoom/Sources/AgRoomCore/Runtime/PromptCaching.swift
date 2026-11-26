import Foundation

/// Provider defaults remain available for workloads without reusable prefixes.
public enum PromptCachePolicy: String, Codable, Sendable, CaseIterable {
    case automatic
    case providerDefault
}

extension CloudProvider {
    private func optimizedCacheScope(_ config: LLMConfig) -> AppSpace? {
        guard config.promptCachePolicy == .automatic else { return nil }
        return ProviderRequestContext.current?.space
    }

    /// Official Responses API introduced explicit boundaries with GPT-5.6.
    /// Similar model names on gateways do not establish support for these fields.
    func usesExplicitCacheBoundaries(_ config: LLMConfig) -> Bool {
        guard optimizedCacheScope(config) != nil,
              URL(string: endpoint)?.host?.lowercased() == "api.openai.com",
              wireProtocol(for: config) == .responses else { return false }
        let components = requestModel(config).lowercased().split(separator: "-")
        guard components.first == "gpt", components.count > 1 else { return false }
        let version = components[1].split(separator: ".")
        guard let major = version.first.flatMap({ Int($0) }) else { return false }
        if major >= 6 { return true }
        return major == 5 && version.count > 1 && (Int(version[1]) ?? 0) >= 6
    }

    func applyPromptCaching(to body: inout [String: Any], config: LLMConfig) {
        guard let space = optimizedCacheScope(config),
              let url = URL(string: endpoint), url.scheme == "https" else { return }
        if url.host?.lowercased() == "api.openai.com", wireProtocol(for: config) == .responses {
            // Routing/accounting keys stay separate by space and contain no business data.
            body["prompt_cache_key"] = "agroom-coding-v1-\(space.rawValue)-\(providerID.uuidString)"
            if usesExplicitCacheBoundaries(config) {
                body["prompt_cache_options"] = ["mode": "implicit", "ttl": "30m"]
            }
        } else if url.host?.lowercased() == "api.anthropic.com", wireProtocol(for: config) == .anthropicMessages {
            body["cache_control"] = ["type": "ephemeral"]
        }
    }
}
