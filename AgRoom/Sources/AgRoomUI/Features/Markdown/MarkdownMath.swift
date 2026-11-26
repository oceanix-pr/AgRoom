import Foundation

struct MarkdownMath: Sendable, Equatable, Hashable {
    let source: String
    let display: Bool
}

/// 在 CommonMark 转义处理前保护公式，字节数和换行位置保持不变。
/// 单美元不跨行，开符后/闭符前不能有空白，闭符后不能紧邻数字。
struct MarkdownMathProtection {
    struct Span {
        let range: Range<Int>
        let math: MarkdownMath?
    }
    let bytes: [UInt8]
    let spans: [Span]

    init(source: String, startingAt offset: Int, excluded: [Range<Int>]) {
        let original = Array(source.utf8)
        var masked = original
        var found: [Span] = []
        // 选择原文中不存在的私用字符，避免普通正文与占位符混淆。
        let scalars = Set(source.unicodeScalars)
        guard let sentinel = (0xE000...0xF8FF).lazy.compactMap(UnicodeScalar.init).first(where: { !scalars.contains($0) }),
              let shortSentinel = (0xA1...0x7FF).lazy.compactMap(UnicodeScalar.init).first(where: { !scalars.contains($0) }) else {
            bytes = original; spans = []; return
        }
        let marker = Array(String(sentinel).utf8)
        let shortMarker = Array(String(shortSentinel).utf8)
        func escaped(_ index: Int) -> Bool {
            var cursor = index
            while cursor > offset && original[cursor - 1] == 92 { cursor -= 1 }
            return (index - cursor) % 2 == 1
        }
        func matches(_ token: [UInt8], at index: Int) -> Bool {
            index + token.count <= original.count && original[index..<(index + token.count)].elementsEqual(token)
        }
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        var index = offset
        let exclusions = excluded.sorted { $0.lowerBound < $1.lowerBound }
        var exclusionIndex = 0
        while index < original.count, found.count < 128 {
            while exclusionIndex < exclusions.count && exclusions[exclusionIndex].upperBound <= index { exclusionIndex += 1 }
            if exclusionIndex < exclusions.count, exclusions[exclusionIndex].contains(index) {
                index = exclusions[exclusionIndex].upperBound; continue
            }
            let open: [UInt8], close: [UInt8], display: Bool
            if !escaped(index), matches([36, 36], at: index) { open = [36, 36]; close = open; display = true }
            else if !escaped(index), matches([92, 91], at: index) { open = [92, 91]; close = [92, 93]; display = true }
            else if !escaped(index), matches([92, 40], at: index) { open = [92, 40]; close = [92, 41]; display = false }
            else if original[index] == 36, !escaped(index), index + 1 < original.count,
                    !whitespace(original[index + 1]), original[index + 1] != 36 {
                open = [36]; close = open; display = false
            } else { index += 1; continue }
            let start = index + open.count
            var cursor = start
            var end: Int?
            while cursor < min(original.count, start + 16_384) {
                if !display, [10, 13].contains(original[cursor]) { break }
                if matches(close, at: cursor), !escaped(cursor), cursor > start {
                    let after = cursor + close.count
                    if open.count != 1 || (!whitespace(original[cursor - 1]) && (after == original.count || !(48...57).contains(original[after]))) {
                        end = cursor; break
                    }
                }
                cursor += 1
            }
            guard let end else {
                if open.first == 92 {
                    let range = index..<(index + open.count)
                    masked.replaceSubrange(range, with: shortMarker)
                    found.append(Span(range: range, math: nil))
                }
                index += open.count; continue
            }
            let range = index..<(end + close.count)
            // 多行引用中的容器前缀不属于 LaTeX，也不能在保护时抹掉。
            let lineStart = (original[..<index].lastIndex(of: 10).map { $0 + 1 }) ?? offset
            let prefix = Array(original[lineStart..<index])
            // 列表首行标记在续行上变为同宽缩进，引用符保留。
            let isContainerPrefix = prefix.allSatisfy { [9, 32, 62, 45, 42, 43, 46, 41].contains($0) || (48...57).contains($0) }
            let containerPrefix: [UInt8] = isContainerPrefix ? prefix.map { [9, 32, 62].contains($0) ? $0 : 32 } : []
            var removedPrefixes: [Range<Int>] = []
            if !containerPrefix.isEmpty {
                let quoteDepth = containerPrefix.filter { $0 == 62 }.count
                for position in range where original[position] == 10 {
                    let next = position + 1
                    var cursor = next
                    func skipSpaces() { while cursor < range.upperBound && [9, 32].contains(original[cursor]) { cursor += 1 } }
                    skipSpaces()
                    for _ in 0..<quoteDepth {
                        guard cursor < range.upperBound, original[cursor] == 62 else { break }
                        cursor += 1
                        skipSpaces()
                    }
                    if cursor > next { removedPrefixes.append(next..<cursor) }
                }
            }
            var formulaBytes = Array(original[start..<end])
            for prefixRange in removedPrefixes.reversed() {
                let lower = max(start, prefixRange.lowerBound), upper = min(end, prefixRange.upperBound)
                if lower < upper { formulaBytes.removeSubrange((lower - start)..<(upper - start)) }
            }
            let formula = String(decoding: formulaBytes, as: UTF8.self)
            for position in range where ![10, 13].contains(original[position]) { masked[position] = 81 }
            for prefixRange in removedPrefixes { masked.replaceSubrange(prefixRange, with: original[prefixRange]) }
            if !original[index..<(index + 3)].contains(where: { [10, 13].contains($0) }) {
                masked.replaceSubrange(index..<(index + 3), with: marker)
            } else {
                masked.replaceSubrange(index..<(index + 2), with: shortMarker)
            }
            found.append(Span(range: range, math: MarkdownMath(source: formula.trimmingCharacters(in: .whitespacesAndNewlines), display: display)))
            index = range.upperBound
        }
        bytes = masked
        spans = found
    }
}
