import Foundation

public enum MailMboxVariant: String, Codable, CaseIterable, Sendable {
    case automatic, mboxrd, mboxo, mboxcl, mboxcl2
}

/// Byte positions refer to the selected source file, before transport unquoting.
/// They carry neither a path nor a grant to reopen an external file.
public struct MailMboxRecordLocation: Codable, Sendable, Equatable {
    public let envelopeOffset: Int64
    public let offset: Int64
    public let byteCount: Int
    public let variant: MailMboxVariant
}

extension MailMboxCodec {
    /// A location produced by the stream decoder excludes envelope and framing
    /// padding. The owning source session separately checks file identity and
    /// the complete decoded original's digest before exposing these bytes.
    static func decodeIndexedRecord(_ stored: Data, variant: MailMboxVariant) throws -> Data {
        guard variant != .automatic, stored.count <= MailService.rawMessageByteLimit * 2 else { throw MailImportError.invalidMessage }
        var start = stored.startIndex
        while start < stored.endIndex {
            guard let end = stored[start...].firstIndex(of: 10) else { throw MailImportError.invalidMessage }
            let next = stored.index(after: end)
            if isEmptyLine(Data(stored[start..<next])) {
                return try originalRecord(stored, bodyStart: next, variant: variant, maximumBytes: MailService.rawMessageByteLimit)
            }
            start = next
        }
        throw MailImportError.invalidMessage
    }

    /// Decodes one bounded record at a time. The caller owns source authorization
    /// and supplies chunks no larger than requested; no whole-file buffer is kept.
    public static func decodeStream(variant: MailMboxVariant = .automatic, initialOffset: Int64 = 0, initialIndex: Int = 0,
                                    maximumMessageBytes: Int = MailService.rawMessageByteLimit,
                                    read: @escaping (Int) throws -> Data,
                                    consume: (Int, MailMboxRecordLocation, Data) throws -> Void) throws {
        guard initialOffset >= 0, initialIndex >= 0, initialIndex < Int.max, maximumMessageBytes > 0,
              maximumMessageBytes <= MailService.rawMessageByteLimit else { throw MailImportError.capacity }
        let reader = MboxBytes(read: read, initialOffset: initialOffset)
        let storedLimit = maximumMessageBytes * 2
        var envelope = try reader.line(limit: 4096), index = initialIndex, delivered = false
        while let current = envelope {
            try Task.checkCancellation()
            guard index < Int.max else { throw MailImportError.capacity }
            guard current.data.starts(with: fromPrefix), current.data.last == 10 else { throw MailImportError.invalidMessage }
            let start = reader.offset
            var stored = Data(), headerCount = 0, contentLength: Int?, previousLength = false
            while true {
                guard let line = try reader.line(limit: maximumMessageBytes - stored.count) else { throw MailImportError.invalidMessage }
                stored.append(line.data)
                if isEmptyLine(line.data) { break }
                headerCount += 1
                guard headerCount <= 100_000 else { throw MailImportError.capacity }
                let continuation = line.data.first == 32 || line.data.first == 9
                if continuation, previousLength { throw MailImportError.invalidMessage }
                previousLength = false
                if !continuation, variant != .mboxrd, variant != .mboxo, let value = try lengthValue(line.data) {
                    guard contentLength == nil else { throw MailImportError.invalidMessage }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let length = Int(trimmed) else { throw MailImportError.invalidMessage }
                    guard length <= storedLimit else { throw MailImportError.capacity }
                    contentLength = length; previousLength = true
                }
            }
            guard headerCount > 0 else { throw MailImportError.invalidMessage }
            let headerBytes = stored.count
            let usesLength = variant == .mboxcl || variant == .mboxcl2 || (variant == .automatic && contentLength != nil)
            let resolved: MailMboxVariant
            var end: Int64
            if usesLength {
                guard let contentLength else { throw MailImportError.unsupported }
                guard contentLength <= storedLimit - stored.count else { throw MailImportError.capacity }
                stored.append(try reader.exactly(contentLength))
                end = reader.offset
                var next = try reader.line(limit: 4096), padding = 0
                while let line = next, isEmptyLine(line.data) {
                    padding += 1
                    guard padding <= 2 else { throw MailImportError.invalidMessage }
                    next = try reader.line(limit: 4096)
                }
                if let next {
                    guard next.data.starts(with: fromPrefix), next.data.last == 10,
                          stored.last == 10 || padding > 0 else { throw MailImportError.invalidMessage }
                }
                envelope = next
                if variant == .automatic {
                    // Content-Length proves a boundary, not whether >From was
                    // introduced by mboxcl. Only the user can resolve that case.
                    if hasLegacyQuote(stored, bodyStart: headerBytes) { throw MailImportError.variantRequired }
                    resolved = .mboxcl2
                } else { resolved = variant }
            } else {
                envelope = nil
                while let line = try reader.line(limit: storedLimit - stored.count) {
                    if line.data.starts(with: fromPrefix) {
                        guard line.data.count <= 4096, line.data.last == 10 else { throw MailImportError.invalidMessage }
                        envelope = line; break
                    }
                    stored.append(line.data)
                    envelope = nil
                }
                end = envelope?.offset ?? reader.offset
                // mboxrd and mboxo writers add one empty framing line. The
                // Content-Length branch never removes bytes from the body.
                if stored.count - headerBytes >= 2, stored.suffix(4) == Data([13, 10, 13, 10]) { stored.removeLast(2); end -= 2 }
                else if stored.count > headerBytes, stored.suffix(2) == Data([10, 10]) { stored.removeLast(); end -= 1 }
                resolved = variant == .automatic ? .mboxrd : variant
            }
            guard end >= start, end - start == Int64(stored.count) else { throw MailImportError.invalidMessage }
            let original = try originalRecord(stored, bodyStart: headerBytes, variant: resolved, maximumBytes: maximumMessageBytes)
            try Task.checkCancellation()
            try consume(index, .init(envelopeOffset: current.offset, offset: start, byteCount: stored.count, variant: resolved), original)
            guard index < Int.max else { throw MailImportError.capacity }
            index += 1; delivered = true
        }
        guard delivered else { throw MailImportError.invalidMessage }
    }

    private static let fromPrefix = Data([70, 114, 111, 109, 32])
    private static func isEmptyLine(_ data: Data) -> Bool { data == Data([10]) || data == Data([13, 10]) }

    private static func lengthValue(_ line: Data) throws -> String? {
        guard let colon = line.firstIndex(of: 58) else { return nil }
        let key = line[..<colon]
        guard String(decoding: key, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
        // A malformed length header must not silently switch an otherwise
        // length-framed mailbox to From-line framing.
        guard key.count == 14 else { throw MailImportError.invalidMessage }
        return String(decoding: line[line.index(after: colon)...], as: UTF8.self)
    }

    private static func hasLegacyQuote(_ data: Data, bodyStart: Int) -> Bool {
        var start = bodyStart
        while start < data.count {
            if data[start...].starts(with: Data([62]) + fromPrefix) { return true }
            start = data[start...].firstIndex(of: 10).map { $0 + 1 } ?? data.count
        }
        return false
    }

    private static func originalRecord(_ data: Data, bodyStart: Int, variant: MailMboxVariant, maximumBytes: Int) throws -> Data {
        guard bodyStart <= data.count, bodyStart <= maximumBytes else { throw MailImportError.capacity }
        if variant == .mboxcl2 {
            guard data.count <= maximumBytes else { throw MailImportError.capacity }
            return data
        }
        var output = Data(data.prefix(bodyStart)), start = bodyStart
        while start < data.count {
            try Task.checkCancellation()
            let end = data[start...].firstIndex(of: 10).map { $0 + 1 } ?? data.count
            var first = start
            if data[start] == 62 {
                if variant == .mboxrd {
                    var position = start
                    while position < end, data[position] == 62 { position += 1 }
                    if data[position..<end].starts(with: fromPrefix) { first += 1 }
                } else if data[start..<end].starts(with: Data([62]) + fromPrefix) { first += 1 }
            }
            guard end - first <= maximumBytes - output.count else { throw MailImportError.capacity }
            output.append(data[first..<end]); start = end
        }
        return output
    }
}

/// Mutable cursor state stays within a single synchronous decoding call.
private final class MboxBytes {
    struct Line { let offset: Int64; let data: Data }
    private let read: (Int) throws -> Data
    private var buffer = Data()
    private var cursor = 0
    private var eof = false
    private(set) var offset: Int64

    init(read: @escaping (Int) throws -> Data, initialOffset: Int64) { self.read = read; offset = initialOffset }

    private func fill() throws -> Bool {
        try Task.checkCancellation()
        if cursor < buffer.endIndex { return true }
        guard !eof else { return false }
        buffer = try read(64 * 1024); cursor = buffer.startIndex
        guard buffer.count <= 64 * 1024 else { throw MailImportError.capacity }
        if buffer.isEmpty { eof = true }
        return !eof
    }

    private func advance(_ count: Int) throws {
        let next = offset.addingReportingOverflow(Int64(count))
        guard !next.overflow else { throw MailImportError.capacity }
        offset = next.partialValue; cursor += count
    }

    func line(limit: Int) throws -> Line? {
        guard limit >= 0 else { throw MailImportError.capacity }
        let start = offset
        var data = Data()
        while try fill() {
            let end = buffer[cursor...].firstIndex(of: 10).map { $0 + 1 } ?? buffer.endIndex
            guard end - cursor <= limit - data.count else { throw MailImportError.capacity }
            let ended = buffer[end - 1] == 10
            data.append(buffer[cursor..<end]); try advance(end - cursor)
            if ended { return .init(offset: start, data: data) }
        }
        return data.isEmpty ? nil : .init(offset: start, data: data)
    }

    func exactly(_ count: Int) throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            guard try fill() else { throw MailImportError.invalidMessage }
            let size = min(count - data.count, buffer.endIndex - cursor)
            data.append(buffer[cursor..<(cursor + size)]); try advance(size)
        }
        return data
    }
}
