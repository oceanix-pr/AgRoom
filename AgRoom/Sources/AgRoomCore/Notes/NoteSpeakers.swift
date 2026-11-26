import Foundation
import AVFoundation
@preconcurrency import SherpaOnnx
import GRDB

public struct NoteVoiceprint: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var embedding: [Float]
    public var modelID: String
    public var sampleCount: Int?
    public init(name: String, embedding: [Float], modelID: String) { self.name = name; self.embedding = embedding; self.modelID = modelID; self.sampleCount = 1 }
}
public struct NoteSpeakerTurn: Codable, Sendable {
    public let start: Double
    public let end: Double
    public let speaker: Int
}
public struct NoteSpeakerResult: Codable, Sendable {
    public let turns: [NoteSpeakerTurn]
    public let embeddings: [Int: [Float]]
    public let modelID: String
}
public enum NoteVoiceprintMath {
    public static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty, vector.count <= 4096, vector.allSatisfy(\.isFinite) else { return [] }
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { return [] }
        return vector.map { Float(Double($0) / norm) }
    }
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, x.count == y.count else { return -1 }
        return zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
    }
    public static func match(_ vector: [Float], modelID: String, in records: [NoteVoiceprint]) -> NoteVoiceprint? {
        let scored = NoteSpeakerRefinement.collapsed(records.filter { $0.modelID == modelID }).map { ($0, cosine(vector, $0.embedding)) }.sorted { $0.1 > $1.1 }
        guard let first = scored.first, first.1 >= 0.5,
              scored.count == 1 || first.1 - scored[1].1 >= 0.05 else { return nil }
        return first.0
    }
    public static func apply(_ result: NoteSpeakerResult, to segments: [NoteSegment], voices: [NoteVoiceprint]) -> [NoteSegment] {
        let names = NoteSpeakerRefinement.identify(result.embeddings, modelID: result.modelID, records: voices)
        return segments.enumerated().map { index, segment in
            var copy = segment
            let end = segment.endTimestamp ?? (index + 1 < segments.count ? segments[index + 1].timestamp : segment.timestamp + 0.01)
            let candidates = result.turns.map { ($0,max(0,min(end,$0.end) - max(segment.timestamp,$0.start))) }.filter { $0.1 > 0 }
            if let turn = candidates.max(by: { $0.1 == $1.1 ? $0.0.speaker > $1.0.speaker : $0.1 < $1.1 })?.0 { copy.speaker = names[turn.speaker] ?? "SPEAKER_\(turn.speaker + 1)" }
            return copy
        }
    }

}

extension NoteStore {
    static func createVoiceprintSchema(_ db: Database) throws {
        try db.create(table: "note_voiceprints", ifNotExists: true) { table in
            table.column("id", .text).primaryKey(); table.column("contents", .blob).notNull()
        }
    }
    public func voiceprints() async throws -> [NoteVoiceprint] {
        try await queue.read { db in
            try Data.fetchAll(db, sql: "SELECT contents FROM note_voiceprints ORDER BY id LIMIT 1000").map { try cipher.decode(NoteVoiceprint.self, from: $0, table: "note_voiceprints") }
        }
    }
    public func saveVoiceprint(_ record: NoteVoiceprint) async throws {
        try await queue.maintenanceWrite { db in try persistVoiceprint(record, in: db) }
    }
    func persistVoiceprint(_ record: NoteVoiceprint, in db: Database) throws {
        guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.name.count <= 200,
              !record.modelID.isEmpty, !NoteVoiceprintMath.normalize(record.embedding).isEmpty else { throw NoteStoreError.invalidContent }
        var normalized = record; normalized.embedding = NoteVoiceprintMath.normalize(record.embedding)
        let data = try cipher.encode(normalized, table: "note_voiceprints")
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM note_voiceprints") ?? 0
        let exists = try Int.fetchOne(db, sql: "SELECT count(*) FROM note_voiceprints WHERE id = ?", arguments: [record.id.uuidString]) == 1
        guard count < 1000 || exists else { throw NoteStoreError.tooLarge }
        try db.execute(sql: "INSERT INTO note_voiceprints (id, contents) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET contents=excluded.contents", arguments: [record.id.uuidString, data])
    }
    public func deleteVoiceprint(id: UUID) async throws {
        try await queue.maintenanceWrite { db in try db.execute(sql: "DELETE FROM note_voiceprints WHERE id = ?", arguments: [id.uuidString]) }
    }
}

/// Bounded native calls, no UI or shared content cache. Long recordings use five
/// minute windows with overlap and embedding-based identity across windows.
public actor NoteSpeakerAnalyzer {
    private var busy = false
    public init() {}
    public func analyze(url: URL, modelFolder: URL, precision: NoteSpeakerPrecision = .standard, threads: Int = 2, progress: @escaping @Sendable (Double) async -> Void) async throws -> NoteSpeakerResult {
        guard !busy else { throw NoteStoreError.conflict }; busy = true; defer { busy = false }
        let ticket = try await NoteInferenceGate.shared.acquire()
        defer { Task { await NoteInferenceGate.shared.release(ticket) } }
        let segmentation = modelFolder.appendingPathComponent("segmentation.onnx"), embedding = modelFolder.appendingPathComponent("embedding.onnx")
        _ = try NoteCaptureRecovery.read(segmentation, maximum: 128 * 1024 * 1024)
        let modelID = NoteMediaTranscriber.sourceHash(try NoteCaptureRecovery.read(embedding, maximum: 128 * 1024 * 1024))
        let cpu = min(16,max(1,threads))
        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: segmentation.path,windowShiftRatio: precision.shift),numThreads: cpu),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(model: embedding.path,numThreads: cpu),
            clustering: sherpaOnnxFastClusteringConfig(numClusters: -1))
        let engine = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
        var embeddingConfig = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: embedding.path,numThreads: cpu)
        let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &embeddingConfig)
        guard engine.impl != nil, extractor.impl != nil, engine.sampleRate == 16_000 else { throw NoteStoreError.invalidContent }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 28_800 else { throw NoteStoreError.tooLarge }
        let window = precision.seconds, count = Int(ceil(duration / window))
        var global: [Int:[Float]] = [:], weights: [Int:Double] = [:], turns: [NoteSpeakerTurn] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let nominal = Double(index) * window, start = max(0,nominal - precision.overlap), end = min(duration,nominal + window)
            let samples = try await Self.samples(url: url,start: start,duration: end - start)
            let raw = engine.process(samples: samples).filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && Double($0.end) <= end - start + 1 }
            let localTurns = raw.map { NoteSpeakerTurn(start: Double($0.start),end: Double($0.end),speaker: $0.speaker) }
            var embeddings: [Int:[Float]] = [:]
            for speaker in Set(localTurns.map(\.speaker)).sorted() {
                let chosen = localTurns.filter { $0.speaker == speaker && $0.end - $0.start >= 1.5 }.sorted { $0.end - $0.start > $1.end - $1.start }.prefix(30)
                var vectors: [([Float],Float)] = []
                for range in chosen {
                    try Task.checkCancellation()
                    let lower = max(0,min(samples.count,Int(range.start * 16_000))), upper = max(0,min(samples.count,Int(range.end * 16_000)))
                    guard upper - lower >= 24_000 else { continue }
                    let stream = extractor.createStream(); stream.acceptWaveform(samples: Array(samples[lower..<upper]),sampleRate: 16_000); stream.inputFinished()
                    if extractor.isReady(stream: stream) { let vector = NoteVoiceprintMath.normalize(extractor.compute(stream: stream)); if !vector.isEmpty { vectors.append((vector,Float(range.end - range.start))) } }
                }
                if let first = vectors.first {
                    let valid = vectors.filter { $0.0.count == first.0.count }, total = vectors.reduce(0) { $0 + $1.1 }
                    embeddings[speaker] = NoteVoiceprintMath.normalize(first.0.indices.map { dimension in valid.reduce(0) { $0 + $1.0[dimension] * $1.1 } / max(0.01,total) })
                }
            }
            let local = NoteSpeakerRefinement.refine(.init(turns: localTurns,embeddings: embeddings,modelID: modelID))
            var identities: [Int:Int] = [:], claimed = Set<Int>()
            for speaker in Set(local.turns.map(\.speaker)).sorted() {
                let centroid = local.embeddings[speaker] ?? [], weight = local.turns.filter { $0.speaker == speaker }.reduce(0) { $0 + $1.end - $1.start }
                let scores = global.filter { !claimed.contains($0.key) }.map { ($0.key,NoteVoiceprintMath.cosine($0.value,centroid)) }.sorted { $0.1 > $1.1 }
                let id: Int
                if let best = scores.first, best.1 >= 0.55, scores.count == 1 || best.1 - scores[1].1 >= 0.05 { id = best.0 }
                else { id = (global.keys.max() ?? -1) + 1 }
                if let old = global[id], old.count == centroid.count, !centroid.isEmpty {
                    let oldWeight = weights[id,default: 0]
                    global[id] = NoteVoiceprintMath.normalize(zip(old,centroid).map { ($0 * Float(oldWeight) + $1 * Float(weight)) / Float(max(0.01,oldWeight + weight)) })
                } else { global[id] = centroid }
                weights[id,default: 0] += weight; identities[speaker] = id; claimed.insert(id)
            }
            for turn in local.turns {
                let lower = max(nominal,start + turn.start), upper = min(end,start + turn.end)
                if upper > lower, let speaker = identities[turn.speaker] { turns.append(.init(start: lower,end: upper,speaker: speaker)) }
            }
            await progress(Double(index + 1) / Double(count))
        }
        return NoteSpeakerRefinement.refine(.init(turns: turns.sorted { $0.start < $1.start },embeddings: global,modelID: modelID))
    }
    static func samples(url: URL, start: Double, duration: Double) async throws -> [Float] {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 1260 else { throw NoteStoreError.invalidContent }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw NoteStoreError.missing }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); guard reader.startReading() else { throw NoteStoreError.invalidContent }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let data = CMSampleBufferGetDataBuffer(sample) else { throw NoteStoreError.invalidContent }
            let bytes = CMBlockBufferGetDataLength(data)
            guard bytes % 4 == 0, samples.count + bytes / 4 <= 20_200_000 else { throw NoteStoreError.tooLarge }
            var chunk = [Float](repeating: 0, count: bytes / 4)
            let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard status == noErr, chunk.allSatisfy(\.isFinite) else { throw NoteStoreError.invalidContent }
            samples.append(contentsOf: chunk)
        }
        guard reader.status == .completed, !samples.isEmpty else { throw NoteStoreError.invalidContent }
        return samples
    }
}
