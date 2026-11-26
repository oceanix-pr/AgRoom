import Foundation
import CryptoKit
import Testing
import AgRoomScriptIPC
@testable import AgRoomCore

@Suite("Python package host transport", .serialized)
struct PythonPackageDownloaderTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("package-transport-\(UUID())")
        let directory = try AppDirectory(url: root, create: true)
        for name in ["output", "home", "tmp"] { _ = try directory.child(name, create: true) }
        return root
    }

    private func session(_ replies: [String: PackageHTTPFixture.Reply]) -> URLSession {
        PackageHTTPFixture.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PackageHTTPFixture.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    private func message(_ url: String, method: String = "GET", headers: [String: String] = [:]) -> PythonPackageDownloader.Request {
        let initial = PythonPackageDownloader.Request(method: method, url: url, headers: headers, key: "")
        return .init(method: method, url: url, headers: headers, key: initial.expectedKey)
    }

    @Test func rejectsUntrustedDestinationsAndHeaders() throws {
        let valid = "https://pypi.org/simple/example/"
        _ = try message(valid).validatedURL()
        _ = try message("https://files.pythonhosted.org/packages/aa/example.whl", headers: ["range": "bytes=-1024"]).validatedURL()
        for url in ["http://pypi.org/simple/a/", "https://pypi.org.evil.invalid/simple/a/",
                    "https://user:password@pypi.org/simple/a/", "https://pypi.org:444/simple/a/",
                    "https://pypi.org/simple/../private", "https://pypi.org/simple/%2e%2e/private",
                    "https://pypi.org/simple/%252e%252e/private", "https://pypi.org/simple/a/?token=private",
                    "https://files.pythonhosted.org/packages/source.tar.gz", "file:///tmp/a.whl",
                    "https://127.0.0.1/simple/a/", "https://pypi.org/simple/a/\nHost: localhost"] {
            #expect(throws: ScriptIsolationError.self) { try message(url).validatedURL() }
        }
        for request in [message(valid, method: "POST"), message(valid, headers: ["authorization": "secret"]),
                        message(valid, headers: ["accept": "a\r\nb"]), message(valid, headers: ["range": "bytes=0-1,3-4"]),
                        .init(method: "GET", url: valid, headers: [:], key: "../escape")] {
            #expect(throws: ScriptIsolationError.self) { try request.validatedURL() }
        }
    }

    @Test func enforcesTransferBudgetsAndRedirectBoundary() async throws {
        let first = "https://pypi.org/simple/first/", second = "https://pypi.org/simple/second/"
        for (replies, total, count) in [
            ([first: PackageHTTPFixture.Reply(body: Data(repeating: 65, count: 5)), second: .init(body: Data(repeating: 66, count: 5))], 7, 10),
            ([first: .init(body: Data(), status: 302, headers: ["Location": "https://example.invalid/private"])], 100, 10),
            ([first: .init(body: Data()), second: .init(body: Data())], 100, 1)
        ] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = session(replies)
            defer { transport.invalidateAndCancel() }
            let replay = Replay(root: root, requests: [message(first), message(second)])
            let downloader = PythonPackageDownloader(session: transport, maximumBodyBytes: 100,
                maximumTotalBytes: total, maximumRequests: count)
            await #expect(throws: (any Error).self) {
                try await downloader.resolve(in: root, timeout: 10) { try await replay.execute($0) }
            }
            #expect(PackageHTTPFixture.requests.allSatisfy { $0.url?.host == "pypi.org" })
            #expect(PackageHTTPFixture.requests.count <= 2)
        }
    }

    @Test func cancellationDuringHTTPStopsReplay() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://pypi.org/simple/pause/"
        let transport = session([url: .init(body: Data(), pause: true)])
        defer { transport.invalidateAndCancel() }
        let replay = Replay(root: root, requests: [message(url)])
        let task = Task {
            try await PythonPackageDownloader(session: transport).resolve(in: root, timeout: 10) { try await replay.execute($0) }
        }
        for _ in 0..<100 where PackageHTTPFixture.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!PackageHTTPFixture.requests.isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await replay.executions == 1)
    }

    @Test("The offline pip resolver preserves extras, dependency versions, hashes and installation",
          .enabled(if: FileManager.default.isExecutableFile(atPath: PythonRuntimeManager.shared.managedPythonPath)))
    func wheelResolutionAndInstall() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let interpreter = PythonRuntimeManager.shared.managedPythonPath
        let first = try await wheel(in: root, name: "agroom_fixture", version: "1.0", metadata: "Provides-Extra: feature\nRequires-Dist: agroom-dependency==2.0; extra == 'feature'\n")
        let newer = try await wheel(in: root, name: "agroom_fixture", version: "2.0")
        let dependency = try await wheel(in: root, name: "agroom_dependency", version: "2.0")
        var replies: [String: PackageHTTPFixture.Reply] = [:]
        func index(_ name: String, wheels: [(String, Data)]) {
            let html: String = wheels.map { file, data -> String in
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return "<a href='https://files.pythonhosted.org/packages/aa/\(file)#sha256=\(digest)'>\(file)</a>"
            }.joined(separator: "\n")
            replies["https://pypi.org/simple/\(name)/"] = .init(body: Data(html.utf8), headers: ["Content-Type": "text/html"])
            for (file, data) in wheels {
                replies["https://files.pythonhosted.org/packages/aa/\(file)"] = .init(body: data, headers: ["Content-Type": "application/octet-stream"])
            }
        }
        index("agroom-fixture", wheels: [first, newer])
        index("agroom-dependency", wheels: [dependency])
        let transport = session(replies)
        defer { transport.invalidateAndCancel() }
        let output = root.appendingPathComponent("output")
        let result = try await PythonPackageDownloader(session: transport).resolve(in: root, timeout: 60) { remaining in
            let process = await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: interpreter),
                arguments: PackageDownload.arguments(requirement: "agroom-fixture[feature]<2"), workingDirectory: output,
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.appendingPathComponent("home").path,
                              "TMPDIR": root.appendingPathComponent("tmp").path], timeout: remaining, outputLimit: 6000, label: "offline-resolver-fixture"))
            return PythonExecutionResult(outcome: process.outcome, stdout: process.stdout, stderr: process.stderr, duration: process.duration)
        }
        try #require(result.succeeded, "\(result.displayOutput)")
        let lock = try AppDirectory(url: output, create: false).read("requirements.lock", limit: 128 * 1024)
        try PythonExecutor.validateWheelManifest(lock)
        let text = String(decoding: lock, as: UTF8.self)
        #expect(text.contains("agroom_fixture==1.0"))
        #expect(text.contains("agroom_dependency==2.0"))
        #expect(!text.contains("agroom_fixture==2.0"))
        #expect(PackageHTTPFixture.requests.count >= 4)
        #expect(PackageHTTPFixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
        let target = root.appendingPathComponent("venv")
        try await PythonEnvironmentService.createVenv(base: interpreter, at: target)
        let installed = await ChildProcessRunner.run(ChildProcessRequest(executable: target.appendingPathComponent("bin/python3"),
            arguments: PackageDownload.offlineArguments(["install", "--no-index", "--no-deps", "--require-hashes",
                "--find-links", output.path, "-r", output.appendingPathComponent("requirements.lock").path]),
            workingDirectory: root, environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path],
            timeout: 30, outputLimit: 4000, label: "fixture-install"))
        #expect(installed.succeeded, "\(installed.stderr)")
    }

    private func wheel(in root: URL, name: String, version: String, metadata: String = "") async throws -> (String, Data) {
        let contents = root.appendingPathComponent("\(name)-\(version)")
        let dist = "\(name)-\(version).dist-info"
        let directory = try AppDirectory(url: contents, create: true)
        let info = try directory.child(dist, create: true)
        try info.write(Data("Metadata-Version: 2.1\nName: \(name)\nVersion: \(version)\n\(metadata)\n".utf8), name: "METADATA")
        try info.write(Data("Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n".utf8), name: "WHEEL")
        try info.write(Data(), name: "RECORD")
        let file = "\(name)-\(version)-py3-none-any.whl"
        let zipped = await ChildProcessRunner.run(ChildProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-qr", root.appendingPathComponent(file).path, "."], workingDirectory: contents,
            timeout: 10, outputLimit: 1000, label: "wheel-fixture"))
        try #require(zipped.succeeded)
        return (file, try Data(contentsOf: root.appendingPathComponent(file)))
    }

    private actor Replay {
        let root: URL
        var requests: [PythonPackageDownloader.Request]
        var executions = 0
        init(root: URL, requests: [PythonPackageDownloader.Request]) { self.root = root; self.requests = requests }
        func execute(_ remaining: TimeInterval) throws -> PythonExecutionResult {
            executions += 1
            if !requests.isEmpty {
                try AppDirectory(url: root.appendingPathComponent("output"), create: false)
                    .write(JSONEncoder().encode(requests.removeFirst()), name: "network-request.json")
            }
            return PythonExecutionResult(outcome: .exited(0), stdout: "", stderr: "", duration: 0)
        }
    }
}

private final class PackageHTTPFixture: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let body: Data
        var status = 200
        var headers: [String: String] = [:]
        var pause = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var observed: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { observed } }
    static func reset(_ values: [String: Reply]) { lock.withLock { replies = values; observed = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.observed.append(request)
            return Self.replies[request.url?.absoluteString ?? ""]
        }
        guard let reply, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        if reply.pause { return }
        var headers = reply.headers
        headers["Content-Length"] = String(reply.body.count)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
