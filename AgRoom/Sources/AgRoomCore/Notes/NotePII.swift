import Foundation
import NaturalLanguage

public struct NotePIIEnvelope: Sendable {
    public let text: String
    let pairs: [(String, String)]
    public func restore(_ value: String) -> String { pairs.reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) } }
}
public enum NotePII {
    /// Local detection and explicit terms only. Never sends content to a detector service.
    public static func redact(_ text: String, terms: String = "") throws -> NotePIIEnvelope {
        guard text.utf8.count <= NoteStore.maximumContentBytes * 2, terms.utf8.count <= 32_768 else { throw NoteStoreError.tooLarge }
        let original = text as NSString
        var candidates: [NSRange] = []
        for pattern in [#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"(?<![0-9A-Z])\d{17}[0-9X](?![0-9A-Z])"#, #"(?<!\d)(?:\+?\d[\d ()-]{6,}\d)(?!\d)"#] {
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            candidates += regex.matches(in: text, range: NSRange(location: 0, length: original.length)).map(\.range)
        }
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, [NLTag.personalName, .organizationName, .placeName].contains(tag) { candidates.append(NSRange(range, in: text)) }
            return !Task.isCancelled
        }
        guard terms.components(separatedBy: .newlines).count <= 500 else { throw NoteStoreError.tooLarge }
        for term in terms.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            var search = NSRange(location: 0, length: original.length)
            while search.length > 0 {
                let range = original.range(of: term, options: [], range: search)
                if range.location == NSNotFound { break }
                candidates.append(range)
                search = NSRange(location: NSMaxRange(range), length: original.length - NSMaxRange(range))
            }
        }
        try Task.checkCancellation()
        let sorted = candidates.sorted { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var accepted: [NSRange] = []
        for range in sorted where range.length > 0 {
            if let last = accepted.last, range.location < NSMaxRange(last) { continue }
            accepted.append(range)
        }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var redacted = text, pairs: [(String, String)] = []
        for (index, range) in accepted.enumerated().reversed() {
            let token = "[PRIVATE_\(nonce)_\(index)]"
            pairs.append((token, original.substring(with: range)))
            redacted = (redacted as NSString).replacingCharacters(in: range, with: token)
        }
        return .init(text: redacted, pairs: pairs)
    }
}
