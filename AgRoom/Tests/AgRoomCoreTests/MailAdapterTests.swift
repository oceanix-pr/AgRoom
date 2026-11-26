import Testing
import Foundation
import MailFoundation
@testable import AgRoomCore
@testable import AgRoomUI

// MARK: - Mail Adapter Level Tests

/// 适配器级回归：路径编码契约、错误分类、以及基于内存字节通道的协议回放。
///
/// 现有同步测试使用 `MailProtocolClient` mock，绕过了 MailFoundation 的自动编码，
/// 因此发现不了「已编码路径被二次编码」这类缺陷。这里的回放测试直接检查最终发出的
/// 命令字节，覆盖真实协议边界。
@Suite("Mail adapter path & diagnostics")
struct MailAdapterTests {
    @Test("Signature discovery follows the inbox namespace and fetches only the latest envelopes", .timeLimit(.minutes(1)))
    func signatureEnvelopeReplay() async throws {
        let transport = AsyncStreamTransport()
        for response in [
            "* OK ready\r\n",
            "A0001 OK LOGIN completed\r\n",
            "* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n",
            "* LIST () \".\" \"INBOX.Sent Messages\"\r\nA0003 OK LIST completed\r\n",
            "* 1000 EXISTS\r\nA0004 OK [READ-WRITE] SELECT completed\r\n",
            "* 1000 FETCH (UID 81000 ENVELOPE (NIL \"Signature draft\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\nA0005 OK FETCH completed\r\n"
        ] {
            await transport.yieldIncoming(Array(response.utf8))
        }
        let adapter = MailFoundationAdapter(host: "imap.example.test", port: 143, security: .none) { transport }
        try await adapter.connect()
        try await adapter.authenticate(username: "synthetic", password: "fixture")
        let folder = try #require(try await adapter.listFolders().first)
        #expect(folder.role == .sent)
        let summaries = try await adapter.recentSummaries(path: folder.path, messageCount: 1000, limit: 30)
        #expect(summaries.map(\.uid) == [81000] && summaries.first?.subject == "Signature draft")
        let headings = await transport.sentSnapshot().map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(headings.contains("FETCH 971:1000") && !headings.contains("BODY") && !headings.contains("STORE"))
        let signature = "你好\r\n-- \r\n研发团队 🪴"
        let header = "From: team@example.test\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
        let structure = "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" \(signature.utf8.count) 3)"
        await transport.yieldIncoming(Array("* 1000 FETCH (UID 81000 BODYSTRUCTURE \(structure))\r\nA0006 OK FETCH completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1000 FETCH (UID 81000 BODY[HEADER] {\(header.utf8.count)}\r\n\(header) BODY[1] {\(signature.utf8.count)}\r\n\(signature))\r\nA0007 OK FETCH completed\r\n".utf8))
        let body = try await adapter.fetchBody(path: folder.path, uid: 81000, maxBytes: 128 * 1024)
        let preview = try MailSignaturePreview(body: body)
        #expect((preview.text as NSString).substring(with: try #require(preview.suggestedRange)) == "研发团队 🪴")
        await adapter.disconnect()
    }

    @Test("Received CID images are indexed and downloadable with inline, absent, or attachment disposition", .timeLimit(.minutes(1)),
          arguments: ["inline", "cidOnly", "attachment"])
    func receivedInlineImageReplay(_ disposition: String) async throws {
        let transport = AsyncStreamTransport()
        let html = "<p>Announcement</p><img src='cid:logo@example.test'>"
        let header = "From: sender@example.test\r\nMessage-ID: <received@example.test>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/related; boundary=original\r\n\r\n"
        let bytes = Data([0, 1, 2, 3, 255]), encoded = bytes.base64EncodedString()
        let suffix = disposition == "cidOnly" ? "NIL" : "(\"\(disposition)\" (\"FILENAME\" \"logo.png\"))"
        let structure = "((\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" \(html.utf8.count) 1)(\"IMAGE\" \"PNG\" NIL \"<logo@example.test>\" NIL \"BASE64\" \(encoded.utf8.count) NIL \(suffix)) \"RELATED\")"
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 EXISTS\r\nA0003 OK [READ-WRITE] SELECT completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 FETCH (UID 42 BODYSTRUCTURE \(structure))\r\nA0004 OK FETCH completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 FETCH (UID 42 BODY[HEADER] {\(header.utf8.count)}\r\n\(header) BODY[1] {\(html.utf8.count)}\r\n\(html))\r\nA0005 OK FETCH completed\r\n".utf8))
        let adapter = MailFoundationAdapter(host: "imap.example.test", port: 143, security: .none) { transport }
        try await adapter.connect(); try await adapter.authenticate(username: "synthetic", password: "fixture")
        let body = try await adapter.fetchBody(path: "INBOX", uid: 42, maxBytes: 128 * 1024)
        let image = try #require(body.attachments.first)
        #expect(body.attachments.count == 1 && body.htmlBody?.contains("cid:logo@example.test") == true)
        #expect(image.partID == "2" && image.contentId == "<logo@example.test>" && image.mimeType == "image/png")
        #expect(image.filename == (disposition == "cidOnly" ? "attachment" : "logo.png"))
        #expect(image.isInline == (disposition != "attachment") && image.sizeBytes == encoded.utf8.count)
        #expect(body.rawMessage == nil)
        let bodyCommands = await transport.sentSnapshot().map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(bodyCommands.contains("BODY.PEEK[1]") && !bodyCommands.contains("BODY.PEEK[2]"))
        await transport.yieldIncoming(Array("* 1 FETCH (UID 42 BODYSTRUCTURE \(structure))\r\nA0006 OK FETCH completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 FETCH (UID 42 BODY[2]<0> {\(encoded.utf8.count)}\r\n\(encoded))\r\nA0007 OK FETCH completed\r\n".utf8))
        #expect(try await adapter.fetchAttachment(path: "INBOX", uid: 42, partID: "2", maxBytes: 1024) == bytes)
        let commands = await transport.sentSnapshot().map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(commands.contains("UID FETCH 42") && commands.contains("BODY.PEEK[2]<0.1025>"))
        await adapter.disconnect()
    }

    @Test("The bounded whole-message fallback retains CID images and their exact original", .timeLimit(.minutes(1)))
    func inlineOriginalFallbackReplay() async throws {
        let original = Data([
            "From: sender@example.test", "Message-ID: <fallback@example.test>", "MIME-Version: 1.0",
            "Content-Type: multipart/related; boundary=inline-original", "", "--inline-original",
            "Content-Type: text/html; charset=utf-8", "", "<img src='cid:logo@example.test'>",
            "--inline-original", "Content-Type: image/png", "Content-Disposition: inline; filename=logo.png",
            "Content-ID: <logo@example.test>", "Content-Transfer-Encoding: base64", "", "AAECAw==", "--inline-original--", ""
        ].joined(separator: "\r\n").utf8)
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 EXISTS\r\nA0003 OK [READ-WRITE] SELECT completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 FETCH (UID 42)\r\nA0004 OK FETCH completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 FETCH (UID 42 BODY[]<0> {\(original.count)}\r\n".utf8) + Array(original) + Array(")\r\nA0005 OK FETCH completed\r\n".utf8))
        let adapter = MailFoundationAdapter(host: "imap.example.test", port: 143, security: .none) { transport }
        try await adapter.connect(); try await adapter.authenticate(username: "synthetic", password: "fixture")
        let body = try await adapter.fetchBody(path: "INBOX", uid: 42, maxBytes: 4096)
        #expect(body.rawMessage == original && body.attachments.count == 1)
        let image = try #require(body.attachments.first)
        #expect(image.partID == "local:0" && image.isInline && image.contentId == "logo@example.test")
        #expect(try MailSmtpAdapter.localAttachment(try #require(body.rawMessage), index: 0, filename: image.filename, mimeType: image.mimeType) == Data([0, 1, 2, 3]))
        let commands = await transport.sentSnapshot().map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(commands.contains("BODY.PEEK[]<0.4097>"))
        await adapter.disconnect()
    }

    @Test("Header identity handles both CRLF and retained LF originals without scanning the body", arguments: ["\r\n", "\n"])
    func originalIdentityLineEndings(_ newline: String) throws {
        let data = Data(["From: synthetic@example.test", "Message-ID: <line-ending@example.test>", "Subject: Header identity", "",
                         "Message-ID: <body-impostor@example.test>"].joined(separator: newline).utf8)
        #expect(try MailFoundationAdapter.originalMessageID(data) == "<line-ending@example.test>")
    }
    @Test("Draft APPEND waits for continuation, preserves binary octets, encodes the mailbox once, and requires APPENDUID",
          arguments: ["saved", "rejected", "missingUID"])
    func draftAppendReplay(_ outcome: String) async throws {
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1 UIDPLUS\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        if outcome == "rejected" {
            await transport.yieldIncoming(Array("A0003 NO Draft storage denied\r\n".utf8))
        } else {
            await transport.yieldIncoming(Array("+ Send literal\r\n".utf8))
            await transport.yieldIncoming(Array((outcome == "saved" ? "A0003 OK [APPENDUID 41 42] saved\r\n" : "A0003 OK saved\r\n").utf8))
        }
        let adapter = MailFoundationAdapter(host: "imap.example.test", port: 143, security: .none) { transport }
        try await adapter.connect(); try await adapter.authenticate(username: "synthetic", password: "fixture")
        let bytes = Data([0, 255, 13, 10, 128]), path = ImapMailboxEncoding.encode("测试/草稿")
        if outcome == "saved" {
            #expect(try await adapter.appendDraft(path: path, data: bytes) == .init(uidValidity: 41, uid: 42))
        } else if outcome == "rejected" {
            await #expect(throws: MailServerDiagnostic.self) { try await adapter.appendDraft(path: path, data: bytes) }
        } else {
            await #expect(throws: MailServerDraftError.unresolved) { try await adapter.appendDraft(path: path, data: bytes) }
        }
        let sent = await transport.sentSnapshot()
        let header = "A0003 APPEND \"\(path)\" (\\Draft) {\(bytes.count)}\r\n"
        #expect(sent.contains(Array(header.utf8)))
        #expect(sent.contains(Array(bytes) + [13, 10]) == (outcome != "rejected"))
        await adapter.disconnect()
    }

    // MARK: - 路径编码契约

    @Test("落库原始 UTF-7 路径解码为 Unicode 提交给会话；ASCII 名不变")
    func sessionMailboxDecodesModifiedUTF7() {
        let raw = ImapMailboxEncoding.encode("测试/草稿")
        #expect(raw != "测试/草稿") // 确认该名字确实被编码
        #expect(MailFoundationAdapter.sessionMailbox(from: raw) == "测试/草稿")
        #expect(MailFoundationAdapter.sessionMailbox(from: "INBOX") == "INBOX")
        // 名称含 & / 空格 / 引号时同样可逆
        let tricky = ImapMailboxEncoding.encode("A & B \"C\"")
        #expect(MailFoundationAdapter.sessionMailbox(from: tricky) == "A & B \"C\"")
    }

    @Test("诊断用文件夹名取末段且已解码，不泄露完整原始路径")
    func displayFolderNameUsesLastComponent() {
        let raw = ImapMailboxEncoding.encode("工作/草稿")
        #expect(MailFoundationAdapter.displayFolderName(raw) == "草稿")
    }

    // MARK: - 错误分类

    @Test("服务器 NO/BAD → 服务器拒绝，保留状态与脱敏说明")
    func mapsServerRejection() {
        let diagnostic = MailFoundationAdapter.failure(
            SessionError.imapError(status: .no, text: "Mailbox does not exist"),
            stage: .folderStatus,
            folderPath: ImapMailboxEncoding.encode("已发送")
        ) as? MailServerDiagnostic
        #expect(diagnostic?.kind == .serverRejected)
        #expect(diagnostic?.status == "NO")
        #expect(diagnostic?.detail == "Mailbox does not exist")
        #expect(diagnostic?.stage == .folderStatus)
        #expect(diagnostic?.folder == "已发送")

        // BAD 与 NO 同属服务器拒绝
        let bad = MailFoundationAdapter.failure(
            SessionError.imapError(status: .bad, text: "Unknown command"),
            stage: .select,
            folderPath: nil
        ) as? MailServerDiagnostic
        #expect(bad?.kind == .serverRejected)
        #expect(bad?.status == "BAD")
    }

    @Test("OK 但无可解析数据 → 归为响应不可解读，不描述成服务器拒绝")
    func mapsMalformedResponse() {
        let diagnostic = MailFoundationAdapter.failure(
            SessionError.imapError(status: .ok, text: "unparsable payload"),
            stage: .fetchSummaries,
            folderPath: nil
        ) as? MailServerDiagnostic
        #expect(diagnostic?.kind == .malformedResponse)
        #expect(diagnostic?.status == "OK")
    }

    @Test("超时 / 断链 / 状态错误保留各自语义")
    func mapsRemainingKinds() {
        func kind(_ error: Error, stage: MailOperationStage = .select) -> MailFailureKind? {
            (MailFoundationAdapter.failure(error, stage: stage, folderPath: nil) as? MailServerDiagnostic)?.kind
        }
        #expect(kind(SessionError.timeout) == .timedOut)
        #expect(kind(SessionError.connectionClosed(message: "closed")) == .connectionClosed)
        #expect(kind(SessionError.invalidImapState(expected: .authenticated, actual: .connected)) == .invalidState)
        #expect(kind(URLError(.timedOut)) == .transport)
    }

    @Test("取消继续上抛；项目自有错误不被重复包装")
    func preservesCancellationAndOwnErrors() {
        #expect(MailFoundationAdapter.failure(CancellationError(), stage: .fetchBody, folderPath: nil) is CancellationError)
        #expect(MailFoundationAdapter.failure(MailProtocolError.timedOut("folderStatus"), stage: .folderStatus, folderPath: nil) is MailProtocolError)
        let existing = MailServerDiagnostic(stage: .move, status: "NO", detail: "x", kind: .serverRejected, folder: nil)
        #expect(MailFoundationAdapter.failure(existing, stage: .select, folderPath: nil) as? MailServerDiagnostic == existing)
    }

    @Test("服务器说明脱敏：折叠空白并限长")
    func sanitizesServerText() {
        let noisy = "line one\r\n   line two\t" + String(repeating: "x", count: 500)
        let detail = MailFoundationAdapter.failure(
            SessionError.imapError(status: .bad, text: noisy),
            stage: .search,
            folderPath: nil
        )
        let text = (detail as? MailServerDiagnostic)?.detail ?? ""
        #expect(!text.contains("\n"))
        #expect(!text.contains("\r"))
        #expect(text.count <= 201)
    }

    // MARK: - 协议回放（内存字节通道）

    @Test("Raw export requests a bounded PEEK section and preserves its bytes")
    func rawMessageReplay() async throws {
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 1 EXISTS\r\nA0003 OK [READ-WRITE] SELECT completed\r\n".utf8))
        let bytes = Array("Message-ID: <raw@example.test>\r\nX-Header: keep\r\n\r\nExact bytes\r\n".utf8)
        await transport.yieldIncoming(Array("* 1 FETCH (UID 42 BODY[]<0> {\(bytes.count)}\r\n".utf8) + bytes + Array(")\r\nA0004 OK FETCH completed\r\n".utf8))
        let adapter = MailFoundationAdapter(host: "imap.example.test", port: 143, security: .none) { transport }
        try await adapter.connect(); try await adapter.authenticate(username: "synthetic", password: "fixture")
        #expect(try await adapter.fetchRawMessage(path: "INBOX", uid: 42, maxBytes: 128) == Data(bytes))
        let sent = await transport.sentSnapshot().map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(sent.contains("BODY.PEEK[]<0.129>"))
        await adapter.disconnect()
    }

    @Test("标记搜索使用 SEARCH 关键字，写入仍使用带反斜杠的系统标记", arguments: [
        (MailFlag.seen, "SEEN", "\\Seen"),
        (MailFlag.flagged, "FLAGGED", "\\Flagged"),
        (MailFlag.deleted, "DELETED", "\\Deleted")
    ])
    func flagSearchUsesSearchKeys(flag: MailFlag, searchKey: String, storedFlag: String) async throws {
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 2 EXISTS\r\nA0003 OK [READ-WRITE] SELECT completed\r\n".utf8))
        await transport.yieldIncoming(Array("A0004 OK STORE completed\r\n".utf8))
        await transport.yieldIncoming(Array("* SEARCH 42 9\r\nA0005 OK UID SEARCH completed\r\n".utf8))
        await transport.yieldIncoming(Array("A0006 OK STORE completed\r\n".utf8))
        await transport.yieldIncoming(Array("* SEARCH\r\nA0007 OK UID SEARCH completed\r\n".utf8))

        let adapter = MailFoundationAdapter(host: "imap.example.com", port: 143, security: .none) { transport }
        try await adapter.connect()
        try await adapter.authenticate(username: "user", password: "secret")
        try await adapter.storeFlags(path: "INBOX", uid: 42, add: [flag], remove: [])
        let matchingUIDs = try await adapter.searchUIDs(path: "INBOX", flag: flag)
        #expect(matchingUIDs == [9, 42])
        try await adapter.storeFlags(path: "INBOX", uid: 42, add: [], remove: [flag])
        let emptyUIDs = try await adapter.searchUIDs(path: "INBOX", flag: flag)
        #expect(emptyUIDs.isEmpty)

        let sent = await transport.sentSnapshot()
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        #expect(sent.contains("A0004 UID STORE 42 +FLAGS.SILENT (\(storedFlag))\r\n"))
        #expect(sent.contains("A0005 UID SEARCH \(searchKey)\r\n"))
        #expect(sent.contains("A0006 UID STORE 42 -FLAGS.SILENT (\(storedFlag))\r\n"))
        #expect(sent.contains("A0007 UID SEARCH \(searchKey)\r\n"))

        await adapter.disconnect()
    }

    @Test("标记搜索被 BAD 拒绝时保留错误，不能当作空 UID 集合")
    func flagSearchPreservesBadResponse() async throws {
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array("* 2 EXISTS\r\nA0003 OK [READ-WRITE] SELECT completed\r\n".utf8))
        await transport.yieldIncoming(Array("A0004 BAD Parse command error\r\n".utf8))

        let adapter = MailFoundationAdapter(host: "imap.example.com", port: 143, security: .none) { transport }
        try await adapter.connect()
        try await adapter.authenticate(username: "user", password: "secret")
        let error = await #expect(throws: MailServerDiagnostic.self) {
            try await adapter.searchUIDs(path: "INBOX", flag: .seen)
        }
        #expect(error?.kind == .serverRejected)
        #expect(error?.status == "BAD")
        #expect(error?.detail == "Parse command error")
        #expect(error?.stage == .search)
        #expect(error?.folder == "INBOX")
        await adapter.disconnect()
    }

    @MainActor
    @Test("BAD 命令错误不引导用户检查文件夹是否存在")
    func badCommandUsesProtocolGuidance() {
        let bad = MailServerDiagnostic(stage: .search, status: "BAD", detail: "Parse command error", kind: .serverRejected, folder: "INBOX")
        let badMessage = MailErrorText.message(for: bad)
        let guidance = L.string("mail.diag.action.invalidCommand")
        #expect(guidance != "mail.diag.action.invalidCommand")
        #expect(badMessage.contains(guidance))
        #expect(badMessage.contains("Parse command error"))
        #expect(!badMessage.contains(L.string("mail.diag.action.serverRejected")))

        let missing = MailServerDiagnostic(stage: .folderStatus, status: "NO", detail: "Mailbox does not exist", kind: .serverRejected, folder: "INBOX")
        #expect(MailErrorText.message(for: missing).contains(L.string("mail.diag.action.serverRejected")))
    }

    @Test("协议回放：中文文件夹 STATUS 只编码一次，且不二次编码")
    func statusEncodesChineseFolderOnce() async throws {
        let raw = ImapMailboxEncoding.encode("已发送")
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array(
            "* STATUS \"\(raw)\" (MESSAGES 3 UNSEEN 1 UIDNEXT 4 UIDVALIDITY 10)\r\nA0003 OK STATUS completed\r\n".utf8
        ))

        let adapter = MailFoundationAdapter(host: "imap.example.com", port: 143, security: .none) { transport }
        try await adapter.connect()
        try await adapter.authenticate(username: "user", password: "secret")

        let status = try await adapter.folderStatus(path: raw)
        #expect(status.uidNext == 4)
        #expect(status.messageCount == 3)

        let sent = await transport.sentSnapshot()
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        // 线路上的文件夹名必须正好是单次编码的原始路径
        #expect(sent.contains(raw))
        // 若把已编码路径再次编码（修复前的缺陷），线路会出现二次编码形态
        #expect(!sent.contains(ImapMailboxEncoding.encode(raw)))

        await adapter.disconnect()
    }

    @Test("协议回放：服务器 NO 时保留阶段、状态与脱敏说明")
    func replayPreservesRejectionDiagnostic() async throws {
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array("A0003 NO Mailbox does not exist\r\n".utf8))

        let adapter = MailFoundationAdapter(host: "imap.example.com", port: 143, security: .none) { transport }
        try await adapter.connect()
        try await adapter.authenticate(username: "user", password: "secret")

        let error = await #expect(throws: MailServerDiagnostic.self) {
            try await adapter.folderStatus(path: "&XfJT0ZAB-")
        }
        #expect(error?.kind == .serverRejected)
        #expect(error?.status == "NO")
        #expect(error?.detail == "Mailbox does not exist")
        #expect(error?.stage == .folderStatus)

        await adapter.disconnect()
    }

    @Test("协议回放：中文文件夹 SELECT（经 ensureSelected）只编码一次")
    func selectEncodesChineseFolderOnce() async throws {
        let raw = ImapMailboxEncoding.encode("存档/项目")
        let transport = AsyncStreamTransport()
        await transport.yieldIncoming(Array("* OK IMAP4rev1 ready\r\n".utf8))
        await transport.yieldIncoming(Array("A0001 OK LOGIN completed\r\n".utf8))
        await transport.yieldIncoming(Array("* CAPABILITY IMAP4rev1\r\nA0002 OK CAPABILITY completed\r\n".utf8))
        await transport.yieldIncoming(Array(
            "* 3 EXISTS\r\n* 0 RECENT\r\nA0003 OK [READ-WRITE] SELECT completed\r\n".utf8
        ))
        await transport.yieldIncoming(Array("A0004 OK STORE completed\r\n".utf8))

        let adapter = MailFoundationAdapter(host: "imap.example.com", port: 143, security: .none) { transport }
        try await adapter.connect()
        try await adapter.authenticate(username: "user", password: "secret")

        try await adapter.storeFlags(path: raw, uid: 1, add: [.seen], remove: [])

        let sent = await transport.sentSnapshot()
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        #expect(sent.contains("SELECT"))
        #expect(sent.contains(raw))
        #expect(!sent.contains(ImapMailboxEncoding.encode(raw)))

        await adapter.disconnect()
    }
}
