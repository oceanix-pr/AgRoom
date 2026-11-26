import Foundation
import Observation
import AgRoomCore

/// Application chrome observes activity flags only, never content or space services.
@MainActor @Observable
public final class NotesRecordingStatus {
    public static let shared = NotesRecordingStatus()
    private var owners: [AppSpace:Set<UUID>] = [:]
    public var anyRecording: Bool { owners.values.contains { !$0.isEmpty } }
    public func isRecording(space: AppSpace) -> Bool { owners[space]?.isEmpty == false }
    func set(_ active: Bool, space: AppSpace, owner: UUID) {
        if active { owners[space,default: []].insert(owner) } else { owners[space]?.remove(owner) }
    }
}
