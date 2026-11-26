import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Manual provider order")
struct ProviderOrderingTests {
    private func queue(path: String = ":memory:") throws -> DatabaseQueue {
        let database = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareGlobal(database)
        return database
    }

    private func config(_ name: String, enabled: Bool = true, id: UUID = UUID()) -> LLMProviderConfig {
        var value = LLMProviderConfig(id: id, name: name, endpoint: "https://provider-order.invalid/v1/chat/completions",
                                      model: name + "-model", isEnabled: enabled, alias: name + " alias")
        value.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        return value
    }

    @Test("Migration preserves historical creation order and insertion order for tied dates")
    func migration() async throws {
        let database = try queue(), service = ProviderConfigService(databaseQueue: database)
        var late = config("Late")
        var first = config("First tie", id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!)
        var second = config("Second tie", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        late.createdAt = Date(timeIntervalSince1970: 300)
        first.createdAt = Date(timeIntervalSince1970: 100); second.createdAt = first.createdAt
        for value in [late, first, second] { try await service.save(value, apiKey: nil) }
        try await database.write { db in
            try db.execute(sql: "ALTER TABLE llm_providers DROP COLUMN sortOrder")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v3_llm_providers_order'")
        }
        try DatabaseBootstrap.prepareGlobal(database)
        #expect(try await service.getAll() == [first, second, late])
        _ = try await service.move(id: late.id, direction: .up)
        try DatabaseBootstrap.prepareGlobal(database)
        #expect(try await service.getAll() == [first, late, second])
    }

    @Test("Manual order survives reopen and edits; new models append and boundary moves are harmless")
    func persistenceAndEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-order-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("global.sqlite").path
        let database = try queue(path: path), service = ProviderConfigService(databaseQueue: database)
        var first = config("First")
        let disabled = config("Disabled", enabled: false), last = config("Last")
        for value in [first, disabled, last] { try await service.save(value, apiKey: nil) }
        #expect(try await service.move(id: last.id, direction: .up).map(\.id) == [first.id, last.id, disabled.id])
        #expect(try await service.move(id: last.id, direction: .up).map(\.id) == [last.id, first.id, disabled.id])
        first.alias = "Edited alias"; first.model = "edited-model"
        try await service.save(first, apiKey: nil)
        var added = config("Added"); added.createdAt = Date(timeIntervalSince1970: 0)
        try await service.save(added, apiKey: nil)
        let reopened = try queue(path: path), restored = ProviderConfigService(databaseQueue: reopened)
        let expected = [last, first, disabled, added]
        #expect(try await restored.getAll() == expected)
        #expect(try await restored.getAll().filter(\.isEnabled).map(\.id) == [last.id, first.id, added.id])
        #expect(try await restored.move(id: last.id, direction: .up) == expected)
        #expect(try await restored.move(id: added.id, direction: .down) == expected)
    }

    @Test("Relative moves preserve concurrent additions and edits, and stale rows cannot change order")
    func staleList() async throws {
        let database = try queue(), service = ProviderConfigService(databaseQueue: database)
        let first = config("First"), third = config("Third")
        var second = config("Second")
        for value in [first, second] { try await service.save(value, apiKey: nil) }
        _ = try await service.getAll() // The settings snapshot predates this addition and edit.
        try await service.save(third, apiKey: nil)
        second.alias = "Updated elsewhere"; try await service.save(second, apiKey: nil)
        #expect(try await service.move(id: first.id, direction: .down) == [second, first, third])
        try await database.write { db in
            try db.execute(sql: "DELETE FROM llm_providers WHERE id=?", arguments: [first.id.uuidString])
        }
        await #expect(throws: ProviderConfigService.OrderingError.self) { _ = try await service.move(id: first.id, direction: .up) }
        #expect(try await service.getAll() == [second, third])
    }

    @Test("A failed write rolls back the entire move and can be retried")
    func failedSave() async throws {
        let database = try queue(), service = ProviderConfigService(databaseQueue: database)
        let first = config("First"), second = config("Second"), third = config("Third")
        for value in [first, second, third] { try await service.save(value, apiKey: nil) }
        try await database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_order BEFORE UPDATE OF sortOrder ON llm_providers WHEN OLD.name='Second' BEGIN SELECT RAISE(FAIL,'fixture'); END")
        }
        await #expect(throws: (any Error).self) { _ = try await service.move(id: third.id, direction: .up) }
        #expect(try await service.getAll() == [first, second, third])
        try await database.write { try $0.execute(sql: "DROP TRIGGER fail_order") }
        #expect(try await service.move(id: third.id, direction: .up) == [first, third, second])
    }
}
