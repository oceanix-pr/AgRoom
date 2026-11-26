import Foundation

/// Memonta-compatible Markdown rules, with operation-local phonetic state.
public struct NoteTranscriptDictionary: Sendable {
    let replacements: [(String,String)]
    let terms: [String]
    public let privateTerms: [String]
    public init(_ source: String) throws {
        guard source.utf8.count <= 32_768 else { throw NoteStoreError.tooLarge }
        var pairs: [String:String] = [:], terms = Set<String>(), privateTerms = Set<String>()
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("<!--") { continue }
            if let marker = line.range(of: "#去标识化:") {
                let term = line[..<marker.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "- *\t"))
                if !term.isEmpty { privateTerms.insert(term) }; continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let term = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !term.isEmpty, term.count <= 100 else { throw NoteStoreError.invalidContent }
                terms.insert(term); continue
            }
            let values: [String]
            if line.hasPrefix("|") {
                let columns = line.split(separator: "|", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
                if columns.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) || ["错误词","錯誤詞","Wrong","wrong"].contains(columns.first ?? "") { continue }
                values = columns
            } else if line.contains("->") { values = line.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) } }
            else { values = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
            guard values.count == 2, !values[0].isEmpty, !values[1].isEmpty, pairs[values[0]] == nil else { throw NoteStoreError.invalidContent }
            pairs[values[0]] = values[1]; terms.insert(values[1])
        }
        guard pairs.count + terms.count <= 1000, privateTerms.count <= 500 else { throw NoteStoreError.tooLarge }
        replacements = pairs.sorted { $0.key.count > $1.key.count }.map { ($0.key,$0.value) }
        self.terms = terms.filter { $0.count >= 2 && $0.count <= 30 }.sorted { $0.count > $1.count }
        self.privateTerms = privateTerms.sorted()
    }
    public func apply(_ text: String) throws -> String {
        var result = text
        if !replacements.isEmpty {
            let map = Dictionary(uniqueKeysWithValues: replacements)
            let regex = try NSRegularExpression(pattern: replacements.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|"))
            let original = text as NSString
            // Build once from the original ranges. Replacing each match in a new
            // NSString repeatedly copied the entire transcript for dense corrections.
            result = ""
            result.reserveCapacity(text.utf8.count)
            var cursor = 0
            var cancelled = false
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: original.length)) { match, _, stop in
                if Task.isCancelled { cancelled = true; stop.pointee = true; return }
                guard let match else { return }
                result += original.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let source = original.substring(with: match.range)
                result += map[source] ?? source
                cursor = NSMaxRange(match.range)
            }
            if cancelled { throw CancellationError() }
            result += original.substring(from: cursor)
        }
        guard !terms.isEmpty else { return result }
        var cache: [Character:String] = [:]
        func han(_ c: Character) -> Bool { c.unicodeScalars.count == 1 && c.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value) } }
        func phonetic(_ value: String) -> String {
            value.map { c in
                if let existing = cache[c] { return existing }
                let pinyin = String(c).applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)?.lowercased().replacingOccurrences(of: " ", with: "") ?? String(c)
                cache[c] = pinyin; return pinyin
            }.joined(separator: "|")
        }
        var bySound: [String:[String]] = [:]
        for term in terms where term.allSatisfy(han) { bySound[phonetic(term),default: []].append(term) }
        let characters = Array(result), lengths = Set(terms.map(\.count)).sorted(by: >)
        var output = "", index = 0
        while index < characters.count {
            if index % 512 == 0 { try Task.checkCancellation() }
            var replacement: String?, consumed = 1
            for length in lengths where index + length <= characters.count && han(characters[index]) {
                let candidate = String(characters[index..<index + length])
                guard candidate.allSatisfy(han), let matches = bySound[phonetic(candidate)] else { continue }
                if matches.contains(candidate) { replacement = candidate; consumed = length; break }
                if matches.count == 1 { replacement = matches[0]; consumed = length; break }
            }
            output += replacement ?? String(characters[index]); index += consumed
        }
        return output
    }
}
