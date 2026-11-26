import Foundation
import AVFoundation
import ScreenCaptureKit

/// The native picker belongs to UI; Core receives only the chosen capture filter.
@MainActor
final class NoteScreenCapture: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    nonisolated private let completion = NoteScreenCompletion()
    private var startedAt = Date()
    private var configuration: SCStreamConfiguration?
    private var microphoneEnabled = true
    private var muted = false
    func setMicrophoneMuted(_ value: Bool) {
        guard muted != value, let stream, let configuration else { return }
        muted = value
        configuration.captureMicrophone = microphoneEnabled && !value
        Task { do { try await stream.updateConfiguration(configuration) } catch { completion.finish(.failure(error)) } }
    }
    func start(filter: SCContentFilter, to url: URL, options: NoteCaptureOptions) async throws {
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { throw NoteStoreError.invalidContent }
        let maximum: Double = options.screenQuality == "compact" ? 1280 : options.screenQuality == "high" ? 2560 : 1920
        let scale = min(maximum / size.width, (maximum * 9 / 16) / size.height, Double(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(size.width * scale) / 2 * 2)
        configuration.height = max(2, Int(size.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.capturesAudio = ["system", "mixed"].contains(options.screenAudio)
        configuration.captureMicrophone = ["microphone", "mixed"].contains(options.screenAudio)
        if !options.microphoneUID.isEmpty { configuration.microphoneCaptureDeviceID = options.microphoneUID }
        configuration.captureMicrophone = configuration.captureMicrophone && !options.startMuted
        muted = options.startMuted
        self.configuration = configuration
        microphoneEnabled = ["microphone", "mixed"].contains(options.screenAudio)
        configuration.excludesCurrentProcessAudio = true
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url; recording.outputFileType = .mp4; recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream; self.output = output; startedAt = Date()
        try await stream.startCapture()
    }
    var failure: Error? {
        if let error = completion.error { return error }
        if let output, output.recordedFileSize >= 96 * 1024 * 1024 { return NoteStoreError.tooLarge }
        if Date().timeIntervalSince(startedAt) > 15, (output?.recordedDuration.seconds ?? 0) <= 0 { return NoteStoreError.invalidContent }
        return nil
    }
    func stop() async {
        guard let stream else { return }
        self.stream = nil
        let completion = completion
        // Finish must outlive cancellation of the caller to retain a playable file.
        let finish = Task { @MainActor in
            do {
                try await stream.stopCapture()
                try await TaskDeadline.run(until: Date().addingTimeInterval(15)) { try await completion.wait() }
            } catch { completion.finish(.failure(error)) }
        }
        await finish.value
        output = nil
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { completion.finish(.success(())) }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { completion.finish(.failure(error)) }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) { completion.finish(.failure(error)) }
}

private final class NoteScreenCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    var error: Error? { lock.withLock { if case .failure(let error) = result { return error }; return nil } }
    func finish(_ value: Result<Void, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard result == nil else { return nil }
            result = value; let waiter = continuation; continuation = nil; return waiter
        }
        waiter?.resume(with: value)
    }
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let complete = lock.withLock { () -> Result<Void, Error>? in
                    if let result { return result }
                    self.continuation = continuation; return nil
                }
                if let complete { continuation.resume(with: complete) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
}
