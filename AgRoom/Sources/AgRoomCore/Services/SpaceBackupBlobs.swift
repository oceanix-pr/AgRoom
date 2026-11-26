import CryptoKit
import Darwin
import Foundation

struct SpaceBackupBlobReference: Codable, Hashable, Sendable {
    let sha256: String
    let byteCount: Int
    let part: UUID
    let offset: Int

    var fileName: String { part.uuidString.lowercased() + ".bin" }
    func validate() throws {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              byteCount >= 0, byteCount <= SpaceBackupBlobs.maximumBlobBytes,
              offset >= 0, offset <= SpaceBackupBlobs.maximumBlobBytes - byteCount else {
            throw BackupError.preflightFailed("Invalid database content reference")
        }
    }
}

enum BackupContentCancellation {
    @TaskLocal static var current: CancellationGate?
    static func run<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        if current != nil { return try await operation() }
        let gate = CancellationGate()
        return try await withTaskCancellationHandler {
            try await $current.withValue(gate) { try await operation() }
        } onCancel: { gate.markCancelled() }
    }
}

/// Fixed owned root, bounded binary parts, and relative range references. Small
/// contents share parts, so many tiny versions do not exhaust archive file limits.
/// The lock owns only the in-memory index and range reservations; all I/O is outside.
final class SpaceBackupBlobs: @unchecked Sendable {
    let root: URL
    private let cancellation: CancellationGate?
    private let lock = NSLock()
    private var known: [String: SpaceBackupBlobReference] = [:]
    private var currentPart = UUID()
    private var nextOffset = 0
    static let maximumBlobBytes = 256 * 1024 * 1024
    static let privateInlineLimit = 64 * 1024

    init(root: URL, cancellation: CancellationGate? = BackupContentCancellation.current) {
        self.root = root; self.cancellation = cancellation
    }

    func checkCancellation() throws {
        if cancellation?.isCancelled == true { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Rebuild the index from the durable plan, without trusting an external index
    /// or rewriting existing parts after a restart or restore-point move.
    func prime(_ references: Set<SpaceBackupBlobReference>) throws {
        for ref in references {
            try checkCancellation(); try ref.validate()
            try lock.withLock {
                if let previous = known[ref.sha256], previous.byteCount != ref.byteCount {
                    throw BackupError.preflightFailed("Conflicting database content references")
                }
                if known[ref.sha256] == nil { known[ref.sha256] = ref }
            }
        }
    }

    func put(_ data: Data) throws -> SpaceBackupBlobReference {
        try checkCancellation()
        guard data.count <= Self.maximumBlobBytes else { throw BackupError.preflightFailed("Database content exceeds its per-record limit") }
        let digest = Self.digest(data)
        if let existing = lock.withLock({ known[digest] }) {
            guard existing.byteCount == data.count else { throw BackupError.preflightFailed("Conflicting database content identity") }
            try verify(existing); return existing
        }
        let ref = lock.withLock {
            if nextOffset > Self.maximumBlobBytes - data.count { currentPart = UUID(); nextOffset = 0 }
            let value = SpaceBackupBlobReference(sha256: digest, byteCount: data.count, part: currentPart, offset: nextOffset)
            nextOffset += data.count
            return value
        }
        let directory = try AppDirectory(url: root, create: true)
        let fd = openat(directory.fd, ref.fileName, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeAppError(.storage) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.maximumBlobBytes else { throw NativeAppError(.unsafePath) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                try checkCancellation()
                let amount = pwrite(fd, bytes.baseAddress!.advanced(by: written), min(64 * 1024, bytes.count - written), off_t(ref.offset + written))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw NativeAppError(.storage) }
                written += amount
            }
        }
        guard fsync(fd) == 0, fsync(directory.fd) == 0 else { throw NativeAppError(.storage) }
        try checkCancellation()
        lock.withLock { if known[digest] == nil { known[digest] = ref } }
        return ref
    }

    func verify(_ ref: SpaceBackupBlobReference) throws { try stream(ref) { _ in } }

    func read(_ ref: SpaceBackupBlobReference) throws -> Data {
        try checkCancellation(); try ref.validate()
        var data = Data(); data.reserveCapacity(ref.byteCount)
        try stream(ref) { data.append($0) }
        return data
    }

    /// Freeze only referenced ranges into the private recovery material. Returned
    /// locators belong to this root, independent of the package's temporary root.
    func copy(_ references: Set<SpaceBackupBlobReference>, from source: SpaceBackupBlobs) throws -> [SpaceBackupBlobReference: SpaceBackupBlobReference] {
        var mapping: [SpaceBackupBlobReference: SpaceBackupBlobReference] = [:]
        for ref in references.sorted(by: { $0.sha256 < $1.sha256 }) {
            try checkCancellation()
            mapping[ref] = try put(source.read(ref))
        }
        return mapping
    }

    func validateInventory(_ references: Set<SpaceBackupBlobReference>) throws {
        try checkCancellation()
        let directory = try AppDirectory(url: root, create: false)
        let groups = Dictionary(grouping: references, by: \.fileName)
        guard Set(try directory.names(limit: BackupService.maxExtractedFileCount)) == Set(groups.keys) else {
            throw BackupError.preflightFailed("Database content inventory does not match its references")
        }
        for (name, values) in groups {
            try checkCancellation()
            var end = 0
            for value in values.sorted(by: { $0.offset == $1.offset ? $0.byteCount < $1.byteCount : $0.offset < $1.offset }) {
                try value.validate()
                if value.byteCount > 0 {
                    guard value.offset == end else { throw BackupError.preflightFailed("Invalid database content ranges") }
                    end += value.byteCount
                }
                try verify(value)
            }
            var info = stat()
            guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size == end else {
                throw BackupError.preflightFailed("Unreferenced bytes in database content part")
            }
        }
    }

    private func stream(_ ref: SpaceBackupBlobReference, consume: (Data) throws -> Void) throws {
        try checkCancellation(); try ref.validate()
        let directory = try AppDirectory(url: root, create: false)
        let fd = openat(directory.fd, ref.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BackupError.preflightFailed("Referenced database content is missing") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= ref.offset + ref.byteCount, info.st_size <= Self.maximumBlobBytes else { throw NativeAppError(.unsafePath) }
        var hasher = SHA256(), offset = 0, buffer = Data(count: 64 * 1024)
        while offset < ref.byteCount {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, min($0.count, ref.byteCount - offset), off_t(ref.offset + offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw BackupError.preflightFailed("Referenced database content is truncated") }
            let chunk = Data(buffer.prefix(count)); hasher.update(data: chunk); try consume(chunk); offset += count
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == ref.sha256 else {
            throw BackupError.preflightFailed("Referenced database content does not match its checksum")
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_nlink == 1, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
            throw BackupError.preflightFailed("Referenced database content changed while reading")
        }
        try checkCancellation()
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension SpaceDatabaseBackup {
    var blobReferences: Set<SpaceBackupBlobReference> {
        var result = Set<SpaceBackupBlobReference>()
        for table in tables {
            for row in table.rows {
                for value in row { if case .blobFile(let ref) = value { result.insert(ref) } }
            }
        }
        return result
    }

    func replacingBlobReferences(_ mapping: [SpaceBackupBlobReference: SpaceBackupBlobReference]) throws -> Self {
        var copy = self
        for table in copy.tables.indices {
            for row in copy.tables[table].rows.indices {
                copy.tables[table].rows[row] = try copy.tables[table].rows[row].map { value in
                    guard case .blobFile(let ref) = value else { return value }
                    guard let replacement = mapping[ref] else { throw BackupError.preflightFailed("Missing frozen database content") }
                    return .blobFile(replacement)
                }
            }
        }
        return copy
    }
}
