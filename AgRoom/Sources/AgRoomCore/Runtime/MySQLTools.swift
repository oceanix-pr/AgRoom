import Foundation

/// The same native connector backs chat tools and declared app capabilities.
struct MySQLConnectionsTool: DispatcherTool {
    let service: MySQLConnectorService
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var definition: ToolDefinition {
        .init(name: "mysql_connections", description: "List this space's host-managed MySQL connections, without credentials. Configure connections in the Database page; apps select them through a host resource picker.", parametersSchemaJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#)
    }
    func execute(argumentsJSON: String) async throws -> String {
        let summaries = try await service.connections().map {
            ["id": $0.id.uuidString, "name": $0.name, "host": $0.host, "database": $0.database]
        }
        return String(decoding: try JSONEncoder().encode(summaries), as: UTF8.self)
    }
}

struct MySQLMetadataTool: DispatcherTool {
    let service: MySQLConnectorService
    let configurations: [MySQLConnectionConfig]
    var requiresConfirmation: Bool { true }
    var permissionClass: PermissionClass { .externalEffect }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    var definition: ToolDefinition {
        .init(name: "mysql_metadata", description: "Read MySQL metadata using a host-managed connection in this space. Omit table to list tables; provide table to read columns. Only parameterized information_schema reads are available. No arbitrary SQL, credentials or Python networking. A fresh user approval is required.", parametersSchemaJSON: #"{"type":"object","properties":{"connection":{"type":"string","description":"Connection id from mysql_connections"},"table":{"type":"string"}},"required":["connection"],"additionalProperties":false}"#)
    }
    private func config(_ arguments: String) -> MySQLConnectionConfig? {
        let id = ToolArguments.string(ToolArguments.parse(arguments), "connection")
        return configurations.first { $0.id.uuidString == id }
    }
    func executionAuthorizationKey(argumentsJSON: String) -> String? {
        guard let config = config(argumentsJSON) else { return nil }
        return NativeAppDisk.digest(Data((service.space.rawValue + config.id.uuidString + config.revision.uuidString + argumentsJSON).utf8))
    }
    func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        guard let config = config(argumentsJSON) else { return nil }
        return .init(executionKind: .other,
            resourceAccess: .init(readable: [config.database], verified: true),
            network: .init(allowed: true, detail: "\(config.host):\(config.port)"), childProcesses: .init(allowed: false),
            reasonCode: "other", constraintSources: ["space", "mode"],
            executionDetails: [config.name, "\(config.host):\(config.port) / \(config.database)", "TLS=\(config.requiresTLS)", argumentsJSON])
    }
    func execute(argumentsJSON: String) async throws -> String {
        guard let config = config(argumentsJSON) else { throw MySQLConnectorError(.changed) }
        let table = ToolArguments.string(ToolArguments.parse(argumentsJSON), "table")
        let result = try await service.metadata(config, table: table.isEmpty ? nil : table)
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}
