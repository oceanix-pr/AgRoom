import Foundation

public struct NativeAppCapability: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int
    /// A host picker supplies this resource slot. It is never resolved from model/script arguments.
    public var resource: String?
    public init(name: String, version: Int = 1, resource: String? = nil) {
        self.name = name; self.version = version; self.resource = resource
    }
}

public struct HostCapabilityDescriptor: Codable, Sendable {
    public let name: String
    public let version: Int
    public let inputs: [String: NativeAppValue.ValueType]
    public let outputs: [String: NativeAppValue.ValueType]
    public let tableColumns: [String]?
    public let resourceKind: String?
    public var localizationKey: String { "apps.capability." + name }
}

/// Pure metadata, without providers, service instances, credentials or network discovery.
public enum NativeAppCapabilityCatalog {
    public static let all: [HostCapabilityDescriptor] = [
        .init(name: "knowledge.search", version: 1, inputs: ["query": .string, "offset": .number],
              outputs: ["count": .number, "next-offset": .number], tableColumns: ["name"], resourceKind: nil),
        .init(name: "web.fetch", version: 1, inputs: ["url": .string], outputs: ["text": .string], tableColumns: nil, resourceKind: nil),
        .init(name: "database.tables", version: 1, inputs: [:], outputs: ["count": .number],
              tableColumns: ["name", "comment", "type"], resourceKind: "mysql"),
        .init(name: "database.columns", version: 1, inputs: ["table": .string], outputs: ["count": .number],
              tableColumns: ["name", "type", "nullable", "default-value", "default-is-null", "comment", "column-key", "position", "extra"], resourceKind: "mysql"),
        .init(name: "clipboard.writeText", version: 1, inputs: ["text": .string], outputs: [:], tableColumns: nil, resourceKind: nil)
    ]
    public static func descriptor(_ requirement: NativeAppCapability) -> HostCapabilityDescriptor? {
        all.first { $0.name == requirement.name && $0.version == requirement.version }
    }
}

public struct NativeAppCapabilityCommand: Sendable {
    public let engine: DispatcherEngine
    public let call: ToolCallRaw
    public let receipt: HostCapabilityReceipt
    public let summary: String
}

/// Per-window capability assembly. UI facilities are injected; Core never imports AppKit.
public struct NativeAppCapabilityBridge: Sendable {
    public typealias PlatformHandler = @Sendable (String, [String: NativeAppValue]) async throws -> HostCapabilityResult
    public let space: AppSpace
    public let mysql: MySQLConnectorService?
    private let resources: NativeAppResources?
    private let platform: PlatformHandler?
    private let permissionMode: PermissionMode
    public init(space: AppSpace, resources: NativeAppResources?, mysql: MySQLConnectorService? = nil,
                permissionMode: PermissionMode = .workspaceWrite, platform: PlatformHandler? = nil) {
        self.space = space; self.resources = resources; self.mysql = mysql; self.platform = platform; self.permissionMode = permissionMode
    }
    public func prepare(definition: NativeAppDefinition, workspace: NativeAppWorkspace, actionID: String,
                        inputs: [String: NativeAppValue], connection: MySQLConnectionConfig?) async throws -> NativeAppCapabilityCommand {
        try definition.validate()
        guard workspace.space == space, mysql == nil || mysql?.space == space,
              resources == nil || resources?.space == space,
              let action = definition.actions[actionID], action.type == .callCapability,
              let capability = definition.capabilities?[action.capability ?? ""],
              let descriptor = NativeAppCapabilityCatalog.descriptor(capability),
              Set(inputs.keys) == Set(descriptor.inputs.keys),
              inputs.allSatisfy({ $0.value.isBounded && descriptor.inputs[$0.key] == $0.value.valueType }),
              (descriptor.resourceKind == nil) == (connection == nil) else { throw NativeAppError(.invalidDefinition) }
        try await workspace.validateScriptInstallation(definition)
        if let connection {
            guard let mysql, try await mysql.connection(id: connection.id) == connection else { throw MySQLConnectorError(.changed) }
        }
        if capability.name == "clipboard.writeText", platform == nil { throw NativeAppError(.unavailable) }
        let captured = Invocation(app: definition.id, installation: workspace.identity,
            definition: NativeAppDisk.digest(try definition.encoded()), action: actionID, capability: capability,
            inputs: inputs, connection: connection?.id, revision: connection?.revision)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let arguments = String(decoding: try encoder.encode(captured), as: UTF8.self)
        let receipt = HostCapabilityReceipt()
        let summary = [capability.name, connection.map { "\($0.name) · \($0.host):\($0.port) / \($0.database)" },
                       String(decoding: try encoder.encode(inputs), as: UTF8.self)].compactMap { $0 }.joined(separator: "\n")
        let tool = NativeAppHostTool(name: capability.name, arguments: arguments, summary: summary,
            endpoint: connection.map { "\($0.host):\($0.port)" }, receipt: receipt) {
            try await workspace.validateScriptInstallation(definition)
            try Task.checkCancellation()
            let result = try await invoke(capability.name, inputs: inputs, connection: connection)
            try await workspace.validateScriptInstallation(definition)
            try Task.checkCancellation()
            try result.table?.validate()
            guard Set(result.values.keys) == Set(descriptor.outputs.keys), result.values.allSatisfy({
                $0.value.isBounded && descriptor.outputs[$0.key] == $0.value.valueType
            }), (result.table != nil) == (descriptor.tableColumns != nil),
                result.table == nil || result.table?.columns == descriptor.tableColumns else { throw NativeAppError(.invalidDefinition) }
            return result
        }
        let policy = PermissionPolicy(mode: permissionMode, fileAreaPolicy: nil)
        let runID = UUID()
        let scope = TaskExecutionScope.make(space: space, sessionID: nil, runID: runID, parentRunID: nil,
            workspaceID: workspace.identity, workspacePath: workspace.root.path, readRoots: [workspace.root],
            writeRoots: [], artifactRoots: [], mode: permissionMode, autoReviewEnabled: false,
            policyVersion: "nativeapp-capabilities.v1", userRequest: "Run the installed app's captured, declared capability.")
        let context = ExecutionContext(space: space, runID: runID, permissionPolicy: policy, taskScope: scope, deadline: Date().addingTimeInterval(120))
        return .init(engine: DispatcherEngine(tools: [tool], systemPrompt: "", permissionPolicy: policy, executionContext: context),
            call: ToolCallRaw(id: UUID().uuidString, name: "nativeapp_host_call", argumentsJSON: arguments), receipt: receipt, summary: summary)
    }

    private struct Invocation: Encodable {
        let app: String
        let installation: UUID
        let definition: String
        let action: String
        let capability: NativeAppCapability
        let inputs: [String: NativeAppValue]
        let connection: UUID?
        let revision: UUID?
    }
    private func invoke(_ name: String, inputs: [String: NativeAppValue], connection: MySQLConnectionConfig?) async throws -> HostCapabilityResult {
        switch name {
        case "database.tables", "database.columns":
            guard let mysql, let connection else { throw NativeAppError(.unavailable) }
            let table = try await mysql.metadata(connection, table: name == "database.columns" ? inputs["table"]?.string : nil)
            return .init(values: ["count": .number(Double(table.rows.count))], table: table)
        case "knowledge.search":
            guard let resources, case .number(let offset) = inputs["offset"], offset.isFinite,
                  offset.rounded() == offset, (0...10000).contains(offset) else { throw NativeAppError(.invalidDefinition) }
            let page = try await resources.queryKnowledge(search: inputs["query"]?.string ?? "", offset: Int(offset), limit: 50)
            var rows: [HostDataRow] = []
            for item in page.items {
                let detail = try await resources.knowledgeContent(id: item.id)
                guard !detail.isTruncated else { throw NativeAppScriptError(.inputTruncated) }
                rows.append(.init(id: item.id.uuidString, title: item.title, content: detail.content, fields: ["name": .string(item.title)]))
            }
            return .init(values: ["count": .number(Double(rows.count)), "next-offset": .number(page.hasMore ? offset + Double(rows.count) : -1)],
                table: .init(columns: ["name"], rows: rows, hasMore: page.hasMore, isComplete: offset == 0 && !page.hasMore))
        case "web.fetch":
            return .init(values: ["text": .string(try await WebFetchTool().fetchForApplication(inputs["url"]?.string ?? ""))])
        default:
            guard name == "clipboard.writeText", let platform else { throw NativeAppError(.unavailable) }
            return try await platform(name, inputs)
        }
    }
}

/// Host-defined classification applies to the captured real operation, never to a model supplied tool name.
private struct NativeAppHostTool: DispatcherTool {
    let name: String
    let arguments: String
    let summary: String
    let endpoint: String?
    let receipt: HostCapabilityReceipt
    let operation: @Sendable () async throws -> HostCapabilityResult
    var permissionClass: PermissionClass { name == "knowledge.search" ? .readOnly : .externalEffect }
    var sideEffectClass: ToolSideEffectClass { name == "clipboard.writeText" ? .idempotentWrite : .readOnly }
    var requiresConfirmation: Bool { permissionClass != .readOnly }
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { endpoint != nil || name == "web.fetch" }
    var definition: ToolDefinition { .init(name: "nativeapp_host_call", description: "Perform one captured host capability.", parametersSchemaJSON: #"{"type":"object"}"#) }
    func executionAuthorizationKey(argumentsJSON: String) -> String? {
        argumentsJSON == arguments ? NativeAppDisk.digest(Data(arguments.utf8)) : nil
    }
    func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        .init(executionKind: .other,
            resourceAccess: .init(readable: endpoint.map { [$0] } ?? [], verified: true),
            network: .init(allowed: endpoint != nil || name == "web.fetch", detail: endpoint), childProcesses: .init(allowed: false),
            reasonCode: "other", constraintSources: ["space", "mode"], executionDetails: [summary])
    }
    func execute(argumentsJSON: String) async throws -> String {
        guard argumentsJSON == arguments else { throw NativeAppError(.conflict) }
        do {
            let result = try await operation()
            await receipt.complete(.success(result))
            return "Host capability completed; structured receipt validated."
        } catch {
            await receipt.complete(.failure(error))
            throw error
        }
    }
}
