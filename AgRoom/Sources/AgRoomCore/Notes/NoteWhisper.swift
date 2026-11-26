import Foundation
import AVFoundation
@preconcurrency import WhisperKit

/// Instance ownership follows one transcription operation and its fixed space.
/// No audio, transcript or model state is cached in a cross-space singleton.
public actor NoteWhisperEngine {
    private var model: WhisperKit?
    private var busy = false
    private let folder: URL
    public init(folder: URL) { self.folder = folder }
    public func transcribe(url: URL, locale: String) async throws -> NoteTranscriptionChunk {
        guard !busy else { throw NoteStoreError.conflict }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        let ticket = try await NoteInferenceGate.shared.acquire()
        defer { Task { await NoteInferenceGate.shared.release(ticket) } }
        if model == nil {
            model = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                verbose: false, logLevel: .none, prewarm: true, load: true, download: false))
        }
        guard let model else { throw NoteStoreError.missing }
        try Task.checkCancellation()
        let cancellation = CancellationGate()
        let language = locale == "auto" ? nil : locale.split(separator: "-").first.map(String.init)
        let options = DecodingOptions(task: .transcribe, language: language, temperature: 0)
        let result = try await withTaskCancellationHandler {
            try await model.transcribe(audioPath: url.path, decodeOptions: options, callback: { _ in cancellation.isCancelled ? false : nil })
        } onCancel: { cancellation.markCancelled() }
        try Task.checkCancellation()
        let segments = result.flatMap(\.segments).map { segment in
            NoteSegment(timestamp: Double(segment.start), endTimestamp: Double(segment.end), text: Self.clean(segment.text))
        }
        return NoteTranscriptionChunk(text: result.map { Self.clean($0.text) }.joined(separator: "\n"), segments: segments)
    }
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static let variants = ["openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small", "openai_whisper-medium", "openai_whisper-large-v3_turbo", "openai_whisper-large-v3"]
    public static func download(variant: String, to root: URL, endpoint: String = "https://hf-mirror.com", progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard variants.contains(variant), ["https://huggingface.co", "https://hf-mirror.com"].contains(endpoint) else { throw NoteStoreError.invalidContent }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let location = try await WhisperKit.download(variant: variant, downloadBase: root, endpoint: endpoint, progressCallback: { progress($0.fractionCompleted) })
        try Task.checkCancellation()
        return location
    }
}

extension NoteMediaTranscriber {
    public static func whisper(folder: URL) -> NoteMediaTranscriber {
        let engine = NoteWhisperEngine(folder: folder)
        return NoteMediaTranscriber(duration: { url in try await AVURLAsset(url: url).load(.duration).seconds }, recognize: { url, start, length, locale in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("slice.m4a")
            try await exportAudioSlice(source: url, target: target, start: start, length: length)
            return try await engine.transcribe(url: target, locale: locale)
        })
    }
}
