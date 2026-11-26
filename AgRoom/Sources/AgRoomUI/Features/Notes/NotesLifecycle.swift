import Foundation
import AgRoomCore

@MainActor
public enum NotesLifecycle {
    private final class Entry { weak var model: NotesModel?; init(_ model: NotesModel) { self.model = model } }
    private static var entries: [Entry] = []
    private static var active: [ObjectIdentifier:NotesModel] = [:]
    static func setActive(_ model: NotesModel, active isActive: Bool) { active[ObjectIdentifier(model)] = isActive ? model : nil }
    static func retained(space: AppSpace, hub: Hub) -> NotesModel? { active.values.first { $0.space == space && $0.hub === hub } }
    static func register(_ model: NotesModel) { entries.removeAll { $0.model == nil }; entries.append(Entry(model)) }
    public static func prepareForTermination() async -> Bool {
        entries.removeAll { $0.model == nil }
        for entry in entries { if let model = entry.model, !(await model.prepareForTermination()) { return false } }
        return true
    }
    public static func resumeAfterCancelledExit() { for entry in entries { entry.model?.resumeAfterCancelledExit() } }
}

/// 草稿确认期间不暂停笔记、不发布后台交接；只恢复本次已进入准备阶段的模块。
@MainActor
public enum AppQuitSequence {
    public static func shouldQuit(
        markdown: @MainActor () async -> Bool, mail: @MainActor () async -> Bool,
        nativeApps: @MainActor () async -> Bool, prepareNotes: @MainActor () async -> Bool,
        handoff: @MainActor () async -> Bool, resumeNotes: @MainActor () -> Void,
        resumeApps: @MainActor () -> Void
    ) async -> Bool {
        guard await markdown(), await mail() else { return false }
        guard await nativeApps() else { resumeApps(); return false }
        guard await prepareNotes(), await handoff() else {
            resumeNotes()
            resumeApps()
            return false
        }
        return true
    }
}

enum NoteCaptureRecoveryText {
    static func read(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw AgRoomCore.NoteStoreError.tooLarge }
        return try Data(contentsOf: file)
    }
}
