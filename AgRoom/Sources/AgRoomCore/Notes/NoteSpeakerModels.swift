import Foundation

public enum NoteSpeakerModels {
    /// Mirrors Memonta's upstream release assets; only validated weight files are published.
    public static func download(to root: URL, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let archiveURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!
        let archive = try await NoteModelDownload.fetch(archiveURL,root: root)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw NoteStoreError.invalidContent }
        try Task.checkCancellation()
        let extracted = try await extractModel(archive)
        guard NoteMediaTranscriber.sourceHash(extracted) == "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079" else { throw NoteStoreError.invalidContent }
        try extracted.write(to: staging.appendingPathComponent("segmentation.onnx"), options: .atomic)
        await progress(0.3)
        let embeddingURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")!
        let temporary = try await NoteModelDownload.fetch(embeddingURL,root: root)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try NoteCaptureRecovery.read(temporary, maximum: 128 * 1024 * 1024)
        guard NoteMediaTranscriber.sourceHash(data) == "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b" else { throw NoteStoreError.invalidContent }
        try data.write(to: staging.appendingPathComponent("embedding.onnx"), options: .atomic)
        try Task.checkCancellation()
        let destination = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: staging, to: destination)
        await progress(1)
        return destination
    }
    /// tar writes only one named member to stdout, never extracts archive paths or links.
    private static func extractModel(_ archive: URL) async throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOjf", archive.path, "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let task = Task.detached { () throws -> Data in
            try process.run()
            defer { try? output.fileHandleForReading.close() }
            var bytes = Data()
            while let data = try output.fileHandleForReading.read(upToCount: 64 * 1024), !data.isEmpty {
                guard bytes.count + data.count <= 8 * 1024 * 1024 else { process.terminate(); throw NoteStoreError.tooLarge }
                bytes.append(data)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NoteStoreError.invalidContent }
            return bytes
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            task.cancel(); if process.isRunning { process.terminate() }
        }
    }
}
