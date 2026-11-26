import Foundation
import CoreFoundation

internal protocol MCPClient: Sendable {
    func discover() async throws -> MCPToolCatalog
    func callTool(_ tool: MCPToolDescriptor, argumentsJSON: String) async throws -> MCPToolOutput
    func close() async
}

extension MCPClient {
    func close() async {}
}

/// A short-lived, space-owned remote client. No GET subscription, sampling, roots, OAuth or MRTR.
/// Protocol negotiation happens only during discovery, never by replaying a tool call.
internal actor MCPHTTPClient: MCPClient {
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private let endpoint: URL
    private let token: String?
    private let transport: any MCPHTTPTransporting
    private let messages: [String: String]
    private let deadline: ContinuousClock.Instant
    private var version = modernVersion
    private var sessionID: String?
    private var connected = false
    private var catalog: MCPToolCatalog?

    init(config: MCPServerConfig, token: String?,
         transport: any MCPHTTPTransporting = MCPHTTPTransport(), timeout: Duration = .seconds(60),
         messages: [String: String] = [:]) throws {
        endpoint = try config.validatedEndpoint()
        self.token = config.authentication == .bearer ? token : nil
        if config.authentication == .bearer {
            guard let token, !token.isEmpty,
                  token.utf8.count <= 16_384,
                  token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw MCPError(.credentialsRequired) }
        }
        self.transport = transport
        self.messages = messages
        deadline = .now.advanced(by: timeout)
    }

    func discover() async throws -> MCPToolCatalog {
        if let catalog { return catalog }
        try await connect()
        var tools: [MCPToolDescriptor] = []
        var rejected = 0
        var cursor: String?
        var seenCursors: Set<String> = []
        var names: Set<String> = []
        var catalogBytes = 0
        for _ in 0..<16 {
            let response = try await rpc("tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            let result = try completeResult(response)
            guard let definitions = result["tools"] as? [[String: Any]] else { throw MCPError(.invalidResponse) }
            guard definitions.count + tools.count + rejected <= 256 else { throw MCPError(.catalogLimit) }
            for definition in definitions {
                if let token, MCPJSON.containsCredential(token, in: definition) {
                    rejected += 1
                    continue
                }
                do {
                    let tool = try MCPToolDescriptor(json: definition)
                    // An ambiguous catalog must never silently replace a reviewed definition.
                    guard names.insert(tool.name).inserted else { throw MCPError(.invalidResponse) }
                    catalogBytes += tool.inputSchemaJSON.utf8.count + tool.description.utf8.count
                    guard catalogBytes <= 1_024 * 1_024 else { throw MCPError(.catalogLimit) }
                    tools.append(tool)
                } catch let error as MCPError where error.code == .invalidTool {
                    rejected += 1
                }
            }
            if result["nextCursor"] == nil || result["nextCursor"] is NSNull {
                let value = MCPToolCatalog(tools: tools.sorted { $0.name < $1.name },
                                           protocolVersion: version, rejectedToolCount: rejected)
                catalog = value
                return value
            }
            guard let next = result["nextCursor"] as? String, !next.isEmpty, next.utf8.count <= 4_096,
                  seenCursors.insert(next).inserted else { throw MCPError(.catalogLimit) }
            cursor = next
        }
        throw MCPError(.catalogLimit)
    }

    func callTool(_ tool: MCPToolDescriptor, argumentsJSON: String) async throws -> MCPToolOutput {
        // The approved schema must still describe the live remote tool before any side effect.
        guard let live = try await discover().tools.first(where: { $0.name == tool.name }),
              live.fingerprint == tool.fingerprint else { throw MCPError(.catalogChanged) }
        guard argumentsJSON.utf8.count <= 256 * 1_024,
              let arguments = try? MCPJSON.object(argumentsJSON) as? [String: Any] else {
            throw MCPError(.invalidConfiguration)
        }
        var headers: [String: String] = [:]
        if version == Self.modernVersion {
            for binding in try tool.headerBindings() {
                var value: Any = arguments
                var found = true
                for key in binding.path {
                    guard let next = (value as? [String: Any])?[key] else { found = false; break }
                    value = next
                }
                if !found || value is NSNull { continue }
                let text: String
                switch binding.type {
                case "string":
                    guard let string = value as? String else { throw MCPError(.invalidConfiguration) }
                    text = string
                case "boolean":
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                        throw MCPError(.invalidConfiguration)
                    }
                    text = number.boolValue ? "true" : "false"
                default:
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          abs(number.doubleValue) <= 9_007_199_254_740_991,
                          number.doubleValue.rounded() == number.doubleValue else { throw MCPError(.invalidConfiguration) }
                    text = number.stringValue
                }
                headers["Mcp-Param-" + binding.name] = Self.headerValue(text)
            }
        }
        try Task.checkCancellation()
        let response: MCPHTTPResponse
        do {
            // Exactly one dispatch. In particular, no re-initialize/retry after a session 404.
            response = try await rpc("tools/call", params: ["name": tool.name, "arguments": arguments],
                                     headers: headers)
        } catch let error as MCPError where [.authenticationRequired, .redirectBlocked].contains(error.code) {
            throw error
        } catch {
            // Once handed to the HTTP transport, neither a timeout nor cancellation proves non-execution.
            throw MCPError(.resultUnknown)
        }
        do {
            let result = try completeResult(response)
            var parts: [String] = []
            if let structured = result["structuredContent"] {
                guard structured is [String: Any] else { throw MCPError(.invalidResponse) }
                let safe = try token.map { try MCPJSON.redactingCredential($0, in: structured) } ?? structured
                parts.append(try MCPJSON.string(safe))
            }
            if let content = result["content"] as? [[String: Any]] {
                for item in content {
                    if item["type"] as? String == "text", let text = item["text"] as? String { parts.append(text) }
                    else { parts.append(messages["contentOmitted"] ?? "[MCP content omitted: only text and structured JSON are supported.]") }
                }
            } else if result["structuredContent"] == nil {
                throw MCPError(.invalidResponse)
            }
            var text = parts.joined(separator: "\n\n")
            if text.isEmpty { text = messages["emptyResult"] ?? "[MCP tool returned no text.]" }
            if let token, !token.isEmpty { text = text.replacingOccurrences(of: token, with: "[REDACTED]") }
            if let value = result["isError"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw MCPError(.invalidResponse)
                }
            }
            return MCPToolOutput(text: text, isError: result["isError"] as? Bool ?? false)
        } catch let error as MCPError where error.code == .interactionUnsupported {
            throw error
        } catch {
            throw MCPError(.resultUnknown)
        }
    }

    /// Best-effort legacy session teardown; never retries an operation or sends new business calls.
    func close() async {
        guard let id = sessionID else { return }
        sessionID = nil
        guard !Task.isCancelled else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 2
        request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        _ = try? await transport.send(request, responseID: nil)
    }

    private func connect() async throws {
        guard !connected else { return }
        let probe = try await rpc("server/discover", params: [:], permitsProtocolError: true)
        if let object = try? JSONSerialization.jsonObject(with: probe.body) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int
            if code == -32022 {
                let supported = (error["data"] as? [String: Any])?["supported"] as? [String] ?? []
                guard supported.contains(where: Self.legacyVersions.contains) else { throw MCPError(.unsupportedProtocol) }
            }
            guard code == -32601 || probe.status == 400 || probe.status == 404 || probe.status == 405 else {
                throw MCPError(.unsupportedProtocol)
            }
        } else if probe.status == 200 {
            let result = try completeResult(probe)
            guard (result["supportedVersions"] as? [String])?.contains(Self.modernVersion) == true,
                  let capabilities = result["capabilities"] as? [String: Any],
                  capabilities["tools"] is [String: Any] else { throw MCPError(.unsupportedProtocol) }
            connected = true
            return
        } else if ![400, 404, 405].contains(probe.status) {
            throw MCPError(.http)
        }

        version = Self.legacyVersions[0]
        let initialized = try await rpc("initialize", params: [
            "protocolVersion": version, "capabilities": [String: String](),
            "clientInfo": ["name": "AgRoom", "version": "1"]
        ])
        let result = try completeResult(initialized)
        guard let negotiated = result["protocolVersion"] as? String,
              Self.legacyVersions.contains(negotiated),
              let capabilities = result["capabilities"] as? [String: Any],
              capabilities["tools"] is [String: Any] else { throw MCPError(.unsupportedProtocol) }
        version = negotiated
        sessionID = initialized.sessionID
        _ = try await rpc("notifications/initialized", params: [:], notification: true)
        connected = true
    }

    private func rpc(_ method: String, params: [String: Any], headers: [String: String] = [:],
                     notification: Bool = false, permitsProtocolError: Bool = false) async throws -> MCPHTTPResponse {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw MCPError(.timeout) }
        var params = params
        if version == Self.modernVersion {
            params["_meta"] = [
                "io.modelcontextprotocol/protocolVersion": version,
                "io.modelcontextprotocol/clientInfo": ["name": "AgRoom", "version": "1"],
                "io.modelcontextprotocol/clientCapabilities": [String: String]()
            ]
        }
        let id = notification ? nil : UUID().uuidString
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { body["id"] = id }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = min(30, Double(remaining.components.seconds)
            + Double(remaining.components.attoseconds) / 1e18)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if version == Self.modernVersion {
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let name = params["name"] as? String { request.setValue(Self.headerValue(name), forHTTPHeaderField: "Mcp-Name") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        }
        let response = try await transport.send(request, responseID: id)
        if response.status == 401 || response.status == 403 { throw MCPError(.authenticationRequired) }
        if (300...399).contains(response.status) { throw MCPError(.redirectBlocked) }
        if permitsProtocolError, [400, 404, 405].contains(response.status) { return response }
        if notification {
            guard response.status == 202 else { throw MCPError(.invalidResponse) }
        } else {
            guard response.status == 200 else { throw MCPError(.http) }
            guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  object["jsonrpc"] as? String == "2.0", object["id"] as? String == id else {
                throw MCPError(.invalidResponse)
            }
        }
        return response
    }

    private func completeResult(_ response: MCPHTTPResponse) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              object["error"] == nil, let result = object["result"] as? [String: Any] else {
            throw MCPError(.invalidResponse)
        }
        if let resultType = result["resultType"] as? String, resultType != "complete" {
            throw MCPError(.interactionUnsupported)
        }
        return result
    }

    internal static func headerValue(_ value: String) -> String {
        let safe = !value.isEmpty && value.utf8.allSatisfy { (0x20...0x7e).contains($0) }
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        return safe ? value : "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }
}
