import Foundation
import AVFoundation
import CryptoKit
import GRDB

public struct NoteTranscriptionSettings: Codable, Sendable, Equatable {
    public var redactText: Bool?
    public var privateTerms: String?
    public var engine: String?
    public var visualTextOnly: Bool?
    public var diarizationBookmark: Data?
    public var diarizationEnabled: Bool?
    public var diarizationPrecision: Int?
    public var diarizationThreads: Int?
    public var locale: String
    /// none / simplified / traditional
    public var normalization: String
    public var whisperBookmark: Data?
    public var whisperIdentity: String?
    public var cloudModel: String?
    public var providerIdentity: String?
    public var cloudProviderID: UUID?
    public var dictionary: String
    public init(locale: String = "zh-CN", normalization: String = "none", dictionary: String = "") {
        self.locale = locale; self.normalization = normalization; self.dictionary = dictionary
    }

    public var effectiveEngine: String { engine ?? (cloudModel == nil ? "system" : "cloud") }

    public func recognitionMatches(_ other: Self) -> Bool {
        effectiveEngine == other.effectiveEngine && locale == other.locale && normalization == other.normalization &&
        dictionary == other.dictionary && cloudModel == other.cloudModel && providerIdentity == other.providerIdentity &&
        whisperIdentity == other.whisperIdentity
    }

    public func validate() throws {
        guard ["system", "cloud", "whisper"].contains(effectiveEngine), ["none", "simplified", "traditional"].contains(normalization),
              dictionary.utf8.count <= 32_768, locale.count <= 64,
              cloudModel.map({ !$0.isEmpty && $0.count <= 200 && !$0.contains(where: { $0.isNewline }) }) != false else { throw NoteStoreError.invalidContent }
        guard (privateTerms?.utf8.count ?? 0) <= 32_768, (privateTerms?.components(separatedBy: .newlines).count ?? 0) <= 500,
              (whisperBookmark?.count ?? 0) <= 65_536, (diarizationBookmark?.count ?? 0) <= 65_536 else { throw NoteStoreError.tooLarge }
        _ = try replacements()
    }

    private func replacements() throws -> [(String, String)] { try NoteTranscriptDictionary(dictionary).replacements }

    public func apply(to text: String) throws -> String {
        var normalized = text
        if normalization != "none" {
            normalized = (text as NSString).applyingTransform(StringTransform(normalization == "simplified" ? "Traditional-Simplified" : "Simplified-Traditional"), reverse: false) ?? text
        }
        return try NoteTranscriptDictionary(dictionary).apply(normalized)
    }

}

public struct NoteTranscriptionChunk: Codable, Sendable, Equatable {
    public let text: String
    public let segments: [NoteSegment]
    public init(text: String, segments: [NoteSegment]) { self.text = text; self.segments = segments }
}

public struct NoteTranscriptionCheckpoint: Codable, Sendable, Equatable {
    public let generation: UUID
    public let mediaID: UUID
    public let sourceHash: String
    public let settings: NoteTranscriptionSettings
    public var chunks: [NoteTranscriptionChunk]
}

extension NoteStore {
    static func createTranscriptionSchema(_ db: Database) throws {
        try db.create(table: "note_transcription_checkpoints", ifNotExists: true) { t in
            t.column("mediaID", .text).primaryKey().references("note_media", onDelete: .cascade)
            t.column("generation", .text).notNull()
            t.column("contents", .blob).notNull()
        }
    }

    /// A fresh generation revokes any late writer. Only identical source bytes and
    /// settings can reuse the prefix; restored or replaced media cannot inherit it.
    public func beginTranscription(mediaID: UUID, sourceHash: String, settings: NoteTranscriptionSettings) async throws -> NoteTranscriptionCheckpoint {
        try settings.validate()
        return try await queue.maintenanceWrite { db in
            let old = try Data.fetchOne(db, sql: "SELECT contents FROM note_transcription_checkpoints WHERE mediaID = ?", arguments: [mediaID.uuidString])
            let previous = try old.map { try cipher.decode(NoteTranscriptionCheckpoint.self, from: $0, table: "note_transcription_checkpoints") }
            let reuse = previous?.mediaID == mediaID && previous?.sourceHash == sourceHash && previous?.settings.recognitionMatches(settings) == true
            let checkpoint = NoteTranscriptionCheckpoint(generation: UUID(), mediaID: mediaID, sourceHash: sourceHash, settings: settings, chunks: reuse ? previous!.chunks : [])
            try db.execute(sql: "INSERT INTO note_transcription_checkpoints (mediaID, generation, contents) VALUES (?, ?, ?) ON CONFLICT(mediaID) DO UPDATE SET generation=excluded.generation, contents=excluded.contents", arguments: [mediaID.uuidString, checkpoint.generation.uuidString, try cipher.encode(checkpoint, table: "note_transcription_checkpoints")])
            return checkpoint
        }
    }

    public func saveTranscriptionCheckpoint(_ checkpoint: NoteTranscriptionCheckpoint) async throws {
        let data = try cipher.encode(checkpoint, table: "note_transcription_checkpoints")
        guard checkpoint.chunks.count <= NoteMediaTranscriber.maximumChunks, data.count <= Self.maximumContentBytes else { throw NoteStoreError.tooLarge }
        try await queue.maintenanceWrite { db in
            try db.execute(sql: "UPDATE note_transcription_checkpoints SET contents = ? WHERE mediaID = ? AND generation = ?", arguments: [data, checkpoint.mediaID.uuidString, checkpoint.generation.uuidString])
            guard db.changesCount == 1 else { throw NoteStoreError.conflict }
        }
    }
}

/// AVFoundation exports a bounded audio slice, including from a video source.
/// The existing Speech service remains the sole recognition implementation.
public struct NoteMediaTranscriber: Sendable {
    public static let chunkSeconds: Double = 50
    public static let maximumChunks = 576 // Eight hours, with bounded checkpoint storage.
    public typealias Recognize = @Sendable (URL, Double, Double, String) async throws -> NoteTranscriptionChunk
    private let duration: @Sendable (URL) async throws -> Double
    private let recognize: Recognize

    public init() {
        duration = { url in try await AVURLAsset(url: url).load(.duration).seconds }
        recognize = Self.recognizeSlice
    }

    public static func cloud(provider: CloudProvider, model: String) -> NoteMediaTranscriber {
        NoteMediaTranscriber(duration: { url in try await AVURLAsset(url: url).load(.duration).seconds }, recognize: { url, start, length, locale in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("slice.m4a")
            try await exportAudioSlice(source: url, target: target, start: start, length: length)
            let data = try NoteCaptureRecovery.read(target, maximum: 25 * 1024 * 1024)
            let result = try await provider.transcribeAudio(data, modelName: model, language: locale)
            return NoteTranscriptionChunk(text: result.text, segments: result.segments.map { NoteSegment(timestamp: $0.timestamp, endTimestamp: $0.endTimestamp, text: $0.text) })
        })
    }

    /// Injection for deterministic cancellation/resume tests without system permissions.
    init(duration: @escaping @Sendable (URL) async throws -> Double, recognize: @escaping Recognize) {
        self.duration = duration; self.recognize = recognize
    }

    public func transcribe(url: URL, mediaID: UUID, sourceHash: String, settings: NoteTranscriptionSettings,
                           store: NoteStore, progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> NoteTranscriptionChunk {
        try settings.validate()
        let seconds = try await duration(url)
        guard seconds.isFinite, seconds > 0, seconds <= Double(Self.maximumChunks) * Self.chunkSeconds else { throw NoteStoreError.tooLarge }
        let count = Int(ceil(seconds / Self.chunkSeconds))
        var checkpoint = try await store.beginTranscription(mediaID: mediaID, sourceHash: sourceHash, settings: settings)
        guard checkpoint.chunks.count <= count else { throw NoteStoreError.invalidContent }
        await progress(checkpoint.chunks.count, count)
        for index in checkpoint.chunks.count..<count {
            try Task.checkCancellation()
            let start = Double(index) * Self.chunkSeconds
            let result = try await recognize(url, start, min(Self.chunkSeconds, seconds - start), settings.locale)
            try Task.checkCancellation()
            let text = try settings.apply(to: result.text)
            let segments = try result.segments.map { segment in
                guard segment.timestamp.isFinite, segment.timestamp >= 0 else { throw NoteStoreError.invalidContent }
                return NoteSegment(timestamp: start + segment.timestamp, endTimestamp: segment.endTimestamp.map { start + $0 }, speaker: segment.speaker, text: try settings.apply(to: segment.text))
            }
            checkpoint.chunks.append(NoteTranscriptionChunk(text: text, segments: segments))
            try await store.saveTranscriptionCheckpoint(checkpoint)
            await progress(index + 1, count)
        }
        try Task.checkCancellation()
        return NoteTranscriptionChunk(text: checkpoint.chunks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n"), segments: checkpoint.chunks.flatMap(\.segments))
    }

    public static func sourceHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func recognizeSlice(url: URL, start: Double, length: Double, locale: String) async throws -> NoteTranscriptionChunk {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("slice.m4a")
        try await exportAudioSlice(source: url, target: target, start: start, length: length)
        try Task.checkCancellation()
        do {
            if NoteSystemSpeech.available { return try await NoteSystemSpeech.transcribe(target, locale: locale) }
            let result = try await TranscriptionService().transcribeFile(at: target, locale: Locale(identifier: locale))
            return NoteTranscriptionChunk(text: result.text, segments: result.segments.map { NoteSegment(timestamp: $0.timestamp, endTimestamp: $0.endTimestamp, text: $0.text) })
        } catch TranscriptionService.TranscriptionError.noResult {
            return NoteTranscriptionChunk(text: "", segments: [])
        }
    }
    static func exportAudioSlice(source: URL, target: URL, start: Double, length: Double) async throws {
        guard start.isFinite, start >= 0, length.isFinite, length > 0, length <= chunkSeconds else { throw NoteStoreError.invalidContent }
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw NoteStoreError.invalidContent }
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        let handle = AudioExportHandle(exporter)
        try await TaskDeadline.run(until: Date().addingTimeInterval(120)) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await handle.exporter.export(to: target, as: .m4a)
            } onCancel: { handle.exporter.cancelExport() }
        }
    }

}

/// AVAssetExportSession supports cancellation from another thread; configuration
/// is complete before the task starts and only its cancellation API is shared.
private final class AudioExportHandle: @unchecked Sendable {
    let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
}
