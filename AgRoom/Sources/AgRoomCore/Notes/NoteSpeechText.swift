import Foundation

public enum NoteSpeechText {
    public static func prepare(_ markdown: String) -> String {
        var lines: [String] = [], fenced = false, headers: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced { continue }
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                if headers.isEmpty { headers = cells; continue }
                lines.append(cells.enumerated().map { index, cell in index < headers.count ? headers[index] + ": " + cell : cell }.joined(separator: "; ")); continue
            }
            headers = []
            var text = line.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#,with: "",options: .regularExpression)
            text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#,with: "$1",options: .regularExpression)
            text = text.replacingOccurrences(of: #"^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s*)?|\d+[.)]\s+)"#,with: "",options: .regularExpression)
            text = text.replacingOccurrences(of: #"[`*_~]"#,with: "",options: .regularExpression)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }
    static func chunks(_ text: String, limit: Int = 400) -> [String] {
        var result: [String] = [], start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start,offsetBy: limit,limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let stop = text[text.index(start,offsetBy: limit / 2)..<end].lastIndex(where: { ".!?。！？；;\n".contains($0) }) { end = text.index(after: stop) }
            result.append(String(text[start..<end])); start = end
        }
        return result
    }
}
