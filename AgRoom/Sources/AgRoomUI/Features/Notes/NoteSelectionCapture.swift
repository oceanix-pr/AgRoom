import Foundation
import CoreGraphics
import AgRoomCore

/// The system's interactive selection UI supports region and Space-to-window capture.
/// Arguments are fixed; this is not a shell or a general code execution entry point.
enum NoteSelectionCapture {
    static func image() async throws -> Data {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw OCRService.OCRError.screenCaptureNotPermitted }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("selection.png"), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-t", "png", url.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let job = Task.detached {
            try Task.checkCancellation(); try process.run()
            if Task.isCancelled { ProcessTerminator.terminate(process: process, label: "notes-screenshot"); throw CancellationError() }
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else { throw CancellationError() }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 32 * 1024 * 1024 else { throw NoteStoreError.tooLarge }
            return try Data(contentsOf: url)
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: {
            job.cancel(); ProcessTerminator.terminate(process: process, label: "notes-screenshot")
        }
    }
}
