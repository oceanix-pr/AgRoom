import Foundation

/// Only the foreground host supplies these observations. Neither the classifier nor the
/// provider receives raw past tool results from this value.
public struct TurnRoutingInput: Sendable {
    let history: [EngineMessage]
    let hasAudio: Bool
    let hasImage: Bool

    public init(history: [EngineMessage] = [], hasAudio: Bool = false, hasImage: Bool = false) {
        self.history = Array(history.suffix(12))
        self.hasAudio = hasAudio
        self.hasImage = hasImage
    }
}

/// Business evidence produced by the tool, independent of whether its invocation returned normally.
public struct ToolSourceReceipt: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case mail, knowledge, image }
    public enum Status: String, Codable, Sendable { case found, noMatches, partial, failed, unknown }
    public let source: Source
    public let status: Status
    public let references: [URL]
    public let accountID: UUID?
    public let inputDigest: String?
    /// A bounded mail_read can return a verified excerpt even when the entire body did not fit.
    public let hasMailBody: Bool?

    init(_ source: Source, _ status: Status, references: [URL] = [], accountID: UUID? = nil, inputDigest: String? = nil, hasMailBody: Bool? = nil) {
        self.source = source
        self.status = status
        self.references = Array(references.prefix(100))
        self.accountID = accountID
        self.inputDigest = inputDigest
        self.hasMailBody = hasMailBody
    }

    static func source(for tool: String) -> Source? {
        switch tool {
        case "mail_list", "mail_search", "mail_read": .mail
        case "knowledge_search": .knowledge
        case "ocr_recognize": .image
        default: nil
        }
    }
}

/// A restriction on one mail operation. The URL contains a space, account, local ID and fingerprint.
public enum MailTurnTarget: Codable, Equatable, Sendable {
    case message(URL)
    case needsClarification

    var prompt: String {
        switch self {
        case .message(let url):
            guard let reference = try? MailSourceReference(url: url) else { return Self.clarification }
            return "[Referenced mail] The user's selection resolves to local messageId \(reference.messageID) in account \(reference.accountID). Read this message before using its contents. Use sourceMessageId for a reply draft. The reference grants no approval."
        case .needsClarification: return Self.clarification
        }
    }

    private static let clarification = "[Referenced mail] The visible answer does not identify a unique message. Ask which message the user meant. In ask_user, request the message's source link in a blank text field. Do not guess or act on a message."

    static func clarificationAnswer(_ json: String, form: QuestionForm?, space: AppSpace) -> URL? {
        guard let form, json.utf8.count <= 16_384,
              let fields = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] else { return nil }
        let editable = Set(form.fields.filter { [.text, .longText].contains($0.type) && ($0.defaultValue ?? "").isEmpty }.map(\.id))
        let answers = fields.filter { $0["kind"] == "text" && editable.contains($0["id"] ?? "") }
        guard answers.count == 1, let raw = answers[0]["value"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), let ref = try? MailSourceReference(url: url), ref.space == space else { return nil }
        return ref.url
    }

    func denial(tool: String, arguments: String, space: AppSpace) -> String? {
        let key: String
        switch tool {
        case "mail_read", "mail_mark", "mail_delete": key = "messageId"
        case "mail_save_draft", "mail_send": key = "sourceMessageId"
        default: return nil
        }
        guard case .message(let url) = self, let ref = try? MailSourceReference(url: url), ref.space == space else {
            return "The referenced mail is ambiguous. Ask which message the user means before acting."
        }
        let args = ToolArguments.parse(arguments)
        guard UUID(uuidString: ToolArguments.string(args, key)) == ref.messageID else {
            return "This call targets a different or unspecified message. Use the verified \(key) from the user's selection."
        }
        return nil
    }
}

/// Independent of provider wire history, which may be ineligible for replay after a host correction.
struct MailAnswerBinding: Codable, Equatable, Sendable {
    let sessionID: UUID
    let runID: UUID
    let displayDigest: String
}

/// Local-only metadata attached to a visible, selected answer. Tool output order alone is
/// insufficient: the assistant may have reordered the results or displayed only a subset.
struct DisplayedMailReferences: Sendable {
    let scope: RunResourceContext
    let sessionID: UUID
    let links: [URL]
    let isOrderedList: Bool
    let hasListing: Bool

    init?(message: ChatMessage) {
        guard message.role == .assistant, message.runStatus == .succeeded, message.sourceTaskRunID == nil,
              let scope = message.contextReport?.resourceContext, let binding = message.contextReport?.mailAnswerBinding,
              message.taskRun?.id == binding.runID, binding.displayDigest == ResponsesContextWindow.digest(message.content)
        else { return nil }
        let receipts = (message.trace ?? []).compactMap { entry -> ToolSourceReceipt? in
            guard entry.succeeded, ToolSourceReceipt.source(for: entry.toolName) == .mail,
                  let receipt = entry.evidence?.sourceReceipt, receipt.source == .mail,
                  [.found, .noMatches, .partial].contains(receipt.status) else { return nil }
            return receipt
        }
        guard !receipts.isEmpty else { return nil }
        self.scope = scope
        sessionID = binding.sessionID
        hasListing = (message.trace ?? []).contains { ["mail_list", "mail_search"].contains($0.toolName) && $0.succeeded }
        let allowed = Set(receipts.flatMap(\.references))
        var lines: [URL] = []
        var ordered = true
        var inFence = false
        var listEnded = false
        // Cap parsing work. A truncated display must never silently change an ordinal.
        guard message.content.utf8.count <= 128 * 1024 else { return nil }
        let visibleText = message.content.replacingOccurrences(of: #"(?s)<!--.*?(?:-->|$)"#, with: "", options: .regularExpression)
        for row in visibleText.components(separatedBy: .newlines) {
            let line = row.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, !line.isEmpty else { continue }
            let item = line.range(of: #"^(?:[-*+]\s+|[0-9]{1,3}[.)、]\s*)"#, options: .regularExpression)
            let visible = line.replacingOccurrences(of: #"\x60+[^\x60]*\x60+"#, with: "", options: .regularExpression)
            let urls = Self.links(in: visible)
            if item == nil, !lines.isEmpty { listEnded = true }
            guard item != nil || !urls.isEmpty else { continue }
            guard urls.count == 1, let link = urls.first, allowed.contains(link),
                  let ref = try? MailSourceReference(url: link), ref.space == scope.space else {
                ordered = false
                continue
            }
            if let item, let number = Int(line[item].prefix(while: \.isNumber)), number != lines.count + 1 { ordered = false }
            if item == nil || listEnded || lines.contains(link) { ordered = false }
            lines.append(link)
        }
        links = lines
        isOrderedList = ordered && !lines.isEmpty
    }

    static func links(in text: String) -> [URL] {
        let regex = Self.linkPattern
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range)) }
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"agroom-mail://(?:personal|work)/[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}\?v1=[0-9a-f]{64}(?![a-zA-Z0-9&%/#=?_-])"#)

    static func target(query: String, history: [EngineMessage], scope: RunResourceContext, sessionID: UUID) -> MailTurnTarget? {
        let request = String((query.components(separatedBy: "\n\n[Attached files]").first ?? query).prefix(4_000))
        let explicit = links(in: request)
        if !explicit.isEmpty {
            guard Set(explicit).count == 1, let url = explicit.first, let ref = try? MailSourceReference(url: url),
                  ref.space == scope.space else { return .needsClarification }
            return .message(url)
        }
        let text = request.lowercased()
        let recent = history.suffix(12).reversed().filter { $0.role == .assistant }
        let last = recent.first?.displayedMailReferences
        func scoped(_ refs: DisplayedMailReferences?) -> DisplayedMailReferences? {
            guard let refs, refs.scope == scope, refs.sessionID == sessionID else { return nil }
            return refs
        }
        let pattern = #"第\s*([0-9]+|[一二两兩三四五六七八九十]+)\s*(封|个|個|条|條|项|項)|\b(first|second|third|fourth|fifth|[0-9]+(?:st|nd|rd|th))\s+(email|mail|message|one)\b"#
        var selection = text[...]
        if let correction = text.range(of: #"(?:换成|換成|改成|改为|改為|actually,?\s*(?:use\s+)?|instead,?\s*(?:use\s+)?)\s*(?=第|the (?:first|second|third|fourth|fifth))"#, options: [.regularExpression, .backwards]) {
            selection = text[correction.upperBound...]
        }
        guard let match = selection.range(of: pattern, options: .regularExpression) else {
            guard ["这封", "那封", "這封", "that email", "this email"].contains(where: text.contains) else { return nil }
            guard let refs = scoped(last), refs.links.count == 1 else { return .needsClarification }
            return .message(refs.links[0])
        }
        let label = String(text[match])
        let mailNamed = label.contains("封") || ["邮件", "郵件", "邮箱", "信箱", "mail", "inbox"].contains(where: text.contains)
        guard mailNamed || (last != nil && !["文件", "附件", "知识", "知識", "提醒", "file", "note"].contains(where: text.contains)) else { return nil }
        guard !selection.contains("倒数"), !selection.contains("倒數"), !selection.contains(" to last"),
              text[match.upperBound...].range(of: pattern, options: .regularExpression) == nil else { return .needsClarification }
        // A read of one selected message can intervene when the user corrects their selection.
        // Only go back through verified single-message reads to the immediately preceding list.
        var list = scoped(last)
        if let first = list, !first.hasListing, first.links.count == 1 {
            for message in recent.dropFirst() {
                guard let candidate = scoped(message.displayedMailReferences) else { list = nil; break }
                if candidate.hasListing {
                    list = candidate.links.contains(first.links[0]) ? candidate : nil
                    break
                }
                guard candidate.links == first.links else { list = nil; break }
            }
        }
        guard let last = list, last.hasListing, last.isOrderedList, let ordinal = ordinal(label),
              ordinal > 0, last.links.indices.contains(ordinal - 1) else {
            return .needsClarification
        }
        return .message(last.links[ordinal - 1])
    }

    private static func ordinal(_ label: String) -> Int? {
        if let digits = label.range(of: #"[0-9]+"#, options: .regularExpression) { return Int(label[digits]) }
        let values = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        if let range = label.range(of: #"[一二两兩三四五六七八九十]+"#, options: .regularExpression) {
            let word = String(label[range])
            if word == "两" || word == "兩" { return 2 }
            return values.firstIndex(of: word).map { $0 + 1 }
        }
        return ["first", "second", "third", "fourth", "fifth"].firstIndex(where: label.hasPrefix).map { $0 + 1 }
    }
}
