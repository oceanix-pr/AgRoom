import Darwin
import Foundation
import AgRoomScriptIPC

/// 数据文件先冻结/暂存，控制请求和模型摘要均不承担数据传输。
/// 不把宿主目标文件描述符交给不可信程序，失败时不发布重定向产物。
struct ShellFileRedirection {
    static let keys = ["stdin_file", "stdout_file", "stderr_file", "output_mode"]
    static func isRequested(_ args: [String: Any]) -> Bool { keys.contains { args[$0] != nil } }

    enum Mode: String { case create, overwrite, append }
    struct Destination {
        let url: URL
        let stream: String
        let previous: Data?
    }
    let root: URL
    let input: Data?
    let destinations: [Destination]
    let mode: Mode

    init(args: [String: Any], directory: URL, denied: [URL]) throws {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.root = root
        let rawMode = args["output_mode"] as? String ?? "create"
        guard args["output_mode"] == nil || args["output_mode"] is String,
              let mode = Mode(rawValue: rawMode) else { throw Self.invalid() }
        self.mode = mode
        func path(_ key: String) throws -> URL? {
            guard let raw = args[key] else { return nil }
            guard let value = raw as? String, !value.isEmpty, !value.contains("\0"), !value.contains("\n"), !value.contains("\r"),
                  !value.split(separator: "/").contains("..") else { throw Self.invalid() }
            var url = (value.hasPrefix("/") ? URL(fileURLWithPath: value) : root.appendingPathComponent(value)).standardizedFileURL
            let suppliedRoot = directory.standardizedFileURL.path
            if suppliedRoot != root.path, url.path.hasPrefix(suppliedRoot + "/") {
                url = root.appendingPathComponent(String(url.path.dropFirst(suppliedRoot.count + 1)))
            }
            guard url.path.hasPrefix(root.path + "/"),
                  !denied.contains(where: { FileAreaService.isInside(url, root: $0) }) else { throw Self.invalid() }
            return url
        }
        let source = try path("stdin_file")
        input = try source.map { try ScriptFileIdentity.read($0, root: root, limit: ScriptRunnerStandardIO.maximumFileBytes) }
        var destinations: [Destination] = []
        for (key, stream) in [("stdout_file", "stdout"), ("stderr_file", "stderr")] {
            guard let url = try path(key) else { continue }
            guard source?.path != url.path, !destinations.contains(where: { $0.url.path == url.path }) else { throw Self.invalid() }
            let previous = try Self.previous(at: url, root: root)
            guard mode != .create || previous == nil else {
                throw ToolExecutionFailure(message: "The output file already exists. Nothing was executed. Choose another path or explicitly request overwrite/append with a fresh confirmation.")
            }
            destinations.append(Destination(url: url, stream: stream, previous: previous))
        }
        guard !destinations.isEmpty || args["output_mode"] == nil else { throw Self.invalid() }
        self.destinations = destinations
    }

    func stage(in temporary: URL) throws -> ScriptRunnerStandardIO {
        let temporary = temporary.standardizedFileURL.resolvingSymlinksInPath()
        var streams = ScriptRunnerStandardIO()
        if let input {
            let path = temporary.appendingPathComponent("stdin.bin")
            try SecureFileWriter.write(input, to: path, root: temporary, policy: .createOnly)
            streams.input = path.path
        }
        for destination in destinations {
            let path = temporary.appendingPathComponent(destination.stream + ".bin")
            try SecureFileWriter.write(Data(), to: path, root: temporary, policy: .createOnly)
            if destination.stream == "stdout" { streams.output = path.path } else { streams.error = path.path }
        }
        return streams
    }

    struct Captured {
        let result: ChildProcessResult
        let files: [(Destination, Data)]
    }

    func collect(_ result: ChildProcessResult, temporary: URL, previewLimit: Int) throws -> Captured {
        var stdout = result.stdout
        var stderr = result.stderr
        var files: [(Destination, Data)] = []
        for destination in destinations {
            let data = try ScriptFileIdentity.read(temporary.appendingPathComponent(destination.stream + ".bin"),
                                                   root: temporary, limit: ScriptRunnerStandardIO.maximumFileBytes)
            let text = String(decoding: data.prefix(previewLimit), as: UTF8.self)
                + (data.count > previewLimit ? "\n[preview truncated; output is staged and is published only after successful execution]" : "")
            if destination.stream == "stdout" { stdout = text } else { stderr = text }
            files.append((destination, data))
        }
        return Captured(result: ChildProcessResult(outcome: result.outcome, stdout: stdout, stderr: stderr, duration: result.duration), files: files)
    }

    func publish(_ captured: Captured, didPublish: (URL) -> Void = { _ in }) throws -> String {
        try Task.checkCancellation()
        // 先检查全部追加后的大小，避免已知的配额失败造成部分发布。
        guard captured.files.allSatisfy({ destination, data in
            data.count + (mode == .append ? destination.previous?.count ?? 0 : 0) <= ScriptRunnerStandardIO.maximumFileBytes
        }) else { throw ToolExecutionFailure(message: "Output exceeds the 64 MiB file limit. No redirected files were published.") }
        var published: [String] = []
        for (destination, data) in captured.files {
            let contents = mode == .append ? (destination.previous ?? Data()) + data : data
            do {
                try SecureFileWriter.write(contents, to: destination.url, root: root,
                    policy: destination.previous.map { .matching($0) } ?? .createOnly)
            } catch {
                throw ToolExecutionFailure(message: "Output publication failed: \(error.localizedDescription)\nAlready published: \(published.isEmpty ? "none" : published.joined(separator: ", ")). Do not retry automatically.")
            }
            published.append("\(destination.stream): \(destination.url.path) (\(contents.count) bytes, \(mode.rawValue))")
            didPublish(destination.url)
        }
        return published.joined(separator: "\n")
    }

    private static func previous(at url: URL, root: URL) throws -> Data? {
        let components = String(url.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw invalid() }
        descriptors.append(directory)
        for component in components.dropLast() {
            directory = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw invalid() }
            descriptors.append(directory)
        }
        var info = stat()
        guard let leaf = components.last else { throw invalid() }
        if fstatat(directory, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw invalid() }
            return nil
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw invalid() }
        return try ScriptFileIdentity.read(url, root: root, limit: ScriptRunnerStandardIO.maximumFileBytes)
    }

    private static func invalid() -> ToolExecutionFailure {
        ToolExecutionFailure(message: "Invalid standard I/O files. Use distinct regular files inside the working directory, without symlinks, traversal or private space data. Output parent folders must already exist; output_mode must be create, overwrite or append. Nothing was executed.")
    }
}
