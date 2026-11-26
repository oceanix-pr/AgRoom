import CryptoKit
import Darwin
import Foundation

/// Descriptor-anchored, bounded streaming I/O shared by portable backups and local
/// recovery. Paths supplied by a package never become absolute filesystem authority.
enum BackupFileIO {
    struct Receipt: Codable, Equatable, Sendable {
        let byteCount: Int
        let sha256: String
        let executable: Bool
    }

    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && $0.utf8.count <= 255
        }) else { throw BackupError.preflightFailed("Invalid backup file path") }
        return parts
    }

    static func parent(_ path: String, in root: AppDirectory, create: Bool) throws -> (AppDirectory, String) {
        let parts = try components(path)
        var directory = root
        for part in parts.dropLast() { directory = try directory.child(part, create: create) }
        return (directory, parts.last!)
    }

    static func receipt(_ path: String, in root: AppDirectory, limit: Int) throws -> Receipt {
        let (directory, name) = try parent(path, in: root, create: false)
        let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeAppError(errno == ENOENT ? .missing : .unsafePath) }
        defer { Darwin.close(fd) }
        return try stream(fd: fd, limit: limit, consume: { _ in })
    }

    @discardableResult
    static func copy(_ path: String, from source: AppDirectory, to target: AppDirectory, as targetPath: String,
                     limit: Int, expected: Receipt? = nil) throws -> Receipt {
        let (sourceDirectory, sourceName) = try parent(path, in: source, create: false)
        let input = openat(sourceDirectory.fd, sourceName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw NativeAppError(errno == ENOENT ? .missing : .unsafePath) }
        defer { Darwin.close(input) }
        let (destinationDirectory, name) = try parent(targetPath, in: target, create: true)
        let temporary = ".backup-pending-" + UUID().uuidString
        let output = openat(destinationDirectory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw NativeAppError(.storage) }
        defer { Darwin.close(output); _ = unlinkat(destinationDirectory.fd, temporary, 0) }
        let receipt = try stream(fd: input, limit: limit) { bytes in
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw NativeAppError(.storage) }
                    offset += written
                }
            }
        }
        if let expected, receipt.byteCount != expected.byteCount || receipt.sha256 != expected.sha256 {
            throw BackupError.preflightFailed("Backup file content changed")
        }
        let executable = expected?.executable ?? receipt.executable
        guard fchmod(output, executable ? 0o700 : 0o600) == 0, fsync(output) == 0,
              renameatx_np(destinationDirectory.fd, temporary, destinationDirectory.fd, name, UInt32(RENAME_EXCL)) == 0,
              fsync(destinationDirectory.fd) == 0 else { throw NativeAppError(.storage) }
        return Receipt(byteCount: receipt.byteCount, sha256: receipt.sha256, executable: executable)
    }

    static func write(_ data: Data, path: String, in root: AppDirectory) throws {
        let (directory, name) = try parent(path, in: root, create: true)
        guard !directory.exists(name) else { throw MaintenanceError.busy }
        try directory.write(data, name: name)
    }

    static func read(_ path: String, in root: AppDirectory, limit: Int) throws -> Data {
        let (directory, name) = try parent(path, in: root, create: false)
        return try directory.read(name, limit: limit)
    }

    static func removeUnchanged(_ path: String, in root: AppDirectory, expected: Receipt, limit: Int) throws {
        let (directory, name) = try parent(path, in: root, create: false)
        guard directory.exists(name) else { return }
        let current = try receipt(path, in: root, limit: limit)
        guard current.sha256 == expected.sha256 && current.byteCount == expected.byteCount else { throw MaintenanceError.busy }
        try directory.removeFile(name)
    }

    private static func stream(fd: Int32, limit: Int, consume: (Data) throws -> Void) throws -> Receipt {
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw NativeAppError(.unsafePath)
        }
        guard before.st_size >= 0, before.st_size <= limit else { throw NativeAppError(.tooLarge) }
        var hasher = SHA256(), size = 0
        var buffer = Data(count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NativeAppError(.storage) }
            if count == 0 { break }
            size += count
            guard size <= limit else { throw NativeAppError(.tooLarge) }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            try consume(chunk)
        }
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw BackupError.preflightFailed("A source file changed while its backup was being read. Retry after saving it.")
        }
        return Receipt(byteCount: size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                       executable: before.st_mode & 0o111 != 0)
    }
}
