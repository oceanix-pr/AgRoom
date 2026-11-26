import Foundation

// MARK: - AI Assist Generator（通用 AI 辅助生成）

/// 轻量单轮生成底座：OCR 结构化、人设展开、NL→SQL、改进建议、快捷提示推荐等
/// AI 辅助场景共用。输出小、无需流式与复杂容错——剥围栏/思考标签后即用
public struct AIAssistGenerator: Sendable {

    public enum AssistError: Error, LocalizedError {
        case emptyOutput

        public var errorDescription: String? {
            "The model returned an empty response. Try again or switch models."
        }
    }

    let provider: CloudProvider

    /// 辅助场景默认配置：输出小，4096 够用（思考型模型留推理裕量）
    public static let defaultConfig = LLMConfig(maxTokens: 4096, temperature: 0.5)

    public init(provider: CloudProvider) {
        self.provider = provider
    }

    /// 单轮文本生成：剥围栏与思考标签后返回
    public func text(
        system: String,
        user: String,
        config: LLMConfig = AIAssistGenerator.defaultConfig
    ) async throws -> String {
        let reply = try await provider.chat(
            messages: [
                EngineMessage(role: .system, text: system),
                EngineMessage(role: .user, text: user)
            ],
            tools: [],
            config: config
        )
        var text = SkillGenerator.stripReasoningBlocks(reply.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw AssistError.emptyOutput }
        return text
    }

    /// 编号列表生成：解析 "1. xxx" / "- xxx" 行为条目数组（空行剔除）
    public func list(
        system: String,
        user: String,
        config: LLMConfig = AIAssistGenerator.defaultConfig
    ) async throws -> [String] {
        let raw = try await text(system: system, user: user, config: config)
        return Self.parseListItems(raw)
    }

    /// 行级解析：剥编号/圆点前缀与首尾空白；跳过空行与纯编号行
    static func parseListItems(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: \.isNewline)
            .map { line in
                var text = line.trimmingCharacters(in: .whitespaces)
                // 剥 "1." / "1、" / "-" / "•" 前缀
                if let first = text.first, first.isNumber {
                    if let dot = text.firstIndex(where: { $0 == "." || $0 == "、" }),
                       dot < text.index(text.startIndex, offsetBy: 4) {
                        text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                    }
                } else if text.hasPrefix("-") || text.hasPrefix("•") {
                    text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
            .filter { !$0.isEmpty }
    }
}
