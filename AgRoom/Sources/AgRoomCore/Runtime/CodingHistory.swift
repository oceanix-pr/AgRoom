import Foundation

public enum CodingHistory {
    /// 编码历史按实际文本估算预算；长消息不再因超过固定字符阈值而丢掉绝大部分内容。
    public static func messages(_ messages: [ChatMessage], limit: Int, tokenBudget: Int) -> [EngineMessage] {
        guard limit > 0, tokenBudget > 0 else { return [] }
        var result: [EngineMessage] = []
        var remaining = tokenBudget
        for message in messages.suffix(limit).reversed() where message.role == .user || message.role == .assistant {
            guard !message.content.isEmpty, remaining > 0 else { continue }
            var text = message.content
            let estimate = TokenEstimator.estimate(text)
            if estimate > remaining {
                // 字符上限 <= token 上限，兼顾中文和代码；保留尾部验收条件并明确省略。
                guard remaining > 300 else { break }
                text = CodingTaskRuntime.bounded(text, maximum: remaining - 80)
            }
            remaining -= TokenEstimator.estimate(text)
            var item = EngineMessage(role: message.role == .user ? .user : .assistant, text: text)
            item.chatMessageID = message.id
            if result.count < 12, text == message.content {
                item.displayedMailReferences = DisplayedMailReferences(message: message)
            }
            if message.role == .assistant, text == message.content, let turn = message.providerTurn, turn.matchesDisplay(text) {
                item.historyTurn = turn
                let evidence = (message.trace ?? []).filter(\.succeeded).suffix(3).map {
                    "\($0.toolName): " + String($0.resultPreview.prefix(800))
                }.joined(separator: "\n")
                item.historyEvidence = evidence.isEmpty ? nil : evidence
            }
            result.insert(item, at: 0)
        }
        return result
    }
}
