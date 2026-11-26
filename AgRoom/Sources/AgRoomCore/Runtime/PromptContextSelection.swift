import Foundation

/// Per-run selection from already space-scoped data. No global cache or filesystem access.
enum PromptContextSelection {
    static func memories(_ items: [MemoryItem], query: String, tokenBudget: Int = 1_200) -> [MemoryItem] {
        let words = KnowledgeRanker.tokenize(String(query.prefix(8_000)))
        let ranked = items.filter(\.isEnabled).map { item in
            (item, score(item.content, words: words) + (item.category == .preference ? 2 : 0))
        }.filter { $0.1 > 0 }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.createdAt != $1.0.createdAt { return $0.0.createdAt > $1.0.createdAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        var remaining = max(0, tokenBudget)
        var result: [MemoryItem] = []
        for (var item, _) in ranked.prefix(8) {
            if item.content.count > 900 {
                item.content = String(item.content.prefix(600))
                    + "\n[Memory excerpt omitted; use memory_search to retrieve the stored entry.]\n"
                    + String(item.content.suffix(200))
            }
            let size = TokenEstimator.estimate(item.content) + 12
            guard size <= remaining else { continue }
            result.append(item); remaining -= size
        }
        return result
    }

    static func skills(_ items: [Skill], query: String, preferred: Set<String>, tokenBudget: Int = 900) -> [Skill] {
        let words = KnowledgeRanker.tokenize(String(query.prefix(8_000)))
        let ranked = items.filter(\.isEnabled).sorted {
            let lhs = score($0.name + " " + $0.alias + " " + $0.description, words: words) + (preferred.contains($0.name) ? 100 : 0)
            let rhs = score($1.name + " " + $1.alias + " " + $1.description, words: words) + (preferred.contains($1.name) ? 100 : 0)
            return lhs != rhs ? lhs > rhs : $0.name < $1.name
        }
        var remaining = max(0, tokenBudget)
        var result: [Skill] = []
        for var skill in ranked.prefix(8) {
            skill.description = String(skill.description.prefix(160))
            let size = TokenEstimator.estimate(skill.name + skill.alias + skill.description) + 12
            guard size <= remaining else { continue }
            result.append(skill); remaining -= size
        }
        return result
    }

    static func agents(_ items: [Agent], query: String) -> [Agent] {
        let words = KnowledgeRanker.tokenize(String(query.prefix(8_000)))
        return items.filter(\.isEnabled).sorted {
            let lhs = score($0.name + " " + $0.description, words: words)
            let rhs = score($1.name + " " + $1.description, words: words)
            return lhs != rhs ? lhs > rhs : $0.toolName < $1.toolName
        }.prefix(6).map { agent in
            var bounded = agent
            bounded.description = String(agent.description.prefix(240))
            return bounded
        }
    }

    private static func score(_ text: String, words: Set<String>) -> Int {
        let text = text.lowercased()
        return words.reduce(0) { $0 + (text.contains($1) ? min(12, $1.count) : 0) }
    }
}
