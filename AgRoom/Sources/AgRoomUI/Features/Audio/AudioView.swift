import SwiftUI
import AVFoundation
import AgRoomCore

// MARK: - Audio Player Model

/// 音频播放模型：AVAudioPlayer（倍速/进度/音量）
@MainActor
@Observable
final class AudioPlayerModel {
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

    var currentURL: URL?
    var isPlaying = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Double = 1.0
    var rate: Float = 1.0

    func open(url: URL) {
        stopTicker()
        player?.stop()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.enableRate = true
            newPlayer.volume = Float(volume)
            newPlayer.rate = rate
            newPlayer.prepareToPlay()
            player = newPlayer
            currentURL = url
            duration = newPlayer.duration
            position = 0
            isPlaying = false
        } catch {
            HubLogger.shared.error("Failed to open audio: \(HubLogger.safeErrorSummary(error))")
            currentURL = nil
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicker()
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = time
        position = time
    }

    func setVolume(_ value: Double) {
        volume = value
        player?.volume = Float(value)
    }

    func setRate(_ value: Float) {
        rate = value
        player?.rate = value
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let player = self.player else { self.stopTicker(); return }
                self.position = player.currentTime
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.stopTicker()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
    func dispose() { player?.stop(); stopTicker(); isPlaying = false }
}

// MARK: - Audio View

/// 音频页：播放器 + 语音转写（系统引擎，明示来源）+ 分段点击跳转播放位置
public struct AudioView: View {
    let hub: Hub

    @State private var playerModel = AudioPlayerModel()
    @State private var transcription = TranscriptionService()
    @State private var operation: Task<Void, Never>?
    @State private var startingRecording = false

    @State private var localeIndex = 0
    @State private var isTranscribing = false
    @State private var isRecording = false
    @State private var transcriptResult: TranscriptionResult?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    public init(hub: Hub) {
        self.hub = hub
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string("audio.title"))
                .font(.title2)
                .fontWeight(.bold)

            playerSection
            Divider()
            transcriptionSection
            Divider()
            resultSection
        }
        .padding(20)
        .onDisappear {
            operation?.cancel()
            playerModel.dispose()
            if let url = transcription.stopRecording() { try? FileManager.default.removeItem(at: url) }
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Player

    private var playerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: openFile) {
                    Label(L.string("audio.open"), systemImage: "folder")
                }
                if let url = playerModel.currentURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 12) {
                Button(action: { playerModel.togglePlay() }) {
                    Image(systemName: playerModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(playerModel.currentURL == nil)

                Text(formatTime(playerModel.position))
                    .font(.system(size: 11, design: .monospaced))

                Slider(value: Binding(
                    get: { playerModel.position },
                    set: { playerModel.seek(to: $0) }
                ), in: 0...max(0.01, playerModel.duration))

                Text(formatTime(playerModel.duration))
                    .font(.system(size: 11, design: .monospaced))

                // 倍速
                Picker("", selection: Binding(
                    get: { playerModel.rate },
                    set: { playerModel.setRate($0) }
                )) {
                    Text("0.75×").tag(Float(0.75))
                    Text("1×").tag(Float(1.0))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                    Text("2×").tag(Float(2.0))
                }
                .pickerStyle(.menu)
                .frame(width: 80)

                // 音量
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(value: Binding(
                    get: { playerModel.volume },
                    set: { playerModel.setVolume($0) }
                ), in: 0...1)
                .frame(width: 90)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L.string("audio.transcribe.title"))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker("", selection: $localeIndex) {
                    ForEach(Array(TranscriptionService.supportedLocales.enumerated()), id: \.offset) { index, entry in
                        Text(entry.name).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)

                Spacer()

                Button(action: transcribeCurrentFile) {
                    if isTranscribing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L.string("audio.transcribe.file"), systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                .disabled(isTranscribing || isRecording || playerModel.currentURL == nil)

                Button(action: toggleRecording) {
                    if isRecording {
                        Label(L.string("audio.record.stop"), systemImage: "stop.circle.fill")
                            .foregroundColor(.red)
                    } else {
                        Label(L.string("audio.record.start"), systemImage: "mic.circle")
                    }
                }
                .disabled(isTranscribing || startingRecording)
            }

            Text(L.string("audio.transcribe.engine_notice"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Result

    private var resultSection: some View {
        Group {
            if let result = transcriptResult {
                HStack(alignment: .top, spacing: 14) {
                    // 全文
                    ScrollView {
                        Text(result.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)

                    // 分段（点击跳转播放）
                    if !result.segments.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(result.segments.enumerated()), id: \.offset) { _, segment in
                                    Button(action: { playerModel.seek(to: segment.timestamp) }) {
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(formatTime(segment.timestamp))
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.accentColor)
                                            Text(segment.text)
                                                .font(.system(size: 12))
                                                .multilineTextAlignment(.leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(4)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(width: 260)
                        .background(Color.secondary.opacity(0.04))
                        .cornerRadius(8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(L.string("audio.transcribe.empty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .init(filenameExtension: "m4a") ?? .audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        playerModel.open(url: url)
    }

    private func transcribeCurrentFile() {
        guard let url = playerModel.currentURL else { return }
        isTranscribing = true
        let locale = TranscriptionService.supportedLocales[localeIndex].locale
        operation?.cancel()
        operation = Task {
            do {
                let result = try await transcription.transcribeFile(at: url, locale: locale)
                try Task.checkCancellation()
                transcriptResult = result
            } catch is CancellationError {
            } catch {
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.audio_transcribe")
                showErrorAlert = true
            }
            isTranscribing = false
        }
    }

    /// 录音 → 停止后自动转写
    private func toggleRecording() {
        if isRecording {
            isRecording = false
            guard let url = transcription.stopRecording() else { return }
            isTranscribing = true
            let locale = TranscriptionService.supportedLocales[localeIndex].locale
            operation = Task {
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    let result = try await transcription.transcribeFile(at: url, locale: locale)
                    try Task.checkCancellation()
                    transcriptResult = result
                    try? FileManager.default.removeItem(at: url)
                } catch is CancellationError {
                } catch {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.audio_transcribe")
                    showErrorAlert = true
                }
                isTranscribing = false
            }
        } else {
            startingRecording = true
            operation = Task {
                defer { startingRecording = false }
                do {
                    try await transcription.startRecording()
                    try Task.checkCancellation()
                    isRecording = true
                } catch is CancellationError {
                    _ = transcription.stopRecording()
                } catch {
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.audio_record")
                    showErrorAlert = true
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
