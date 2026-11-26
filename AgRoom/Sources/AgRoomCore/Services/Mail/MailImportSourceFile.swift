import Darwin
import Foundation

struct MailImportFileIdentity: Sendable, Equatable {
    let device: Int64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64
    init(_ value: stat) {
        device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

/// One synchronous reader owns its cursor and descriptor. It never follows a
/// link, and checks the pinned directory and file identity after reading.
final class MailImportSourceFile {
    private let descriptor: Int32
    private let parent: AppDirectory
    private let parentURL: URL
    private let name: String
    private let original: stat
    private(set) var offset: Int64 = 0
    var identity: MailImportFileIdentity { .init(original) }
    var byteCount: Int64 { original.st_size }

    init(parent: AppDirectory, name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw MailImportError.unreadable }
        self.parent = parent; self.name = name; parentURL = try parent.kernelURL()
        let file = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw MailImportError.unreadable }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else {
            Darwin.close(file); throw MailImportError.unreadable
        }
        descriptor = file; original = info
        try validate()
    }

    deinit { Darwin.close(descriptor) }

    func read(maximum: Int) throws -> Data {
        try Task.checkCancellation()
        guard maximum > 0, maximum <= 64 * 1024 else { throw MailImportError.capacity }
        var data = Data(count: maximum)
        var count: Int
        repeat { count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) } } while count < 0 && errno == EINTR
        if count < 0 { try validate(); throw MailImportError.unreadable }
        let next = offset.addingReportingOverflow(Int64(count))
        guard !next.overflow, next.partialValue <= original.st_size else { throw MailImportError.changed }
        offset = next.partialValue
        if count == 0 {
            try validate()
            guard offset == original.st_size else { throw MailImportError.changed }
        }
        data.removeSubrange(count..<data.count)
        return data
    }

    func readAll(limit: Int) throws -> Data {
        guard limit > 0, original.st_size <= limit else { throw MailImportError.capacity }
        var data = Data()
        while true {
            let chunk = try read(maximum: 64 * 1024)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        try validate()
        return data
    }

    func readRange(offset: Int64, count: Int, limit: Int) throws -> Data {
        try Task.checkCancellation(); try validate()
        guard offset >= 0, count >= 0, count <= limit, offset <= original.st_size,
              Int64(count) <= original.st_size - offset, lseek(descriptor, offset, SEEK_SET) == offset else { throw MailImportError.changed }
        self.offset = offset
        var data = Data()
        while data.count < count {
            let chunk = try read(maximum: min(64 * 1024, count - data.count))
            guard !chunk.isEmpty else { throw MailImportError.changed }
            data.append(chunk)
        }
        try validate()
        return data
    }

    func validate() throws {
        do { try parent.verifyIdentity(at: parentURL) }
        catch { throw MailImportError.changed }
        var opened = stat(), entry = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parent.fd, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(original, opened), Self.same(original, entry) else { throw MailImportError.changed }
    }

    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        rhs.st_mode & S_IFMT == S_IFREG && rhs.st_nlink == 1
            && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
