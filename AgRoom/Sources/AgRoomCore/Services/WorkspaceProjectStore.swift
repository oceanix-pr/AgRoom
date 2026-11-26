import Foundation
import GRDB

public final class WorkspaceProjectStore: Sendable {
    public static let didChange = Notification.Name("agroom.workspaceProjectChanged")
    private let queue: DatabaseQueue
    public let space: AppSpace
    public init(databaseQueue: DatabaseQueue, space: AppSpace) { queue = databaseQueue; self.space = space }
    static func createSchema(_ db: Database) throws {
        try db.create(table: "workspace_projects", ifNotExists: true) { table in
            table.column("workspaceID", .text).primaryKey()
            table.column("revision", .text).notNull()
            table.column("configuration", .blob).notNull()
        }
    }
    public func project(workspaceID: UUID) async throws -> WorkspaceProject? {
        let space = space
        return try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workspace_projects WHERE workspaceID=?", arguments: [workspaceID.uuidString]) else { return nil }
            let data: Data = row["configuration"], raw: String = row["revision"]
            guard let configuration = try? JSONDecoder().decode(WorkspaceProjectConfiguration.self, from: data),
                  configuration.isValid, let revision = UUID(uuidString: raw) else { throw WorkspaceProjectError.invalid }
            return WorkspaceProject(space: space, workspaceID: workspaceID, revision: revision, configuration: configuration)
        }
    }
    @discardableResult
    public func save(_ configuration: WorkspaceProjectConfiguration, workspaceID: UUID, expectedRevision: UUID?) async throws -> WorkspaceProject {
        guard configuration.isValid else { throw WorkspaceProjectError.invalid }
        let data = try JSONEncoder().encode(configuration), revision = UUID()
        try await queue.maintenanceWrite { db in
            let current = try String.fetchOne(db, sql: "SELECT revision FROM workspace_projects WHERE workspaceID=?", arguments: [workspaceID.uuidString])
            guard current == expectedRevision?.uuidString else { throw WorkspaceProjectError.changed }
            try db.execute(sql: "INSERT INTO workspace_projects(workspaceID,revision,configuration) VALUES(?,?,?) ON CONFLICT(workspaceID) DO UPDATE SET revision=excluded.revision,configuration=excluded.configuration",
                arguments: [workspaceID.uuidString, revision.uuidString, data])
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didChange, object: space.rawValue) }
        return WorkspaceProject(space: space, workspaceID: workspaceID, revision: revision, configuration: configuration)
    }
    public func context(workspaceID: UUID, excludesMemory: Bool = false) async throws -> RunResourceContext {
        try await RunResourceContext(space: space, workspaceID: workspaceID, project: project(workspaceID: workspaceID), excludesMemory: excludesMemory)
    }
}
