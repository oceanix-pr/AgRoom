import Foundation

// MARK: - Question Form Models

/// 结构化提问的字段类型（ask_user 工具声明 → GUI 控件映射）
public enum QuestionFieldType: String, Sendable, Equatable, Codable {
    /// 单选（按钮/单选组/下拉，样式见 QuestionFieldStyle）
    case singleChoice = "single_choice"
    /// 复选
    case multiChoice = "multi_choice"
    /// 单行文本
    case text
    /// 多行文本
    case longText = "long_text"
    /// 日期（往返输出 ISO8601 字符串）
    case date
    /// 日期时间
    case dateTime = "date_time"
}

/// 单选字段的呈现样式（仅 singleChoice 生效；缺省按选项数自动选择）
public enum QuestionFieldStyle: String, Sendable, Equatable, Codable {
    /// 按钮横排（选项 ≤4 时的默认形态，一键作答）
    case buttons
    /// 单选组（radio group）
    case radio
    /// 下拉框（选项多时的默认形态）
    case dropdown
}

/// 表单字段：label/option 一律按纯文本渲染（不解析 Markdown，防注入）
public struct QuestionField: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let type: QuestionFieldType
    public let style: QuestionFieldStyle?
    /// singleChoice/multiChoice 的选项
    public let options: [String]
    /// 默认值（文本类 = 文本；选择类 = 选项值；日期 = ISO8601）
    public let defaultValue: String?
    /// multiChoice 默认选中项
    public let defaultValues: [String]?
    public let required: Bool
    public let placeholder: String?
    /// multiChoice 最少/最多选择数
    public let minSelect: Int?
    public let maxSelect: Int?

    public init(
        id: String,
        label: String,
        type: QuestionFieldType,
        style: QuestionFieldStyle? = nil,
        options: [String] = [],
        defaultValue: String? = nil,
        defaultValues: [String]? = nil,
        required: Bool = false,
        placeholder: String? = nil,
        minSelect: Int? = nil,
        maxSelect: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.style = style
        self.options = options
        self.defaultValue = defaultValue
        self.defaultValues = defaultValues
        self.required = required
        self.placeholder = placeholder
        self.minSelect = minSelect
        self.maxSelect = maxSelect
    }
}

/// 结构化提问表单（模型声明 → 引擎挂起 → GUI 渲染 → 作答恢复）
public struct QuestionForm: Sendable, Equatable {
    public let title: String
    public let prompt: String
    public let fields: [QuestionField]

    public init(title: String, prompt: String, fields: [QuestionField]) {
        self.title = title
        self.prompt = prompt
        self.fields = fields
    }

    /// 宿主侧硬校验（防表单滥用）：字段 ≤6、选项 ≤10、文本长度钳制。
    /// 超限字段直接丢弃；无有效字段时返回 nil（调用方降级为普通文本提问）
    public func sanitized() -> QuestionForm? {
        var kept: [QuestionField] = []
        for field in fields.prefix(Self.maxFields) {
            // Reject oversized labels rather than silently changing the meaning of an answer.
            guard field.options.allSatisfy({ $0.count <= Self.optionLimit }) else { return nil }
            let options = Array(field.options
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(Self.maxOptions))
            let typeNeedsOptions = field.type == .singleChoice || field.type == .multiChoice
            if typeNeedsOptions, options.count < 2 { continue }
            guard Set(options).count == options.count else { return nil }
            kept.append(QuestionField(
                id: String(field.id.prefix(40)),
                label: String(field.label.prefix(120)),
                type: field.type,
                style: field.style,
                options: options,
                defaultValue: field.defaultValue.map { String($0.prefix(500)) },
                defaultValues: field.defaultValues.map { values in
                    Array(values.filter { options.contains($0) }.prefix(Self.maxOptions))
                },
                required: field.required,
                placeholder: field.placeholder.map { String($0.prefix(80)) },
                minSelect: field.minSelect.map { max(0, min($0, options.count)) },
                maxSelect: field.maxSelect.map { max(1, min($0, options.count)) }
            ))
        }
        guard !kept.isEmpty else { return nil }
        return QuestionForm(
            title: String(title.prefix(80)),
            prompt: String(prompt.prefix(1_000)),
            fields: kept
        )
    }

    /// 字段呈现样式：显式声明优先，否则按选项数自动（≤4 按钮 / >4 下拉）
    public func resolvedStyle(for field: QuestionField) -> QuestionFieldStyle {
        if let style = field.style { return style }
        return field.options.count <= 4 ? .buttons : .dropdown
    }

    static let maxFields = 6
    static let maxOptions = 10
    static let optionLimit = 500
}

/// 表单作答：字段 id → 值（文本 / 选项集合 / ISO8601 日期字符串）
public struct QuestionFormAnswer: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case text(String)
        case choices([String])
        /// ISO8601 字符串（避免本地化格式歧义）
        case date(String)
    }

    public let values: [String: Value]

    public init(values: [String: Value]) {
        self.values = values
    }

    /// 模型可读的作答文本（逐字段「label: 值」；也是工具结果回灌格式）
    public func readableAnswer(for form: QuestionForm) -> String {
        form.fields.compactMap { field -> String? in
            guard let value = values[field.id] else { return nil }
            let rendered: String
            switch value {
            case .text(let text):
                rendered = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .choices(let choices):
                rendered = choices.joined(separator: ", ")
            case .date(let iso):
                rendered = iso
            }
            guard !rendered.isEmpty else { return nil }
            return "\(field.label): \(rendered)"
        }
        .joined(separator: "\n")
    }

    /// JSON 编码（经 resume(.answered) 回灌引擎）
    public func encodedJSON() -> String {
        struct Wire: Codable {
            let id: String
            let value: String
            let kind: String
        }
        let wires = values.map { key, value -> Wire in
            switch value {
            case .text(let text): return Wire(id: key, value: text, kind: "text")
            case .choices(let choices): return Wire(id: key, value: choices.joined(separator: "\u{1F}"), kind: "choices")
            case .date(let iso): return Wire(id: key, value: iso, kind: "date")
            }
        }
        .sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(wires),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

// MARK: - Codable（容忍模型缺字段/多余键，避免 JSON 严格解码失败）

extension QuestionField: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, label, type, style, options
        case defaultValue, defaultValues, required, placeholder, minSelect, maxSelect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        type = (try? c.decode(QuestionFieldType.self, forKey: .type)) ?? .text
        style = try? c.decodeIfPresent(QuestionFieldStyle.self, forKey: .style)
        options = (try? c.decode([String].self, forKey: .options)) ?? []
        defaultValue = try? c.decodeIfPresent(String.self, forKey: .defaultValue)
        defaultValues = try? c.decodeIfPresent([String].self, forKey: .defaultValues)
        required = (try? c.decode(Bool.self, forKey: .required)) ?? false
        placeholder = try? c.decodeIfPresent(String.self, forKey: .placeholder)
        minSelect = try? c.decodeIfPresent(Int.self, forKey: .minSelect)
        maxSelect = try? c.decodeIfPresent(Int.self, forKey: .maxSelect)
    }
}

extension QuestionForm: Codable {
    private enum CodingKeys: String, CodingKey {
        case title, prompt, fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        fields = (try? c.decode([QuestionField].self, forKey: .fields)) ?? []
    }
}

// MARK: - Ask User Tool

/// 结构化提问工具：模型声明表单（字段类型即 GUI 控件），引擎挂起等待用户作答，
/// 答案经 resume(.answered) 作为工具结果回灌，工具循环继续。
/// requiresConfirmation = false（本工具就是提问，无需再确认）
public struct AskUserTool: DispatcherTool {

    public init() {}

    public let definition = ToolDefinition(
        name: "ask_user",
        description: "Ask the user a structured question when critical information is missing. "
            + "Declare 1-4 fields: single_choice (few options -> style \"buttons\"; many -> \"dropdown\"), "
            + "multi_choice, text, long_text, date, date_time. "
            + "Use it instead of guessing; at most ONE ask_user call per turn.",
        parametersSchemaJSON: """
        {"type":"object","properties":{
          "title":{"type":"string","description":"Short card title"},
          "prompt":{"type":"string","description":"The question shown to the user, plain text"},
          "fields":{"type":"array","maxItems":6,"items":{"type":"object","properties":{
            "id":{"type":"string"},
            "label":{"type":"string"},
            "type":{"type":"string","enum":["single_choice","multi_choice","text","long_text","date","date_time"]},
            "style":{"type":"string","enum":["buttons","radio","dropdown"]},
            "options":{"type":"array","maxItems":10,"items":{"type":"string","maxLength":500}},
            "required":{"type":"boolean"},
            "placeholder":{"type":"string"},
            "minSelect":{"type":"integer"},
            "maxSelect":{"type":"integer"}
          },"required":["id","label","type"]}}
        },"required":["prompt","fields"]}
        """
    )
    public let requiresConfirmation = false
    /// 只读（仅挂起等用户作答）：不入副作用日志，可安全重试
    public let sideEffectClass = ToolSideEffectClass.readOnly

    public func execute(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let raw = try? JSONDecoder().decode(QuestionForm.self, from: data),
              let form = raw.sanitized() else {
            throw LLMError.configurationError(
                reason: "ask_user requires a valid form: prompt plus 1-6 fields "
                    + "(choice fields need 2-10 options, each at most 500 characters; shorten oversized options and retry)"
            )
        }
        throw ToolSuspensionError(suspension: ToolSuspension(
            request: ToolSuspensionRequest(
                toolName: "ask_user",
                argumentsDisplay: form.prompt,
                form: form
            ),
            resume: { input in
                switch input {
                case .answered(let json):
                    return ToolSuspension.ResumeResult(text: "The user answered the form:\n\(json)")
                case .cancelled:
                    return ToolSuspension.ResumeResult(
                        text: "The user dismissed the question without answering. "
                            + "Do not repeat the same form; use sensible defaults, "
                            + "or clearly state what you could not determine."
                    )
                case .approved, .confirmed:
                    return ToolSuspension.ResumeResult(text: "Unexpected input for a question form; treat it as unanswered.")
                case .autoApproved, .autoRejected:
                    return ToolSuspension.ResumeResult(
                        text: "Unexpected automated approval for a question form; treat it as unanswered."
                    )
                }
            }
        ))
    }
}
