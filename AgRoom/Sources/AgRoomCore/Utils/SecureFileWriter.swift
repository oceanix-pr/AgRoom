import Foundation
import Darwin

// MARK: - Secure File Writer

/// 团队写的最终落盘路径：从工作区根开始逐级 `openat(O_NOFOLLOW)`，
/// 在父目录句柄上创建临时文件并 `renameat` 替换目标。
///
/// 目的：缩短“校验父目录”和“写入”之间的窗口，防止父目录在两者之间被替换成
/// 指向工作区外的符号链接。调用方仍需在写入前再次核对旧内容。
public enum SecureFileWriter {
    public enum WritePolicy {
        case replace
        case createOnly
        /// 调用方已读取的旧内容；发布前再次核对，发现并发变化即拒绝。
        case matching(Data)
    }

    public enum WriteError: LocalizedError, Equatable {
        case outsideRoot
        case symlinkComponent(String)
        case invalidPath
        case openFailed(String, Int32)
        case writeFailed(Int32)
        case renameFailed(Int32)
        case targetChanged

        public var errorDescription: String? {
            switch self {
            case .outsideRoot:
                return "Secure write target is outside the workspace root."
            case .symlinkComponent(let component):
                return "Secure write refused symbolic link component '\(component)'."
            case .invalidPath:
                return "Secure write target has an invalid path."
            case .openFailed(let path, let code):
                return "Secure write could not open '\(path)' (errno \(code))."
            case .writeFailed(let code):
                return "Secure write failed while writing data (errno \(code))."
            case .renameFailed(let code):
                return "Secure write could not atomically replace the target (errno \(code))."
            case .targetChanged:
                return "The output target already exists or changed while the command was running. It was not replaced."
            }
        }
    }

    /// 原子写入。`root` 必须已解析符号链接；`target` 也必须位于 root 下。
    /// 目标可以是新文件；若已存在则被原子替换。
    public static func write(_ content: String, to target: URL, root: URL) throws {
        guard let data = content.data(using: .utf8) else {
            throw WriteError.writeFailed(EINVAL)
        }
        try write(data, to: target, root: root)
    }

    /// 二进制产物与文本使用相同的目录句柄和符号链接防护。
    public static func write(_ data: Data, to target: URL, root: URL, policy: WritePolicy = .replace,
                             expectedRoot: TaskDirectoryIdentity? = nil) throws {
        let strict: Bool
        if case .replace = policy { strict = false } else { strict = true }
        let rootURL = strict ? root.standardizedFileURL : root.standardizedFileURL.resolvingSymlinksInPath()
        let targetURL = target.standardizedFileURL
        guard targetURL.path != rootURL.path,
              targetURL.path.hasPrefix(rootURL.path + "/") else {
            throw WriteError.outsideRoot
        }
        let relative = String(targetURL.path.dropFirst(rootURL.path.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let filename = components.last else {
            throw WriteError.invalidPath
        }
        let directoryComponents = Array(components.dropLast())

        let rootFD = strict ? openDirectoryWithoutLinks(rootURL) : open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw WriteError.openFailed(rootURL.path, errno)
        }
        defer { close(rootFD) }
        if let expectedRoot {
            var info = stat()
            guard rootURL.path == expectedRoot.canonicalPath, fstat(rootFD, &info) == 0,
                  UInt64(bitPattern: Int64(info.st_dev)) == expectedRoot.device,
                  UInt64(info.st_ino) == expectedRoot.inode else { throw WriteError.targetChanged }
        }

        var directoryFD = rootFD
        var openedFDs: [Int32] = []
        defer {
            for fd in openedFDs.reversed() { close(fd) }
        }

        for component in directoryComponents {
            var next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                _ = mkdirat(directoryFD, component, S_IRWXU | S_IRGRP | S_IXGRP)
                next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                let code = errno
                if code == ELOOP || code == ENOTDIR {
                    throw WriteError.symlinkComponent(component)
                }
                throw WriteError.openFailed(component, code)
            }
            openedFDs.append(next)
            directoryFD = next
        }

        let tempName = ".agroom-write-\(UUID().uuidString)"
        let tempFD = openat(
            directoryFD,
            tempName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard tempFD >= 0 else {
            throw WriteError.openFailed(tempName, errno)
        }
        var tempExists = true
        defer {
            close(tempFD)
            if tempExists { unlinkat(directoryFD, tempName, 0) }
        }

        var written = 0
        let result: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            while written < raw.count {
                let count = Darwin.write(tempFD, base.advanced(by: written), raw.count - written)
                if count <= 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                written += count
            }
            return 0
        }
        guard result == 0, written == data.count else {
            throw WriteError.writeFailed(errno)
        }
        guard fsync(tempFD) == 0 else {
            throw WriteError.writeFailed(errno)
        }
        switch policy {
        case .createOnly:
            // linkat 的“不覆盖”语义是原子的；不能先判断不存在再普通 rename。
            guard linkat(directoryFD, tempName, directoryFD, filename, 0) == 0 else {
                if errno == EEXIST { throw WriteError.targetChanged }
                throw WriteError.renameFailed(errno)
            }
            _ = unlinkat(directoryFD, tempName, 0)
        case .matching(let expected):
            guard let mode = try matchingMode(expected, directory: directoryFD, filename: filename) else { throw WriteError.targetChanged }
            guard fchmod(tempFD, mode) == 0, fsync(tempFD) == 0 else { throw WriteError.writeFailed(errno) }
            guard renameat(directoryFD, tempName, directoryFD, filename) == 0 else { throw WriteError.renameFailed(errno) }
        case .replace:
            guard renameat(directoryFD, tempName, directoryFD, filename) == 0 else { throw WriteError.renameFailed(errno) }
        }
        tempExists = false
        return
    }

    private static func matchingMode(_ expected: Data, directory: Int32, filename: String) throws -> mode_t? {
        let descriptor = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == expected.count else { return nil }
        var actual = Data()
        while let data = try handle.read(upToCount: min(64 * 1024, expected.count + 1 - actual.count)), !data.isEmpty {
            actual.append(data)
            if actual.count > expected.count { return nil }
        }
        return actual == expected ? info.st_mode & 0o777 : nil
    }

    /// 条件发布不能重新解析已批准根目录的符号链接；从 / 起逐层固定目录句柄。
    private static func openDirectoryWithoutLinks(_ root: URL) -> Int32 {
        // Foundation 在部分系统上保留 /var、/tmp 的系统别名；仅展开这两个固定前缀，
        // 其余可被工作区程序替换的路径组件仍逐层拒绝链接。
        let path = root.path.hasPrefix("/var/") || root.path.hasPrefix("/tmp/") ? "/private" + root.path : root.path
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(descriptor)
            guard next >= 0 else { errno = code; return -1 }
            descriptor = next
        }
        return descriptor
    }
}
