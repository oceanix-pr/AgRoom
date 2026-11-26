import Foundation

/// Transient import draft. Tokens are passed directly to the editor and only saved to Keychain.
public struct MCPImportedConnection: Identifiable, Sendable {
    public let config: MCPServerConfig
    public let token: String
    public var id: UUID { config.id }
}

public enum MCPConnectionImport {
    public static func parse(_ text: String) throws -> [MCPImportedConnection] {
        guard text.utf8.count <= 128 * 1024 else { throw MCPError(.importInvalid) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("https://") || trimmed.lowercased().hasPrefix("http://") {
            return [try connection(name: URLComponents(string: trimmed)?.host ?? "MCP", value: ["url": trimmed])]
        }
        guard let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw MCPError(.importInvalid) }
        if let servers = root["mcpServers"] as? [String: Any] {
            guard !servers.isEmpty, servers.count <= MCPServerConfig.maximumServers else { throw MCPError(.invalidConfiguration) }
            return try servers.keys.sorted().map { name in
                guard let value = servers[name] as? [String: Any] else { throw MCPError(.importInvalid) }
                return try connection(name: name, value: value)
            }
        }
        guard let url = root["url"] as? String else { throw MCPError(.importInvalid) }
        return [try connection(name: root["name"] as? String ?? URLComponents(string: url)?.host ?? "MCP", value: root)]
    }

    private static func connection(name: String, value: [String: Any]) throws -> MCPImportedConnection {
        guard Set(value.keys).isSubset(of: ["name", "url", "type", "headers"]) else { throw MCPError(.importUnsupported) }
        if let transport = value["type"] {
            guard let transport = transport as? String, ["http", "streamable-http", "streamableHttp"].contains(transport) else {
                throw MCPError(.importUnsupported)
            }
        }
        guard let endpoint = value["url"] as? String else { throw MCPError(.importInvalid) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MCPError(.importInvalid) }
        var token = ""
        if let headersValue = value["headers"] {
            guard let headers = headersValue as? [String: String], headers.count <= 1,
                  headers.keys.allSatisfy({ $0.lowercased() == "authorization" }) else { throw MCPError(.importUnsupported) }
            if let authorization = headers.values.first {
                guard authorization.lowercased().hasPrefix("bearer ") else { throw MCPError(.importUnsupported) }
                token = String(authorization.dropFirst(7))
                guard !token.isEmpty, token.utf8.count <= 8192,
                      token.utf8.allSatisfy({ (33...126).contains($0) }), !token.contains("${") else { throw MCPError(.importInvalid) }
            }
        }
        let config = MCPServerConfig(name: name, endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                     authentication: token.isEmpty ? .none : .bearer)
        _ = try config.validatedEndpoint()
        return MCPImportedConnection(config: config, token: token)
    }
}
