import Combine
import Foundation
import SwiftUI
import AgRoomCore

enum FirstResultReview {
    struct Inspection: Equatable, Sendable {
        let sessionID: UUID
        let messageID: UUID
        let runID: UUID?
        let artifactID: String
    }

    static func key(progress: FirstResultProgress, session: ChatSession?) -> String {
        progress.sessionID.uuidString + (session.map { value in
            value.id.uuidString + value.messages.filter { $0.role == .assistant }.map {
                $0.id.uuidString + ($0.taskRun?.id.uuidString ?? "") + ($0.runStatus?.rawValue ?? "") +
                String($0.completion?.isIncomplete == true) + ($0.trace ?? []).flatMap(\.allArtifacts).map(\.id).joined()
            }.joined()
        } ?? "")
    }

    static func matches(_ inspection: Inspection, session: ChatSession?) -> Bool {
        guard let session, session.id == inspection.sessionID,
              let message = session.messages.first(where: { $0.id == inspection.messageID }),
              message.runStatus == .succeeded, message.completion?.isIncomplete != true,
              message.taskRun?.id == inspection.runID else { return false }
        return (message.trace ?? []).flatMap(\.allArtifacts).contains { $0.id == inspection.artifactID }
    }

    /// A retained version is verified against its own space store. Legacy paths
    /// are accepted only inside this conversation's registered directory roots.
    static func inspect(progress: FirstResultProgress, session: ChatSession?, roots: [URL],
                        store: TaskArtifactStore?) async throws -> Inspection? {
        guard let session, session.id == progress.sessionID else { return nil }
        for message in session.messages.reversed() where message.role == .assistant && message.runStatus == .succeeded && message.completion?.isIncomplete != true {
            for artifact in (message.trace ?? []).flatMap(\.allArtifacts) {
                try Task.checkCancellation()
                if let sourceSpace = artifact.sourceSpace, sourceSpace != store?.space { continue }
                if artifact.versionID != nil {
                    guard let store else { continue }
                    do { _ = try await store.materialize(artifact) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as TaskArtifactError where error == .unavailable || error == .unsafeFile || error == .changedFile { continue }
                } else {
                    let available = await Task.detached {
                        let url = URL(fileURLWithPath: artifact.path).standardizedFileURL.resolvingSymlinksInPath()
                        guard roots.contains(where: { FileAreaService.isInside(url, root: $0.standardizedFileURL.resolvingSymlinksInPath()) }) else { return false }
                        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    }.value
                    guard available else { continue }
                }
                return Inspection(sessionID: session.id, messageID: message.id, runID: message.taskRun?.id, artifactID: artifact.id)
            }
        }
        return nil
    }
}

struct FirstResultReviewCard: View {
    let progress: FirstResultProgress
    let session: ChatSession?
    let isRunning: Bool
    let roots: [URL]
    let store: TaskArtifactStore?
    let preferences: ProductPreferencesService?
    let isCurrent: @MainActor (FirstResultReview.Inspection) -> Bool
    let onResume: () -> Void
    let onVerified: (FirstResultProgress) -> Void
    let onError: (String) -> Void
    @State private var inspection: FirstResultReview.Inspection?
    @State private var checking = false
    @State private var visible = false
    @State private var generation = UUID()
    @State private var metadataRevision = UUID()

    var body: some View {
        HStack(spacing: 8) {
            Label(L.string("product.setup.check.title"), systemImage: "checklist")
            Spacer()
            if session?.id != progress.sessionID {
                Button(L.string("product.setup.resume"), action: onResume)
            } else {
                Button(L.string("product.setup.check.confirm")) { confirm() }
                    .disabled(isRunning || checking || inspection == nil)
                    .help(L.string("product.setup.check.help"))
            }
        }.font(.caption).controlSize(.small).padding(.horizontal, 16)
        .onAppear { visible = true }
        .onDisappear { visible = false; generation = UUID() }
        // The final message may be saved before the engine releases its running
        // state. Recheck at idle even when the saved message and artifacts match.
        .task(id: FirstResultReview.key(progress: progress, session: session) + ":running:\(isRunning):" + metadataRevision.uuidString) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: TaskArtifactStore.didChange).receive(on: RunLoop.main)) { notification in
            guard visible, notification.object as? String == store?.space.rawValue else { return }
            metadataRevision = UUID()
        }
    }

    private func refresh() async {
        let ticket = UUID(); generation = ticket
        inspection = nil
        do {
            let result = try await FirstResultReview.inspect(progress: progress, session: session, roots: roots, store: store)
            guard visible, generation == ticket, !Task.isCancelled else { return }
            inspection = result.flatMap { isCurrent($0) ? $0 : nil }
        } catch is CancellationError { }
        catch { if generation == ticket, visible { onError(L.errorDescription(error)) } }
    }

    private func confirm() {
        guard let inspection, !checking, !isRunning, isCurrent(inspection) else { return }
        checking = true
        let ticket = generation
        Task {
            defer { checking = false }
            do {
                let fresh = try await FirstResultReview.inspect(progress: progress, session: session, roots: roots, store: store)
                guard visible, generation == ticket, !Task.isCancelled, isCurrent(inspection) else { return }
                guard fresh == inspection else {
                    self.inspection = nil
                    onError(L.string("product.artifact.error.unavailable"))
                    return
                }
                guard let preferences else { throw SpaceServiceError.encodingFailed }
                let verified = try await preferences.verifyFirstResult(sessionID: progress.sessionID)
                guard visible, generation == ticket, isCurrent(inspection) else { return }
                onVerified(verified)
            } catch { if visible, generation == ticket { onError(L.errorDescription(error)) } }
        }
    }
}
