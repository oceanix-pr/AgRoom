import Foundation
import Testing
import AVFoundation
import GRDB
@testable import AgRoomCore

struct NoteTranscriptionTests {
    private func store() throws -> NoteStore {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return NoteStore(databaseQueue: queue)
    }
    private func media(_ store: NoteStore) async throws -> NoteMedia {
        let note = try await store.save(WorkNote(title: "Synthetic"))
        try await store.addMedia(noteID: note.id, name: "synthetic.mov", data: Data([1]))
        return try #require(try await store.media(noteID: note.id).first)
    }

    @Test func normalizationAndDictionary() throws {
        let settings = NoteTranscriptionSettings(normalization: "simplified", dictionary: "軟體=软件\n软体工程=开发\n开发=研发")
        // Normalize first, choose longest source, never cascade the replacement.
        #expect(try settings.apply(to: "軟體工程和开发") == "开发和研发")
        #expect(try NoteTranscriptionSettings(normalization: "traditional").apply(to: "会议记录") == "會議記錄")
        #expect(throws: NoteStoreError.invalidContent) { try NoteTranscriptionSettings(dictionary: "a=b\na=c").validate() }
        #expect(throws: NoteStoreError.invalidContent) { try NoteTranscriptionSettings(dictionary: "bad row").validate() }
        #expect(try NoteTranscriptionSettings(dictionary: "a+=dollar$1").apply(to: "a+") == "dollar$1")
    }

    @Test func cancellationResumeAndTimestamps() async throws {
        let store = try store(), media = try await media(store)
        let calls = SliceCalls()
        let interrupted = NoteMediaTranscriber(duration: { _ in 125 }, recognize: { _, start, _, _ in
            await calls.add(start)
            if start == 50 { throw CancellationError() }
            return NoteTranscriptionChunk(text: "first", segments: [NoteSegment(timestamp: 1, text: "first")])
        })
        await #expect(throws: CancellationError.self) {
            try await interrupted.transcribe(url: URL(fileURLWithPath: "/unused"), mediaID: media.id, sourceHash: "same", settings: .init(), store: store, progress: { _, _ in })
        }
        let resumed = NoteMediaTranscriber(duration: { _ in 125 }, recognize: { _, start, _, _ in
            await calls.add(start)
            return NoteTranscriptionChunk(text: "next", segments: [NoteSegment(timestamp: 2, text: "next")])
        })
        let result = try await resumed.transcribe(url: URL(fileURLWithPath: "/unused"), mediaID: media.id, sourceHash: "same", settings: .init(), store: store, progress: { _, _ in })
        #expect(await calls.values == [0, 50, 50, 100])
        #expect(result.segments.map(\.timestamp) == [1, 52, 102])
        #expect(result.text == "first\nnext\nnext")
        _ = try await resumed.transcribe(url: URL(fileURLWithPath: "/unused"), mediaID: media.id, sourceHash: "same", settings: .init(), store: store, progress: { _, _ in })
        #expect(await calls.values == [0, 50, 50, 100])
    }

    @Test func sourceAndSettingsInvalidateAndGenerationRejectsLateWrite() async throws {
        let store = try store(), media = try await media(store)
        var first = try await store.beginTranscription(mediaID: media.id, sourceHash: "one", settings: .init())
        first.chunks.append(NoteTranscriptionChunk(text: "old", segments: []))
        try await store.saveTranscriptionCheckpoint(first)
        let second = try await store.beginTranscription(mediaID: media.id, sourceHash: "one", settings: .init())
        #expect(second.chunks.count == 1)
        await #expect(throws: NoteStoreError.conflict) { try await store.saveTranscriptionCheckpoint(first) }
        let changed = try await store.beginTranscription(mediaID: media.id, sourceHash: "two", settings: .init())
        #expect(changed.chunks.isEmpty)
        let settings = try await store.beginTranscription(mediaID: media.id, sourceHash: "one", settings: .init(dictionary: "old=new"))
        #expect(settings.chunks.isEmpty)
        let other = try self.store()
        await #expect(throws: (any Error).self) { try await other.beginTranscription(mediaID: media.id, sourceHash: "one", settings: .init()) }
    }

    @Test func subtitleExportAndRealAudioSlicing() async throws {
        let text = NoteSubtitleExporter.srt([NoteSegment(timestamp: 65.125, speaker: "A", text: "hello"), NoteSegment(timestamp: 0, text: "start")])
        #expect(text.contains("00:00:00,000 --> 00:01:05,125"))
        #expect(text.contains("00:01:05,125 --> 00:01:08,125\nA: hello"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav"), output = root.appendingPathComponent("slice.m4a")
        try Self.writeSilence(source)
        try await NoteMediaTranscriber.exportAudioSlice(source: source, target: output, start: 1, length: 1)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1) < 0.15)
    }

    private static func writeSilence(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        if let samples = buffer.floatChannelData { samples[0].initialize(repeating: 0, count: 48_000) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private actor SliceCalls {
    var values: [Double] = []
    func add(_ value: Double) { values.append(value) }
}
