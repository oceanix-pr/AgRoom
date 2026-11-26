import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("MCP", .serialized)
struct MCPTests {
    private func descriptor(_ name: String = "files_read", schema: String = #"{"type":"object","properties":{"q":{"type":"string"}}}"#) throws -> MCPToolDescriptor {
        try MCPToolDescriptor(name: name, description: "External test tool", inputSchemaJSON: schema)
    }

    private func configured(_ service: MCPServerConfigService, id: UUID = UUID(),
                            token: String? = nil) async throws -> MCPServerConfig {
        var config = MCPServerConfig(id: id, name: "Test", endpoint: "https://mcp.example.test/mcp",
                                     authentication: token == nil ? .none : .bearer)
        config.tools = [try descriptor()]
        config.selectedToolNames = ["files_read"]
        return try await service.save(config, token: token, creating: true)
    }

    private func fixture(space: AppSpace = .work, credentials: MCPMemoryCredentials = .init()) throws
        -> (DatabaseQueue, MCPServerConfigService) {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return (queue, MCPServerConfigService(databaseQueue: queue, space: space, credentials: credentials))
    }

    @Test("Editor presentations save new services and existing edits without mixing their modes")
    func editorSaveRouting() async throws {
        let credentials = MCPMemoryCredentials()
        let (_, service) = try fixture(credentials: credentials)
        let creation = MCPServerEditorContext.create(MCPServerConfig())
        var draft = creation.config
        draft.name = "Memonta"
        draft.endpoint = "http://127.0.0.1:42817/mcp"
        draft.authentication = .bearer
        let tool = try descriptor()
        draft.tools = [tool]

        // A discovered catalog with no tools selected is still a valid first save.
        let saved = try await creation.save(draft, token: "editor-test-token", service: service)
        #expect(saved.id == creation.id)
        #expect(saved.tools == [tool])
        #expect(saved.selectedToolNames.isEmpty)
        #expect(try await service.getAll() == [saved])

        let editing = MCPServerEditorContext.edit(saved)
        var edit = editing.config
        edit.name = "Renamed service"
        edit.selectedToolNames = [tool.name]
        let latest = try await editing.save(edit, token: nil, service: service)
        #expect(latest.id == saved.id)
        #expect(latest.revision != saved.revision)
        #expect(try await service.getAll() == [latest])
        #expect(try await service.requireCurrent(latest, tool: tool) == "editor-test-token")

        // Retrying an old editor must not replace a newer configuration or credential.
        await #expect(throws: MCPError(.configurationChanged)) {
            try await editing.save(edit, token: "must-not-replace", service: service)
        }
        #expect(credentials.values == ["editor-test-token"])
        #expect(try await service.getAll() == [latest])

        let next = MCPServerEditorContext.create(MCPServerConfig(
            name: "Another service", endpoint: "http://localhost:42817/mcp"
        ))
        let second = try await next.save(next.config, token: nil, service: service)
        #expect(second.id != latest.id)
        #expect(Set(try await service.getAll().map(\.id)) == [latest.id, second.id])
    }

    @Test("Space migrations and credentials remain physically separate, including matching server IDs")
    func spacesAndSecrets() async throws {
        let credentials = MCPMemoryCredentials()
        let (workQueue, work) = try fixture(credentials: credentials)
        let (personalQueue, personal) = try fixture(space: .personal, credentials: credentials)
        let id = UUID()
        let a = try await configured(work, id: id, token: "work-secret")
        let b = try await configured(personal, id: id, token: "personal-secret")
        #expect(try await work.requireCurrent(a, tool: a.tools[0]) == "work-secret")
        #expect(try await personal.requireCurrent(b, tool: b.tools[0]) == "personal-secret")
        #expect(credentials.accounts.allSatisfy { $0.hasPrefix("mcp.work.") || $0.hasPrefix("mcp.personal.") })
        for queue in [workQueue, personalQueue] {
            let payload = try await queue.read { try String.fetchOne($0, sql: "SELECT configurationJSON FROM mcp_servers") }
            #expect(payload?.contains("work-secret") == false)
            #expect(payload?.contains("personal-secret") == false)
            try DatabaseBootstrap.prepareSpace(queue)
        }
        try await work.delete(a)
        #expect(try await work.getAll().isEmpty)
        #expect(try await personal.getAll().count == 1)
        #expect(credentials.values == ["personal-secret"])
        let global = try DatabaseQueue()
        try DatabaseBootstrap.prepareGlobal(global)
        #expect(try await global.read { try !$0.tableExists("mcp_servers") })
    }

    @Test("Failed and stale edits preserve the previous credential and cannot resurrect a removed server")
    func atomicConfiguration() async throws {
        let credentials = MCPMemoryCredentials()
        let (queue, service) = try fixture(credentials: credentials)
        let config = try await configured(service, token: "previous-secret")
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_mcp_update BEFORE UPDATE ON mcp_servers
                BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
                """)
        }
        await #expect(throws: MCPError(.storage)) {
            try await service.save(config, token: "replacement-secret")
        }
        #expect(credentials.values == ["previous-secret"])
        #expect(try await service.requireCurrent(config, tool: config.tools[0]) == "previous-secret")
        try await queue.write { try $0.execute(sql: "DROP TRIGGER fail_mcp_update") }
        let otherService = MCPServerConfigService(databaseQueue: queue, space: .work, credentials: credentials)
        var edit = config
        edit.name = "Renamed"
        let latest = try await otherService.save(edit)
        await #expect(throws: MCPError(.configurationChanged)) {
            try await service.save(config, token: "must-be-discarded")
        }
        #expect(credentials.values == ["previous-secret"])
        try await otherService.delete(latest)
        await #expect(throws: MCPError(.configurationChanged)) { try await service.save(latest) }
    }

    @Test("Changing endpoints cannot send the old credential to a different server")
    func credentialOrigin() async throws {
        let (_, service) = try fixture()
        var config = try await configured(service, token: "private-token")
        config.endpoint = "https://different.example.test/mcp"
        await #expect(throws: MCPError(.credentialsRequired)) { try await service.save(config) }
        await #expect(throws: MCPError(.credentialsRequired)) { try await service.discover(config: config, token: nil) }
        for endpoint in ["http://remote.example/mcp", "https://u:p@example.com/mcp",
                         "https://example.com/mcp?token=secret", "https://example.com/mcp#secret",
                         "file:///tmp/server", "https:///mcp"] {
            config.endpoint = endpoint
            #expect(throws: MCPError.self) { try config.validatedEndpoint() }
        }
        for endpoint in ["https://example.com/mcp", "  https://example.com/mcp\n", "http://localhost:8000/mcp", "http://127.0.0.1:8000/mcp", "http://[::1]:8000/mcp"] {
            config.endpoint = endpoint
            #expect(throws: Never.self) { try config.validatedEndpoint() }
        }
    }

    @Test("Catalogs use stable bounded names and reject unsafe or ambiguous header definitions")
    func schemaAndNames() throws {
        let id = UUID()
        let first = try descriptor()
        let reordered = try descriptor(schema: #"{"properties":{"q":{"type":"string"}},"type":"object"}"#)
        #expect(first.fingerprint == reordered.fingerprint)
        #expect(first.dispatcherName(serverID: id) == reordered.dispatcherName(serverID: id))
        #expect(first.dispatcherName(serverID: id).count <= 64)
        #expect(first.dispatcherName(serverID: id) != "files_read")
        #expect(first.dispatcherName(serverID: id) != first.dispatcherName(serverID: UUID()))
        for schema in [
            #"{"type":"object","properties":{"q":{"type":"string","x-mcp-header":"Bad\nName"}}}"#,
            #"{"type":"object","properties":{"a":{"type":"string","x-mcp-header":"X"},"b":{"type":"boolean","x-mcp-header":"x"}}}"#,
            #"{"type":"object","properties":{"q":{"type":"number","x-mcp-header":"X"}}}"#,
            #"{"type":"object","properties":{"a":{"type":"array","items":{"type":"string","x-mcp-header":"X"}}}}"#,
            #"{"type":"object","allOf":[{"properties":{"q":{"type":"string","x-mcp-header":"X"}}}]}"#
        ] {
            #expect(throws: MCPError.self) { try descriptor(schema: schema) }
        }
        #expect(MCPHTTPClient.headerValue("hello") == "hello")
        #expect(MCPHTTPClient.headerValue("世界\r\nx").hasPrefix("=?base64?"))
        #expect(MCPHTTPClient.headerValue("=?base64?literal?=") != "=?base64?literal?=")
    }

    @Test("Modern HTTP discovers paginated tools and mirrors only declared, safely encoded arguments")
    func modernHTTP() async throws {
        let tool = try descriptor(schema: #"{"type":"object","properties":{"q":{"type":"string","x-mcp-header":"Project"}}}"#)
        let transport = MCPStubTransport(tool: tool, paginated: true)
        let config = MCPServerConfig(name: "Modern", endpoint: "https://mcp.example.test/mcp", authentication: .bearer)
        let client = try MCPHTTPClient(config: config, token: "test-token", transport: transport)
        let catalog = try await client.discover()
        #expect(catalog.protocolVersion == MCPHTTPClient.modernVersion)
        #expect(catalog.tools.count == 2)
        let output = try await client.callTool(tool, argumentsJSON: #"{"q":"世界\nvalue"}"#)
        #expect(output.text.contains("42"))
        #expect(!output.isError)
        let records = await transport.records
        #expect(records.map(\.method) == ["server/discover", "tools/list", "tools/list", "tools/call"])
        let call = try #require(records.last)
        #expect(call.authorization == "Bearer test-token")
        #expect(call.version == MCPHTTPClient.modernVersion)
        #expect(call.headerName == tool.name)
        #expect(call.projectHeader == MCPHTTPClient.headerValue("世界\nvalue"))
        let callJSON = try #require(MCPJSON.object(call.body) as? [String: Any])
        let params = try #require(callJSON["params"] as? [String: Any])
        let meta = try #require(params["_meta"] as? [String: Any])
        #expect(meta["io.modelcontextprotocol/clientCapabilities"] is [String: Any])
        #expect(!call.body.contains("test-token"))
    }

    @Test("Selection budgets span servers without throwing away the discovered catalog")
    func contextBudget() async throws {
        let (_, service) = try fixture()
        var large = MCPServerConfig(name: "Large", endpoint: "https://mcp.example.test/mcp")
        large.tools = try (0..<5).map { index in
            try MCPToolDescriptor(name: "tool\(index)", description: String(repeating: "x", count: 8_000),
                                  inputSchemaJSON: #"{"type":"object"}"#)
        }
        large.selectedToolNames = Set(large.tools.map(\.name))
        await #expect(throws: MCPError(.toolBudget)) { try await service.save(large, creating: true) }
        large.selectedToolNames = ["tool0"]
        let saved = try await service.save(large, creating: true)
        #expect(saved.tools.count == 5)
        #expect(try await MCPToolFactory.build(service: service, existingNames: []).count == 1)
    }

    @Test("Legacy HTTP initializes once, negotiates its version, and sends the session ID on later requests")
    func legacyHTTP() async throws {
        let tool = try descriptor()
        let transport = MCPStubTransport(tool: tool, mode: .legacy)
        let client = try MCPHTTPClient(config: .init(name: "Legacy", endpoint: "http://localhost:8000/mcp"),
                                       token: nil, transport: transport)
        #expect(try await client.discover().protocolVersion == "2025-06-18")
        _ = try await client.callTool(tool, argumentsJSON: "{}")
        let records = await transport.records
        #expect(records.map(\.method) == ["server/discover", "initialize", "notifications/initialized", "tools/list", "tools/call"])
        #expect(records.last?.sessionID == "fixture-session")
        #expect(records.last?.version == "2025-06-18")
        #expect(records.last?.headerName == nil)
    }

    @Test("Malformed paging, duplicate names and mismatched RPC IDs fail before tool dispatch")
    func badCatalogs() async throws {
        for mode in [MCPStubTransport.Mode.repeatedCursor, .duplicateNames, .wrongID] {
            let transport = MCPStubTransport(tool: try descriptor(), mode: mode)
            let client = try MCPHTTPClient(config: .init(name: "Bad", endpoint: "https://mcp.example.test/mcp"),
                                           token: nil, transport: transport)
            await #expect(throws: MCPError.self) { try await client.discover() }
            #expect(await transport.records.allSatisfy { $0.method != "tools/call" })
        }
    }

    @Test("SSE supports comments, chunk boundaries, Unicode, multiline data and matching response IDs")
    func sseFraming() throws {
        let stream = "\u{feff}:keepalive\r\n\r\ndata:\r\n\r\n"
            + "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\r\n\r\n"
            + "data: {\"jsonrpc\":\"2.0\",\"id\":\"other\",\"result\":{}}\r\n\r\n"
            + "event: message\rdata: {\"jsonrpc\":\"2.0\",\"id\":\"wanted\",\r"
            + "data: \"result\":{\"text\":\"你好\"}}\r\r"
        var parser = MCPEventParser(responseID: "wanted")
        var response: Data?
        for byte in stream.utf8 {
            if let value = try parser.append(byte) { response = value }
        }
        let data = try #require(response)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["result"] as? [String: Any])?["text"] as? String == "你好")
        var invalid = MCPEventParser(responseID: "wanted")
        #expect(throws: MCPError.self) {
            for byte in "data: not-json\n\n".utf8 { _ = try invalid.append(byte) }
        }
    }

    @Test("External hints never grant read-only, round, persistent or automatic approval")
    func permissionsAndRegistration() async throws {
        let (_, service) = try fixture()
        let config = try await configured(service)
        let tools = try await MCPToolFactory.build(service: service, existingNames: ["files_read"])
        let tool = try #require(tools.first)
        #expect(tool.requiresConfirmation)
        #expect(tool.requiresHardConfirmation(argumentsJSON: "{}"))
        #expect(tool.sideEffectClass == .nonIdempotentWrite)
        #expect(tool.permissionClass == .externalEffect)
        #expect(tool.approvalRoute(argumentsJSON: "{}") == .manualOnly)
        #expect(tool.roundAuthorizationKey(argumentsJSON: "{}") == nil)
        #expect(tool.persistentApprovalCandidates(argumentsJSON: "{}") == nil)
        #expect(tool.approvalPresentation(argumentsJSON: "{}")?.executionKind == .remoteMCP)
        let policy = PermissionPolicy(mode: .readOnly, fileAreaPolicy: nil)
        guard case .deny = policy.assess(toolName: tool.definition.name, permissionClass: tool.permissionClass,
                                        argumentsJSON: "{}", skillWorkspace: nil) else {
            Issue.record("Read-only sessions must reject remote MCP"); return
        }
        await #expect(throws: MCPError.self) {
            try await MCPToolFactory.build(service: service, existingNames: [tool.definition.name])
        }
        #expect(!DaemonCapabilitySet.supports(tool.definition.name))
        #expect(config.tools[0].dispatcherName(serverID: config.id) == tool.definition.name)
    }

    @Test("Query names are only review candidates; mutations, dispatch controls and secrets stay manual")
    func queryReviewCandidates() throws {
        let schema = #"{"type":"object","properties":{"entry_id":{"type":"string"},"cursor":{"type":"string"},"limit":{"type":"integer"}}}"#
        for name in ["list_entries", "get_entry", "get_transcript", "get_todos", "search_entries", "getEntries"] {
            let tool = try descriptor(name, schema: schema)
            #expect(MCPQueryReviewPolicy.isCandidate(tool, argumentsJSON: #"{"entry_id":"meeting-1","limit":20}"#))
            #expect(!MCPQueryReviewPolicy.isCandidate(tool, argumentsJSON: #"{"action":"delete"}"#))
            #expect(!MCPQueryReviewPolicy.isCandidate(tool, argumentsJSON: #"{"entry_id":{"operation":"delete"}}"#))
            #expect(!MCPQueryReviewPolicy.isCandidate(tool, argumentsJSON: "[]"))
        }
        for name in ["delete_entry", "send_email", "get_and_delete", "getCredentials", "list_tokens", "list_api_keys", "query", "run_query"] {
            #expect(!MCPQueryReviewPolicy.isCandidate(try descriptor(name), argumentsJSON: "{}"))
        }
        for schema in [
            #"{"type":"object","properties":{"mark_as_read":{"type":"boolean","default":true}}}"#,
            #"{"type":"object","properties":{"path":{"type":"string"}}}"#,
            #"{"type":"object","properties":{"sql":{"type":"string"}}}"#,
            #"{"type":"object","properties":{"headers":{"type":"object","additionalProperties":true}}}"#,
            #"{"type":"object","oneOf":[{"properties":{"action":{"const":"delete"}}}]}"#,
        ] {
            #expect(!MCPQueryReviewPolicy.isCandidate(try descriptor("get_entry", schema: schema), argumentsJSON: "{}"))
        }
    }

    private func queryHarness(autoReview: Bool = true, mode: PermissionMode = .workspaceWrite) async throws
        -> (directory: URL, service: MCPServerConfigService, config: MCPServerConfig, engine: DispatcherEngine,
            transport: MCPStubTransport, context: ExecutionContext) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (_, service) = try fixture()
        let remote = try descriptor("list_entries", schema: #"{"type":"object","properties":{"cursor":{"type":"string"}}}"#)
        var config = MCPServerConfig(name: "Memonta", endpoint: "https://mcp.example.test/mcp")
        config.tools = [remote]
        config.selectedToolNames = [remote.name]
        config = try await service.save(config, creating: true)
        let transport = MCPStubTransport(tool: remote)
        let tool = MCPDispatcherTool(server: config, remoteTool: remote, service: service,
            makeClient: { try MCPHTTPClient(config: $0, token: $1, transport: transport) })
        let scope = TaskExecutionScope.make(space: .work, sessionID: UUID(), runID: UUID(), parentRunID: nil,
            workspaceID: nil, workspacePath: directory.path, readRoots: [directory], writeRoots: [directory], artifactRoots: [],
            mode: mode, autoReviewEnabled: autoReview, policyVersion: AutoReviewService.ruleVersion,
            userRequest: "只查询 Memonta 里十月的会议并总结，不要修改，不要执行脚本。")
        let policy = PermissionPolicy(mode: mode, fileAreaPolicy: nil)
        let context = ExecutionContext(space: .work, permissionPolicy: policy, taskScope: scope)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MCPModelURLProtocol.self]
        let provider = CloudProvider(config: .init(name: "Test model", endpoint: "https://model.test/v1", model: "test"),
            apiKey: "", session: URLSession(configuration: session))
        let engine = DispatcherEngine(provider: provider, tools: [tool], systemPrompt: "Use the query tool.", executionContext: context)
        return (directory, service, config, engine, transport, context)
    }

    @Test("The normal dispatcher can automatically approve a query without any earlier MCP traffic")
    func automaticallyReviewedQuery() async throws {
        let f = try await queryHarness()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let outcome = try await f.engine.run(userMessage: f.context.taskScope!.userRequest, history: [])
        guard case .needsConfirmation(_, _, _, let requirement) = outcome else { Issue.record("Expected reviewable query"); return }
        #expect(requirement.kind == .normal)
        #expect(requirement.availableApprovalDurations == [.once])
        #expect(await f.transport.records.isEmpty)
        let reviewer = MCPQueryTestReviewer(decision: .approve(reason: "matches_lookup"))
        let environment = AutoReviewEnvironment(space: .work, workspacePath: f.directory.path)
        let result = try #require(await f.engine.reviewPending(environment: environment, service: AutoReviewService(reviewer: reviewer)))
        #expect(result.decision == .approve(reason: "matches_lookup"))
        #expect(await reviewer.calls == 1)
        #expect(result.request.evidence["execution_profile"] == "mcp_query")
        #expect(!f.context.taskScope!.allows(.confinedCodeExecution))
        #expect(await f.transport.records.isEmpty)
        let finished = try await f.engine.resume(.autoApproved(callId: result.request.callId,
            generation: result.request.authorizationGeneration, digest: result.request.callDigest))
        guard case .finished(_, _, let trace, _, _, _, _) = finished else { Issue.record("Query did not finish"); return }
        #expect(trace.count == 1 && trace[0].succeeded)
        #expect(await f.transport.records.filter { $0.method == "tools/call" }.count == 1)
    }

    @Test("Unavailable or uncertain review stays manual; disabling auto review invalidates a late approval")
    func queryReviewFallsBack() async throws {
        let f = try await queryHarness()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.engine.run(userMessage: f.context.taskScope!.userRequest, history: [])
        let environment = AutoReviewEnvironment(space: .work, workspacePath: f.directory.path)
        let unavailable = try #require(await f.engine.reviewPending(environment: environment, service: AutoReviewService()))
        #expect(unavailable.decision == .manual(reason: "review_unavailable"))
        let uncertain = MCPQueryTestReviewer(decision: .manual(reason: "uncertain"))
        #expect(await f.engine.reviewPending(environment: environment, service: AutoReviewService(reviewer: uncertain))?.decision == .manual(reason: "uncertain"))
        let approving = MCPQueryTestReviewer(decision: .approve(reason: "matches_lookup"))
        let approved = try #require(await f.engine.reviewPending(environment: environment, service: AutoReviewService(reviewer: approving)))
        f.context.authorizationState.setEnabled(false)
        let resumed = try await f.engine.resume(.autoApproved(callId: approved.request.callId,
            generation: approved.request.authorizationGeneration, digest: approved.request.callDigest))
        guard case .needsConfirmation = resumed else { Issue.record("Late approval bypassed disabled auto review"); return }
        #expect(await f.transport.records.isEmpty)
    }

    @Test("Query review cannot override read-only mode, disabled review, modified evidence or revoked services")
    func queryReviewBoundaries() async throws {
        for (mode, autoReview) in [(PermissionMode.readOnly, true), (.workspaceWrite, false)] {
            let f = try await queryHarness(autoReview: autoReview, mode: mode)
            defer { try? FileManager.default.removeItem(at: f.directory) }
            _ = try await f.engine.run(userMessage: f.context.taskScope!.userRequest, history: [])
            if mode == .readOnly {
                #expect(f.engine.pendingAutoReviewRequest() == nil)
            } else {
                let reviewer = MCPQueryTestReviewer(decision: .approve(reason: "must_not_run"))
                let result = await f.engine.reviewPending(environment: .init(space: .work, workspacePath: f.directory.path), service: AutoReviewService(reviewer: reviewer))
                #expect(result?.decision == .manual(reason: "auto_review_disabled"))
                #expect(await reviewer.calls == 0)
            }
            #expect(await f.transport.records.isEmpty)
        }
        let f = try await queryHarness()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.engine.run(userMessage: f.context.taskScope!.userRequest, history: [])
        let request = try #require(f.engine.pendingAutoReviewRequest())
        let environment = AutoReviewEnvironment(space: .work, workspacePath: f.directory.path)
        var evidence = request.evidence
        evidence["tool_fingerprint"] = "changed"
        let changed = AutoReviewRequest(callId: request.callId, toolName: request.toolName, argumentsJSON: request.argumentsJSON,
            requirement: request.requirement, route: request.route, sideEffectClass: request.sideEffectClass,
            taskScope: request.taskScope, evidence: evidence)
        #expect(AutoReviewService.ruleResult(changed, environment: environment) == .manual(reason: "mcp_query_unverified"))
        #expect(AutoReviewService.ruleResult(request, environment: .init(space: .personal, workspacePath: f.directory.path)) == .manual(reason: "outside_task_scope"))
        #expect(AutoReviewService.ruleResult(request, environment: .init(space: .work, workspacePath: f.directory.deletingLastPathComponent().path)) == .manual(reason: "outside_task_scope"))
        var config = f.config
        config.isEnabled = false
        try await f.service.save(config)
        _ = try await f.engine.resume(.autoApproved(callId: request.callId,
            generation: request.authorizationGeneration, digest: request.callDigest))
        #expect(await f.transport.records.isEmpty)
    }

    @Test("Live definition changes fail before business calls")
    func changedTool() async throws {
        let (_, service) = try fixture()
        let config = try await configured(service)
        let changed = try descriptor(schema: #"{"type":"object","properties":{"different":{"type":"string"}}}"#)
        let transport = MCPStubTransport(tool: changed)
        let tool = MCPDispatcherTool(server: config, remoteTool: config.tools[0], service: service,
            makeClient: { try MCPHTTPClient(config: $0, token: $1, transport: transport) })
        await #expect(throws: ToolExecutionFailure.self) { try await tool.execute(argumentsJSON: "{}") }
        #expect(await transport.records.allSatisfy { $0.method != "tools/call" })
    }

    @Test("The real dispatcher suspends before any MCP network activity and records only approved calls")
    func dispatcherApprovalLoop() async throws {
        let (_, service) = try fixture()
        let config = try await configured(service)
        let transport = MCPStubTransport(tool: config.tools[0])
        let tool = MCPDispatcherTool(server: config, remoteTool: config.tools[0], service: service,
            makeClient: { try MCPHTTPClient(config: $0, token: $1, transport: transport) })
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MCPModelURLProtocol.self]
        let provider = CloudProvider(config: .init(name: "Test model", endpoint: "https://model.test/v1", model: "test"),
                                     apiKey: "", session: URLSession(configuration: sessionConfig))
        let engine = DispatcherEngine(provider: provider, tools: [tool], systemPrompt: "Use the tool.",
            permissionPolicy: PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil))
        let outcome = try await engine.run(userMessage: "Call the external tool", history: [])
        guard case .needsConfirmation(_, _, _, let requirement) = outcome else {
            Issue.record("MCP must suspend for explicit approval"); return
        }
        #expect(requirement.kind == .hard)
        #expect(requirement.availableApprovalDurations == [.once])
        #expect(requirement.presentation?.executionDetails == [config.name, config.endpoint, config.tools[0].name])
        #expect(await transport.records.isEmpty)
        #expect(engine.hasRemoteMCPTools)
        let result = try await engine.resume(approved: true, alwaysAllow: true, persistRule: true)
        guard case .finished(_, _, let trace, _, _, _, _) = result else {
            Issue.record("Approved tool should complete"); return
        }
        #expect(trace.count == 1)
        #expect(trace.first?.succeeded == true)
        #expect(await transport.records.filter { $0.method == "tools/call" }.count == 1)
    }

    @Test("Revoking a configuration while discovery is suspended prevents dispatch")
    func revokeDuringDiscovery() async throws {
        let (_, service) = try fixture()
        var config = try await configured(service)
        let gate = MCPGatedClient(tool: config.tools[0])
        let tool = MCPDispatcherTool(server: config, remoteTool: config.tools[0], service: service,
                                     makeClient: { _, _ in gate })
        let invocation = Task { try await tool.execute(argumentsJSON: "{}") }
        await gate.waitForDiscovery()
        config.isEnabled = false
        try await service.save(config)
        await gate.release()
        await #expect(throws: ToolExecutionFailure.self) { try await invocation.value }
        #expect(await gate.callCount == 0)
    }

    @Test("A lost write response is never retried, even when the model repeats reordered arguments")
    func noReplay() async throws {
        let (queue, service) = try fixture()
        let config = try await configured(service)
        let transport = MCPStubTransport(tool: config.tools[0], mode: .disconnect)
        func rebuiltTool() -> MCPDispatcherTool { MCPDispatcherTool(server: config, remoteTool: config.tools[0], service: service,
            makeClient: { try MCPHTTPClient(config: $0, token: $1, transport: transport) }) }
        for arguments in [#"{"a":1,"b":2}"#, #"{"b":2,"a":1}"#] {
            do { _ = try await rebuiltTool().execute(argumentsJSON: arguments); Issue.record("Expected uncertainty") }
            catch let error as ToolExecutionFailure { #expect(error.message.contains("resultUnknown")) }
        }
        #expect(await transport.records.filter { $0.method == "tools/call" }.count == 1)
        let reopened = MCPServerConfigService(databaseQueue: queue, space: service.space)
        let pending = try await reopened.uncertainSubmissions()
        #expect(pending.count == 1)
        try await reopened.acknowledgeSubmission(try #require(pending.first).id)
        #expect(try await reopened.uncertainSubmissions().isEmpty)
        #expect(await transport.records.filter { $0.method == "tools/call" }.count == 1)
    }

    @Test("Server errors remain failed executions and tool results redact the active token")
    func resultSemantics() async throws {
        let (_, service) = try fixture()
        let config = try await configured(service, token: "test-token")
        let transport = MCPStubTransport(tool: config.tools[0], mode: .toolFailure)
        let tool = MCPDispatcherTool(server: config, remoteTool: config.tools[0], service: service,
            makeClient: { try MCPHTTPClient(config: $0, token: $1, transport: transport) })
        do { _ = try await tool.execute(argumentsJSON: "{}"); Issue.record("Expected a failed tool result") }
        catch let failure as ToolExecutionFailure {
            #expect(failure.message.contains("remote failure"))
            #expect(!failure.message.contains("test-token"))
            #expect(failure.message.contains("[REDACTED]"))
        }
    }

    @Test("Credential echoes cannot enter catalog storage, including JSON-escaped values")
    func credentialEchoes() async throws {
        let token = "a/b\\c\"d"
        let contaminated = try MCPToolDescriptor(name: "echo", description: "credential: " + token,
                                                inputSchemaJSON: #"{"type":"object"}"#)
        let transport = MCPStubTransport(tool: contaminated)
        let config = MCPServerConfig(name: "Echo", endpoint: "https://mcp.example.test/mcp", authentication: .bearer)
        let client = try MCPHTTPClient(config: config, token: token, transport: transport)
        let catalog = try await client.discover()
        #expect(catalog.tools.isEmpty && catalog.rejectedToolCount == 1)
        let payload: [String: Any] = ["nested": [["echo": token]], "text": "prefix " + token]
        #expect(MCPJSON.containsCredential(token, in: payload))
        let sanitized = try MCPJSON.redactingCredential(token, in: payload)
        #expect(!MCPJSON.containsCredential(token, in: sanitized))
        let decoded = try MCPJSON.object(MCPJSON.string(sanitized))
        #expect(!MCPJSON.containsCredential(token, in: decoded))
    }

    @Test("Real URLSession framing is bounded, cancellable and does not share cookies")
    func transportBoundaries() async throws {
        let transport = MCPHTTPTransport(configuration: {
            let value = URLSessionConfiguration.ephemeral
            value.protocolClasses = [MCPURLProtocol.self]
            return value
        })
        var request = URLRequest(url: URL(string: "https://mcp.test/sse")!)
        request.timeoutInterval = 1
        let response = try await transport.send(request, responseID: "test")
        #expect(response.body == Data(#"{"jsonrpc":"2.0","id":"test","result":{}}"#.utf8))
        request.url = URL(string: "https://mcp.test/oversized")!
        await #expect(throws: MCPError(.responseTooLarge)) { try await transport.send(request, responseID: "test") }
        request.url = URL(string: "https://mcp.test/stall")!
        request.timeoutInterval = 0.05
        await #expect(throws: MCPError(.timeout)) { try await transport.send(request, responseID: "test") }
        let cancelled = Task { try await transport.send(request, responseID: "test") }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @MainActor
    @Test("MCP settings and errors have translations in all three UI languages")
    func localization() {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            for code in MCPError.Code.allCases {
                let error = MCPError(code)
                #expect(L.errorDescription(error) != error.localizationKey)
            }
            for key in ["mcp.title", "mcp.foreground", "mcp.tools.help", "mcp.approval.scope",
                        "mcp.save.failed", "mcp.save.configurationChanged",
                        "permissions.kind.remoteMCP", "permissions.reason.mcp_remote_call", "permissions.reason.mcp_query",
                        "chat.autoReview.reason.mcp_query", "chat.autoReview.reason.mcp_query_unverified"] {
                #expect(L.string(key) != key)
            }
            #expect(L.string("mcp.save.configurationChanged") != L.errorDescription(MCPError(.configurationChanged)))
        }
    }
}

private actor MCPQueryTestReviewer: AutoReviewReviewer {
    let decision: AutoReviewDecision
    private(set) var calls = 0
    init(decision: AutoReviewDecision) { self.decision = decision }
    func reviewCandidate(_ request: AutoReviewRequest, environment: AutoReviewEnvironment) async -> AutoReviewDecision? {
        calls += 1
        return decision
    }
}

private final class MCPMemoryCredentials: MCPCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]
    var accounts: [String] { lock.withLock { Array(stored.keys) } }
    var values: Set<String> { lock.withLock { Set(stored.values) } }
    func read(account: String) -> String? { lock.withLock { stored[account] } }
    func save(_ value: String, account: String) throws { lock.withLock { stored[account] = value } }
    func delete(account: String) throws { lock.withLock { _ = stored.removeValue(forKey: account) } }
}

private struct MCPRequestRecord: Sendable {
    let method: String
    let authorization: String?
    let version: String?
    let sessionID: String?
    let headerName: String?
    let projectHeader: String?
    let body: String
}

private actor MCPStubTransport: MCPHTTPTransporting {
    enum Mode: Sendable { case modern, legacy, repeatedCursor, duplicateNames, wrongID, disconnect, toolFailure }
    let tool: MCPToolDescriptor
    let mode: Mode
    let paginated: Bool
    private(set) var records: [MCPRequestRecord] = []

    init(tool: MCPToolDescriptor, mode: Mode = .modern, paginated: Bool = false) {
        self.tool = tool; self.mode = mode; self.paginated = paginated
    }

    func send(_ request: URLRequest, responseID: String?) async throws -> MCPHTTPResponse {
        let data = request.httpBody ?? Data()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try #require(object["method"] as? String)
        let params = object["params"] as? [String: Any] ?? [:]
        records.append(MCPRequestRecord(method: method, authorization: request.value(forHTTPHeaderField: "Authorization"),
            version: request.value(forHTTPHeaderField: "MCP-Protocol-Version"),
            sessionID: request.value(forHTTPHeaderField: "Mcp-Session-Id"),
            headerName: request.value(forHTTPHeaderField: "Mcp-Name"),
            projectHeader: request.value(forHTTPHeaderField: "Mcp-Param-Project"), body: String(decoding: data, as: UTF8.self)))
        var result: [String: Any] = ["resultType": "complete"]
        var status = 200
        var sessionID: String?
        switch method {
        case "server/discover":
            if mode == .legacy {
                return MCPHTTPResponse(status: 400, sessionID: nil, body: try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": responseID ?? "", "error": ["code": -32601, "message": "Unknown method"]
                ]))
            }
            result["capabilities"] = ["tools": [String: String]()]
            result["supportedVersions"] = [MCPHTTPClient.modernVersion]
        case "initialize":
            result["protocolVersion"] = "2025-06-18"
            result["capabilities"] = ["tools": [String: String]()]
            sessionID = "fixture-session"
        case "notifications/initialized":
            return MCPHTTPResponse(status: 202, sessionID: nil, body: Data())
        case "tools/list":
            var definition: [String: Any] = [
                "name": tool.name, "description": tool.description,
                "inputSchema": try MCPJSON.object(tool.inputSchemaJSON),
                "annotations": ["readOnlyHint": true, "idempotentHint": true]
            ]
            if paginated, params["cursor"] != nil { definition["name"] = "second" }
            result["tools"] = mode == .duplicateNames ? [definition, definition] : [definition]
            if mode == .repeatedCursor || (paginated && params["cursor"] == nil) { result["nextCursor"] = "next" }
        case "tools/call":
            if mode == .disconnect { throw URLError(.networkConnectionLost) }
            result["structuredContent"] = ["value": 42]
            result["content"] = [["type": "text", "text": mode == .toolFailure ? "remote failure test-token" : "done"]]
            result["isError"] = mode == .toolFailure
        default: status = 404
        }
        return MCPHTTPResponse(status: status, sessionID: sessionID,
            body: try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": mode == .wrongID ? "wrong" : (responseID ?? ""), "result": result
            ]))
    }
}

private actor MCPGatedClient: MCPClient {
    let tool: MCPToolDescriptor
    private var discovery: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private(set) var callCount = 0
    init(tool: MCPToolDescriptor) { self.tool = tool }
    func discover() async throws -> MCPToolCatalog {
        started = true
        for waiter in waiters { waiter.resume() }
        waiters = []
        await withCheckedContinuation { discovery = $0 }
        return MCPToolCatalog(tools: [tool], protocolVersion: MCPHTTPClient.modernVersion, rejectedToolCount: 0)
    }
    func waitForDiscovery() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { discovery?.resume(); discovery = nil }
    func callTool(_ tool: MCPToolDescriptor, argumentsJSON: String) async throws -> MCPToolOutput {
        callCount += 1
        return MCPToolOutput(text: "done", isError: false)
    }
}

private final class MCPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        if url.path == "/stall" { return }
        let oversized = url.path == "/oversized"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "text/event-stream",
            "Content-Length": oversized ? "\(MCPHTTPTransport.maximumResponseBytes + 1)" : "128"
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !oversized {
            client?.urlProtocol(self, didLoad: Data("data: {\"jsonrpc\":\"2.0\",\"id\":\"test\",\"result\":{}}\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class MCPModelURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        do {
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = body["messages"] as? [[String: Any]] ?? []
            let completed = messages.contains { $0["role"] as? String == "tool" }
            let definitions = body["tools"] as? [[String: Any]] ?? []
            let function = definitions.first?["function"] as? [String: Any]
            let name = function?["name"] as? String ?? "missing"
            let delta: [String: Any] = completed ? ["content": "done"] : [
                "tool_calls": [["index": 0, "id": "mcp-call", "type": "function",
                                "function": ["name": name, "arguments": "{}"]]]
            ]
            let first = try MCPJSON.string(["choices": [["delta": delta, "finish_reason": NSNull()]]])
            let last = try MCPJSON.string(["choices": [["delta": [String: String](),
                                                         "finish_reason": completed ? "stop" : "tool_calls"]]])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: \(first)\n\ndata: \(last)\n\ndata: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
