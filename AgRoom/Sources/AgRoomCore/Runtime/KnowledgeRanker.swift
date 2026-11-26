import Foundation

// MARK: - Knowledge Ranker

/// 知识相关性检索（RAG v1：关键词加权排序，本地执行、零模型依赖）。
/// 权重：标题命中 ×3、标签命中 ×2、正文命中 ×1（单 token 封顶 3 次）。
/// CJK 采用二字分词（bigram），ASCII 采用连续字母数字词。
public enum KnowledgeRanker {

    /// 检索 Top-N 相关条目；无命中返回空数组
    public static func search(query: String, items: [KnowledgeItem], limit: Int) -> [KnowledgeItem] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        let scored: [(item: KnowledgeItem, score: Int)] = items.compactMap { item in
            let score = self.score(item: item, tokens: tokens)
            return score > 0 ? (item, score) : nil
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.item)
    }

    // MARK: - Scoring

    static func score(item: KnowledgeItem, tokens: Set<String>) -> Int {
        let title = item.title.lowercased()
        let content = item.content.lowercased()
        let tags = item.tags.map { $0.lowercased() }

        var total = 0
        for token in tokens {
            if title.contains(token) {
                total += 3
            }
            if tags.contains(where: { $0.contains(token) }) {
                total += 2
            }
            if content.contains(token) {
                // 正文命中按出现次数计，封顶 3
                var count = 0
                var searchRange = content.startIndex..<content.endIndex
                while let range = content.range(of: token, range: searchRange), count < 3 {
                    count += 1
                    searchRange = range.upperBound..<content.endIndex
                }
                total += count
            }
        }
        return total
    }

    // MARK: - Tokenization

    /// 分词：ASCII 连续字母数字为词；CJK 连续段切二字组合（单字段保留单字）
    public static func tokenize(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        var asciiWord = ""
        var cjkRun: [Character] = []

        func flushASCII() {
            if asciiWord.count >= 2 {
                tokens.insert(asciiWord.lowercased())
            }
            asciiWord = ""
        }

        func flushCJK() {
            if cjkRun.count == 1 {
                tokens.insert(String(cjkRun))
            } else if cjkRun.count > 1 {
                for index in 0..<(cjkRun.count - 1) {
                    tokens.insert(String(cjkRun[index...index + 1]))
                }
            }
            cjkRun = []
        }

        for character in text {
            if character.isASCII && (character.isLetter || character.isNumber) {
                flushCJK()
                asciiWord.append(character)
            } else if isCJK(character) {
                flushASCII()
                cjkRun.append(character)
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()
        return tokens
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)      // CJK 统一表意文字
            || (0x3400...0x4DBF).contains(value)      // 扩展 A
            || (0x3040...0x30FF).contains(value)      // 日文假名
            || (0xAC00...0xD7AF).contains(value)      // 韩文音节
    }
}
