import CryptoKit
import Foundation

/// Provider-generated compaction is opaque. Keep the complete canonical output message,
/// including all calls, so results after that message remain strictly paired.
enum ResponsesContextWindow {
    static func containsCompaction(_ continuation: EngineContinuation?) -> Bool {
        guard let raw = continuation?.responsesItemsJSON,
              let items = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return false }
        return items.contains {
            $0["type"] as? String == "compaction" && !($0["encrypted_content"] as? String ?? "").isEmpty
        }
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func prune(_ messages: [EngineMessage], pinnedUserDigest: String?) -> [EngineMessage]? {
        guard let boundary = messages.lastIndex(where: { $0.role == .assistant && containsCompaction($0.continuation) }), boundary > 0 else { return nil }
        let prefix = messages[..<boundary]
        let rules = prefix.filter { $0.role == .system }
        let userMessages: [EngineMessage]
        if let pinnedUserDigest, let request = prefix.last(where: { $0.role == .user && digest($0.text) == pinnedUserDigest }) {
            userMessages = [request]
        } else {
            // Legacy snapshots did not identify the current request. Preserve all user data.
            userMessages = prefix.filter { $0.role == .user }
        }
        guard rules.count + userMessages.count < prefix.count else { return nil }
        return rules + userMessages + Array(messages[boundary...])
    }
}

extension CloudProvider {
    func nativeCompactionThreshold(_ config: LLMConfig) -> Int? {
        guard let threshold = config.nativeCompactionThreshold, threshold >= 1_000,
              let url = URL(string: endpoint), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.openai.com", url.port == nil || url.port == 443,
              wireProtocol(for: config) == .responses else { return nil }
        if config.modelCapabilities?.supportedParameters?.contains("context_management") == true { return threshold }
        let model = requestModel(config).lowercased()
        let parts = model.split(separator: "-")
        guard parts.first == "gpt", parts.count > 1 else { return nil }
        let version = parts[1].split(separator: ".")
        guard let major = version.first.flatMap({ Int($0) }) else { return nil }
        if major >= 6 { return threshold }
        if major == 5, version.count > 1, let minor = Int(version[1]),
           minor >= 4 || (minor == 3 && model.hasPrefix("gpt-5.3-codex")) { return threshold }
        return nil
    }
}
