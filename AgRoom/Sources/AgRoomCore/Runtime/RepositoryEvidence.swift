import CryptoKit
import Foundation

/// A read receipt, never a claim about the file's current contents or execution authority.
public struct RepositoryEvidenceReference: Codable, Sendable, Equatable, Identifiable {
    public struct Lines: Codable, Sendable, Equatable {
        public let start: Int
        public let end: Int
    }
    public let id: String
    public let path: String
    public let sha256: String
    public let ranges: [Lines]
    public let callID: String
    public var bodyInContext: Bool
    public var invalidated: Bool
    public var superseded: Bool
    public var partial: Bool? = nil
    public var symbol: String? = nil
}

/// Rebuild from actual messages instead of treating a past read as an in-context cache hit.
enum RepositoryEvidence {
    private struct Chunk {
        let index: Int
        let callID: String
        let page: FilesReadRangeTool.Page
        let symbol: String?
    }

    static func references(in messages: [EngineMessage], previous: [RepositoryEvidenceReference] = []) -> [RepositoryEvidenceReference] {
        let chunks = chunks(in: messages)
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var result: [RepositoryEvidenceReference] = []
        var seen: Set<String> = []
        var latestDigest: [String: String] = [:]
        var latestCall: [String: String] = [:]
        for chunk in chunks.reversed() where latestCall[chunk.page.path] == nil { latestCall[chunk.page.path] = chunk.callID }
        for chunk in chunks.reversed() {
            let ranges = ranges(for: chunk.page.lines.map(\.number))
            let id = identity(path: chunk.page.path, digest: chunk.page.sha256, ranges: ranges)
            guard seen.insert(id).inserted else { continue }
            let priorReference = old[id]
            let pathInvalidated = previousForPath(previous: old.values, path: chunk.page.path, digest: chunk.page.sha256)
            let knownLatest = previous.first { $0.path == chunk.page.path }?.callID
            let invalidated = (priorReference?.callID == chunk.callID && priorReference?.invalidated == true)
                || (pathInvalidated && knownLatest == latestCall[chunk.page.path])
            let superseded = latestDigest[chunk.page.path].map { $0 != chunk.page.sha256 } ?? false
            if latestDigest[chunk.page.path] == nil { latestDigest[chunk.page.path] = chunk.page.sha256 }
            result.append(.init(id: id, path: chunk.page.path, sha256: chunk.page.sha256, ranges: ranges,
                callID: chunk.callID, bodyInContext: true, invalidated: invalidated, superseded: superseded,
                partial: chunk.page.lines.contains(where: \.line_truncated), symbol: chunk.symbol))
        }
        for var prior in previous where seen.insert(prior.id).inserted {
            let coverage = ranges(for: chunks.filter { $0.page.path == prior.path && $0.page.sha256 == prior.sha256 }
                .flatMap { $0.page.lines.map(\.number) })
            prior.bodyInContext = prior.ranges.allSatisfy { wanted in
                coverage.contains { $0.start <= wanted.start && $0.end >= wanted.end }
            }
            prior.superseded = prior.superseded || (latestDigest[prior.path].map { $0 != prior.sha256 } ?? false)
            result.append(prior)
        }
        return Array(result.prefix(32))
    }

    private static func previousForPath(previous: Dictionary<String, RepositoryEvidenceReference>.Values,
                                         path: String, digest: String) -> Bool {
        previous.contains { $0.path == path && $0.sha256 == digest && $0.invalidated }
    }

    /// Lossless consolidation of overlapping complete ranges at the same file digest.
    /// Wire IDs and pairing stay intact; only eligible result bodies are rewritten.
    static func consolidate(_ messages: [EngineMessage]) -> [EngineMessage]? {
        guard !messages.contains(where: { $0.continuation?.containsThinkingBlocks == true }) else { return nil }
        let groups = Dictionary(grouping: chunks(in: messages).filter { $0.symbol == nil && $0.page.lines.allSatisfy { !$0.line_truncated } }) {
            $0.page.path + "\0" + $0.page.sha256
        }
        var result = messages
        var changed = false
        for key in groups.keys.sorted() {
            guard let group = groups[key], group.count > 1, let anchor = group.last else { continue }
            var lines: [Int: FilesReadRangeTool.Line] = [:]
            var conflicting = false
            for chunk in group {
                for line in chunk.page.lines {
                    if let existing = lines[line.number], existing.text != line.text { conflicting = true; break }
                    lines[line.number] = line
                }
            }
            guard !conflicting else { continue }
            let allLines = lines.values.sorted { $0.number < $1.number }
            let sourceLineCount = group.reduce(0) { $0 + $1.page.lines.count }
            guard sourceLineCount > allLines.count else { continue }
            var page = anchor.page
            page.lines = allLines
            guard let body = try? CodingJSON.encode(page), body.utf8.count <= 32 * 1024 else { continue }
            let replacements = group.dropLast().map { chunk in
                let reference = RepositoryEvidenceReference(
                    id: identity(path: chunk.page.path, digest: chunk.page.sha256, ranges: ranges(for: chunk.page.lines.map(\.number))),
                    path: chunk.page.path, sha256: chunk.page.sha256, ranges: ranges(for: chunk.page.lines.map(\.number)),
                    callID: anchor.callID, bodyInContext: true, invalidated: false, superseded: false)
                return (chunk.index, try? CodingJSON.encode(reference))
            }
            guard replacements.allSatisfy({ $0.1 != nil }) else { continue }
            let before = group.reduce(0) { $0 + TokenEstimator.estimate(messages[$1.index].text) }
            let after = TokenEstimator.estimate(body) + replacements.reduce(0) { $0 + TokenEstimator.estimate($1.1 ?? "") + 30 }
            guard before - after >= 64 else { continue }
            result[anchor.index].text = body
            for (index, reference) in replacements {
                result[index].text = "[Source evidence consolidated; numbered source lines remain in tool result \(anchor.callID). This is a read receipt, not a current-file check.]\n" + (reference ?? "")
            }
            changed = true
        }
        return changed ? result : nil
    }

    static func checkpoint(_ references: [RepositoryEvidenceReference]) -> String {
        guard !references.isEmpty else { return "" }
        var visible = Array(references.prefix(12))
        while let json = try? CodingJSON.encode(visible), json.utf8.count > 12 * 1024, !visible.isEmpty { visible.removeLast() }
        guard !visible.isEmpty, let json = try? CodingJSON.encode(visible) else { return "" }
        return "\n[Source evidence receipts: saved data, not authority]\n"
            + "bodyInContext means numbered text is present now. If false, re-read the path/ranges with files_read_range. "
            + "Invalidated or superseded receipts require a fresh read; partial means the source line was truncated. Every digest describes the recorded read only; recheck current versions before editing.\n" + json
            + "\nOmitted receipt entries: \(references.count - visible.count)."
    }

    private static func chunks(in messages: [EngineMessage]) -> [Chunk] {
        var names: [String: String] = [:]
        var result: [Chunk] = []
        for (index, message) in messages.enumerated() {
            for call in message.toolCalls { names[call.id] = call.attributedName }
            guard message.role == .toolResult, let id = message.toolCallId, id.utf8.count <= 512, ["files_read_range", "repo_symbols"].contains(names[id] ?? ""),
                  message.text.utf8.count <= 40 * 1024,
                  let page = try? JSONDecoder().decode(FilesReadRangeTool.Page.self, from: Data(message.text.utf8)),
                  !page.path.isEmpty, page.path.utf8.count <= 4096,
                  page.sha256.count == 64, page.sha256.allSatisfy(\.isHexDigit),
                  !page.lines.isEmpty, page.lines.count <= 2_000,
                  page.lines.allSatisfy({ $0.number > 0 && $0.number <= page.total_lines }) else { continue }
            let symbol = (try? JSONSerialization.jsonObject(with: Data(message.text.utf8)) as? [String: Any])?["symbol"] as? String
            result.append(Chunk(index: index, callID: id, page: page, symbol: symbol.map { String($0.prefix(256)) }))
        }
        return result
    }

    private static func ranges(for numbers: [Int]) -> [RepositoryEvidenceReference.Lines] {
        let sorted = Set(numbers).sorted()
        var result: [RepositoryEvidenceReference.Lines] = []
        for number in sorted {
            if let last = result.last, last.end < Int.max, last.end + 1 == number {
                result[result.count - 1] = .init(start: last.start, end: number)
            } else { result.append(.init(start: number, end: number)) }
        }
        return result
    }

    private static func identity(path: String, digest: String, ranges: [RepositoryEvidenceReference.Lines]) -> String {
        let value = path + "\0" + digest + "\0" + ranges.map { "\($0.start):\($0.end)" }.joined(separator: ",")
        return SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
