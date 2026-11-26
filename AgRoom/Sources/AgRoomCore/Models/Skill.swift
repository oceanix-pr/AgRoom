import Foundation

// MARK: - Skill Tool Declaration

/// `allowed-tools` 的四种状态必须区分，不能把“未声明”和“显式空集合”都当成空串：
/// - undeclared：继承父级工具面；
/// - explicitEmpty：只保留技能导航工具（skill_load / skill_file）；
/// - valid：与当前工具面求交集；
/// - invalid：声明无法解析，按空集合处理并报错，绝不恢复全部工具。
public enum SkillToolDeclaration: Sendable, Equatable {
    case undeclared
    case explicitEmpty
    case valid(Set<String>)
    case invalid(String)

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self = .undeclared
            return
        }
        if trimmed == "[]" {
            self = .explicitEmpty
            return
        }
        // 允许 YAML 常见的方括号数组与引号，但内部仍必须是逗号/空白分隔的工具名。
        var normalized = trimmed
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        let names = normalized
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { token -> String in
                var value = String(token).trimmingCharacters(in: .whitespaces)
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\""))
                    || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            self = .explicitEmpty
            return
        }
        let pattern = "^[a-z0-9_][a-z0-9_-]*$"
        if let bad = names.first(where: {
            $0.range(of: pattern, options: .regularExpression) == nil
        }) {
            self = .invalid("invalid tool name '\(bad)'")
            return
        }
        self = .valid(Set(names))
    }

    public var names: Set<String>? {
        switch self {
        case .undeclared: return nil
        case .explicitEmpty: return []
        case .valid(let names): return names
        case .invalid: return []
        }
    }

    public var errorDescription: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Skill（Anthropic Agent Skills 标准）

/// 技能模型，符合 Anthropic Agent Skills 标准：
/// - name：小写字母/数字/连字符，最长 64 字符（对应 SKILL.md frontmatter 的 name）
/// - description：说明技能做什么、何时使用，最长 1024 字符
/// - content：SKILL.md 正文（Markdown 指令），调度 Agent 按渐进式披露加载
/// - allowedTools：Anthropic 标准的 allowed-tools 字段（可选）
public struct Skill: Codable, Identifiable, Equatable, Sendable {
    public enum Constants {
        public static let nameLimit = 64
        public static let descriptionLimit = 1024
    }
    public let id: UUID
    public var name: String
    /// 显示别名（frontmatter alias 字段）：不限语言（可中文），供列表/搜索展示；
    /// name 仍受 Anthropic slug 标准约束
    public var alias: String
    public var description: String
    /// SKILL.md 正文：给模型的 Markdown 指令
    public var content: String
    public var allowedTools: String
    /// 参数化变量（frontmatter variables 字段，逗号分隔）：正文中以 {{变量名}} 占位，
    /// skill_load 后由调度 Agent 按当前对话上下文填空，技能保持通用可复用
    public var variables: [String]
    /// 技能工作区（frontmatter workspace-folder 字段）：
    /// 指定受管文件区内的文件夹路径时，技能加载后 files_* 写类工具只能操作该文件夹内；
    /// nil = 未指定，写操作落默认工作区（work → workspace / personal → privatespace）
    public var workspaceFolder: String?
    /// 可选产物契约（frontmatter outputs 字段，逗号分隔的技能包内相对路径）：
    /// 声明本轮运行后必须存在的产物文件。引擎据此判定「已完成 / 未完成」——
    /// 只依据实际执行回执与文件校验，不从模型自然语言里猜路径。
    public var outputs: [String]
    /// 产物必需字段（frontmatter output-required-fields 字段，逗号分隔）：
    /// 对 `.json` 产物进一步校验顶层必需字段（参数提取类技能的参数表契约）。
    public var outputRequiredFields: [String]
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        alias: String = "",
        description: String = "",
        content: String = "",
        allowedTools: String = "",
        variables: [String] = [],
        workspaceFolder: String? = nil,
        outputs: [String] = [],
        outputRequiredFields: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.alias = alias
        self.description = description
        self.content = content
        self.allowedTools = allowedTools
        self.variables = variables
        self.workspaceFolder = workspaceFolder
        self.outputs = outputs
        self.outputRequiredFields = outputRequiredFields
        self.isEnabled = isEnabled
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Display

    /// 外显名称：优先 alias（不限语言、人类可读，如中文），无 alias 时回退 name（slug）
    public var displayName: String {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAlias.isEmpty ? name : trimmedAlias
    }

    // MARK: - Validation

    /// Anthropic 标准：小写字母/数字/连字符，1-64 字符
    public var isNameValid: Bool {
        !name.isEmpty && name.count <= Constants.nameLimit
            && name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    public var isDescriptionValid: Bool {
        description.count <= Constants.descriptionLimit
    }

    public var isValid: Bool { isNameValid && isDescriptionValid }

    /// 将任意显示名转为符合标准的 slug
    public static func slugify(_ raw: String) -> String {
        let mapped = raw
            .lowercased()
            .map { char -> Character in
                if char.isASCII, char.isLetter || char.isNumber { return char }
                return "-"
            }
        let collapsed = String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
        return String(collapsed.prefix(Constants.nameLimit))
    }

    // MARK: - Legacy Migration

    enum CodingKeys: String, CodingKey {
        case id, name, alias, description, content, allowedTools, variables, workspaceFolder
        case outputs, outputRequiredFields
        case isEnabled, createdAt, updatedAt
        // 旧版字段（type/config），仅用于读取迁移
        case type, config
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        alias = try container.decodeIfPresent(String.self, forKey: .alias) ?? ""
        description = try container.decode(String.self, forKey: .description)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        allowedTools = try container.decodeIfPresent(String.self, forKey: .allowedTools) ?? ""
        variables = try container.decodeIfPresent([String].self, forKey: .variables) ?? []
        // 旧数据无此字段解码为 nil（未指定工作区，走默认工作区）
        workspaceFolder = try container.decodeIfPresent(String.self, forKey: .workspaceFolder)
        // 旧数据无产物契约：空集合 = 不声明，不参与完成判定
        outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? []
        outputRequiredFields = try container.decodeIfPresent([String].self, forKey: .outputRequiredFields) ?? []

        if let content = try container.decodeIfPresent(String.self, forKey: .content) {
            self.content = content
            return
        }

        // 旧版数据迁移：promptInjection 的 config["prompt"] → content；
        // apiCall 的 HTTP 配置转写为自然语言指令，保证旧技能不静默丢失
        let legacyType = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        let config = try container.decodeIfPresent([String: String].self, forKey: .config) ?? [:]
        if legacyType == "apiCall" {
            let method = (config["method"] ?? "GET").uppercased()
            let url = config["url"] ?? ""
            var text = "Call the external API with HTTP \(method) \(url)."
            if let body = config["body"], !body.isEmpty {
                text += "\nRequest body template:\n\(body)"
            }
            content = text
        } else {
            content = config["prompt"] ?? ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(alias, forKey: .alias)
        try container.encode(description, forKey: .description)
        try container.encode(content, forKey: .content)
        try container.encode(allowedTools, forKey: .allowedTools)
        try container.encode(variables, forKey: .variables)
        try container.encodeIfPresent(workspaceFolder, forKey: .workspaceFolder)
        try container.encode(outputs, forKey: .outputs)
        try container.encode(outputRequiredFields, forKey: .outputRequiredFields)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - SkillDocument（SKILL.md 编解码）

/// SKILL.md 文档编解码：YAML frontmatter + Markdown 正文
/// 兼容 Anthropic Agent Skills 文件格式，可导入/导出互通
public enum SkillDocument {
    public enum DocumentError: Error, Equatable, LocalizedError {
        case missingFrontmatter
        case missingName

        public var errorDescription: String? {
            switch self {
            case .missingFrontmatter: return "SKILL.md must start with YAML frontmatter (--- ... ---)"
            case .missingName: return "SKILL.md frontmatter must contain a 'name' field"
            }
        }
    }

    /// 解析 SKILL.md 文本为技能（仅取标准字段，其余字段忽略）
    public static func parse(_ text: String) throws -> Skill {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("---") else { throw DocumentError.missingFrontmatter }
        let afterFirst = normalized.dropFirst(3)
        guard let close = afterFirst.range(of: "\n---") else { throw DocumentError.missingFrontmatter }

        var fields: [String: String] = [:]
        for line in afterFirst[..<close.lowerBound]
            .split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard let name = fields["name"], !name.isEmpty else { throw DocumentError.missingName }

        let body = afterFirst[close.upperBound...]
            .drop(while: \.isNewline)
        // variables：逗号分隔的占位变量清单（如 "department, meeting_date"）
        let variables = (fields["variables"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // workspace-folder：技能指定工作区（受管文件区内文件夹路径，可省略）
        let workspaceFolder = fields["workspace-folder"]?
            .trimmingCharacters(in: .whitespaces)
        // allowed-tools 的“出现过但为空”与“未出现”语义不同：前者是显式空集合，
        // 后者继承父级工具面。用 "[]" 作为显式空的稳定标记。
        let allowedTools: String
        if let raw = fields["allowed-tools"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            allowedTools = trimmed.isEmpty ? "[]" : trimmed
        } else {
            allowedTools = ""
        }
        // outputs / output-required-fields：逗号分隔清单（产物契约，可选）
        let outputs = Self.commaList(fields["outputs"])
        let outputRequiredFields = Self.commaList(fields["output-required-fields"])
        return Skill(
            name: name,
            alias: fields["alias"] ?? "",
            description: fields["description"] ?? "",
            content: String(body),
            allowedTools: allowedTools,
            variables: variables,
            workspaceFolder: (workspaceFolder?.isEmpty == true) ? nil : workspaceFolder,
            outputs: outputs,
            outputRequiredFields: outputRequiredFields
        )
    }

    /// 逗号分隔清单解析（空白项剔除）
    private static func commaList(_ raw: String?) -> [String] {
        (raw ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 序列化为 SKILL.md 文本（可保存为文件与其他工具互通）
    public static func render(_ skill: Skill) -> String {
        var lines = ["---"]
        lines.append("name: \(skill.name)")
        if !skill.alias.isEmpty {
            lines.append("alias: \(yamlQuote(skill.alias))")
        }
        if !skill.description.isEmpty {
            lines.append("description: \(yamlQuote(skill.description))")
        }
        if skill.allowedTools == "[]" {
            lines.append("allowed-tools: []")
        } else if !skill.allowedTools.isEmpty {
            lines.append("allowed-tools: \(yamlQuote(skill.allowedTools))")
        }
        if !skill.variables.isEmpty {
            lines.append("variables: \(yamlQuote(skill.variables.joined(separator: ", ")))")
        }
        if let folder = skill.workspaceFolder, !folder.isEmpty {
            lines.append("workspace-folder: \(yamlQuote(folder))")
        }
        if !skill.outputs.isEmpty {
            lines.append("outputs: \(yamlQuote(skill.outputs.joined(separator: ", ")))")
        }
        if !skill.outputRequiredFields.isEmpty {
            lines.append("output-required-fields: \(yamlQuote(skill.outputRequiredFields.joined(separator: ", ")))")
        }
        lines.append("---")
        lines.append("")
        lines.append(skill.content)
        return lines.joined(separator: "\n")
    }

    private static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
