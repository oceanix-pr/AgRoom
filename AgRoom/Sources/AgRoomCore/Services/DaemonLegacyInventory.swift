import CryptoKit
import Darwin
import Foundation

/// Read-only evidence inventory for the legacy, shared Daemon root. This is an
/// internal migration prerequisite, not an authorization to move or resume a run.
/// In particular, file corroboration does not establish database ownership.
enum DaemonLegacyInventory {
    struct Limits: Sendable {
        let maxFileBytes: Int64
        let maxTotalBytes: Int64
        let maxIdentityBytes: Int64
        let maxEntries: Int
        let maxDepth: Int

        init(maxFileBytes: Int64 = 64 * 1_024 * 1_024,
             maxTotalBytes: Int64 = 512 * 1_024 * 1_024,
             maxIdentityBytes: Int64 = 32 * 1_024 * 1_024,
             maxEntries: Int = 20_000, maxDepth: Int = 16) {
            self.maxFileBytes = max(0, maxFileBytes)
            self.maxTotalBytes = max(0, maxTotalBytes)
            self.maxIdentityBytes = max(0, maxIdentityBytes)
            self.maxEntries = max(0, maxEntries)
            self.maxDepth = max(0, maxDepth)
        }
    }

    enum Kind: Sendable, Equatable {
        case runRecord, handoffRecord, ownerRecord
        case journalDirectory, journalFile
        case quarantineDirectory, abandonedDirectory
        case quarantinedEvidence, abandonedEvidence
        case legacyLog, globalLock, layout, spaceBoundary
        case temporary, unknown, symbolicLink, unsupportedType
    }

    enum Status: Sendable, Equatable {
        case verified, directory, notInspected
        case unreadable, changedDuringScan, overBudget
        case foreignOwner, hardLinked, invalidIdentity
        case symbolicLink, unsupportedType
    }

    struct Entry: Sendable {
        /// Relative to the explicit root. Never write this or a digest to logs.
        let relativePath: String
        let kind: Kind
        let byteCount: Int64?
        let sha256: String?
        let runID: UUID?
        let status: Status
    }

    enum UnknownReason: Sendable, Equatable {
        case missingOwner, missingBody, multipleBodies
        case invalidIdentity, conflictingIdentity, relatedEvidence, incompleteScan
    }

    enum Ownership: Sendable, Equatable {
        /// Only owner/body/journal files corroborate each other. The space DB,
        /// daemon state, store lock and migration target still require checks.
        case fileCorroborated(space: AppSpace, sessionID: UUID,
                             messageID: UUID, taskRunID: UUID?)
        case unknown(reason: UnknownReason)
    }

    enum BodyState: Sendable, Equatable {
        case completed, recoveryRequired, active
    }

    struct Group: Sendable {
        let id: UUID
        let entries: [Entry]
        let ownership: Ownership
        let bodySHA256: String?
        let bodyState: BodyState?
        /// Hash only; the raw restore token is never put in an inventory
        /// report or diagnostic description.
        let restorationTokenSHA256: String?
        /// Canonical hash of a decoded run body, including state, restore
        /// token, settings and snapshot. Nil for a legacy handoff or an
        /// unreadable body. This is a preflight consistency hint only.
        let canonicalRunSHA256: String?
    }

    struct Summary: Sendable {
        let entryCount: Int
        let groupCount: Int
        let totalHashedBytes: Int64
        let hasLegacyContent: Bool
        let hasUnknownEvidence: Bool
        let isComplete: Bool
    }

    struct Report: Sendable {
        let entries: [Entry]
        let groups: [Group]
        let summary: Summary
    }

    static func inspect(root: URL, limits: Limits = Limits()) -> Report {
        var scanner = Scanner(limits: limits)
        scanner.inspect(root: root)
        return scanner.report()
    }

    static func canonicalRunSHA256(_ record: DaemonRunRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return nil }
        return "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func restorationTokenSHA256(_ token: String?) -> String? {
        guard let token else { return nil }
        return "sha256:" + SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func bodyState(_ state: DaemonRunState) -> BodyState {
        switch state {
        case .completed: return .completed
        case .recoveryRequired: return .recoveryRequired
        default: return .active
        }
    }

    private struct Identity: Equatable {
        let id: UUID
        let space: AppSpace
        let sessionID: UUID
        let messageID: UUID
        let taskRunID: UUID?
    }

    private struct OwnerHeader: Decodable {
        let version: Int
        let id: UUID
        let space: AppSpace
        let sessionId: UUID
        let assistantMessageId: UUID
        let taskRunID: UUID?

        var identity: Identity {
            Identity(id: id, space: space, sessionID: sessionId,
                     messageID: assistantMessageId, taskRunID: taskRunID)
        }
    }

    private struct JournalPayload: Decodable {
        let version: Int
        let entries: [String: OperationJournal.Entry]
    }

    private enum ParsedEvidence {
        case owner(Identity, version: Int)
        case body(Identity, state: BodyState?,
                  restorationTokenSHA256: String?, canonicalRunSHA256: String?)
        case journal(runID: UUID, spaces: Set<AppSpace>, valid: Bool)
        case invalid
    }

    private struct Scanner {
        let limits: Limits
        var entries: [Entry] = []
        var parsed: [String: ParsedEvidence] = [:]
        var totalHashedBytes: Int64 = 0
        var complete = true

        mutating func inspect(root: URL) {
            let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                complete = false
                entries.append(Entry(relativePath: ".", kind: .unknown, byteCount: nil,
                                     sha256: nil, runID: nil, status: .unreadable))
                return
            }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, Self.isDirectory(before),
                  before.st_uid == geteuid() else {
                complete = false
                entries.append(Entry(relativePath: ".", kind: .unknown, byteCount: nil,
                                     sha256: nil, runID: nil, status: .foreignOwner))
                return
            }
            walk(directoryFD: fd, prefix: "", depth: 0)
            var after = stat()
            var pathAfter = stat()
            if fstat(fd, &after) != 0 || lstat(root.path, &pathAfter) != 0 ||
                !Self.sameMetadata(before, after) || !Self.sameMetadata(before, pathAfter) {
                complete = false
            }
        }

        private mutating func walk(directoryFD: Int32, prefix: String, depth: Int) {
            guard depth <= limits.maxDepth else { complete = false; return }
            guard let stream = fdopendir(dup(directoryFD)) else { complete = false; return }
            var names: [String] = []
            errno = 0
            while let item = readdir(stream) {
                if names.count >= max(0, limits.maxEntries - entries.count) {
                    complete = false
                    break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: 1_024) {
                        String(validatingCString: $0)
                    }
                }
                guard let name else { complete = false; continue }
                if name != "." && name != ".." { names.append(name) }
                errno = 0
            }
            if errno != 0 { complete = false }
            closedir(stream)

            for name in names.sorted() {
                if entries.count >= limits.maxEntries { complete = false; break }
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                var before = stat()
                guard name.withCString({ fstatat(directoryFD, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    append(path: path, kind: .unknown, id: nil, size: nil, digest: nil, status: .unreadable)
                    complete = false
                    continue
                }
                let classification = Self.classify(path: path, isDirectory: Self.isDirectory(before))
                let id = classification.id
                if Self.isSymbolicLink(before) {
                    append(path: path, kind: .symbolicLink, id: id, size: nil, digest: nil, status: .symbolicLink)
                    continue
                }
                if before.st_uid != geteuid() {
                    append(path: path, kind: classification.kind, id: id, size: nil, digest: nil, status: .foreignOwner)
                    continue
                }
                if Self.isDirectory(before) {
                    if classification.kind == .spaceBoundary {
                        append(path: path, kind: .spaceBoundary, id: nil, size: nil, digest: nil, status: .notInspected)
                        continue
                    }
                    let child = name.withCString { openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    guard child >= 0 else {
                        append(path: path, kind: classification.kind, id: id, size: nil, digest: nil, status: .unreadable)
                        complete = false
                        continue
                    }
                    var opened = stat()
                    if fstat(child, &opened) != 0 || !Self.sameMetadata(before, opened) {
                        append(path: path, kind: classification.kind, id: id, size: nil, digest: nil, status: .changedDuringScan)
                        complete = false
                        close(child)
                        continue
                    }
                    let entryIndex = entries.count
                    append(path: path, kind: classification.kind, id: id, size: nil, digest: nil, status: .directory)
                    walk(directoryFD: child, prefix: path, depth: depth + 1)
                    var after = stat()
                    var pathAfter = stat()
                    let stable = fstat(child, &after) == 0 &&
                        name.withCString({ fstatat(directoryFD, $0, &pathAfter, AT_SYMLINK_NOFOLLOW) }) == 0 &&
                        Self.sameMetadata(opened, after) && Self.sameMetadata(opened, pathAfter)
                    close(child)
                    if !stable {
                        entries[entryIndex] = Entry(relativePath: path, kind: classification.kind,
                                                    byteCount: nil, sha256: nil, runID: id,
                                                    status: .changedDuringScan)
                        complete = false
                    }
                    continue
                }
                guard Self.isRegular(before) else {
                    append(path: path, kind: .unsupportedType, id: id, size: nil, digest: nil, status: .unsupportedType)
                    continue
                }
                if before.st_nlink > 1 {
                    append(path: path, kind: classification.kind, id: id,
                           size: before.st_size, digest: nil, status: .hardLinked)
                    continue
                }
                readFile(directoryFD: directoryFD, name: name, path: path,
                         before: before, kind: classification.kind, id: id)
            }
        }

        private mutating func readFile(directoryFD: Int32, name: String, path: String,
                                       before: stat, kind: Kind, id: UUID?) {
            let size = before.st_size
            guard size >= 0, size <= limits.maxFileBytes,
                  size <= limits.maxTotalBytes - totalHashedBytes else {
                append(path: path, kind: kind, id: id, size: size, digest: nil, status: .overBudget)
                complete = false
                return
            }
            let fd = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            guard fd >= 0 else {
                append(path: path, kind: kind, id: id, size: size, digest: nil, status: .unreadable)
                complete = false
                return
            }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, Self.isRegular(opened),
                  opened.st_uid == geteuid(), opened.st_nlink == 1,
                  Self.sameMetadata(before, opened) else {
                append(path: path, kind: kind, id: id, size: size, digest: nil, status: .changedDuringScan)
                complete = false
                return
            }
            var hasher = SHA256()
            let needsIdentity = kind == .ownerRecord || kind == .runRecord ||
                kind == .handoffRecord || kind == .journalFile
            var data: Data? = needsIdentity && size <= limits.maxIdentityBytes ? Data() : nil
            var readBytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            var failed = false
            var readError = false
            var exceededBudget = false
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(fd, bytes.baseAddress, bytes.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    readError = true
                    break
                }
                readBytes += Int64(count)
                if readBytes > limits.maxFileBytes || readBytes > limits.maxTotalBytes - totalHashedBytes {
                    failed = true
                    exceededBudget = true
                    break
                }
                buffer.withUnsafeBytes { bytes in
                    let part = UnsafeRawBufferPointer(rebasing: bytes[..<count])
                    hasher.update(data: part)
                    data?.append(part.bindMemory(to: UInt8.self))
                }
            }
            var after = stat()
            var pathAfter = stat()
            let stable = !failed && readBytes == size && fstat(fd, &after) == 0 &&
                name.withCString({ fstatat(directoryFD, $0, &pathAfter, AT_SYMLINK_NOFOLLOW) }) == 0 &&
                Self.sameMetadata(opened, after) && Self.sameMetadata(opened, pathAfter)
            guard stable else {
                append(path: path, kind: kind, id: id, size: size, digest: nil,
                       status: exceededBudget ? .overBudget : (readError ? .unreadable : .changedDuringScan))
                complete = false
                return
            }
            totalHashedBytes += readBytes
            let digest = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            var status: Status = .verified
            if needsIdentity && data == nil {
                status = .overBudget
                complete = false
            } else if needsIdentity {
                if let data, let id, let identity = Self.parse(kind: kind, id: id, data: data) {
                    parsed[path] = identity
                } else {
                    parsed[path] = .invalid
                    status = .invalidIdentity
                }
            }
            append(path: path, kind: kind, id: id, size: size, digest: digest, status: status)
        }

        private mutating func append(path: String, kind: Kind, id: UUID?, size: Int64?,
                                     digest: String?, status: Status) {
            entries.append(Entry(relativePath: path, kind: kind, byteCount: size,
                                 sha256: digest, runID: id, status: status))
        }

        private static func parse(kind: Kind, id: UUID, data: Data) -> ParsedEvidence? {
            let decoder = JSONDecoder()
            switch kind {
            case .ownerRecord:
                guard let owner = try? decoder.decode(OwnerHeader.self, from: data),
                      owner.id == id, owner.version == 1 else { return nil }
                return .owner(owner.identity, version: owner.version)
            case .runRecord:
                guard let record = try? decoder.decode(DaemonRunRecord.self, from: data),
                      record.id == id else { return nil }
                return .body(Identity(id: id, space: record.space,
                                      sessionID: record.sessionId,
                                      messageID: record.assistantMessageId,
                                      taskRunID: record.settings.taskAuthorization?.runID),
                             state: DaemonLegacyInventory.bodyState(record.state),
                             restorationTokenSHA256: DaemonLegacyInventory.restorationTokenSHA256(record.restorationToken),
                             canonicalRunSHA256: DaemonLegacyInventory.canonicalRunSHA256(record))
            case .handoffRecord:
                guard let handoff = try? decoder.decode(DaemonHandoff.self, from: data),
                      handoff.id == id else { return nil }
                return .body(Identity(id: id, space: handoff.space,
                                      sessionID: handoff.sessionId,
                                      messageID: handoff.assistantMessageId,
                                      taskRunID: handoff.settings.taskAuthorization?.runID),
                             state: nil, restorationTokenSHA256: nil,
                             canonicalRunSHA256: nil)
            case .journalFile:
                guard let payload = try? decoder.decode(JournalPayload.self, from: data),
                      payload.version == 2 else { return nil }
                var spaces = Set<AppSpace>()
                for (operationID, entry) in payload.entries {
                    let digest = entry.argumentDigest
                    guard operationID == entry.operationID,
                          let binding = entry.binding, binding.runID == id,
                          let modelStep = entry.modelStep, modelStep >= 0,
                          entry.receipt == nil || entry.succeeded != nil,
                          digest.hasPrefix("sha256:"), digest.count == 71,
                          digest.dropFirst(7).allSatisfy(\.isHexDigit) else { return nil }
                    spaces.insert(binding.space)
                }
                return .journal(runID: id, spaces: spaces, valid: true)
            default:
                return nil
            }
        }

        private static func classify(path: String, isDirectory: Bool) -> (kind: Kind, id: UUID?) {
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last else { return (.unknown, nil) }
            if parts.count == 1 {
                if isDirectory {
                    if name == "personal" || name == "work" { return (.spaceBoundary, nil) }
                    if name == "quarantine" { return (.quarantineDirectory, nil) }
                    if let id = runID(in: name, prefix: "run-", suffix: "") { return (.journalDirectory, id) }
                } else {
                    if let id = runID(in: name, prefix: "run-", suffix: ".json") { return (.runRecord, id) }
                    if let id = runID(in: name, prefix: "handoff-", suffix: ".json") { return (.handoffRecord, id) }
                    if let id = runID(in: name, prefix: "owner-", suffix: ".json") { return (.ownerRecord, id) }
                    if name == "daemon.log" { return (.legacyLog, nil) }
                    if name == "daemon.lock" || name == "store.lock" { return (.globalLock, nil) }
                    if name == "layout.json" { return (.layout, nil) }
                }
            }
            if parts.first == "quarantine" {
                if isDirectory && parts.count == 2 && name == "abandoned" { return (.abandonedDirectory, nil) }
                let id = evidenceID(in: name)
                return (parts.count > 1 && parts[1] == "abandoned" ? .abandonedEvidence : .quarantinedEvidence, id)
            }
            if let top = parts.first,
               let id = runID(in: top, prefix: "run-", suffix: ""),
               parts.count == 2 && name == "operations.json" && !isDirectory {
                return (.journalFile, id)
            }
            if name.hasPrefix(".") || name.hasSuffix(".tmp") || name.hasSuffix(".partial") ||
                name.contains("staging") || name.contains("temporary") {
                return (.temporary, evidenceID(in: name))
            }
            return (.unknown, evidenceID(in: name) ?? parts.first.flatMap { runID(in: $0, prefix: "run-", suffix: "") })
        }

        private static func evidenceID(in name: String) -> UUID? {
            // Attach staging, backup and quarantined copies to the same group.
            // The filename is only a grouping hint; it never establishes space.
            for marker in ["run-", "handoff-", "owner-"] {
                guard let range = name.range(of: marker, options: .backwards) else { continue }
                let suffix = name[range.upperBound...]
                guard suffix.count >= 36 else { continue }
                if let id = UUID(uuidString: String(suffix.prefix(36))) { return id }
            }
            return nil
        }

        private static func runID(in name: String, prefix: String, suffix: String) -> UUID? {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
        }

        private static func isRegular(_ info: stat) -> Bool {
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        }
        private static func isDirectory(_ info: stat) -> Bool {
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        }
        private static func isSymbolicLink(_ info: stat) -> Bool {
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
        }
        private static func sameMetadata(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
                a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
                a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
                a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
                a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
                a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }

        func report() -> Report {
            let byID = Dictionary(grouping: entries.compactMap { entry -> (UUID, Entry)? in
                entry.runID.map { ($0, entry) }
            }, by: { $0.0 })
            let groups: [Group] = byID.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
                let members = (byID[id] ?? []).map(\.1)
                let bodyEntry = members.first { $0.kind == .runRecord || $0.kind == .handoffRecord }
                let bodyState: BodyState?
                let tokenDigest: String?
                let fingerprint: String?
                if let bodyEntry,
                   case let .body(_, state, token, canonical)? = parsed[bodyEntry.relativePath] {
                    bodyState = state
                    tokenDigest = token
                    fingerprint = canonical
                } else {
                    bodyState = nil
                    tokenDigest = nil
                    fingerprint = nil
                }
                return Group(id: id, entries: members,
                             ownership: ownership(for: id, entries: members),
                             bodySHA256: bodyEntry?.sha256,
                             bodyState: bodyState,
                             restorationTokenSHA256: tokenDigest,
                             canonicalRunSHA256: fingerprint)
            }
            let unknownKinds: Set<Kind> = [.unknown, .temporary, .symbolicLink, .unsupportedType,
                                           .legacyLog, .quarantinedEvidence, .abandonedEvidence]
            let hasUnknown = !complete || entries.contains { unknownKinds.contains($0.kind) ||
                ![.verified, .directory, .notInspected].contains($0.status) } ||
                groups.contains { if case .unknown = $0.ownership { true } else { false } }
            let hasLegacy = entries.contains { ![.globalLock, .layout, .spaceBoundary].contains($0.kind) }
            return Report(entries: entries, groups: groups,
                          summary: Summary(entryCount: entries.count, groupCount: groups.count,
                                           totalHashedBytes: totalHashedBytes,
                                           hasLegacyContent: hasLegacy,
                                           hasUnknownEvidence: hasUnknown, isComplete: complete))
        }

        private func ownership(for id: UUID, entries group: [Entry]) -> Ownership {
            guard complete else { return .unknown(reason: .incompleteScan) }
            guard group.allSatisfy({ $0.status == .verified || $0.status == .directory }) else {
                return .unknown(reason: .incompleteScan)
            }
            let owners = group.filter { $0.kind == .ownerRecord }
            let bodies = group.filter { $0.kind == .runRecord || $0.kind == .handoffRecord }
            guard !owners.isEmpty else { return .unknown(reason: .missingOwner) }
            guard !bodies.isEmpty else { return .unknown(reason: .missingBody) }
            guard bodies.count == 1, owners.count == 1 else { return .unknown(reason: .multipleBodies) }
            guard case let .owner(owner, version)? = parsed[owners[0].relativePath], version == 1,
                  case let .body(body, _, _, _)? = parsed[bodies[0].relativePath] else {
                return .unknown(reason: .invalidIdentity)
            }
            guard owner == body, owner.id == id else { return .unknown(reason: .conflictingIdentity) }
            for entry in group where entry.kind == .journalFile {
                guard case let .journal(runID, spaces, valid)? = parsed[entry.relativePath],
                      valid, runID == id, spaces.isEmpty || spaces == [owner.space] else {
                    return .unknown(reason: .conflictingIdentity)
                }
            }
            let allowed: Set<Kind> = [.ownerRecord, .runRecord, .handoffRecord,
                                      .journalDirectory, .journalFile]
            guard group.allSatisfy({ allowed.contains($0.kind) }) else {
                return .unknown(reason: .relatedEvidence)
            }
            return .fileCorroborated(space: owner.space, sessionID: owner.sessionID,
                                    messageID: owner.messageID, taskRunID: owner.taskRunID)
        }
    }
}
