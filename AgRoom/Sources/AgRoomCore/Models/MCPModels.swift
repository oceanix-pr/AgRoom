import Foundation
import CryptoKit

/// Remote MCP metadata belongs to one space. Credentials are referenced, never serialized here.
public struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
    public enum Authentication: String, Codable, CaseIterable, Sendable {
        case none, bearer
    }

    public let id: UUID
    public var name: String
    public var endpoint: String
    public var authentication: Authentication
    public var isEnabled: Bool
    public var tools: [MCPToolDescriptor]
    public var selectedToolNames: Set<String>
    public var catalogProtocolVersion: String?
    public var rejectedToolCount: Int
    public internal(set) var revision: UUID
    internal var credentialID: UUID?

    public init(id: UUID = UUID(), name: String = "", endpoint: String = "",
                authentication: Authentication = .none, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.authentication = authentication
        self.isEnabled = isEnabled
        tools = []
        selectedToolNames = []
        rejectedToolCount = 0
        revision = UUID()
    }

    public static let maximumServers = 8
    public static let maximumSelectedTools = 32
    internal static let maximumSelectedDefinitionBytes = 32 * 1_024

    internal var selectedDefinitionBytes: Int {
        tools.filter { selectedToolNames.contains($0.name) }.reduce(0) {
            $0 + $1.name.utf8.count + $1.description.utf8.count + $1.inputSchemaJSON.utf8.count
        }
    }

    public func validatedEndpoint() throws -> URL {
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw MCPError(.invalidEndpoint) }
        do { try EndpointSafety.validate(address) }
        catch { throw MCPError(.invalidEndpoint) }
        return url
    }
}

public struct MCPToolDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              description.utf8.count <= 8_192, inputSchemaJSON.utf8.count <= 65_536,
              let schema = try MCPJSON.object(inputSchemaJSON) as? [String: Any],
              schema["type"] == nil || schema["type"] as? String == "object" else {
            throw MCPError(.invalidTool)
        }
        self.name = name
        self.description = description
        self.inputSchemaJSON = try MCPJSON.string(schema)
        _ = try headerBindings()
    }

    internal init(json: [String: Any]) throws {
        guard let name = json["name"] as? String,
              json["description"] == nil || json["description"] is String,
              let schema = json["inputSchema"] as? [String: Any] else { throw MCPError(.invalidTool) }
        try self.init(name: name, description: json["description"] as? String ?? "",
                      inputSchemaJSON: MCPJSON.string(schema))
    }

    /// Approval binds the exposed name, description and input schema, independent of JSON key order.
    public var fingerprint: String {
        MCPJSON.digest(name + "\u{0}" + description + "\u{0}" + inputSchemaJSON)
    }

    /// Independent of editable server labels and of the remote name's character set/length.
    public func dispatcherName(serverID: UUID) -> String {
        "mcp_" + serverID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + "_" + String(MCPJSON.digest(name).prefix(20))
    }

    internal struct HeaderBinding: Sendable {
        let name: String
        let path: [String]
        let type: String
    }

    /// Only statically reachable properties may be mirrored to MCP HTTP headers.
    internal func headerBindings() throws -> [HeaderBinding] {
        var bindings: [HeaderBinding] = []
        var names: Set<String> = []
        func walk(_ value: Any, path: [String]?, depth: Int) throws {
            guard depth <= 48 else { throw MCPError(.invalidTool) }
            if let array = value as? [Any] {
                for item in array { try walk(item, path: nil, depth: depth + 1) }
                return
            }
            guard let object = value as? [String: Any] else { return }
            if let annotation = object["x-mcp-header"] {
                guard let name = annotation as? String, !name.isEmpty, name.utf8.count <= 128,
                      name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                          || (97...122).contains($0) || $0 == 96 || "!#$%&'*+-.^_|~".utf8.contains($0) }),
                      let path, !path.isEmpty, let type = object["type"] as? String,
                      ["string", "integer", "boolean"].contains(type),
                      names.insert(name.lowercased()).inserted else { throw MCPError(.invalidTool) }
                bindings.append(HeaderBinding(name: name, path: path, type: type))
            }
            for (key, child) in object {
                if key == "properties", let properties = child as? [String: Any] {
                    for (property, schema) in properties {
                        try walk(schema, path: path.map { $0 + [property] }, depth: depth + 1)
                    }
                } else if child is [String: Any] || child is [Any] {
                    try walk(child, path: nil, depth: depth + 1)
                }
            }
        }
        try walk(MCPJSON.object(inputSchemaJSON), path: [], depth: 0)
        return bindings.sorted { $0.name < $1.name }
    }
}

public struct MCPToolCatalog: Sendable {
    public let tools: [MCPToolDescriptor]
    public let protocolVersion: String
    public let rejectedToolCount: Int
}

public struct MCPToolOutput: Sendable {
    public let text: String
    public let isError: Bool
}

/// 对话可见的目录快照，不包含凭据引用或输入 Schema。
public struct MCPServerToolSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let endpoint: String
    public let isEnabled: Bool
    public let revision: UUID?
    public let tools: [MCPConversationTool]

    public init(config: MCPServerConfig) {
        id = config.id
        name = config.name
        endpoint = config.endpoint
        isEnabled = config.isEnabled
        revision = config.revision
        tools = config.tools.map {
            MCPConversationTool(id: $0.dispatcherName(serverID: config.id), name: $0.name,
                description: config.selectedToolNames.contains($0.name) ? String($0.description.prefix(240)) : "",
                isSelected: config.selectedToolNames.contains($0.name))
        }
    }

    public func availability(of tool: MCPConversationTool, exposedNames: Set<String>?, mode: PermissionMode,
                             configuredServers: [MCPServerToolSummary]? = nil) -> MCPToolAvailability {
        guard isEnabled else { return .serverDisabled }
        guard tool.isSelected else { return .notSelected }
        guard mode != .readOnly else { return .readOnlyBlocked }
        if let configuredServers,
           !configuredServers.contains(where: { $0.id == id && $0.revision == revision }) {
            return .configurationChanged
        }
        if let exposedNames, !exposedNames.contains(tool.id) { return .notLoaded }
        return .available
    }
}

public struct MCPConversationTool: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let isSelected: Bool
}

public enum MCPToolAvailability: String, Sendable {
    case available, serverDisabled, notSelected, readOnlyBlocked, notLoaded, configurationChanged
}

/// Stable, privacy-safe errors. UI maps codes to its three localization bundles.
public struct MCPError: Error, LocalizedError, Sendable, Equatable {
    public enum Code: String, CaseIterable, Sendable {
        case invalidEndpoint, invalidConfiguration, invalidTool, credentialsRequired, storage
        case configurationChanged, catalogChanged, unavailable, authenticationRequired
        case redirectBlocked, http, invalidResponse, responseTooLarge, catalogLimit
        case unsupportedProtocol, interactionUnsupported, timeout, transport, resultUnknown, toolBudget
        case importInvalid, importUnsupported
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public var errorDescription: String? { modelMessage }
    public var localizationKey: String { "mcp.error." + code.rawValue }
    public var modelMessage: String {
        switch code {
        case .importInvalid: "Paste one MCP HTTP endpoint, a JSON server definition, or an mcpServers configuration. Check the name, URL and literal Bearer token."
        case .importUnsupported: "This configuration requires unsupported stdio, SSE, OAuth, environment variables or custom headers. Use a Streamable HTTP URL and optional Bearer token."
        case .invalidEndpoint: "Use an HTTPS MCP endpoint (HTTP is allowed only on loopback). Put credentials in the token field, not the URL; URL credentials, queries and fragments are not supported."
        case .invalidConfiguration: "Check the server name and tool selection. A space supports up to 8 servers and 32 selected MCP tools."
        case .invalidTool: "The server returned an invalid or unsupported tool definition."
        case .credentialsRequired: "Enter a token for this endpoint. A saved token is never reused for a different endpoint."
        case .storage: "The MCP settings could not be saved or read. Retry in Settings."
        case .configurationChanged: "The server configuration or approval changed. Nothing was called. Review the server in Settings and request a fresh approval."
        case .catalogChanged: "The remote tool definition changed or disappeared. Nothing was called. Refresh and review its tools in Settings."
        case .unavailable: "This MCP server or tool is disabled or unavailable. Review it in Settings."
        case .authenticationRequired: "The MCP server rejected authentication. Update the token in Settings; interactive OAuth is not supported yet."
        case .redirectBlocked: "The MCP endpoint redirected the request. Enter the final trusted endpoint in Settings; credentials were not forwarded."
        case .http: "The MCP endpoint rejected the request. Check its URL and Streamable HTTP support in Settings."
        case .invalidResponse: "The MCP server returned an invalid response. Check the endpoint and server implementation."
        case .responseTooLarge: "The MCP response exceeded the size limit. Narrow the request."
        case .catalogLimit: "The MCP tool catalog exceeded the size or pagination limit. Expose a smaller catalog."
        case .toolBudget: "The selected MCP tool definitions use too much model context. Select fewer tools in Settings."
        case .unsupportedProtocol: "This server uses an unsupported MCP protocol or transport. Use Streamable HTTP with a supported protocol version."
        case .interactionUnsupported: "This tool requires interactive client capabilities that are not supported yet. No follow-up request was sent."
        case .timeout: "The MCP server timed out. Check its status before trying again."
        case .transport: "The MCP connection failed. Check the endpoint and network."
        case .resultUnknown: "The MCP call was sent, but its outcome is unknown. It may already have changed external data. Do NOT repeat it automatically; ask the user to verify the external service first."
        }
    }
}

internal enum MCPJSON {
    static func object(_ string: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(string.utf8))
    }
    static func string(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Inspect decoded strings so JSON escaping cannot hide an echoed credential.
    static func containsCredential(_ token: String, in value: Any, depth: Int = 0) -> Bool {
        guard depth <= 128 else { return true }
        if let string = value as? String { return string.contains(token) }
        if let object = value as? [String: Any] {
            return object.contains { $0.key.contains(token) || containsCredential(token, in: $0.value, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.contains { containsCredential(token, in: $0, depth: depth + 1) }
        }
        return (value as? NSNumber)?.stringValue == token
    }

    static func redactingCredential(_ token: String, in value: Any, depth: Int = 0) throws -> Any {
        guard depth <= 128 else { throw MCPError(.responseTooLarge) }
        if let string = value as? String { return string.replacingOccurrences(of: token, with: "[REDACTED]") }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in object {
                result[key.replacingOccurrences(of: token, with: "[REDACTED]")] =
                    try redactingCredential(token, in: child, depth: depth + 1)
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map { try redactingCredential(token, in: $0, depth: depth + 1) }
        }
        if (value as? NSNumber)?.stringValue == token { return "[REDACTED]" }
        return value
    }
}
