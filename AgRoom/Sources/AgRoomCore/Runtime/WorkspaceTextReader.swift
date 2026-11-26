import CryptoKit
import Darwin
import Foundation

enum WorkspaceTextLimits {
    static let maximumReadBytes = 32 * 1024 * 1024
    static let maximumEditBytes = 16 * 1024 * 1024
    static let maximumBatchEditBytes = 32 * 1024 * 1024
}

/// A bounded, versioned UTF-8 read. Callers must retain callback results privately until scan returns:
/// a callback can precede a final file or directory identity failure.
struct WorkspaceTextReader {
    struct Line {
        let number: Int
        /// Excludes the original LF; a preceding CR remains part of the text.
        let text: String
        let terminated: Bool
        /// Swift Character offset, compatible with the existing files_read cursor.
        let characterOffset: Int
    }

    struct Summary {
        let sha256: String
        let byteCount: Int
        let totalLines: Int
        let totalCharacters: Int
    }

    struct DirectoryEntry: Sendable {
        let name: String
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymbolicLink: Bool
    }

    struct DirectoryListing: Sendable {
        let entries: [DirectoryEntry]
        let truncated: Bool
    }

    private struct Cursor: Codable {
        let pathHash: String
        let sha256: String
        let offset: Int
    }

    private struct Page: Codable {
        let path: String
        let sha256: String
        let total_characters: Int
        let offset: Int
        let next_cursor: String?
        let content: String
    }

    /// Detach synchronous file work without losing cancellation from the calling task.
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task<Never, Never>.checkCancellation()
        let worker = Task.detached(priority: Task.currentPriority, operation: operation)
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task<Never, Never>.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Enumerates only the opened directory inode. A failed final chain check discards all
    /// collected names; callers must not publish entries before this function returns.
    static func directoryEntries(
        _ url: URL,
        root: URL,
        limit: Int,
        beforeEnumeration: (() throws -> Void)? = nil
    ) throws -> DirectoryListing {
        guard (0...12_000).contains(limit) else {
            throw failure("The directory entry limit is invalid.")
        }
        let directoryParts = try components(of: physicalURL(url))
        let rootParts = try components(of: physicalURL(root))
        guard directoryParts.count >= rootParts.count,
              directoryParts.prefix(rootParts.count).elementsEqual(rootParts) else {
            throw FileAreaService.AreaError.unsafePath
        }

        let absoluteFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard absoluteFD >= 0 else { throw failure("The directory cannot be opened safely.") }
        var directoryFDs = [absoluteFD]
        defer { for fd in directoryFDs.reversed() { _ = Darwin.close(fd) } }
        for part in directoryParts {
            try Task<Never, Never>.checkCancellation()
            let next = Darwin.openat(directoryFDs[directoryFDs.count - 1], part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure("The directory changed or is unavailable.") }
            directoryFDs.append(next)
        }
        guard directoryChainMatches(parts: directoryParts, fds: directoryFDs) else {
            throw failure("The directory changed during opening.")
        }
        let directoryFD = directoryFDs[directoryFDs.count - 1]
        try beforeEnumeration?()

        let duplicateFD = Darwin.fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard duplicateFD >= 0 else { throw failure("The directory cannot be enumerated safely.") }
        guard let stream = Darwin.fdopendir(duplicateFD) else {
            _ = Darwin.close(duplicateFD)
            throw failure("The directory cannot be enumerated safely.")
        }
        defer { _ = Darwin.closedir(stream) }

        var entries: [DirectoryEntry] = []
        var truncated = false
        while true {
            try Task<Never, Never>.checkCancellation()
            errno = 0
            guard let item = Darwin.readdir(stream) else {
                guard errno == 0 else { throw failure("The directory could not be enumerated completely.") }
                break
            }
            let nameBytes = withUnsafeBytes(of: item.pointee.d_name) { raw -> [UInt8]? in
                let length = Int(item.pointee.d_namlen)
                guard length > 0, length <= raw.count else { return nil }
                return Array(raw.prefix(length))
            }
            guard let nameBytes, let name = String(bytes: nameBytes, encoding: .utf8),
                  !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
                throw failure("The directory contains an invalid file name.")
            }
            if name == "." || name == ".." { continue }
            if entries.count >= limit { truncated = true; break }

            var linked = stat()
            guard Darwin.fstatat(directoryFD, name, &linked, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw failure("A directory entry changed during enumeration.")
            }
            let kind = linked.st_mode & mode_t(S_IFMT)
            entries.append(DirectoryEntry(name: name,
                isDirectory: kind == mode_t(S_IFDIR),
                isRegularFile: kind == mode_t(S_IFREG),
                isSymbolicLink: kind == mode_t(S_IFLNK)))
        }
        guard directoryChainMatches(parts: directoryParts, fds: directoryFDs) else {
            throw failure("The directory changed during enumeration.")
        }
        entries.sort { $0.name < $1.name }
        return DirectoryListing(entries: entries, truncated: truncated)
    }

    static func scan(
        _ url: URL,
        root: URL,
        limit: Int = WorkspaceTextLimits.maximumReadBytes,
        expectedRoot: TaskDirectoryIdentity? = nil,
        onLine: (Line) throws -> Void
    ) throws -> Summary {
        guard (0...WorkspaceTextLimits.maximumReadBytes).contains(limit) else {
            throw failure("The text file exceeds the read limit.")
        }
        let fileParts = try components(of: physicalURL(url))
        let rootParts = try components(of: physicalURL(root))
        guard fileParts.count > rootParts.count,
              fileParts.prefix(rootParts.count).elementsEqual(rootParts) else {
            throw FileAreaService.AreaError.unsafePath
        }

        let absoluteFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard absoluteFD >= 0 else { throw failure("The text file cannot be opened safely.") }
        var directoryFDs = [absoluteFD]
        defer { for fd in directoryFDs.reversed() { _ = Darwin.close(fd) } }
        for part in fileParts.dropLast() {
            try Task<Never, Never>.checkCancellation()
            let next = Darwin.openat(directoryFDs[directoryFDs.count - 1], part,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure("The text file's directory changed or is unavailable.") }
            directoryFDs.append(next)
        }

        if let expectedRoot {
            var info = stat()
            guard fstat(directoryFDs[rootParts.count], &info) == 0,
                  expectedRoot.device == UInt64(bitPattern: Int64(info.st_dev)),
                  expectedRoot.inode == UInt64(info.st_ino) else { throw FileAreaService.AreaError.unsafePath }
        }
        let name = fileParts[fileParts.count - 1]
        let parentFD = directoryFDs[directoryFDs.count - 1]
        let fileFD = Darwin.openat(parentFD, name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else { throw failure("The text file changed or is unavailable.") }
        defer { _ = Darwin.close(fileFD) }

        var before = stat()
        guard Darwin.fstat(fileFD, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= limit,
              entryMatches(fileFD, in: parentFD, name: name) else {
            throw failure("The text file is unsafe, changed, or exceeds the read limit.")
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pendingLine = [UInt8]()
        var bytesRead = 0
        var lineNumber = 1
        var characterOffset = 0

        func emitLine(terminated: Bool) throws {
            guard let text = String(bytes: pendingLine, encoding: .utf8) else {
                throw failure("The file is not UTF-8 text. Use a dedicated binary file tool.")
            }
            try onLine(Line(number: lineNumber, text: text, terminated: terminated,
                characterOffset: characterOffset))
            // CRLF is one Swift Character. Counting each part separately would corrupt cursors.
            characterOffset += (text + (terminated ? "\n" : "")).count
            lineNumber += 1
            pendingLine.removeAll(keepingCapacity: true)
        }

        while true {
            try Task<Never, Never>.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fileFD, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("The text file changed or could not be read.")
            }
            if count == 0 { break }
            guard count <= limit - bytesRead else {
                throw failure("The text file exceeds the read limit.")
            }
            bytesRead += count
            hasher.update(data: Data(buffer[0..<count]))
            var segmentStart = 0
            for index in 0..<count {
                let byte = buffer[index]
                guard byte != 0 else {
                    throw failure("The file contains a NUL byte. Use a dedicated binary file tool.")
                }
                if byte == 10 {
                    pendingLine.append(contentsOf: buffer[segmentStart..<index])
                    try emitLine(terminated: true)
                    segmentStart = index + 1
                }
            }
            pendingLine.append(contentsOf: buffer[segmentStart..<count])
        }
        // split(omittingEmptySubsequences: false) semantics: even an empty file or final LF
        // has a final, unterminated empty line.
        try emitLine(terminated: false)
        try Task<Never, Never>.checkCancellation()

        var after = stat()
        guard Darwin.fstat(fileFD, &after) == 0,
              sameFileVersion(before, after),
              after.st_size == bytesRead,
              entryMatches(fileFD, in: parentFD, name: name),
              directoryChainMatches(parts: Array(fileParts.dropLast()), fds: directoryFDs) else {
            throw failure("The text file changed during reading. Restart files_read.")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Summary(sha256: digest, byteCount: bytesRead,
            totalLines: lineNumber - 1, totalCharacters: characterOffset)
    }

    /// Encodes the legacy files_read cursor shape. `offset` counts Swift Characters, not bytes.
    static func cursor(url: URL, sha256: String, offset: Int) throws -> String {
        guard offset >= 0 else { throw failure("Invalid read cursor offset.") }
        let pathHash = SHA256.hash(data: Data(physicalURL(url).path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Cursor(pathHash: pathHash, sha256: sha256, offset: offset))
            .base64EncodedString()
    }

    static func page(path: String, service: FileAreaService, args: [String: Any]) throws -> String {
        let url = try service.resolveManaged(path)
        guard let supplied = FileAreaService.expandHome(path),
              physicalURL(supplied.standardizedFileURL).path
                == physicalURL(url.standardizedFileURL).path else {
            // resolveManaged follows symlinks for scope validation, but this reader must not
            // subsequently accept a caller-controlled link even when it stays inside the root.
            throw FileAreaService.AreaError.unsafePath
        }
        let root = service.managedRoots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { url.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
        guard let root else { throw FileAreaService.AreaError.unsafePath }

        let invalidCursor = "The read cursor is invalid or the file changed. Start files_read again without a cursor; do not combine pages from different file versions."
        var offset = 0
        var expectedSHA: String?
        if let raw = args["cursor"] {
            guard let value = raw as? String, value.utf8.count <= 1024,
                  let data = Data(base64Encoded: value),
                  let parsed = try? JSONDecoder().decode(Cursor.self, from: data),
                  parsed.offset >= 0,
                  [physicalURL(url).path, url.path].contains(where: { path in
                    SHA256.hash(data: Data(path.utf8))
                        .map({ String(format: "%02x", $0) }).joined() == parsed.pathHash
                  }) else {
                throw failure(invalidCursor)
            }
            offset = parsed.offset
            expectedSHA = parsed.sha256
        }
        guard args["max_chars"] == nil || args["max_chars"] is Int else {
            throw failure("Invalid read cursor or max_chars. max_chars must be an integer from 1 to 4000.")
        }
        let maximum = args["max_chars"] as? Int ?? 3500
        guard (1...4000).contains(maximum) else {
            throw failure("max_chars must be from 1 to 4000.")
        }
        let (requestedEnd, overflow) = offset.addingReportingOverflow(maximum)
        guard !overflow else { throw failure(invalidCursor) }

        var window = String()
        // FileAreaService has already checked the caller's registered scope. Normalize only
        // macOS's fixed, root-owned /tmp and /var aliases; resolving an arbitrary user-owned
        // path again here would reopen a directory-switch race after the scope check.
        let physicalFile = physicalURL(url)
        let physicalRoot = physicalURL(root)
        let summary = try scan(physicalFile, root: physicalRoot) { line in
            let segment = line.text + (line.terminated ? "\n" : "")
            let segmentEnd = line.characterOffset + segment.count
            guard line.characterOffset < requestedEnd, segmentEnd > offset else { return }
            let localStart = max(0, offset - line.characterOffset)
            let localEnd = min(segment.count, requestedEnd - line.characterOffset)
            let start = segment.index(segment.startIndex, offsetBy: localStart)
            let end = segment.index(start, offsetBy: localEnd - localStart)
            window.append(contentsOf: segment[start..<end])
        }
        guard offset <= summary.totalCharacters else { throw failure(invalidCursor) }
        if let expectedSHA, expectedSHA != summary.sha256 { throw failure(invalidCursor) }
        guard window.count == min(maximum, summary.totalCharacters - offset) else {
            throw failure("The file changed during reading. Restart files_read.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fullCount = min(maximum, summary.totalCharacters - offset)
        func encodedPage(characterCount count: Int) throws -> Data {
            let next = offset + count
            let nextCursor = next < summary.totalCharacters
                ? try cursor(url: url, sha256: summary.sha256, offset: next) : nil
            let page = Page(path: url.path, sha256: summary.sha256,
                total_characters: summary.totalCharacters, offset: offset,
                next_cursor: nextCursor, content: String(window.prefix(count)))
            return try encoder.encode(page)
        }
        // A full final page omits next_cursor, so test it before searching shorter pages.
        let fullPage = try encodedPage(characterCount: fullCount)
        if fullPage.count <= 5500 { return String(decoding: fullPage, as: UTF8.self) }

        var lower = 0
        var upper = fullCount - 1
        var bestCount = -1
        var bestPage: Data?
        while lower <= upper {
            let count = lower + (upper - lower) / 2
            let candidate = try encodedPage(characterCount: count)
            if candidate.count <= 5500 {
                bestCount = count
                bestPage = candidate
                lower = count + 1
            } else {
                upper = count - 1
            }
        }
        guard bestCount > 0, let bestPage else {
            throw failure("The file metadata or a text character exceeds the page budget.")
        }
        return String(decoding: bestPage, as: UTF8.self)
    }

    private static func components(of url: URL) throws -> [String] {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw FileAreaService.AreaError.unsafePath
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw FileAreaService.AreaError.unsafePath
        }
        return parts
    }

    private static func physicalURL(_ url: URL) -> URL {
        for alias in ["/tmp", "/var"] {
            if url.path == alias || url.path.hasPrefix(alias + "/") {
                return URL(fileURLWithPath: "/private" + url.path)
            }
        }
        return url
    }

    private static func entryMatches(_ fd: Int32, in parentFD: Int32, name: String) -> Bool {
        var opened = stat()
        var linked = stat()
        guard Darwin.fstat(fd, &opened) == 0,
              Darwin.fstatat(parentFD, name, &linked, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return opened.st_dev == linked.st_dev && opened.st_ino == linked.st_ino
            && (opened.st_mode & mode_t(S_IFMT)) == (linked.st_mode & mode_t(S_IFMT))
    }

    private static func directoryChainMatches(parts: [String], fds: [Int32]) -> Bool {
        guard fds.count == parts.count + 1 else { return false }
        for index in parts.indices {
            guard entryMatches(fds[index + 1], in: fds[index], name: parts[index]) else {
                return false
            }
        }
        return true
    }

    private static func sameFileVersion(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func failure(_ message: String) -> ToolExecutionFailure {
        ToolExecutionFailure(message: message)
    }
}
