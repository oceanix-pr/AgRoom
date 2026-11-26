import Foundation
import AgRoomCore
import Darwin

struct MarkdownRecoveryDraft: Codable, Sendable, Equatable {
    let text: String
    let suggestedName: String
}

actor MarkdownDraftStore {
    static let shared = MarkdownDraftStore()
    private var revisions: [AppSpace: UInt] = [:]
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgRoom")
    }
    private func path(_ space: AppSpace) -> URL { root.appendingPathComponent(space.rawValue).appendingPathComponent("markdown-editor-draft.json") }
    func load(_ space: AppSpace) throws -> MarkdownRecoveryDraft? {
        let file = path(space)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(MarkdownRecoveryDraft.self, from: BoundedDocumentIO.readData(file, limit: 3 * 1024 * 1024))
    }
    func save(_ draft: MarkdownRecoveryDraft?, space: AppSpace, revision: UInt) throws {
        guard revision >= revisions[space, default: 0] else { return }
        let file = path(space)
        if let draft {
            guard draft.text.utf8.count <= BoundedDocumentIO.limit else { throw LLMError.responseTooLarge }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        revisions[space] = revision
    }
}

enum BoundedDocumentIO {
    static let limit = 2 * 1024 * 1024
    static func readData(_ url: URL, limit: Int = limit) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard info.st_size <= limit else { throw LLMError.responseTooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw LLMError.responseTooLarge }
        }
        return data
    }
    static func read(_ url: URL) throws -> String {
        guard let text = String(data: try readData(url), encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }
}

/// Only UI draft state is retained; each space has its own physical recovery file.
@MainActor public enum MarkdownDraftLifecycle {
    private struct State { let draft: MarkdownRecoveryDraft?; let revision: UInt }
    private static var states: [AppSpace: State] = [:]
    static func update(_ draft: MarkdownRecoveryDraft?, space: AppSpace) {
        states[space] = State(draft: draft, revision: states[space, default: State(draft: nil, revision: 0)].revision &+ 1)
    }
    static func load(space: AppSpace) async throws -> MarkdownRecoveryDraft? {
        if let state = states[space] { return state.draft }
        let draft = try await MarkdownDraftStore.shared.load(space)
        if let state = states[space] { return state.draft }
        states[space] = State(draft: draft, revision: 0)
        return draft
    }
    static func persist(space: AppSpace) async throws {
        guard let state = states[space] else { return }
        try await MarkdownDraftStore.shared.save(state.draft, space: space, revision: state.revision)
    }
    public static func saveAll() async -> Bool {
        do { for space in states.keys { try await persist(space: space) }; return true }
        catch { return false }
    }
}
