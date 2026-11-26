import Foundation
import Speech
import AVFoundation
import AudioToolbox

// MARK: - Transcript Segment

/// 转写分段：文本 + 起始时间（供音频播放器点击跳转）
public struct TranscriptSegment: Sendable, Equatable {
    public let text: String
    public let timestamp: TimeInterval
    public let endTimestamp: TimeInterval?

    public init(text: String, timestamp: TimeInterval, endTimestamp: TimeInterval? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
    }
}

// MARK: - Transcription Result

public struct TranscriptionResult: Sendable {
    public let text: String
    public let segments: [TranscriptSegment]
}

// MARK: - Transcription Service

/// 语音转写服务：系统 Speech 引擎（真实可用，明示引擎来源）；
/// whisper.cpp 本地引擎为后续升级点，接口保持引擎无关。
public final class TranscriptionService: @unchecked Sendable {

    public enum TranscriptionError: LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case noResult
        case microphoneNotAuthorized

        public var errorDescription: String? {
            switch self {
            case .microphoneNotAuthorized:
                return "Microphone access is not authorized. Please grant access in System Settings → Privacy & Security → Microphone."
            case .notAuthorized:
                return "Speech recognition is not authorized. Please grant access in System Settings → Privacy & Security."
            case .recognizerUnavailable:
                return "Speech recognizer is unavailable for the selected language."
            case .noResult:
                return "No speech was recognized."
            }
        }
    }

    /// 支持的转写语言
    public static let supportedLocales: [(name: String, locale: Locale)] = [
        ("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("English", "en-US"),
        ("日本語", "ja-JP"), ("한국어", "ko-KR"), ("Deutsch", "de-DE"),
        ("Français", "fr-FR"), ("Español", "es-ES"), ("Italiano", "it-IT"),
        ("Português", "pt-BR"), ("Русский", "ru-RU"), ("Українська", "uk-UA"),
        ("Nederlands", "nl-NL"), ("Polski", "pl-PL"), ("Türkçe", "tr-TR"),
        ("العربية", "ar-SA"), ("हिन्दी", "hi-IN"), ("Bahasa Indonesia", "id-ID"),
        ("Svenska", "sv-SE"), ("ไทย", "th-TH"), ("Tiếng Việt", "vi-VN")
    ].map { (name: $0.0, locale: Locale(identifier: $0.1)) }


    public init() {}

    // MARK: - Authorization

    /// 请求语音识别授权（幂等）
    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: - File Transcription

    /// 转写音频文件（m4a/mp3/wav 等），返回全文与分段时间戳
    public func transcribeFile(at url: URL, locale: Locale) async throws -> TranscriptionResult {
        guard await Self.requestAuthorization() else {
            throw TranscriptionError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let input = RecognitionInput(request: request, recognizer: recognizer)
        return try await TaskDeadline.run(until: Date().addingTimeInterval(300)) { [self] in
            try await run(request: input.request, recognizer: input.recognizer)
        }
    }

    // MARK: - Mic Recording

    private let recorder = MicRecorder()

    /// 开始麦克风录音（写入临时 m4a）；需要麦克风权限（系统弹窗）
    public func startRecording(to url: URL? = nil, microphoneUID: String = "") async throws {
        try await recorder.start(to: url, microphoneUID: microphoneUID)
    }

    /// 停止录音并返回音频文件路径
    public func stopRecording() -> URL? {
        recorder.stop()
    }

    public func setMicrophoneMuted(_ muted: Bool) { recorder.setMuted(muted) }

    public var recordingIsHealthy: Bool { recorder.isHealthy }

    public var isRecording: Bool {
        recorder.isRecording
    }

    // MARK: - Private

    private func run(request: SFSpeechRecognitionRequest, recognizer: SFSpeechRecognizer) async throws -> TranscriptionResult {
        let handle = RecognitionHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
                handle.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        handle.finish(.failure(error))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let segments = result.bestTranscription.segments.map { segment in
                        TranscriptSegment(text: segment.substring, timestamp: segment.timestamp, endTimestamp: segment.timestamp + segment.duration)
                    }
                    let text = result.bestTranscription.formattedString
                    if text.isEmpty {
                        handle.finish(.failure(TranscriptionError.noResult))
                    } else {
                        handle.finish(.success(TranscriptionResult(text: text, segments: segments)))
                    }
                }
                handle.attach(task)
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// Ownership is transferred once to the recognition operation, never concurrently mutated.
private final class RecognitionInput: @unchecked Sendable {
    let request: SFSpeechRecognitionRequest
    let recognizer: SFSpeechRecognizer
    init(request: SFSpeechRecognitionRequest, recognizer: SFSpeechRecognizer) {
        self.request = request; self.recognizer = recognizer
    }
}

// MARK: - Recognition Handle

/// 单次完成闸门 + 实际请求句柄：结束回调、错误回调与取消可交错抵达，
/// 用锁保证 continuation 只完成一次（否则双 resume 触发运行时崩溃），
/// 并让外部取消/超时能主动中断底层识别任务。
final class RecognitionHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var task: SFSpeechRecognitionTask?
    private var completed = false

    func install(_ continuation: CheckedContinuation<TranscriptionResult, Error>) {
        let accepted = lock.withLock {
            guard !completed else { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(throwing: CancellationError()) }
    }

    /// 绑定底层任务；若此前已取消（continuation 已被清空），立即中断刚创建的任务
    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let alreadyDone = completed
        if !alreadyDone { self.task = task }
        lock.unlock()
        if alreadyDone { task.cancel() }
    }

    func finish(_ result: Result<TranscriptionResult, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let cont = continuation
        continuation = nil
        task = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        completed = true
        let currentTask = task
        task = nil
        let cont = continuation
        continuation = nil
        lock.unlock()
        currentTask?.cancel()
        cont?.resume(throwing: CancellationError())
    }
}

// MARK: - Mic Recorder

/// 麦克风录音：AVAudioEngine + installTap 写入 m4a（规范 §3 模式）
final class MicRecorder: @unchecked Sendable {
    private let deviceQueue = DispatchQueue(label: "agroom.audio.capture")

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputPath: URL?
    private let lock = NSLock()
    private var _isRecording = false
    private let samples = MicSampleState()
    func setMuted(_ value: Bool) { samples.lock.withLock { samples.muted = value } }
    /// 启动中标记：把「检查是否已在录」与「装 tap / 启动引擎」并入同一受控生命周期，
    /// 避免并发 start 在同一 bus 重复 installTap（触发不可捕获的 NSException 直接崩溃）
    private var _isStarting = false
    private var generation: UInt = 0

    deinit { _ = stopCapture() }

    var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    var isHealthy: Bool {
        deviceQueue.sync {
            let recording = lock.withLock { _isRecording }
            let receiving = samples.lock.withLock { !samples.writeFailed && Date().timeIntervalSince(samples.lastSampleAt) < 12 }
            return recording && receiving && engine.isRunning
        }
    }

    func start(to url: URL? = nil, microphoneUID: String = "") async throws {
        let expected = lock.withLock { generation }
        // 麦克风权限请求
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard granted else {
            throw TranscriptionService.TranscriptionError.microphoneNotAuthorized
        }
        // 锁操作封装在同步方法内（规范 §4：async 上下文禁用 NSLock）
        try Task.checkCancellation()
        try deviceQueue.sync {
            guard lock.withLock({ generation == expected }) else { throw CancellationError() }
            try beginCapture(to: url, microphoneUID: microphoneUID)
        }
    }

    /// 同步启动录音（引擎配置与状态写入均无 await）
    private func beginCapture(to url: URL?, microphoneUID: String) throws {
        // 检查与置位在同一临界区完成，把启动纳入受控生命周期
        lock.lock()
        if _isRecording || _isStarting {
            lock.unlock()
            return
        }
        _isStarting = true
        lock.unlock()
        defer { lock.withLock { _isStarting = false } }

        let inputNode = engine.inputNode
        if !microphoneUID.isEmpty {
            guard var device = NoteMicrophoneDevices.deviceID(uid: microphoneUID), let unit = inputNode.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw TranscriptionService.TranscriptionError.recognizerUnavailable }
        }
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw TranscriptionService.TranscriptionError.recognizerUnavailable
        }

        let path = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom_rec_\(UUID().uuidString.prefix(8)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        let file = try AVAudioFile(forWriting: path, settings: path.pathExtension == "caf" ? format.settings : settings)

        let samples = samples
        samples.lock.withLock { samples.writeFailed = false; samples.lastSampleAt = Date() }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            do {
                if samples.lock.withLock({ samples.muted }) {
                    for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                        if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
                    }
                }
                try file.write(from: buffer)
                samples.lock.withLock { samples.lastSampleAt = Date() }
            } catch {
                let firstFailure = samples.lock.withLock {
                    let first = !samples.writeFailed
                    samples.writeFailed = true
                    return first
                }
                if firstFailure { HubLogger.shared.error("Audio write failed: \(HubLogger.safeErrorSummary(error))") }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // start 失败必须擑掉已装的 tap：同一 bus 重复 installTap 触发
            // NSException（Swift 无法捕获，直接崩溃），下次 start 就会踩中
            inputNode.removeTap(onBus: 0)
            HubLogger.shared.error("Audio engine start failed: \(HubLogger.safeErrorSummary(error))")
            throw error
        }

        lock.withLock {
            audioFile = file
            outputPath = path
            _isRecording = true
        }
        HubLogger.shared.info("Mic recording started")
    }

    func stop() -> URL? {
        lock.withLock { generation &+= 1 }
        return deviceQueue.sync { stopCapture() }
    }

    private func stopCapture() -> URL? {
        lock.lock()
        guard _isRecording else {
            lock.unlock()
            return nil
        }
        _isRecording = false
        let path = outputPath
        audioFile = nil
        lock.unlock()
        // 音频设备调用与日志移出锁：锁内不得执行 I/O / 设备操作
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        HubLogger.shared.info("Mic recording stopped")
        return path
    }
}

/// The tap owns sample state and its file, never the recorder or audio engine.
/// This also keeps the recorder's final release off the real-time callback.
private final class MicSampleState: @unchecked Sendable {
    let lock = NSLock()
    var muted = false
    var writeFailed = false
    var lastSampleAt = Date.distantPast
}
