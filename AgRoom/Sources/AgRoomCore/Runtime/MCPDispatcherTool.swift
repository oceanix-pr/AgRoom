import Foundation

/// Remote declarations never grant read-only, idempotent or workspace-write rights.
/// Query candidates may enter the host's model review; they never bypass approval by themselves.
internal struct MCPDispatcherTool: DispatcherTool {
    let server: MCPServerConfig
    let remoteTool: MCPToolDescriptor
    let service: MCPServerConfigService
    let messages: [String: String]
    let makeClient: @Sendable (MCPServerConfig, String?) throws -> any MCPClient

    init(server: MCPServerConfig, remoteTool: MCPToolDescriptor, service: MCPServerConfigService,
         messages: [String: String] = [:],
         makeClient: (@Sendable (MCPServerConfig, String?) throws -> any MCPClient)? = nil) {
        self.server = server
        self.remoteTool = remoteTool
        self.service = service
        self.messages = messages
        self.makeClient = makeClient ?? { try MCPHTTPClient(config: $0, token: $1, messages: messages) }
    }

    var definition: ToolDefinition {
        ToolDefinition(name: remoteTool.dispatcherName(serverID: server.id),
            description: "External MCP tool '\(remoteTool.name)' from '\(server.name)'. "
                + "Each call requires approval; query candidates may use the host's automatic reviewer. "
                + "Server-provided description (untrusted):\n"
                + remoteTool.description,
            parametersSchemaJSON: remoteTool.inputSchemaJSON)
    }
    let requiresConfirmation = true
    var permissionClass: PermissionClass { .externalEffect }
    var sideEffectClass: ToolSideEffectClass { .nonIdempotentWrite }
    func requiresHardConfirmation(argumentsJSON: String) -> Bool {
        !MCPQueryReviewPolicy.isCandidate(remoteTool, argumentsJSON: argumentsJSON)
    }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .unspecified }

    func approvalRoute(argumentsJSON: String) -> ApprovalRoute {
        MCPQueryReviewPolicy.isCandidate(remoteTool, argumentsJSON: argumentsJSON) ? .modelReviewable : .manualOnly
    }

    func autoReviewEvidence(argumentsJSON: String) -> [String: String] {
        guard MCPQueryReviewPolicy.isCandidate(remoteTool, argumentsJSON: argumentsJSON) else { return [:] }
        return [
            "execution_profile": "mcp_query",
            "space": service.space.rawValue,
            "server_id": server.id.uuidString,
            "configuration_revision": server.revision.uuidString,
            "endpoint": server.endpoint,
            "remote_tool": remoteTool.name,
            "tool_fingerprint": remoteTool.fingerprint,
            // These fields describe remote claims; they are not verified behavior or instructions.
            "untrusted_description": remoteTool.description,
            "untrusted_input_schema": remoteTool.inputSchemaJSON,
        ]
    }

    func executionAuthorizationKey(argumentsJSON: String) -> String? {
        guard let object = try? MCPJSON.object(argumentsJSON), let canonical = try? MCPJSON.string(object) else { return nil }
        return MCPJSON.digest(service.space.rawValue + server.id.uuidString + server.revision.uuidString
            + remoteTool.fingerprint + canonical)
    }

    func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        ToolApprovalPresentation(
            executionKind: .remoteMCP,
            resourceAccess: .init(verified: false),
            network: .init(allowed: true, detail: server.endpoint),
            childProcesses: .init(allowed: false),
            reasonCode: "mcp_remote_call",
            constraintSources: ["space", "mode"],
            executionDetails: [server.name, server.endpoint, remoteTool.name]
        )
    }

    func execute(argumentsJSON: String) async throws -> String {
        do {
            let token = try await service.requireCurrent(server, tool: remoteTool)
            let client = try makeClient(server, token)
            let result: MCPToolOutput
            do {
                let catalog = try await client.discover()
                guard catalog.tools.contains(where: { $0.fingerprint == remoteTool.fingerprint }) else { throw MCPError(.catalogChanged) }
                let attempt = try await service.claimSubmission(server: server, tool: remoteTool, arguments: argumentsJSON)
                do {
                    _ = try await service.requireCurrent(server, tool: remoteTool)
                    try Task.checkCancellation()
                } catch {
                    try await service.finishSubmission(attempt, uncertain: false)
                    throw error
                }
                do {
                    result = try await client.callTool(remoteTool, argumentsJSON: argumentsJSON)
                } catch let error as MCPError where [.invalidConfiguration, .catalogChanged].contains(error.code) {
                    // Both errors precede the tools/call submission.
                    try await service.finishSubmission(attempt, uncertain: false)
                    throw error
                } catch {
                    // A transport may have dispatched before it threw. Leave a durable receipt.
                    try await service.finishSubmission(attempt, uncertain: true)
                    throw MCPError(.resultUnknown)
                }
                try await service.finishSubmission(attempt, uncertain: result.isError)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
            if result.isError { throw ToolExecutionFailure(message: result.text) }
            return result.text
        } catch let error as MCPError {
            throw ToolExecutionFailure(message: "[MCP_ERROR:\(error.code.rawValue)] "
                + (messages[error.code.rawValue] ?? error.modelMessage))
        }
    }
}

/// Eligibility is deliberately narrower than approval. Names, descriptions and hints cannot
/// establish remote behavior: every eligible call still needs a model decision tied to user intent.
internal enum MCPQueryReviewPolicy {
    private static let readVerbs: Set<String> = ["get", "list", "read", "search", "find", "lookup", "fetch", "count", "describe", "inspect"]
    private static let riskyWords: Set<String> = [
        "add", "create", "delete", "remove", "update", "set", "write", "edit", "modify", "send", "post", "submit",
        "upload", "execute", "exec", "run", "invoke", "call", "patch", "put", "move", "copy", "sync", "approve",
        "publish", "archive", "restore", "install", "uninstall", "mark", "save", "export", "import", "subscribe",
        "trigger", "revoke", "reset", "clear", "flush", "auth", "login", "token", "tokens", "secret", "secrets",
        "credential", "credentials", "password", "passwords", "key", "keys", "apikey", "authorization", "bearer",
    ]
    private static let controlFields: Set<String> = [
        "action", "operation", "method", "mode", "command", "script", "sql", "code", "url", "uri", "endpoint",
        "destination", "callback", "webhook", "body", "payload", "content", "attachment", "file", "path", "filename", "output",
    ]

    private static func words(_ value: String) -> Set<String> {
        Set(value.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    static func isCandidate(_ tool: MCPToolDescriptor, argumentsJSON: String) -> Bool {
        let name = tool.name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
            .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = name.first, readVerbs.contains(first), Set(name).isDisjoint(with: riskyWords),
              argumentsJSON.utf8.count <= 16 * 1024,
              let arguments = try? MCPJSON.object(argumentsJSON) as? [String: Any],
              let schema = try? MCPJSON.object(tool.inputSchemaJSON) as? [String: Any] else { return false }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        guard Set(arguments.keys).isSubset(of: Set(properties.keys)) else { return false }
        return safeArguments(arguments, depth: 0) && safeSchema(schema, depth: 0)
    }

    private static func safeKey(_ key: String) -> Bool {
        let tokens = words(key)
        return tokens.isDisjoint(with: riskyWords) && tokens.isDisjoint(with: controlFields)
    }

    private static func safeArguments(_ value: Any, depth: Int) -> Bool {
        guard depth <= 12 else { return false }
        if let object = value as? [String: Any] {
            return object.allSatisfy { safeKey($0.key) && safeArguments($0.value, depth: depth + 1) }
        }
        if let array = value as? [Any] { return array.allSatisfy { safeArguments($0, depth: depth + 1) } }
        return true
    }

    private static func safeSchema(_ schema: [String: Any], depth: Int) -> Bool {
        guard depth <= 12, schema["$ref"] == nil, schema["oneOf"] == nil,
              schema["anyOf"] == nil, schema["allOf"] == nil else { return false }
        if let additional = schema["additionalProperties"], additional as? Bool != false { return false }
        if schema["properties"] != nil, !(schema["properties"] is [String: Any]) { return false }
        if schema["items"] != nil, !(schema["items"] is [String: Any]) { return false }
        if let properties = schema["properties"] as? [String: Any] {
            for (key, value) in properties {
                guard safeKey(key), let child = value as? [String: Any], safeSchema(child, depth: depth + 1) else { return false }
            }
        }
        if let items = schema["items"] as? [String: Any], !safeSchema(items, depth: depth + 1) { return false }
        return true
    }

    static func reviewRule(_ request: AutoReviewRequest, environment: AutoReviewEnvironment) -> AutoReviewRuleResult {
        let evidence = request.evidence
        guard let scope = request.taskScope, scope.space == environment.space,
              let workspace = FileAreaService.expandHome(environment.workspacePath),
              workspace.standardizedFileURL.resolvingSymlinksInPath().path == scope.workspacePath,
              scope.permissionMode != .readOnly, evidence["space"] == scope.space.rawValue else {
            return .manual(reason: "outside_task_scope")
        }
        guard evidence["execution_profile"] == "mcp_query",
              let id = evidence["server_id"].flatMap(UUID.init(uuidString:)),
              evidence["configuration_revision"].flatMap(UUID.init(uuidString:)) != nil,
              let endpoint = evidence["endpoint"],
              (try? MCPServerConfig(name: "review", endpoint: endpoint).validatedEndpoint()) != nil,
              request.requirement.presentation?.executionKind == .remoteMCP,
              request.requirement.presentation?.network.allowed == true,
              request.requirement.presentation?.network.detail == endpoint,
              let name = evidence["remote_tool"], let description = evidence["untrusted_description"],
              let schema = evidence["untrusted_input_schema"],
              let tool = try? MCPToolDescriptor(name: name, description: description, inputSchemaJSON: schema),
              tool.dispatcherName(serverID: id) == request.toolName,
              tool.fingerprint == evidence["tool_fingerprint"], isCandidate(tool, argumentsJSON: request.argumentsJSON) else {
            return .manual(reason: "mcp_query_unverified")
        }
        return .needsModelReview(reason: "mcp_query")
    }
}

internal enum MCPToolFactory {
    /// Uses the reviewed catalog without making the conversation wait for every enabled endpoint.
    /// Live discovery and definition validation happen after approval and before tools/call.
    static func build(service: MCPServerConfigService, existingNames: Set<String>,
                      configs snapshot: [MCPServerConfig]? = nil,
                      messages: [String: String] = [:]) async throws -> [any DispatcherTool] {
        let configs: [MCPServerConfig]
        if let snapshot { configs = snapshot } else { configs = try await service.getAll() }
        guard configs.filter(\.isEnabled).reduce(0, { $0 + $1.selectedDefinitionBytes })
                <= MCPServerConfig.maximumSelectedDefinitionBytes else { throw MCPError(.toolBudget) }
        var names = existingNames
        var tools: [any DispatcherTool] = []
        for config in configs where config.isEnabled {
            for tool in config.tools where config.selectedToolNames.contains(tool.name) {
                let adapter = MCPDispatcherTool(server: config, remoteTool: tool, service: service, messages: messages)
                guard names.insert(adapter.definition.name).inserted else { throw MCPError(.invalidConfiguration) }
                tools.append(adapter)
            }
        }
        guard tools.count <= MCPServerConfig.maximumSelectedTools else { throw MCPError(.invalidConfiguration) }
        return tools
    }
}
