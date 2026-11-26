import Darwin
import Foundation

/// One bounded, explicitly approved host query. All process and pipe state belongs to
/// its detached task; cancellation uses the same process-tree terminator as builds.
enum SourceKitLSPTransport {
    struct Request: Sendable {
        let root: URL
        let file: URL
        let text: String
        let method: String
        let line: Int
        let character: Int
        let temporary: URL
        var timeout: TimeInterval = 30
    }

    struct Framer {
        private var buffer = Data()
        mutating func append(_ data: Data) throws -> [Data] {
            guard buffer.count + data.count <= 2 * 1024 * 1024 else { throw failure("lsp_frame_limit") }
            buffer.append(data)
            var frames: [Data] = []
            while let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard split.lowerBound <= 8192,
                      let header = String(data: buffer[..<split.lowerBound], encoding: .ascii) else { throw failure("lsp_header") }
                let sizes = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    let pair = line.split(separator: ":", maxSplits: 1)
                    guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
                    return Int(pair[1].trimmingCharacters(in: .whitespaces))
                }
                guard sizes.count == 1, let size = sizes.first, (1...2 * 1024 * 1024).contains(size) else { throw failure("lsp_length") }
                let end = split.upperBound + size
                guard buffer.count >= end else { break }
                frames.append(Data(buffer[split.upperBound..<end]))
                buffer = Data(buffer.dropFirst(end))
            }
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, buffer.count > 8192 { throw failure("lsp_header_limit") }
            return frames
        }
        static func encode(_ object: [String: Any]) throws -> Data {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            var result = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
            result.append(data)
            return result
        }
    }

    static func query(_ request: Request) async throws -> Data {
        let task = Task.detached { try blockingQuery(request) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func blockingQuery(_ request: Request) throws -> Data {
        try Task.checkCancellation()
        let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["sourcekit-lsp", "--generated-files-path", request.temporary.appendingPathComponent("generated").path]
        process.currentDirectoryURL = request.root
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": request.temporary.appendingPathComponent("home").path,
            "TMPDIR": request.temporary.appendingPathComponent("tmp").path,
            "CLANG_MODULE_CACHE_PATH": request.temporary.appendingPathComponent("modules").path, "LANG": "en_US.UTF-8"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], developer.hasPrefix("/"), !developer.contains("\0") {
            environment["DEVELOPER_DIR"] = developer
        }
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        let descriptors = [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, error.fileHandleForReading.fileDescriptor]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw failure("lsp_pipe") }
        }
        guard fcntl(descriptors[0], F_SETNOSIGPIPE, 1) == 0 else { throw failure("lsp_pipe") }
        defer {
            if process.isRunning { ProcessTerminator.terminate(process: process, label: "sourcekit_lsp") }
            for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                           output.fileHandleForWriting, error.fileHandleForReading, error.fileHandleForWriting] { try? handle.close() }
        }
        try process.run()
        // Parent copies must not keep EOF open after the child exits.
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
        let root = request.root.absoluteString, uri = request.file.absoluteString
        var pending = try Framer.encode(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "processId": ProcessInfo.processInfo.processIdentifier, "rootUri": root,
            "workspaceFolders": [["uri": root, "name": "Bound project"]],
            "capabilities": ["textDocument": ["documentSymbol": ["hierarchicalDocumentSymbolSupport": true]],
                             "general": ["positionEncodings": ["utf-16"]]],
            "initializationOptions": ["backgroundIndexing": false, "swiftPM": ["skipPlugins": true, "forceResolvedVersions": true]]
        ]])
        var offset = 0, received = 0, framer = Framer()
        var result: Data?, initialized = false, shutdown = false
        let start = ProcessInfo.processInfo.systemUptime
        func enqueue(_ object: [String: Any]) throws {
            if offset > 0 { pending = Data(pending.dropFirst(offset)); offset = 0 }
            let data = try Framer.encode(object)
            guard pending.count + data.count <= 2 * 1024 * 1024 else { throw failure("lsp_input_limit") }
            pending.append(data)
        }
        while ProcessInfo.processInfo.systemUptime - start < request.timeout {
            try Task.checkCancellation()
            var events = [pollfd(fd: descriptors[1], events: Int16(POLLIN), revents: 0),
                          pollfd(fd: descriptors[2], events: Int16(POLLIN), revents: 0),
                          pollfd(fd: descriptors[0], events: offset < pending.count ? Int16(POLLOUT) : 0, revents: 0)]
            let ready = poll(&events, nfds_t(events.count), 50)
            if ready < 0, errno != EINTR { throw failure("lsp_poll") }
            if events[2].revents & Int16(POLLOUT) != 0, offset < pending.count {
                let count = pending.withUnsafeBytes { bytes in Darwin.write(descriptors[0], bytes.baseAddress!.advanced(by: offset), min(16 * 1024, pending.count - offset)) }
                if count > 0 { offset += count }
                else if count < 0, errno != EAGAIN, errno != EINTR { throw failure("lsp_write") }
            }
            for index in 0...1 where events[index].revents & Int16(POLLIN | POLLHUP) != 0 {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(events[index].fd, &bytes, bytes.count)
                if count <= 0 { continue }
                received += count
                guard received <= 8 * 1024 * 1024 else { throw failure("lsp_output_limit") }
                guard index == 0 else { continue } // Never publish raw compiler/server logs.
                for frame in try framer.append(Data(bytes.prefix(count))) {
                    guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw failure("lsp_json") }
                    if let method = object["method"] as? String, let id = object["id"] {
                        let value: Any
                        if method == "workspace/configuration" {
                            let items = (object["params"] as? [String: Any])?["items"] as? [Any] ?? []
                            value = Array(repeating: NSNull(), count: min(64, items.count))
                        } else if method == "workspace/applyEdit" { value = ["applied": false] }
                        else { value = NSNull() } // No automatic trust, edits, or server commands.
                        try enqueue(["jsonrpc": "2.0", "id": id, "result": value])
                    } else if let id = object["id"] as? Int {
                        guard object["error"] == nil else { throw failure("lsp_request_rejected") }
                        if id == 1, !initialized {
                            initialized = true
                            try enqueue(["jsonrpc": "2.0", "method": "initialized", "params": [:] as [String: String]])
                            try enqueue(["jsonrpc": "2.0", "method": "textDocument/didOpen", "params": ["textDocument": [
                                "uri": uri, "languageId": "swift", "version": 1, "text": request.text]]])
                            var params: [String: Any] = ["textDocument": ["uri": uri]]
                            if request.method != "textDocument/documentSymbol" {
                                params["position"] = ["line": request.line, "character": request.character]
                            }
                            if request.method == "textDocument/references" { params["context"] = ["includeDeclaration": true] }
                            try enqueue(["jsonrpc": "2.0", "id": 2, "method": request.method, "params": params])
                        } else if id == 2, result == nil {
                            result = try JSONSerialization.data(withJSONObject: object["result"] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
                            try enqueue(["jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": NSNull()])
                        } else if id == 3, !shutdown {
                            shutdown = true
                            try enqueue(["jsonrpc": "2.0", "method": "exit"])
                        }
                    }
                }
            }
            if !process.isRunning {
                guard process.terminationStatus == 0, let result else { throw failure("lsp_exited") }
                return result
            }
        }
        throw failure("lsp_timeout")
    }

    private static func failure(_ reason: String) -> ToolExecutionFailure { .init(message: reason) }
}
