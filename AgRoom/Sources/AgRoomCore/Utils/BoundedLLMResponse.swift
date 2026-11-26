import Foundation

enum LLMResponseLimits {
    static let responseBytes = 16 * 1024 * 1024
    static let eventBytes = 1024 * 1024
    static let textBytes = 8 * 1024 * 1024
    static let argumentBytes = 256 * 1024
    static let toolCalls = 64
    static func check(_ text: String, limit: Int = textBytes) throws {
        guard text.utf8.count <= limit else { throw LLMError.responseTooLarge }
    }
    static func validate(_ reply: ChatReply) throws {
        try check(reply.text)
        try check(reply.reasoning ?? "")
        guard reply.toolCalls.count <= toolCalls else { throw LLMError.responseTooLarge }
        for call in reply.toolCalls { try check(call.argumentsJSON, limit: argumentBytes) }
    }
}

/// Limits are checked before constructing a complete SSE line.
struct BoundedLLMLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String
    let bytes: Base
    func makeAsyncIterator() -> Iterator { Iterator(base: bytes.makeAsyncIterator()) }
    struct Iterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var received = 0
        mutating func next() async throws -> String? {
            try Task.checkCancellation()
            var line = Data()
            while let byte = try await base.next() {
                received += 1
                if received.isMultiple(of: 4096) { try Task.checkCancellation() }
                guard received <= LLMResponseLimits.responseBytes, line.count < LLMResponseLimits.eventBytes else {
                    throw LLMError.responseTooLarge
                }
                if byte == 10 {
                    try Task.checkCancellation()
                    if line.last == 13 { line.removeLast() }
                    return String(decoding: line, as: UTF8.self)
                }
                line.append(byte)
            }
            return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
        }
    }
}

extension CloudProvider {
    func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await responseBytes(for: request)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            guard data.count < LLMResponseLimits.responseBytes else { throw LLMError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }
}
