import Foundation
import GRDB

public struct NoteCaptureReport: Codable, Sendable, Identifiable {
    public let id: UUID
    public let noteID: UUID
    public let startedAt: Date
    public let fragments: Int
    public let repaired: Int
    public let echoReduced: Int
    public let issues: [String]
}
extension NoteStore {
    static func createCaptureReportSchema(_ db: Database) throws {
        try db.create(table: "note_capture_reports", ifNotExists: true) { table in
            table.column("id", .text).primaryKey(); table.column("noteID", .text).notNull().references("notes", onDelete: .cascade)
            table.column("contents", .blob).notNull()
        }
    }
    func saveCaptureReport(_ report: NoteCaptureReport) async throws {
        try await queue.maintenanceWrite { db in
            try db.execute(sql: "INSERT INTO note_capture_reports (id,noteID,contents) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET contents=excluded.contents", arguments: [report.id.uuidString,report.noteID.uuidString,try cipher.encode(report, table: "note_capture_reports")])
        }
    }
    public func captureReports(noteID: UUID) async throws -> [NoteCaptureReport] {
        try await queue.read { db in try Data.fetchAll(db, sql: "SELECT contents FROM note_capture_reports WHERE noteID=? ORDER BY rowid DESC LIMIT 100", arguments: [noteID.uuidString]).map { try cipher.decode(NoteCaptureReport.self, from: $0, table: "note_capture_reports") } }
    }
}
