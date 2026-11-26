import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class NotesScreenPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<NoteFilterTransfer, Error>?
    func choose() async throws -> NoteFilterTransfer {
        guard continuation == nil else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let picker = SCContentSharingPicker.shared
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
                configuration.allowsChangingSelectedContent = false
                picker.defaultConfiguration = configuration
                picker.add(self); picker.isActive = true
                picker.present()
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<NoteFilterTransfer, Error>) {
        let waiter = continuation; continuation = nil
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        waiter?.resume(with: result)
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let transfer = NoteFilterTransfer(filter)
        Task { @MainActor in self.finish(.success(transfer)) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
final class NoteFilterTransfer: @unchecked Sendable {
    let filter: SCContentFilter
    init(_ filter: SCContentFilter) { self.filter = filter }
}
