import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

public enum NoteCaptureMode: String, CaseIterable, Sendable { case microphone, system, mixed, screen }

public struct NoteCaptureManifest: Codable, Sendable, Identifiable {
    public struct Part: Codable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let offset: TimeInterval
        public let source: String
        public var interrupted: Bool? = nil
    }
    public let id: UUID
    public let noteID: UUID
    public let startedAt: Date
    public var parts: [Part]
    public var echoReduction: Bool? = true
    public var issues: [String]?
}

/// Files are always retained until their UUID-bound database imports all succeed.
/// The fixed space root is supplied by Hub; manifest names never grant path access.
public struct NoteCaptureRecovery: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func sessions() throws -> [NoteCaptureManifest] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try Self.regularDirectory(root)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { directory in
            try Self.regularDirectory(directory)
            let url = directory.appendingPathComponent("manifest.json")
            let data = try Self.read(url, maximum: 256 * 1024)
            let manifest = try JSONDecoder().decode(NoteCaptureManifest.self, from: data)
            guard manifest.id.uuidString == directory.lastPathComponent, manifest.parts.count <= 2000 else { throw NoteStoreError.invalidContent }
            return manifest
        }.sorted { $0.startedAt < $1.startedAt }
    }
    public func discard(_ manifest: NoteCaptureManifest) throws {
        try Self.regularDirectory(root)
        let directory = root.appendingPathComponent(manifest.id.uuidString)
        try Self.regularDirectory(directory)
        try FileManager.default.removeItem(at: directory)
    }
    func save(_ manifest: NoteCaptureManifest) throws {
        try Self.regularDirectory(root)
        let directory = root.appendingPathComponent(manifest.id.uuidString)
        try Self.regularDirectory(directory)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
    public func recover(_ manifest: NoteCaptureManifest, store: NoteStore) async throws {
        guard try await store.get(id: manifest.noteID) != nil else { throw NoteStoreError.missing }
        let directory = root.appendingPathComponent(manifest.id.uuidString)
        try Self.regularDirectory(root); try Self.regularDirectory(directory)
        var playable: [UUID: URL] = [:], repaired: [URL] = []
        var issues = manifest.issues ?? []
        defer { for file in repaired { try? FileManager.default.removeItem(at: file) } }
        for part in manifest.parts {
            try Task.checkCancellation()
            guard [part.id.uuidString + ".caf", part.id.uuidString + ".mp4"].contains(part.name), part.offset.isFinite, part.offset >= 0, part.offset <= 28_800 else { throw NoteStoreError.invalidContent }
            let url = directory.appendingPathComponent(part.name)
            if part.interrupted == true, !FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
                // A device failure before the first sample has no media bytes.
                // Archive its explicit evidence instead of inventing an audio file.
                let evidence = try JSONEncoder().encode(part)
                try await store.addMedia(id: part.id, noteID: manifest.noteID, name: part.source + "-no-samples.json", data: evidence)
                issues.append("unreadable-fragment")
                continue
            }
            try await store.addMediaFile(id: part.id, noteID: manifest.noteID, name: part.source + "-" + String(Int(part.offset)) + "." + URL(fileURLWithPath: part.name).pathExtension, file: url)
            // Empty / unplayable fragments are evidence, never silently discarded.
            var readable = url
            let duration = try? await AVURLAsset(url: url).load(.duration).seconds
            if duration?.isFinite != true || (duration ?? 0) <= 0 {
                guard let copy = await NotePCMRepair.playableCopy(url) else {
                    guard part.interrupted == true else { throw NoteStoreError.invalidContent }
                    issues.append("unreadable-fragment"); continue
                }
                repaired.append(copy); readable = copy
            }
            playable[part.id] = readable
        }
        guard !playable.isEmpty else { throw NoteStoreError.invalidContent }
        var echoCount = 0
        if manifest.echoReduction != false {
            let mic = manifest.parts.filter { $0.source == "microphone" && playable[$0.id] != nil }.sorted { $0.offset < $1.offset }
            let system = manifest.parts.filter { $0.source == "system" && playable[$0.id] != nil }.sorted { $0.offset < $1.offset }
            if let reduced = await NoteEchoReductionService.reduceEcho(micURLs: mic.compactMap { playable[$0.id] }, sysURLs: system.compactMap { playable[$0.id] }, deadline: Date().addingTimeInterval(120), isCancelled: { Task.isCancelled }) {
                for (index, part) in mic.enumerated() where index < reduced.micURLs.count { playable[part.id] = reduced.micURLs[index] }
                repaired += reduced.createdURLs; echoCount = reduced.createdURLs.count
            }
        }
        try Task.checkCancellation()
        if (manifest.parts.count > 1 || !repaired.isEmpty), try await !store.media(noteID: manifest.noteID).contains(where: { $0.id == manifest.id }) {
            let output = directory.appendingPathComponent("assembled.m4a")
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try await NoteAudioAssembler.assemble(manifest.parts.filter { playable[$0.id] != nil }.map {
                NoteAudioPart(url: playable[$0.id] ?? directory.appendingPathComponent($0.name), offset: $0.offset, source: $0.source)
            }, to: output)
            try await store.addMediaFile(id: manifest.id, noteID: manifest.noteID, name: "meeting.m4a", file: output)
        }
        try await store.saveCaptureReport(.init(id: manifest.id, noteID: manifest.noteID, startedAt: manifest.startedAt,
            fragments: manifest.parts.count, repaired: repaired.count - echoCount, echoReduced: echoCount, issues: Array(Set(issues)).sorted()))
        try FileManager.default.removeItem(at: directory)
    }
    static func regularDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw NoteStoreError.invalidContent }
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.linkCount == 1,
              let size = values.fileSize, size > 0, size <= maximum else { throw NoteStoreError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw NoteStoreError.tooLarge }
        return data
    }
}

/// One recording instance, one space, bounded files. Device operations are owned
/// by the main actor; each audio writer is owned by its dedicated serial queue.
@MainActor
public final class NoteMeetingCapture {
    public private(set) var manifest: NoteCaptureManifest?
    public private(set) var failure: Error?
    private let recovery: NoteCaptureRecovery
    private var microphone = TranscriptionService()
    private var recoveryAttempts = 0
    private var system: NoteSystemCapture?
    private var screen: NoteScreenCapture?
    private var screenFilter: SCContentFilter?
    private var ticker: Task<Void, Never>?
    private var mode: NoteCaptureMode = .microphone
    private var options = NoteCaptureOptions()
    private var manuallyMuted = false
    public func setMicrophoneMuted(_ muted: Bool) { manuallyMuted = muted; updateMute() }
    private func updateMute() {
        let muted = manuallyMuted || (options.autoMute && NoteMicrophoneDevices.isMuted(uid: options.microphoneUID))
        microphone.setMicrophoneMuted(muted)
        screen?.setMicrophoneMuted(muted)
    }
    public init(root: URL) { recovery = NoteCaptureRecovery(root: root) }

    public func start(noteID: UUID, mode: NoteCaptureMode, screenFilter: SCContentFilter? = nil, echoReduction: Bool = true, options: NoteCaptureOptions = NoteCaptureOptions()) async throws {
        if mode == .screen, screenFilter == nil { throw NoteStoreError.missing }
        self.screenFilter = screenFilter
        self.options = options; manuallyMuted = options.startMuted
        guard manifest == nil else { throw NoteStoreError.conflict }
        try FileManager.default.createDirectory(at: recovery.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try NoteCaptureRecovery.regularDirectory(recovery.root)
        try checkDisk()
        if mode == .microphone || mode == .mixed || (mode == .screen && ["microphone", "mixed"].contains(options.screenAudio)) {
            if !options.microphoneUID.isEmpty, !NoteMicrophoneDevices.available().contains(where: { $0.id == options.microphoneUID }) { throw NoteStoreError.missing }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw TranscriptionService.TranscriptionError.microphoneNotAuthorized }
        }
        if mode != .microphone { _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        try Task.checkCancellation()
        var value = NoteCaptureManifest(id: UUID(), noteID: noteID, startedAt: Date(), parts: [])
        value.echoReduction = echoReduction
        let directory = recovery.root.appendingPathComponent(value.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try recovery.save(value)
        manifest = value; self.mode = mode; failure = nil; recoveryAttempts = 0
        do { try await startPart() }
        catch { _ = await stop(); throw error }
        ticker = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)); try Task.checkCancellation() } catch { return }
                guard let self, self.manifest != nil else { return }
                do {
                    self.updateMute()
                    try self.checkDisk()
                    if let manifest = self.manifest, Date().timeIntervalSince(manifest.startedAt) >= 28_800 { throw NoteStoreError.tooLarge }
                    let systemError = await self.system?.currentError()
                    if (self.mode != .system && self.mode != .screen && !self.microphone.recordingIsHealthy) || systemError != nil {
                        try await self.recoverDevice(); ticks = 0; continue
                    }
                    if let error = self.screen?.failure { throw error }
                    ticks += 1
                    if ticks == 12 {
                        ticks = 0
                        self.stopMicrophone()
                        await self.system?.stop(); self.system = nil
                        await self.screen?.stop()
                        if let failure = self.screen?.failure { throw failure }
                        self.screen = nil
                        try await self.startPart()
                    }
                } catch {
                    if Task.isCancelled { return }
                    self.failure = error
                    if var manifest = self.manifest {
                        for source in ["microphone", "system", "screen"] {
                            if let index = manifest.parts.lastIndex(where: { $0.source == source }) { manifest.parts[index].interrupted = true }
                        }
                        manifest.issues = Array((manifest.issues ?? []) + ["capture-interrupted"])
                        do { try self.recovery.save(manifest); self.manifest = manifest } catch { HubLogger.shared.error("Notes capture report persistence failed") }
                    }
                    _ = await self.stop()
                    return
                }
            }
        }
    }
    private func recoverDevice() async throws {
        guard mode != .screen, recoveryAttempts < 3, let id = manifest?.id else { throw NoteStoreError.invalidContent }
        recoveryAttempts += 1
        stopMicrophone(); await system?.stop(); system = nil
        guard var value = manifest, value.id == id else { throw CancellationError() }
        for source in ["microphone", "system"] {
            if let index = value.parts.lastIndex(where: { $0.source == source }) { value.parts[index].interrupted = true }
        }
        value.issues = Array(Set((value.issues ?? []) + ["device-recovered"]))
        try recovery.save(value); manifest = value
        try await Task.sleep(for: .seconds(recoveryAttempts))
        try Task.checkCancellation()
        guard manifest?.id == id else { throw CancellationError() }
        microphone = TranscriptionService()
        try await startPart()
    }
    private func checkDisk() throws {
        let values = try recovery.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 256 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
    }
    private func startPart() async throws {
        guard var value = manifest else { throw CancellationError() }
        let directory = recovery.root.appendingPathComponent(value.id.uuidString)
        if mode == .screen {
            guard let filter = screenFilter else { throw NoteStoreError.missing }
            let id = UUID(), name = id.uuidString + ".mp4"
            value.parts.append(.init(id: id, name: name, offset: max(0, Date().timeIntervalSince(value.startedAt)), source: "screen"))
            try recovery.save(value); manifest = value
            let capture = NoteScreenCapture(); screen = capture
            do {
                try await capture.start(filter: filter, to: directory.appendingPathComponent(name), options: options)
                updateMute()
                try Task.checkCancellation()
                guard manifest?.id == value.id else { throw CancellationError() }
            } catch { await capture.stop(); throw error }
            return
        }
        if mode != .system {
            let id = UUID(), name: String
            name = id.uuidString + ".caf"
            value.parts.append(.init(id: id, name: name, offset: max(0, Date().timeIntervalSince(value.startedAt)), source: "microphone"))
            try recovery.save(value); manifest = value
            microphone.setMicrophoneMuted(manuallyMuted || (options.autoMute && NoteMicrophoneDevices.isMuted(uid: options.microphoneUID)))
            try await microphone.startRecording(to: directory.appendingPathComponent(name), microphoneUID: options.microphoneUID)
            try Task.checkCancellation()
            guard manifest?.id == value.id else { stopMicrophone(); throw CancellationError() }
        }
        if mode != .microphone {
            let id = UUID(), name = id.uuidString + ".caf"
            value.parts.append(.init(id: id, name: name, offset: max(0, Date().timeIntervalSince(value.startedAt)), source: "system"))
            try recovery.save(value); manifest = value
            let capture = NoteSystemCapture(url: directory.appendingPathComponent(name))
            system = capture
            do {
                try await capture.start()
                try Task.checkCancellation()
                guard manifest?.id == value.id else { throw CancellationError() }
            } catch { await capture.stop(); throw error }
        }
    }
    private func stopMicrophone() { _ = microphone.stopRecording() }
    @discardableResult public func stop() async -> NoteCaptureManifest? {
        ticker?.cancel(); ticker = nil
        stopMicrophone()
        await system?.stop()
        if let error = system?.failure { failure = error }
        system = nil
        await screen?.stop()
        if let error = screen?.failure { failure = error }
        screen = nil; screenFilter = nil
        let result = manifest; manifest = nil
        return result
    }
}

@MainActor
private final class NoteSystemCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    nonisolated let sink: NotePCMSink
    private var stream: SCStream?
    var failure: Error?
    init(url: URL) { sink = NotePCMSink(url: url) }
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw NoteStoreError.missing }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000; configuration.channelCount = 2
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: sink.queue)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: sink.queue)
        stream = capture
        try await capture.startCapture()
    }
    func currentError() async -> Error? { if let failure { return failure }; return await sink.currentError() }
    func stop() async {
        if let stream { do { try await stream.stopCapture() } catch { HubLogger.shared.warning("Notes system capture stop failed: \(HubLogger.safeErrorSummary(error))") } }
        stream = nil
        if let error = await sink.finish() { failure = error }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { sink.append(sampleBuffer) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.failure = error }
    }
}

/// All mutable fields are touched only on queue, including finish and error reads.
private final class NotePCMSink: @unchecked Sendable {
    let queue = DispatchQueue(label: "agroom.notes.system-pcm")
    let url: URL
    private var file: AVAudioFile?
    private var error: Error?
    private var finished = false
    private var lastSampleAt = Date()
    init(url: URL) { self.url = url }
    func append(_ sample: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, error == nil, CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 480_000, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { error = NoteStoreError.invalidContent; return }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved) }
            try file?.write(from: buffer); lastSampleAt = Date()
        } catch { self.error = error }
    }
    func currentError() async -> Error? {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.error ?? (Date().timeIntervalSince(self.lastSampleAt) > 12 ? NoteStoreError.invalidContent : nil)) } }
    }
    func finish() async -> Error? {
        await withCheckedContinuation { continuation in
            queue.async { self.finished = true; self.file = nil; continuation.resume(returning: self.error) }
        }
    }
}
