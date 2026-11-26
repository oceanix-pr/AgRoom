import Foundation
import Testing
@testable import AgRoomCore

@Suite("Recoverable app drafts")
struct NativeAppDraftTests {
    @Test("Restart restores source and definition; replay is idempotent and spaces stay separate")
    func restartAndIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = NativeAppDraftStore(directoryURL: root.appendingPathComponent("personal/app-drafts"), space: .personal)
        let work = NativeAppDraftStore(directoryURL: root.appendingPathComponent("work/app-drafts"), space: .work)
        let definition = try NativeAppTemplates.note(), sessionID = UUID()
        let first = try await personal.save(definition, sourceSessionID: sessionID)
        let replay = try await personal.save(definition, sourceSessionID: sessionID)
        #expect(first == replay)
        let restarted = NativeAppDraftStore(directoryURL: personal.directoryURL, space: .personal)
        #expect(try await restarted.catalog().drafts == [first])
        #expect(first.sourceSessionID == sessionID)
        #expect(try await work.catalog().drafts.isEmpty)
        let wrongSpace = NativeAppDraftStore(directoryURL: personal.directoryURL, space: .work)
        #expect(try await wrongSpace.catalog().drafts.isEmpty)
        #expect(try await wrongSpace.catalog().invalidIDs == [first.id])
        try await restarted.discard(id: first.id)
        #expect(try await restarted.catalog().drafts.isEmpty)
    }

    @Test("Corrupt files remain recoverable and cannot be silently overwritten")
    func corruptDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppDraftStore(directoryURL: root, space: .work)
        let definition = try NativeAppTemplates.note()
        let draft = try await store.save(definition)
        let file = root.appendingPathComponent(draft.id.uuidString.lowercased() + ".draft.json")
        let broken = Data("broken but retained".utf8)
        try broken.write(to: file)
        #expect(try await store.catalog().invalidIDs == [draft.id])
        await #expect(throws: (any Error).self) { _ = try await store.save(definition) }
        #expect(try Data(contentsOf: file) == broken)
    }

    @Test("Capacity rejects a new draft while still allowing replay and explicit discard")
    func boundedStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppDraftStore(directoryURL: root, space: .personal)
        let definition = try NativeAppTemplates.note()
        let first = try await store.save(definition)
        for _ in 1..<8 { try await store.save(definition, sourceSessionID: UUID()) }
        #expect(try await store.save(definition) == first)
        await #expect(throws: NativeAppError.self) { try await store.save(definition, sourceSessionID: UUID()) }
        try await store.discard(id: first.id)
        try await store.save(definition, sourceSessionID: UUID())
        #expect(try await store.catalog().drafts.count == 8)
    }

    @Test("A linked draft root cannot read or modify another directory")
    func linkedRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"), link = root.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = NativeAppDraftStore(directoryURL: link, space: .work)
        await #expect(throws: NativeAppError.self) { try await store.save(NativeAppTemplates.note()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
