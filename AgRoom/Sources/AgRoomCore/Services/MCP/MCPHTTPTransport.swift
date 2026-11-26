import Foundation

internal struct MCPHTTPResponse: Sendable {
    let status: Int
    let sessionID: String?
    let body: Data
}

internal protocol MCPHTTPTransporting: Sendable {
    func send(_ request: URLRequest, responseID: String?) async throws -> MCPHTTPResponse
}

/// A private, cookie-free session per exchange. Never follows redirects or uses ambient credentials.
internal struct MCPHTTPTransport: MCPHTTPTransporting {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    private let configuration: @Sendable () -> URLSessionConfiguration

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configuration = configuration
    }

    func send(_ request: URLRequest, responseID: String?) async throws -> MCPHTTPResponse {
        let config = configuration()
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config, delegate: MCPHTTPDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await withThrowingTaskGroup(of: MCPHTTPResponse.self) { group in
                group.addTask { try await Self.receive(request, responseID: responseID, session: session) }
                group.addTask {
                    try await Task.sleep(for: .seconds(request.timeoutInterval))
                    throw MCPError(.timeout)
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw MCPError(.transport) }
                return response
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? MCPError { throw error }
            if (error as? URLError)?.code == .timedOut { throw MCPError(.timeout) }
            // Foundation errors may contain the credential-bearing request. Never forward them.
            throw MCPError(.transport)
        }
    }

    private static func receive(_ request: URLRequest, responseID: String?,
                                session: URLSession) async throws -> MCPHTTPResponse {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError(.invalidResponse) }
        if (300...399).contains(http.statusCode) { throw MCPError(.redirectBlocked) }
        let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if let sessionID {
            guard !sessionID.isEmpty, sessionID.utf8.count <= 1_024,
                  sessionID.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
                throw MCPError(.invalidResponse)
            }
        }
        guard http.expectedContentLength <= Int64(maximumResponseBytes) else { throw MCPError(.responseTooLarge) }
        if responseID == nil, http.statusCode == 202 {
            return MCPHTTPResponse(status: 202, sessionID: sessionID, body: Data())
        }
        let mime = http.mimeType?.lowercased()
        let streaming = http.statusCode == 200 && mime == "text/event-stream"
        if http.statusCode == 200, mime != "application/json", !streaming {
            throw MCPError(.unsupportedProtocol)
        }
        var body = Data()
        var parser = MCPEventParser(responseID: responseID)
        var received = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            received += 1
            guard received <= maximumResponseBytes else { throw MCPError(.responseTooLarge) }
            if streaming {
                if let result = try parser.append(byte) {
                    return MCPHTTPResponse(status: http.statusCode, sessionID: sessionID, body: result)
                }
            } else {
                body.append(byte)
            }
        }
        if streaming {
            guard let result = try parser.finish() else { throw MCPError(.invalidResponse) }
            body = result
        }
        return MCPHTTPResponse(status: http.statusCode, sessionID: sessionID, body: body)
    }
}

private final class MCPHTTPDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Byte-bounded framing, including CR, LF, CRLF, comments and multi-line data events.
internal struct MCPEventParser {
    let responseID: String?
    private var line = Data()
    private var dataLines: [String] = []
    private var afterCR = false
    private var firstLine = true

    init(responseID: String?) {
        self.responseID = responseID
    }

    mutating func append(_ byte: UInt8) throws -> Data? {
        if afterCR {
            afterCR = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            afterCR = byte == 13
            return try consumeLine()
        }
        guard line.count < MCPHTTPTransport.maximumResponseBytes else { throw MCPError(.responseTooLarge) }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> Data? {
        if !line.isEmpty, let result = try consumeLine() { return result }
        return try event()
    }

    private mutating func consumeLine() throws -> Data? {
        guard var text = String(data: line, encoding: .utf8) else { throw MCPError(.invalidResponse) }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.hasPrefix("\u{feff}") { text.removeFirst() } }
        if text.isEmpty { return try event() }
        if text == "data" { dataLines.append("") }
        else if text.hasPrefix("data:") {
            var value = String(text.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }

    private mutating func event() throws -> Data? {
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        if payload.isEmpty { return nil }
        let data = Data(payload.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["jsonrpc"] as? String == "2.0" else { throw MCPError(.invalidResponse) }
        if json["method"] != nil {
            if json["id"] != nil { throw MCPError(.interactionUnsupported) }
            return nil
        }
        guard json["id"] as? String == responseID else { return nil }
        return data
    }
}
