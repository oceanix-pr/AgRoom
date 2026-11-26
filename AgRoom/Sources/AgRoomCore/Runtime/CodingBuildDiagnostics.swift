import Foundation

enum CodingBuildDiagnostics {
    /// 编译器定位和 XCTest/Swift Testing 的失败摘要；日志原文仍保存在空间内。
    static func parse(_ output: String) -> [CodingDiagnostic] {
        let compiler = try? NSRegularExpression(pattern: #"^(.+?):(\d+)(?::(\d+))?:\s*(error|warning|note):\s*(.*)$"#)
        var diagnostics: [CodingDiagnostic] = []
        var groups: [String: Int] = [:]
        var categoryCounts: [String: Int] = [:]
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var candidate: CodingDiagnostic
            if let match = compiler?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func group(_ index: Int) -> String? { Range(match.range(at: index), in: line).map { String(line[$0]) } }
                candidate = CodingDiagnostic(path: group(1), line: group(2).flatMap(Int.init), column: group(3).flatMap(Int.init),
                    severity: group(4) ?? "error", message: String((group(5) ?? "").prefix(800)))
            } else if line.hasPrefix("error:") || line.contains(" failed") || line.contains("✘ Test") {
                candidate = CodingDiagnostic(path: nil, line: nil, column: nil, severity: "error", message: String(line.prefix(800)))
            } else { continue }
            let key = signature(candidate)
            if let index = groups[key] {
                diagnostics[index].occurrences = (diagnostics[index].occurrences ?? 1) + 1
                let location = CodingDiagnostic.Location(path: candidate.path, line: candidate.line, column: candidate.column)
                let primary = CodingDiagnostic.Location(path: diagnostics[index].path, line: diagnostics[index].line, column: diagnostics[index].column)
                if location != primary, !(diagnostics[index].relatedLocations ?? []).contains(location),
                   (diagnostics[index].relatedLocations?.count ?? 0) < 4 {
                    diagnostics[index].relatedLocations = (diagnostics[index].relatedLocations ?? []) + [location]
                }
                continue
            }
            // Keep scanning after warning saturation: a later error must not disappear.
            let cap = candidate.severity == "error" ? 64 : 32
            guard categoryCounts[candidate.severity, default: 0] < cap else { continue }
            candidate.occurrences = 1
            groups[key] = diagnostics.count
            diagnostics.append(candidate)
            categoryCounts[candidate.severity, default: 0] += 1
        }
        return Array(diagnostics.enumerated().sorted {
            let first = priority($0.element.severity), second = priority($1.element.severity)
            return first != second ? first < second : $0.offset < $1.offset
        }.prefix(40).map(\.element))
    }

    static func signature(_ diagnostic: CodingDiagnostic) -> String {
        // Elapsed time is not a new test failure. Keep its test identity and message.
        let message: String
        if diagnostic.path == nil, diagnostic.message.localizedCaseInsensitiveContains("test") {
            message = diagnostic.message.replacingOccurrences(of: #"(?i)(failed)\s+after\s+\d+(?:\.\d+)?\s+(?:seconds?|milliseconds?)"#,
                with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\s+\(\d+(?:\.\d+)?\s+seconds?\)\.?$"#, with: "", options: .regularExpression)
        } else { message = diagnostic.message }
        return diagnostic.severity + ":" + message
    }

    private static func priority(_ severity: String) -> Int {
        switch severity { case "error": 0; case "warning": 1; default: 2 }
    }
}
