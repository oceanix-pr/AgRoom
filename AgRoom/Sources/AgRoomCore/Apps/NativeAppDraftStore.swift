import Foundation
import CryptoKit

/// Pending generated definitions are internal task state, physically bound to one space.
/// Saving a draft never installs an app or authorizes any of its actions.
public struct NativeAppPendingDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let space: AppSpace
    public let createdAt: Date
    public let definition: NativeAppDefinition
    public let sourceSessionID: UUID?
    public let updatingAppID: String?
}

public struct NativeAppDraftCatalog: Sendable {
    public let drafts: [NativeAppPendingDraft]
    public let invalidIDs: [UUID]
}

public struct NativeAppDraftStore: Sendable {
    public let directoryURL: URL
    public let space: AppSpace
    public init(directoryURL: URL, space: AppSpace) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.space = space
    }
    public func catalog() async throws -> NativeAppDraftCatalog {
        try await NativeAppDraftDisk.shared.catalog(root: directoryURL, space: space)
    }
    @discardableResult
    public func save(_ definition: NativeAppDefinition, sourceSessionID: UUID? = nil,
                     updatingAppID: String? = nil) async throws -> NativeAppPendingDraft {
        try Task.checkCancellation()
        return try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) {
            try await NativeAppDraftDisk.shared.save(definition, root: directoryURL, space: space,
                sourceSessionID: sourceSessionID, updatingAppID: updatingAppID)
        }
    }
    public func discard(id: UUID) async throws {
        try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) {
            try await NativeAppDraftDisk.shared.discard(id: id, root: directoryURL)
        }
    }

    func restoreDraft(_ draft: NativeAppPendingDraft) async throws {
        guard draft.space == space else { throw NativeAppError(.spaceMismatch) }
        try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) {
            try await NativeAppDraftDisk.shared.restore(draft, root: directoryURL, space: space)
        }
    }
}

/// Serial file operations with no cached space content. Reuses the app store's no-follow I/O.
private actor NativeAppDraftDisk {
    static let shared = NativeAppDraftDisk()
    private static let maximumBytes = NativeAppDefinition.maximumBytes + 4096
    private static let maximumDrafts = 8

    private func name(_ id: UUID) -> String { id.uuidString.lowercased() + ".draft.json" }
    private func id(_ name: String) -> UUID? {
        guard name.hasSuffix(".draft.json") else { return nil }
        return UUID(uuidString: String(name.dropLast(".draft.json".count)))
    }
    private func read(_ id: UUID, directory: AppDirectory, space: AppSpace) throws -> NativeAppPendingDraft {
        let data = try directory.read(name(id), limit: Self.maximumBytes)
        let draft = try JSONDecoder().decode(NativeAppPendingDraft.self, from: data)
        guard draft.id == id, draft.space == space else { throw NativeAppError(.spaceMismatch) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let definition = object["definition"] else { throw NativeAppError(.invalidDefinition) }
        _ = try NativeAppDefinition.decode(JSONSerialization.data(withJSONObject: definition))
        if let updating = draft.updatingAppID, updating != draft.definition.id { throw NativeAppError(.incompatibleState) }
        return draft
    }

    func catalog(root: URL, space: AppSpace) throws -> NativeAppDraftCatalog {
        let directory: AppDirectory
        do { directory = try AppDirectory(url: root, create: false) }
        catch let issue as NativeAppError where issue.code == .missing {
            return NativeAppDraftCatalog(drafts: [], invalidIDs: [])
        }
        var drafts: [NativeAppPendingDraft] = [], invalid: [UUID] = []
        let ids = try directory.names().compactMap(id)
        guard ids.count <= Self.maximumDrafts else { throw NativeAppError(.capacity, path: "drafts") }
        for id in ids {
            do { drafts.append(try read(id, directory: directory, space: space)) }
            catch { invalid.append(id) }
        }
        return NativeAppDraftCatalog(drafts: drafts.sorted { $0.createdAt > $1.createdAt }, invalidIDs: invalid)
    }

    func save(_ definition: NativeAppDefinition, root: URL, space: AppSpace,
              sourceSessionID: UUID?, updatingAppID: String?) throws -> NativeAppPendingDraft {
        try Task.checkCancellation()
        try definition.validate()
        if let updatingAppID, updatingAppID != definition.id { throw NativeAppError(.incompatibleState) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var identity = try encoder.encode(definition)
        identity.append(Data(("|" + space.rawValue + "|" + (sourceSessionID?.uuidString ?? "") + "|" + (updatingAppID ?? "")).utf8))
        let hex = SHA256.hash(data: identity).prefix(16).map { String(format: "%02x", $0) }.joined()
        let groups = [8, 4, 4, 4, 12]
        var cursor = hex.startIndex
        let uuid = groups.map { size -> String in
            let end = hex.index(cursor, offsetBy: size)
            defer { cursor = end }
            return String(hex[cursor..<end])
        }.joined(separator: "-")
        guard let id = UUID(uuidString: uuid) else { throw NativeAppError(.storage) }
        let directory = try AppDirectory(url: root, create: true)
        if directory.exists(name(id)) { return try read(id, directory: directory, space: space) }
        guard try directory.names().compactMap(self.id).count < Self.maximumDrafts else { throw NativeAppError(.capacity, path: "drafts") }
        let draft = NativeAppPendingDraft(id: id, space: space, createdAt: Date(), definition: definition,
            sourceSessionID: sourceSessionID, updatingAppID: updatingAppID)
        let data = try encoder.encode(draft)
        guard data.count <= Self.maximumBytes else { throw NativeAppError(.tooLarge) }
        try directory.write(data, name: name(id))
        return draft
    }

    func discard(id: UUID, root: URL) throws {
        let directory = try AppDirectory(url: root, create: false)
        try directory.removeFile(name(id), missingOK: true)
    }

    func restore(_ draft: NativeAppPendingDraft, root: URL, space: AppSpace) throws {
        guard draft.space == space else { throw NativeAppError(.spaceMismatch) }
        try draft.definition.validate()
        if let updating = draft.updatingAppID, updating != draft.definition.id { throw NativeAppError(.incompatibleState) }
        let directory = try AppDirectory(url: root, create: true)
        guard !directory.exists(name(draft.id)), try directory.names().compactMap(id).count < Self.maximumDrafts else {
            throw NativeAppError(.conflict)
        }
        let data = try JSONEncoder().encode(draft)
        guard data.count <= Self.maximumBytes else { throw NativeAppError(.tooLarge) }
        try directory.write(data, name: name(draft.id))
    }
}
