import Foundation
import AVFoundation

@MainActor
public final class NoteSpeechExport {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiter: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    public init() {}
    public func write(text: String, locale: String, voiceID: String? = nil, rate: Float = 0.5, to output: URL) async throws {
        guard waiter == nil, !text.isEmpty, text.count <= 100_000 else { throw NoteStoreError.tooLarge }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("speech.wav"), sink = NoteSpeechSink(url: wav)
        defer { sink.close(); synthesizer.stopSpeaking(at: .immediate) }
        for part in NoteSpeechText.chunks(NoteSpeechText.prepare(text)) {
            try Task.checkCancellation()
            let utterance = AVSpeechUtterance(string: part)
            utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: locale)
            utterance.rate = min(0.65, max(0.25, rate))
            let id = UUID(); generation = id; sink.begin(id)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiter = continuation
                    synthesizer.write(utterance, toBufferCallback: sink.callback(id: id) { [weak self] result in
                        Task { @MainActor in self?.finish(id, result: result) }
                    })
                    timer = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(120)) } catch { return }
                        self?.synthesizer.stopSpeaking(at: .immediate)
                        self?.finish(id, result: .failure(NoteStoreError.invalidContent))
                    }
                }
            } onCancel: {
                sink.close()
                Task { @MainActor in self.synthesizer.stopSpeaking(at: .immediate); self.finish(id, result: .failure(CancellationError())) }
            }
        }
        sink.close()
        try Task.checkCancellation()
        if output.pathExtension.lowercased() == "wav" { try await NoteFileTransfer.copy(wav,to: output) }
        else { try await NoteAudioAssembler.assemble([.init(url: wav, offset: 0, source: "speech")], to: output) }
    }
    private func finish(_ id: UUID, result: Result<Void, Error>) {
        guard generation == id else { return }
        timer?.cancel(); timer = nil
        let continuation = waiter; waiter = nil; continuation?.resume(with: result)
    }
}

/// Buffer lifetime ends with Apple's callback. Synchronous queue ownership keeps
/// writes ordered without holding any lock across I/O or escaping the buffer.
private final class NoteSpeechSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agroom.notes.speech-export")
    private let url: URL
    private var file: AVAudioFile?
    private var closed = false
    private var chunkFrames = 0
    private var chunkID: UUID?
    private var totalFrames = 0
    init(url: URL) { self.url = url }
    func begin(_ id: UUID) { queue.sync { chunkFrames = 0; chunkID = id } }
    func close() { queue.sync { closed = true; chunkID = nil; file = nil } }
    func callback(id: UUID, _ complete: @escaping @Sendable (Result<Void, Error>) -> Void) -> @Sendable (AVAudioBuffer) -> Void {
        { [self] buffer in
            let result = queue.sync { () -> Result<Void, Error>? in
                guard !closed, chunkID == id else { return nil }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return .failure(NoteStoreError.invalidContent) }
                if pcm.frameLength == 0 { chunkID = nil; return chunkFrames > 0 ? .success(()) : .failure(NoteStoreError.invalidContent) }
                guard (totalFrames + Int(pcm.frameLength)) * 4 <= NoteStore.maximumMediaBytes else { return .failure(NoteStoreError.tooLarge) }
                do {
                    if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
                    guard file?.processingFormat == pcm.format else { throw NoteStoreError.invalidContent }
                    try file?.write(from: pcm); chunkFrames += Int(pcm.frameLength); totalFrames += Int(pcm.frameLength)
                    return nil
                } catch { return .failure(error) }
            }
            if let result { complete(result) }
        }
    }
}
