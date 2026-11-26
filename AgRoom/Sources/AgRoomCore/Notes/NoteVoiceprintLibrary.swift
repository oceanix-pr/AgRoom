import Foundation
import GRDB

public enum NoteVoiceprintError: Error, Sendable, Equatable { case identityConflict, consentRequired }
extension NoteStore {
    static func createSpeakerAnalysisSchema(_ db: Database) throws {
        try db.create(table: "note_speaker_analysis", ifNotExists: true) { t in
            t.column("mediaID", .text).primaryKey().references("note_media", onDelete: .cascade)
            t.column("contents", .blob).notNull()
        }
    }
    public func saveSpeakerAnalysis(_ result: NoteSpeakerResult, mediaID: UUID) async throws {
        let data = try cipher.encode(result,table: "note_speaker_analysis")
        guard data.count <= Self.maximumContentBytes else { throw NoteStoreError.tooLarge }
        try await queue.maintenanceWrite { db in try db.execute(sql: "INSERT INTO note_speaker_analysis (mediaID,contents) VALUES (?,?) ON CONFLICT(mediaID) DO UPDATE SET contents=excluded.contents", arguments: [mediaID.uuidString,data]) }
    }
    public func speakerAnalysis(mediaID: UUID) async throws -> NoteSpeakerResult? {
        try await queue.read { db in try Data.fetchOne(db,sql: "SELECT contents FROM note_speaker_analysis WHERE mediaID = ?",arguments: [mediaID.uuidString]).map { try cipher.decode(NoteSpeakerResult.self,from: $0,table: "note_speaker_analysis") } }
    }
    public func registerVoiceprint(_ record: NoteVoiceprint) async throws {
        try await queue.maintenanceWrite { db in
            let records = try Data.fetchAll(db,sql: "SELECT contents FROM note_voiceprints ORDER BY id").map { try cipher.decode(NoteVoiceprint.self,from: $0,table: "note_voiceprints") }
            var value = record
            if let best = records.filter({ $0.modelID == record.modelID && $0.embedding.count == record.embedding.count }).max(by: { NoteVoiceprintMath.cosine($0.embedding,record.embedding) < NoteVoiceprintMath.cosine($1.embedding,record.embedding) }), NoteVoiceprintMath.cosine(best.embedding,record.embedding) >= 0.65 {
                guard best.name == record.name else { throw NoteVoiceprintError.identityConflict }
                value = NoteSpeakerRefinement.collapsed([best,record])[0]; value.id = best.id
            }
            try persistVoiceprint(value,in: db)
        }
    }
    public func mergeVoiceprintNames() async throws {
        // One transaction publishes the replacement set; no intermediate empty library.
        try await queue.maintenanceWrite { db in
            let records = try Data.fetchAll(db,sql: "SELECT contents FROM note_voiceprints ORDER BY id").map { try cipher.decode(NoteVoiceprint.self,from: $0,table: "note_voiceprints") }
            let merged = NoteSpeakerRefinement.collapsed(records)
            try db.execute(sql: "DELETE FROM note_voiceprints")
            for voice in merged { try db.execute(sql: "INSERT INTO note_voiceprints (id,contents) VALUES (?,?)",arguments: [voice.id.uuidString,try cipher.encode(voice,table: "note_voiceprints")]) }
        }
    }
    public func importLegacyVoiceprints(directory: URL) async throws -> Int {
        try NoteCaptureRecovery.regularDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 1000 else { throw NoteStoreError.tooLarge }
        struct Legacy: Decodable { let name: String; let embedding: [Float]; let modelId: String; var sampleCount: Int? }
        var values: [NoteVoiceprint] = []
        for file in files {
            try Task.checkCancellation()
            let raw = try NoteCaptureRecovery.read(file,maximum: 64 * 1024)
            let old = try JSONDecoder().decode(Legacy.self,from: raw)
            let model = old.modelId == "3dspeaker-eres2net-base-zh-16k" ? "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b" : old.modelId
            var voice = NoteVoiceprint(name: old.name,embedding: old.embedding,modelID: model); voice.sampleCount = old.sampleCount
            guard !voice.name.isEmpty, voice.name.count <= 200, !NoteVoiceprintMath.normalize(voice.embedding).isEmpty else { throw NoteStoreError.invalidContent }
            values.append(voice)
        }
        for value in values { try await registerVoiceprint(value) }
        return values.count
    }
}
