// Adapted from Memonta (MIT); see application Notices/Memonta-MIT.txt.
import Foundation
import Speech
import AVFoundation

public enum NoteSystemSpeech {
    public static var available: Bool { if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }; return false }
    public static func installed(locale: String) async -> Bool {
        if #available(macOS 26, *), let language = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) {
            return await AssetInventory.status(forModules: [SpeechTranscriber(locale: language,preset: .transcription)]) == .installed
        }
        return false
    }
    public static func prepare(locale: String) async throws {
        guard #available(macOS 26, *), let language = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else { throw TranscriptionService.TranscriptionError.recognizerUnavailable }
        let transcriber = SpeechTranscriber(locale: language,preset: .transcription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
    }
    static func transcribe(_ file: URL, locale: String) async throws -> NoteTranscriptionChunk {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let language = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else { throw TranscriptionService.TranscriptionError.recognizerUnavailable }
        guard await TranscriptionService.requestAuthorization() else { throw TranscriptionService.TranscriptionError.notAuthorized }
        let ticket = try await NoteInferenceGate.shared.acquire()
        let transcriber = SpeechTranscriber(locale: language,preset: .transcription), collector = NoteSpeechCollector()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await prepare(locale: language.identifier)
            try await withTaskCancellationHandler {
                try await TaskDeadline.run(until: Date().addingTimeInterval(300)) {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { let input = try AVAudioFile(forReading: file); try await analyzer.start(inputAudioFile: input, finishAfterFile: true) }
                        group.addTask {
                            for try await result in transcriber.results {
                                try Task.checkCancellation()
                                guard result.isFinal else { continue }
                                let start = result.range.start.seconds, end = result.range.end.seconds
                                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !text.isEmpty, start.isFinite, end.isFinite, start >= 0, end >= start { await collector.append(.init(timestamp: start,endTimestamp: end,text: text)) }
                            }
                        }
                        try await group.waitForAll()
                    }
                }
            } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
            let segments = await collector.snapshot()
            await NoteInferenceGate.shared.release(ticket)
            return .init(text: segments.map(\.text).joined(separator: "\n"), segments: segments)
        } catch {
            await analyzer.cancelAndFinishNow()
            await NoteInferenceGate.shared.release(ticket)
            throw error
        }
    }
}
private actor NoteSpeechCollector {
    private var segments: [NoteSegment] = []
    func append(_ segment: NoteSegment) { segments.append(segment) }
    func snapshot() -> [NoteSegment] { segments.sorted { $0.timestamp < $1.timestamp } }
}
