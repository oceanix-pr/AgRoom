import Foundation
import Darwin
import CryptoKit

/// A private exchange for the fixed offline pip resolver. No script, credentials,
/// user agent, cookies, proxy settings or arbitrary destination crosses into the host.
struct PythonPackageDownloader: Sendable {
    struct Request: Codable, Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let key: String

        var expectedKey: String {
            SHA256.hash(data: Data([method, url, headers["accept"] ?? "", headers["range"] ?? ""]
                .joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        }

        func validatedURL() throws -> URL {
            guard ["GET", "HEAD"].contains(method), key == expectedKey,
                  headers.keys.allSatisfy({ ["accept", "range"].contains($0) }),
                  headers.values.allSatisfy({ $0.utf8.count <= 1024 && $0.utf8.allSatisfy { (32...126).contains($0) } }),
                  headers["range"].map({ $0.wholeMatch(of: /^bytes=-?[0-9]+(?:-[0-9]*)?$/) != nil }) ?? true,
                  let destination = PythonPackageDownloader.permittedURL(url) else { throw ScriptIsolationError.invalidScope }
            return destination
        }
    }

    private struct Response: Encodable {
        let status: Int
        let headers: [String: String]
    }

    // Injection is internal and used only by deterministic HTTP fixtures.
    var session: URLSession?
    var maximumBodyBytes = 512 * 1024 * 1024
    var maximumTotalBytes = 1024 * 1024 * 1024
    var maximumRequests = 1024

    static func permittedURL(_ text: String) -> URL? {
        guard text.utf8.count <= 4096, text.utf8.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
              let parts = URLComponents(string: text), parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, parts.query == nil,
              parts.fragment == nil || parts.fragment?.wholeMatch(of: /^sha256=[a-f0-9]{64}$/) != nil,
              let path = parts.percentEncodedPath.removingPercentEncoding,
              !path.contains("%"), !path.contains("\\"), path.utf8.allSatisfy({ (32...126).contains($0) }),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let index = parts.host == "pypi.org" && path.hasPrefix("/simple/")
        let wheel = parts.host == "files.pythonhosted.org" && path.hasPrefix("/packages/")
            && (path.hasSuffix(".whl") || path.hasSuffix(".whl.metadata"))
        return index || wheel ? parts.url : nil
    }

    /// Replaying pip keeps its dependency, extra and version selection semantics.
    /// Only the fixed resolver is replayed; package installation happens once afterwards.
    func resolve(in run: URL, timeout: TimeInterval,
                 execute: @Sendable (TimeInterval) async throws -> PythonExecutionResult) async throws -> PythonExecutionResult {
        let start = ProcessInfo.processInfo.systemUptime
        guard timeout.isFinite, timeout > 0 else { throw ScriptIsolationError.invalidScope }
        let deadline = start + timeout
        let root = try AppDirectory(url: run, create: false)
        let cache = try root.child("network", create: true, exclusive: true)
        let cacheURL = try cache.kernelURL()
        let output = try root.child("output", create: false)
        var transferred = 0
        for attempt in 0...maximumRequests {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return Self.timedOut(start: start) }
            try root.verifyIdentity(at: run)
            for name in ["tmp", "home"] { _ = try root.child(name, create: true) }
            let result = try await execute(remaining)
            guard result.succeeded else { return result }
            try root.verifyIdentity(at: run)
            if !output.exists("network-request.json") { return result }
            guard attempt < maximumRequests else { throw LLMError.responseTooLarge }
            let data = try output.read("network-request.json", limit: 16 * 1024)
            let request = try JSONDecoder().decode(Request.self, from: data)
            try output.removeFile("network-request.json")
            let url = try request.validatedURL()
            guard !cache.exists(request.key + ".json"), !cache.exists(request.key + ".body") else {
                throw ScriptIsolationError.invalidScope
            }
            do {
                transferred += try await fetch(request, url: url, cache: cache,
                    cacheURL: cacheURL, remainingBytes: maximumTotalBytes - transferred, deadline: deadline)
            } catch let error as URLError where error.code == .timedOut {
                return Self.timedOut(start: start)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        throw LLMError.responseTooLarge
    }

    private static func timedOut(start: TimeInterval) -> PythonExecutionResult {
        PythonExecutionResult(outcome: .timedOut, stdout: "", stderr: "", duration: ProcessInfo.processInfo.systemUptime - start)
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = min(30, timeout)
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private func fetch(_ message: Request, url: URL, cache: AppDirectory,
                       cacheURL: URL, remainingBytes: Int, deadline: TimeInterval) async throws -> Int {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw URLError(.timedOut) }
        let connection = session ?? Self.makeSession(timeout: remaining)
        defer { if session == nil { connection.invalidateAndCancel() } }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(30, remaining))
        request.httpMethod = message.method
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in message.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await connection.bytes(for: request, delegate: PackageRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ScriptIsolationError.invalidScope }
        // URLSession never follows redirects. Even a returned Location is validated
        // before pip can replay it as another independently checked request.
        if (300...399).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location") {
            guard let next = URL(string: location, relativeTo: url)?.absoluteURL,
                  Self.permittedURL(next.absoluteString) != nil else { throw ScriptIsolationError.invalidScope }
        }
        let isWheel = url.host == "files.pythonhosted.org" && url.path.hasSuffix(".whl")
        let limit = min(maximumBodyBytes, isWheel ? maximumBodyBytes : 64 * 1024 * 1024, remainingBytes)
        guard limit >= 0, response.expectedContentLength <= limit else { throw LLMError.responseTooLarge }
        let temporary = ".pending-" + UUID().uuidString
        let file = openat(cache.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ScriptIsolationError.invalidScope }
        defer { Darwin.close(file); _ = unlinkat(cache.fd, temporary, 0) }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var size = 0
        for try await byte in bytes {
            guard size < limit else { throw LLMError.responseTooLarge }
            size += 1
            buffer.append(byte)
            if buffer.count == 64 * 1024 {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                try Self.write(buffer, to: file)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
        try Self.write(buffer, to: file)
        try cache.verifyIdentity(at: cacheURL)
        guard fsync(file) == 0, renameat(cache.fd, temporary, cache.fd, message.key + ".body") == 0 else {
            throw ScriptIsolationError.invalidScope
        }
        var headers: [String: String] = [:]
        for name in ["content-type", "content-range", "accept-ranges", "etag", "last-modified", "location"] {
            if let value = http.value(forHTTPHeaderField: name), value.utf8.count <= 4096,
               !value.contains("\r"), !value.contains("\n") { headers[name] = value }
        }
        // URLSession may decompress; cache the byte length of the actual body.
        headers["content-length"] = message.method == "HEAD" ? http.value(forHTTPHeaderField: "Content-Length") : String(size)
        try cache.write(JSONEncoder().encode(Response(status: http.statusCode, headers: headers)), name: message.key + ".json")
        return size
    }

    private static func write(_ data: Data, to file: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ScriptIsolationError.invalidScope }
                offset += count
            }
        }
    }
}

private final class PackageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
