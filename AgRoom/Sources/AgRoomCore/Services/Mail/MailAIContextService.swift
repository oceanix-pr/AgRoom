import Foundation

// MARK: - Mail AI Context Service

/// 按**固定邮件 ID** 准备 AI 所需的原邮件上下文。
///
/// 存在理由：AI 回复必须读取被绑定的那封原邮件，而不是界面当前选中的邮件。
/// 本服务只认邮件本地 ID（连同其所属空间的 `MailService`），因此主窗口切换选中项、
/// 邮箱列表刷新都不会改变读取目标。
///
/// 正文来源优先级：本地已就绪缓存 → 服务器按需拉取 → HTML 提取可读文本。
/// 读取失败如实抛出（界面提供重试），**不会**用摘要冒充完整原文。
public struct MailAIContextService: Sendable {
    /// 原邮件正文进入提示词的字符预算（超出即裁剪并提示读取范围）。
    public static let defaultBodyCharacterBudget = 6_000
    /// 「包含相关往来」时的最大封数与单封字符预算。
    public static let defaultThreadCount = 4
    public static let defaultThreadBodyBudget = 1_000

    private let mail: MailService
    private let sync: MailSyncService?

    public init(mail: MailService, sync: MailSyncService?) {
        self.mail = mail
        self.sync = sync
    }

    /// 读取并整理一封原邮件；`includeThread` 时附带同线程的少量往来。
    public func prepare(
        messageId: UUID,
        includeThread: Bool = false,
        bodyBudget: Int = MailAIContextService.defaultBodyCharacterBudget
    ) async throws -> MailAIOriginal {
        guard let message = try await mail.message(id: messageId) else {
            throw MailSyncError.messageNotFound
        }

        let text = try await readableText(messageId: messageId, message: message)
        let trimmed = Self.truncate(text, budget: bodyBudget)
        let attachments = (try? await mail.attachments(messageId: messageId)) ?? []

        var thread: [MailAIBrief] = []
        if includeThread {
            let related = (try? await mail.threadMessages(
                accountId: message.accountId,
                messageId: messageId,
                limit: Self.defaultThreadCount
            )) ?? []
            for item in related {
                let storedBody = try? await mail.body(messageId: item.id)
                var body = storedBody?.textBody
                if body == nil { body = Self.htmlToText(storedBody?.htmlBody) }
                guard let body, !body.isEmpty else { continue }
                thread.append(
                    MailAIBrief(
                        from: item.displayFrom,
                        subject: item.displaySubject,
                        date: item.date,
                        body: Self.truncate(body, budget: Self.defaultThreadBodyBudget).text
                    )
                )
            }
        }

        return MailAIOriginal(
            messageId: message.messageId,
            subject: message.displaySubject,
            from: MailAddress(name: message.fromName, address: message.fromAddress).display,
            to: message.to.map(\.display),
            date: message.date,
            body: trimmed.text,
            isTruncated: trimmed.isTruncated,
            attachments: attachments.map { MailAIAttachment(name: $0.filename, mimeType: $0.mimeType) },
            thread: thread
        )
    }

    /// 可读正文：本地缓存优先，其次按需拉取，最后从 HTML 提取。
    private func readableText(messageId: UUID, message: MailMessage) async throws -> String {
        var body = try? await mail.body(messageId: messageId)
        let needsFetch = message.bodyState != .ready
            || body == nil
            || (body?.textBody == nil && body?.htmlBody == nil)
        if needsFetch, let sync {
            body = try await sync.loadBody(messageId: messageId)
        }
        if let text = body?.textBody?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let html = body?.htmlBody, let extracted = Self.htmlToText(html) {
            return extracted
        }
        throw MailProtocolError.invalidResponse("The message has no readable text body.")
    }

    // MARK: - Helpers

    /// 按字符预算裁剪（保留开头），并报告是否发生裁剪。
    static func truncate(_ text: String, budget: Int) -> (text: String, isTruncated: Bool) {
        guard budget > 0, text.count > budget else { return (text, false) }
        return (String(text.prefix(budget)), true)
    }

    /// HTML → 可读文本：保留段落、列表项与表格单元格的关键边界，去掉标签与脚本。
    ///
    /// 只做「够用」的转换：目标是给模型一段可理解的纯文本，不是精确渲染。因此对
    /// `p/div/br/li/tr` 一类结构标签插入换行，列表项加 `- ` 前缀，其余标签直接剥离。
    static func htmlToText(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var text = html

        // 去掉不参与阅读的部分（脚本 / 样式 / 注释）
        for pattern in ["(?is)<script.*?</script>", "(?is)<style.*?</style>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // 结构标签 → 换行
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</(p|div|tr|h[1-6]|blockquote)>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<li[^>]*>", with: "- ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</li>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</t[dh]>", with: "\t", options: .regularExpression)
        // 其余标签剥离
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
        text = Self.decodeEntities(text)

        // 折叠空白：逐行去尾、压缩连续空行
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var collapsed: [String] = []
        var previousBlank = false
        for line in lines {
            if line.isEmpty {
                if previousBlank { continue }
                previousBlank = true
            } else {
                previousBlank = false
            }
            collapsed.append(line)
        }
        let result = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Decode character references once; escaped text must not become markup.
    private static func decodeEntities(_ text: String) -> String {
        MailFoundationAdapter.decodeHTMLTextEntities(text)
    }
}
