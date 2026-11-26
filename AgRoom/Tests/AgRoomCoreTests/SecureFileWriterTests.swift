import Testing
import Foundation
@testable import AgRoomCore

@Suite("SecureFileWriter")
struct SecureFileWriterTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("secure-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("writes nested paths atomically and creates parent directories")
    func normalWrite() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("a/b/note.txt")
        try SecureFileWriter.write("one", to: target, root: root)
        #expect(try String(contentsOf: target, encoding: .utf8) == "one")
        try SecureFileWriter.write("two", to: target, root: root)
        #expect(try String(contentsOf: target, encoding: .utf8) == "two")
    }

    @Test("refuses a parent directory replaced by an escaping symlink")
    func symlinkEscape() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        do {
            try SecureFileWriter.write(
                "leak",
                to: root.appendingPathComponent("escape/leak.txt"),
                root: root
            )
            Issue.record("secure writer should reject a symlink parent")
        } catch {
            // expected
        }
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("leak.txt").path
        ))
    }
}
