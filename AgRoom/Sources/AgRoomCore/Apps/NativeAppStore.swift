import Foundation
import CryptoKit
import Darwin

public enum NativeAppIconColor: String, CaseIterable, Codable, Sendable {
    case space, blue, teal, green, orange, rose, purple, gray
}

struct NativeAppAppearance: Codable, Sendable {
    let iconColor: NativeAppIconColor
}

public struct NativeAppSnapshot: Sendable, Equatable {
    public let definition: NativeAppDefinition
    public let revision: String
    public let hasPrevious: Bool
    public var isInstalled = true
}

public struct NativeAppSummary: Sendable, Identifiable {
    public let id: String
    public let version: Int
    public let icon: String
    public let names: [String: String]
    public let summaries: [String: String]
    public var iconColor: NativeAppIconColor = .space
    public var iconColorNeedsReset = false
    public func name(language: String) -> String { names[language] ?? names["en"] ?? id }
    public func summary(language: String) -> String { summaries[language] ?? summaries["en"] ?? "" }
}

public struct NativeAppCatalog: Sendable {
    public let apps: [NativeAppSummary]
    public let invalidIDs: [String]
    public var retainedApps: [NativeAppSummary] = []
}

/// Value factory bound to one space directory. The disk actor serializes publication,
/// including stores freshly constructed by different windows; it caches no space data.
public struct NativeAppStore: Sendable {
    public let directoryURL: URL
    public let space: AppSpace
    public init(directoryURL: URL, space: AppSpace) {
        self.directoryURL = directoryURL.standardizedFileURL; self.space = space
    }

    public func catalog() async throws -> NativeAppCatalog {
        try await NativeAppDisk.shared.catalog(root: directoryURL)
    }
    /// User-triggered visual preference, independent of the app definition and business state.
    public func setIconColor(_ color: NativeAppIconColor, id: String) async throws {
        try Task.checkCancellation()
        try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) { try await NativeAppDisk.shared.setIconColor(root: directoryURL, id: id, color: color) }
    }
    public func load(id: String) async throws -> NativeAppSnapshot {
        try await NativeAppDisk.shared.load(root: directoryURL, id: id)
    }
    public func install(_ definition: NativeAppDefinition, replacing revision: String?) async throws {
        try Task.checkCancellation()
        try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) { try await NativeAppDisk.shared.install(root: directoryURL, definition: definition, expected: revision) }
    }
    public func restore(id: String, replacing revision: String) async throws {
        try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) { try await NativeAppDisk.shared.restore(root: directoryURL, id: id, expected: revision) }
    }
    public func remove(id: String, revision: String, keepData: Bool = false) async throws {
        try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) { try await NativeAppDisk.shared.remove(root: directoryURL, id: id, expected: revision, keepData: keepData) }
    }
    public func loadState(for definition: NativeAppDefinition) async throws -> [String: NativeAppValue] {
        try await NativeAppDisk.shared.loadState(root: directoryURL, definition: definition)
    }
    public func saveState(_ values: [String: NativeAppValue], for definition: NativeAppDefinition) async throws {
        try Task.checkCancellation()
        try await ResourceMaintenance.withAsyncAccess(ResourceMaintenance.directoryKey(directoryURL)) { try await NativeAppDisk.shared.saveState(root: directoryURL, definition: definition, values: values) }
    }

    /// Called only for a URL explicitly selected by the user. Bounded even if the
    /// selected file grows after selection; symlinks and non-regular files are rejected.
    public static func importDefinition(from url: URL) async throws -> NativeAppDefinition {
        guard url.isFileURL else { throw NativeAppError(.unsafePath) }
        return try await Task.detached(priority: .userInitiated) {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw NativeAppError(.unsafePath) }
            defer { Darwin.close(fd) }
            return try NativeAppDefinition.decode(AppDirectory.read(fd: fd, limit: NativeAppDefinition.maximumBytes))
        }.value
    }
}

actor NativeAppDisk {
    static let shared = NativeAppDisk()

    func catalog(root: URL) throws -> NativeAppCatalog {
        let directory: AppDirectory
        do { directory = try AppDirectory(url: root, create: false) }
        catch let error as NativeAppError where error.code == .missing { return NativeAppCatalog(apps: [], invalidIDs: []) }
        var apps: [NativeAppSummary] = []
        var invalid: [String] = []
        var retained: [NativeAppSummary] = []
        let ids = try directory.names().filter(NativeAppDefinition.validID).sorted()
        guard ids.count <= 64 else { throw NativeAppError(.capacity) }
        for id in ids {
            do {
                let snapshot = try load(directory: directory, id: id, includingRetained: true)
                let definition = snapshot.definition
                var summary = NativeAppSummary(id: id, version: definition.manifest.version, icon: definition.manifest.icon,
                    names: definition.i18n.mapValues { $0[definition.manifest.nameKey] ?? id },
                    summaries: definition.i18n.mapValues { $0[definition.manifest.summaryKey] ?? "" })
                do { summary.iconColor = try iconColor(app: directory.child(id, create: false)) }
                catch { summary.iconColorNeedsReset = true }
                if snapshot.isInstalled { apps.append(summary) } else { retained.append(summary) }
            } catch { invalid.append(id) }
        }
        return NativeAppCatalog(apps: apps, invalidIDs: invalid, retainedApps: retained)
    }

    func iconColor(app: AppDirectory) throws -> NativeAppIconColor {
        guard app.exists("appearance.json") else { return .space }
        do { return try JSONDecoder().decode(NativeAppAppearance.self, from: app.read("appearance.json", limit: 1024)).iconColor }
        catch let error as NativeAppError { throw error }
        catch { throw NativeAppError(.corruptData) }
    }

    func setIconColor(root: URL, id: String, color: NativeAppIconColor) throws {
        try Task.checkCancellation()
        let directory = try AppDirectory(url: root, create: false)
        _ = try load(directory: directory, id: id)
        let app = try directory.child(id, create: false)
        if color == .space { try app.removeFile("appearance.json", missingOK: true) }
        else { try app.write(JSONEncoder().encode(NativeAppAppearance(iconColor: color)), name: "appearance.json") }
    }

    func load(root: URL, id: String) throws -> NativeAppSnapshot {
        try load(directory: AppDirectory(url: root, create: false), id: id)
    }

    func load(directory: AppDirectory, id: String, includingRetained: Bool = false) throws -> NativeAppSnapshot {
        guard NativeAppDefinition.validID(id) else { throw NativeAppError(.unsafePath) }
        let app = try directory.child(id, create: false)
        let installed = !app.exists("retained.zhiapp.json")
        guard installed || includingRetained else { throw NativeAppError(.missing) }
        let data = try app.read(installed ? "app.zhiapp.json" : "retained.zhiapp.json", limit: NativeAppDefinition.maximumBytes)
        let definition = try NativeAppDefinition.decode(data)
        guard definition.id == id else { throw NativeAppError(.invalidDefinition, path: "manifest.id") }
        return NativeAppSnapshot(definition: definition, revision: Self.digest(data),
            hasPrevious: app.exists("previous.zhiapp.json"), isInstalled: installed)
    }

    func install(root: URL, definition: NativeAppDefinition, expected: String?) throws {
        try Task.checkCancellation()
        try definition.validate()
        let directory = try AppDirectory(url: root, create: true)
        let existing: NativeAppSnapshot?
        do { existing = try load(directory: directory, id: definition.id, includingRetained: true) }
        catch let error as NativeAppError where error.code == .missing { existing = nil }
        guard existing?.revision == expected else { throw NativeAppError(.conflict) }
        if let existing {
            guard !existing.isInstalled || definition.manifest.version > existing.definition.manifest.version else { throw NativeAppError(.conflict, path: "manifest.version") }
            guard definition.acceptsStateSchema(of: existing.definition) else { throw NativeAppError(.incompatibleState) }
            guard definition.dataVersion == existing.definition.dataVersion else { throw NativeAppError(.incompatibleState) }
            let app = try directory.child(definition.id, create: false)
            if app.exists("state.json") {
                try definition.validateSavedDraft(NativeAppDraftState.decode(
                    app.read("state.json", limit: NativeAppDefinition.maximumStateBytes)))
            }
        } else {
            guard try directory.names().filter(NativeAppDefinition.validID).count < 64 else { throw NativeAppError(.capacity) }
            if directory.exists(definition.id) {
                guard try directory.child(definition.id, create: false).names().isEmpty else { throw NativeAppError(.conflict) }
            }
        }
        let app = try directory.child(definition.id, create: true)
        if let existing { try app.write(try existing.definition.encoded(), name: "previous.zhiapp.json") }
        try Task.checkCancellation()
        try app.removeFile(Self.scriptReviewFile, missingOK: true)
        try app.write(try definition.encoded(), name: "app.zhiapp.json")
        if !((existing?.isInstalled) ?? true) { try app.removeFile("retained.zhiapp.json") }
        _ = try workspaceIdentity(app: app, create: true)
    }

    func restore(root: URL, id: String, expected: String) throws {
        try Task.checkCancellation()
        let directory = try AppDirectory(url: root, create: false)
        let current = try load(directory: directory, id: id)
        guard current.revision == expected else { throw NativeAppError(.conflict) }
        let app = try directory.child(id, create: false)
        let data = try app.read("previous.zhiapp.json", limit: NativeAppDefinition.maximumBytes)
        let previous = try NativeAppDefinition.decode(data)
        guard previous.id == id, previous.hasSamePersistentSchema(as: current.definition) else { throw NativeAppError(.incompatibleState) }
        guard previous.dataVersion == current.definition.dataVersion else { throw NativeAppError(.incompatibleState) }
        if app.exists("state.json") {
            try previous.validateSavedDraft(NativeAppDraftState.decode(app.read("state.json", limit: NativeAppDefinition.maximumStateBytes)))
        }
        // Leave the recovery copy intact until the restored definition is published.
        try app.removeFile(Self.scriptReviewFile, missingOK: true)
        try app.write(data, name: "app.zhiapp.json")
    }

    func remove(root: URL, id: String, expected: String, keepData: Bool) throws {
        try Task.checkCancellation()
        let directory = try AppDirectory(url: root, create: false)
        let current = try load(directory: directory, id: id, includingRetained: true)
        guard current.revision == expected else { throw NativeAppError(.conflict) }
        let app = try directory.child(id, create: false)
        if keepData {
            try app.removeFile(Self.scriptReviewFile, missingOK: true)
            try app.write(JSONEncoder().encode(NativeAppWorkspaceIdentity(id: UUID(), dataVersion: 1)), name: "workspace.json")
            try app.write(try current.definition.encoded(), name: "retained.zhiapp.json")
            try app.removeFile("app.zhiapp.json", missingOK: true)
            try app.removeFile("previous.zhiapp.json", missingOK: true)
            return
        }
        let tombstone = ".removed-" + UUID().uuidString
        guard renameat(directory.fd, id, directory.fd, tombstone) == 0 else { throw NativeAppError(.storage) }
        try directory.removeTree(tombstone)
        if directory.exists(".recovery") {
            let recovery = try directory.child(".recovery", create: false)
            try recovery.removeFile(id + ".json", missingOK: true)
            if recovery.exists("raw-" + id) { try recovery.removeTree("raw-" + id) }
        }
    }

    func loadState(root: URL, definition: NativeAppDefinition) throws -> [String: NativeAppValue] {
        let directory = try AppDirectory(url: root, create: false)
        let current = try load(directory: directory, id: definition.id)
        guard current.definition.hasSamePersistentSchema(as: definition) else { throw NativeAppError(.incompatibleState) }
        let app = try directory.child(definition.id, create: false)
        guard app.exists("state.json") else { return [:] }
        do {
            let data = try app.read("state.json", limit: NativeAppDefinition.maximumStateBytes)
            let draft = try NativeAppDraftState.decode(data)
            try definition.validateSavedDraft(draft)
            return draft.values
        } catch let error as NativeAppError { throw error }
        catch { throw NativeAppError(.incompatibleState) }
    }

    func saveState(root: URL, definition: NativeAppDefinition, values: [String: NativeAppValue]) throws {
        try Task.checkCancellation()
        try definition.validateSavedState(values)
        let directory = try AppDirectory(url: root, create: false)
        let current = try load(directory: directory, id: definition.id)
        guard current.definition.hasSamePersistentSchema(as: definition) else { throw NativeAppError(.incompatibleState) }
        try current.definition.validateSavedState(values)
        let app = try directory.child(definition.id, create: false)
        let saved = try app.exists("state.json") ? NativeAppDraftState.decode(app.read("state.json", limit: NativeAppDefinition.maximumStateBytes)) : NativeAppDraftState(values: [:])
        let draft = NativeAppDraftState(values: values, editors: saved.editors, boards: saved.boards)
        try current.definition.validateSavedDraft(draft)
        let data = try draft.encoded()
        guard data.count <= NativeAppDefinition.maximumStateBytes else { throw NativeAppError(.tooLarge) }
        try app.write(data, name: "state.json")
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Descriptor-relative operations avoid check/use races through a renamed directory
/// or symlink. No I/O occurs inside a state lock or on the main actor.
final class AppDirectory {
    let fd: Int32
    private init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }

    convenience init(url: URL, create: Bool) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw NativeAppError(.unsafePath) }
        var directory = AppDirectory(fd: Darwin.open("/", O_RDONLY | O_DIRECTORY))
        guard directory.fd >= 0 else { throw NativeAppError(.storage) }
        let rawPath = url.standardizedFileURL.path
        // Foundation canonicalizes the system temp directory back to /var even
        // after resolvingSymlinksInPath. Expand only these fixed macOS aliases;
        // user-controlled links at any level remain forbidden.
        let path = rawPath.hasPrefix("/var/") || rawPath.hasPrefix("/tmp/") ? "/private" + rawPath : rawPath
        for component in path.split(separator: "/").map(String.init) {
            directory = try directory.child(component, create: create)
        }
        let copied = dup(directory.fd)
        guard copied >= 0 else { throw NativeAppError(.storage) }
        self.init(fd: copied)
    }

    func child(_ name: String, create: Bool, exclusive: Bool = false) throws -> AppDirectory {
        if create, mkdirat(fd, name, 0o700) != 0, exclusive || errno != EEXIST { throw NativeAppError(.storage) }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else {
            throw NativeAppError(errno == ENOENT ? .missing : .unsafePath)
        }
        return AppDirectory(fd: child)
    }

    func exists(_ name: String) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    func names(limit: Int = 512) throws -> [String] {
        let copied = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copied >= 0 else { throw NativeAppError(.storage) }
        guard let stream = fdopendir(copied) else { Darwin.close(copied); throw NativeAppError(.storage) }
        defer { closedir(stream) }
        var result: [String] = []
        // A corrupt or externally populated directory cannot cause an unbounded scan.
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= limit else { throw NativeAppError(.capacity) }
        }
        return result
    }

    func read(_ name: String, limit: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw NativeAppError(errno == ENOENT ? .missing : .unsafePath) }
        defer { Darwin.close(file) }
        return try Self.read(fd: file, limit: limit)
    }

    static func read(fd: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw NativeAppError(.unsafePath) }
        guard info.st_size <= limit else { throw NativeAppError(.tooLarge) }
        guard info.st_size >= 0 else { throw NativeAppError(.storage) }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = Data(count: min(64 * 1024, limit + 1))
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!, min($0.count, limit + 1 - data.count))
            }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw NativeAppError(.storage) }
            data.append(buffer.prefix(count))
        }
        guard data.count <= limit else { throw NativeAppError(.tooLarge) }
        return data
    }

    func write(_ data: Data, name: String) throws {
        let temporary = ".pending-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw NativeAppError(.storage) }
        defer { Darwin.close(file); _ = unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var count = 0
            while count < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                if written < 0 { if errno == EINTR { continue }; throw NativeAppError(.storage) }
                guard written > 0 else { throw NativeAppError(.storage) }
                count += written
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0 else { throw NativeAppError(.storage) }
        guard fsync(fd) == 0 else { throw NativeAppError(.storage) }
    }

    func checkRegular(_ name: String, missingOK: Bool = true, limit: Int = 64 * 1024 * 1024) throws {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if missingOK && errno == ENOENT { return }
            throw NativeAppError(.storage)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw NativeAppError(.unsafePath) }
        guard info.st_size <= limit else { throw NativeAppError(.tooLarge) }
    }

    /// macOS fdescfs does not support opening children through /dev/fd/<dirfd>.
    /// SQLite needs a real pathname; obtain it from the already validated handle
    /// and verify its directory identity before and after opening the connection.
    func kernelURL() throws -> URL {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withUnsafeMutableBufferPointer({ fcntl(fd, F_GETPATH, $0.baseAddress!) }) == 0 else {
            throw NativeAppError(.unsafePath)
        }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let url = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
        try verifyIdentity(at: url)
        return url
    }

    func verifyIdentity(at url: URL) throws {
        let current = try AppDirectory(url: url, create: false)
        var original = stat(), reopened = stat()
        guard fstat(fd, &original) == 0, fstat(current.fd, &reopened) == 0,
              original.st_dev == reopened.st_dev, original.st_ino == reopened.st_ino else {
            throw NativeAppError(.unsafePath)
        }
    }

    func removeFile(_ name: String, missingOK: Bool = false) throws {
        if unlinkat(fd, name, 0) != 0, !(missingOK && errno == ENOENT) { throw NativeAppError(.storage) }
    }

    func removeTree(_ name: String, depth: Int = 0) throws {
        guard depth < 8 else { throw NativeAppError(.unsafePath) }
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeAppError(.storage) }
        if info.st_mode & S_IFMT == S_IFDIR {
            let directory = try child(name, create: false)
            for child in try directory.names() { try directory.removeTree(child, depth: depth + 1) }
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw NativeAppError(.storage) }
        } else {
            // Unlink links themselves; never follow them during deletion.
            try removeFile(name)
        }
    }
}
