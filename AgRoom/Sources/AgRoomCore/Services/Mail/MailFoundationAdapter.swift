import Foundation
import MailFoundation
import MimeFoundation

// MARK: - MailFoundation Adapter

/// `MailProtocolClient` 的 MailFoundation 实现。
///
/// **本文件是项目中唯一 `import MailFoundation` 的位置**：其余代码只依赖
/// 自定的 `MailProtocolClient` 协议与 `RemoteMailFolder` DTO，便于日后替换协议栈。
///
/// 采用 `AsyncImapSession`（而非 `AsyncImapMailStore`），因为只有 session 暴露
/// `startTls()`，从而支持 STARTTLS 账号；同时 session 提供直接可用的
/// `connectSecure` / `login` / `list` 等操作。
public actor MailFoundationAdapter: MailProtocolClient {
    private let host: String
    private let port: Int
    private let security: MailSecurity
    private var session: AsyncImapSession?
    private var networkTransport: (any AsyncTransport)?
    private var connectionID: UUID?
    /// 当前已 SELECT 的文件夹路径；IMAP 同时只能选中一个邮箱。
    private var selectedPath: String?
    /// 传输层工厂；生产走 Network.framework，测试可注入内存字节通道做协议回放。
    /// 非空时 `connect()` 使用它而不是真实网络。
    private let transportFactory: (@Sendable () throws -> any AsyncTransport)?

    public init(host: String, port: Int, security: MailSecurity) {
        self.init(host: host, port: port, security: security, transportFactory: nil)
    }

    /// 仅供测试注入内存传输；生产代码使用上面的公开初始化器。
    init(
        host: String,
        port: Int,
        security: MailSecurity,
        transportFactory: (@Sendable () throws -> any AsyncTransport)?
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.transportFactory = transportFactory
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        try MailServerConfiguration.validate(port: port, security: security, protocolKind: .imap)
        let network: any AsyncTransport
        do {
            network = try transportFactory?()
                ?? AsyncTransportFactory.make(host: host, port: UInt16(port), backend: .network)
        } catch { throw MailProtocolError.connectionFailed(error.localizedDescription) }
        let session = AsyncImapSession(transport: network)
        let id = UUID()
        // Publish the in-flight connection before suspension so the deadline can close it.
        self.networkTransport = network
        self.session = session
        self.connectionID = id
        do {
            try await withTaskCancellationHandler {
                switch security {
                case .tls: _ = try await session.connectSecure()
                case .none: _ = try await session.connect()
                case .startTLS:
                    _ = try await session.connect()
                    _ = try await session.startTls()
                }
                try Task.checkCancellation()
            } onCancel: { Task { await network.stop() } }
            guard connectionID == id else { throw CancellationError() }
        } catch {
            if connectionID == id { self.session = nil; self.networkTransport = nil; self.connectionID = nil }
            await network.stop()
            await session.disconnect()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Self.failure(error, stage: .connect, folderPath: nil)
        }
    }

    public func authenticate(username: String, password: String) async throws {
        guard let session else { throw MailProtocolError.notConnected }
        do {
            _ = try await session.login(user: username, password: password)
        } catch {
            // 认证被服务器拒绝（NO）时保留状态与脱敏说明，便于界面直接指出原因
            throw Self.failure(error, stage: .authenticate, folderPath: nil)
        }
    }

    public func listFolders() async throws -> [RemoteMailFolder] {
        guard let session else { throw MailProtocolError.notConnected }
        let mailboxes: [ImapMailbox]
        do {
            mailboxes = try await session.list(reference: "", mailbox: "*")
        } catch {
            throw Self.failure(error, stage: .listFolders, folderPath: nil)
        }
        return mailboxes.map { box in
            RemoteMailFolder(
                // path 保原始名（Modified UTF-7 编码态）落库：它是文件夹的稳定身份，
                // 提交命令前由 `sessionMailbox(from:)` 解码，`AsyncImapSession` 再按需编码。
                // 展示名用解码后的 Unicode。
                path: box.name,
                name: Self.lastComponent(box.decodedName, delimiter: box.delimiter),
                role: Self.role(for: box),
                delimiter: box.delimiter,
                isSelectable: box.isSelectable
            )
        }
    }

    public func disconnect() async {
        let session = self.session
        let network = networkTransport
        self.session = nil
        networkTransport = nil
        connectionID = nil
        selectedPath = nil
        // Close the byte stream first; a graceful LOGOUT must not delay an expired deadline.
        await network?.stop()
        await session?.disconnect()
    }

    public func createFolder(path: String) async throws {
        guard let session else { throw MailProtocolError.notConnected }
        do { _ = try await session.create(mailbox: Self.sessionMailbox(from: path)) }
        catch { throw Self.failure(error, stage: .createFolder, folderPath: path) }
    }

    public func renameFolder(path: String, toPath: String) async throws {
        guard let session else { throw MailProtocolError.notConnected }
        selectedPath = nil
        do { _ = try await session.rename(mailbox: Self.sessionMailbox(from: path), newName: Self.sessionMailbox(from: toPath)) }
        catch { throw Self.failure(error, stage: .renameFolder, folderPath: path) }
    }

    public func deleteFolder(path: String) async throws {
        guard let session else { throw MailProtocolError.notConnected }
        selectedPath = nil
        do { _ = try await session.delete(mailbox: Self.sessionMailbox(from: path)) }
        catch { throw Self.failure(error, stage: .deleteFolder, folderPath: path) }
    }

    // MARK: - SMTP Probe

    /// SMTP 连通性探测：使用与发信相同的 TLS 握手和 EHLO 路径，不发送凭据或邮件。
    public static func probeSMTP(
        host: String,
        port: Int,
        security: MailSecurity,
        timeoutMilliseconds: Int = MailTimeoutBudget.default.connect
    ) async throws {
        try await probeSMTP(host: host, port: port, security: security,
                            timeoutMilliseconds: timeoutMilliseconds, implicitTLSChannel: nil)
    }

    static func probeSMTP(
        host: String, port: Int, security: MailSecurity, timeoutMilliseconds: Int,
        implicitTLSChannel: (any MailImplicitTLSChannel)?
    ) async throws {
        try MailServerConfiguration.validate(port: port, security: security, protocolKind: .smtp)
        let connection = try SMTPConnection.make(host: host, port: UInt16(port), security: security,
                                                 implicitTLSChannel: implicitTLSChannel)
        do {
            try await MailDeadline.run(milliseconds: timeoutMilliseconds, label: "smtpProbe",
                                       onExpiry: { await connection.close() }) {
                try await connection.open(security: security, domain: "agroom.local")
            }
        } catch {
            await connection.close()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error is MailProtocolError { throw error }
            throw MailProtocolError.connectionFailed(error.localizedDescription)
        }
        await connection.close()
    }

    // MARK: - Sync Operations

    public func folderStatus(path: String) async throws -> RemoteFolderStatus {
        guard let session else { throw MailProtocolError.notConnected }
        let response: ImapStatusResponse
        do {
            // STATUS 不改变当前选中邮箱，可在同步游标读取时安全使用
            response = try await session.status(
                mailbox: Self.sessionMailbox(from: path),
                items: ["MESSAGES", "UNSEEN", "UIDNEXT", "UIDVALIDITY"]
            )
        } catch {
            throw Self.failure(error, stage: .folderStatus, folderPath: path)
        }
        let items = response.items
        return RemoteFolderStatus(
            uidValidity: items["UIDVALIDITY"].flatMap { UInt32(exactly: $0) },
            uidNext: items["UIDNEXT"].flatMap { UInt32(exactly: $0) },
            messageCount: items["MESSAGES"] ?? 0,
            unreadCount: items["UNSEEN"] ?? 0
        )
    }

    /// 增量摘要拉取：单次调用只取一批（受 `limit` 约束），批与批之间由调用方响应取消。
    ///
    /// 分批的理由：单条 `UID FETCH 1:*` 在大文件夹上会产生一个无法中断、无法观察进度、
    /// 内存占用与文件夹规模成正比的请求。调用方循环取批，即可在批间取消与上报进度。
    public func fetchSummaries(
        path: String,
        sinceUID: UInt32?,
        limit: Int
    ) async throws -> [RemoteMessageSummary] {
        guard let session else { throw MailProtocolError.notConnected }
        try await ensureSelected(path)
        guard limit > 0 else { return [] }

        let lower: UInt32
        if let sinceUID {
            // UID 已达上界时不存在增量（也避免 sinceUID + 1 溢出）
            guard sinceUID < UInt32.max else { return [] }
            lower = sinceUID + 1
        } else {
            lower = 1
        }
        // 区间形式 `a:b` 只表达界，不要求中间每个 UID 都存在
        let offset = UInt32(clamping: limit - 1)
        let upper = lower.addingReportingOverflow(offset)
        let range = upper.overflow ? "\(lower):*" : "\(lower):\(upper.partialValue)"
        let set: UniqueIdSet
        do {
            set = try UniqueIdSet(parsing: range)
        } catch {
            throw MailProtocolError.invalidResponse(error.localizedDescription)
        }
        guard !set.isEmpty else { return [] }

        // 只拉纯元数据：不附带 previewText。预览要求服务器逐封解析邮件
        // （RFC 8970 PREVIEW 扩展；不支持时回退 BODY.PEEK[TEXT]<0.512>），
        // 企业/国产服务器（如 Coremail）在整批 200 封上解析不过来——
        // 整批挂起直到超时，同步永远卡在第一页。列表预览改为正文加载后回填。
        let request = FetchRequest(
            items: [.envelope, .flags, .uniqueId, .size, .internalDate]
        )
        let chunk: [MessageSummary]
        do {
            chunk = try await session.uidFetchSummaries(set, request: request)
        } catch {
            throw Self.failure(error, stage: .fetchSummaries, folderPath: path)
        }
        return chunk.compactMap { Self.remoteSummary(from: $0) }
    }

    public func recentSummaries(path: String, messageCount: Int, limit: Int) async throws -> [RemoteMessageSummary] {
        guard let session else { throw MailProtocolError.notConnected }
        guard messageCount > 0, limit > 0 else { return [] }
        try await ensureSelected(path)
        let first = max(1, messageCount - limit + 1)
        let request = FetchRequest(items: [.envelope, .uniqueId, .size, .internalDate])
        do {
            return try await session.fetchSummaries("\(first):\(messageCount)", request: request)
                .compactMap { Self.remoteSummary(from: $0) }
        } catch { throw Self.failure(error, stage: .fetchSummaries, folderPath: path) }
    }

    public func fetchSummaries(path: String, uids: [UInt32]) async throws -> [RemoteMessageSummary] {
        guard let session else { throw MailProtocolError.notConnected }
        let ids = Set(uids.filter { $0 > 0 }).sorted()
        guard !ids.isEmpty else { return [] }
        guard ids.count <= 1_000 else { throw MailProtocolError.invalidResponse("Summary UID batch is too large.") }
        try await ensureSelected(path)
        let set = try UniqueIdSet(parsing: ids.map(String.init).joined(separator: ","))
        do {
            return try await session.uidFetchSummaries(set, request: FetchRequest(items: [.envelope, .flags, .uniqueId, .size, .internalDate]))
                .compactMap { Self.remoteSummary(from: $0) }
        } catch { throw Self.failure(error, stage: .fetchSummaries, folderPath: path) }
    }

    /// 按需正文：先用 `BODYSTRUCTURE` 取部件树，只下载文本部件。
    ///
    /// 旧实现用 `BODY.PEEK[]` 拉整封邮件——附件二进制被完整下载、解析后丢弃，
    /// 既浪费带宽与内存又没有上限。这里只取 `BODY.PEEK[HEADER]` 与文本部件，
    /// 附件只取结构里的 octets（大小不再恒为 0）。
    public func fetchBody(
        path: String,
        uid: UInt32,
        maxBytes: Int
    ) async throws -> RemoteMessageBody {
        guard let session else { throw MailProtocolError.notConnected }
        guard uid != 0 else { throw MailProtocolError.invalidResponse("Invalid UID 0.") }
        try await ensureSelected(path)

        let structure = try await Self.fetchBodyStructure(session: session, uid: uid)
        guard let structure else {
            // 服务器不返回 BODYSTRUCTURE：回落到整封拉取，但同样受字节上限约束
            return try await Self.fetchWholeMessage(
                session: session,
                uid: uid,
                maxBytes: maxBytes,
                reason: "no BODYSTRUCTURE"
            )
        }

        let textParts = Self.textParts(of: structure)
        let wireSize = Self.wireSize(of: structure) + Self.headerAllowance
        guard wireSize <= maxBytes else {
            throw MailProtocolError.messageTooLarge(
                "UID \(uid) needs about \(wireSize) bytes (limit \(maxBytes))."
            )
        }

        let bodies = try await Self.fetchSectionBodies(
            session: session,
            uid: uid,
            textPartIds: textParts.map(\.id)
        )
        guard let header = bodies.header else {
            throw MailProtocolError.invalidResponse("Missing header section for UID \(uid).")
        }
        let sections = textParts.compactMap { item -> (ImapBodyPart, [UInt8])? in
            guard let bytes = bodies.parts[item.id] else { return nil }
            return (item.part, bytes)
        }
        guard !sections.isEmpty else {
            throw MailProtocolError.invalidResponse("Empty body for UID \(uid).")
        }

        let assembled = Self.assembleMultipartMessage(
            header: header,
            textSections: sections,
            boundary: "agroom-\(uid)-\(UUID().uuidString)"
        )
        let message = try Self.parseMessage(assembled)

        // 附件及 CID 资源只落元数据，不下载二进制；大小取自 BODYSTRUCTURE 的 octets。
        let attachments = Self.attachments(of: structure)
        let normalized = Self.normalizedBodies(text: message.textBody, html: message.htmlBody)

        return RemoteMessageBody(
            textBody: normalized.text,
            htmlBody: normalized.html,
            references: Self.threadReferences(references: Self.headerValue("references", in: header), inReplyTo: Self.headerValue("in-reply-to", in: header)),
            attachments: attachments
        )
    }

    public func fetchRawMessage(path: String, uid: UInt32, maxBytes: Int) async throws -> Data {
        guard let session else { throw MailProtocolError.notConnected }
        guard uid > 0, maxBytes > 0, maxBytes < Int.max else { throw MailExportError.incomplete }
        try await ensureSelected(path)
        do {
            let maps = try await session.uidFetchBodySections(UniqueIdSet([UniqueId(id: uid)]),
                items: ImapFetchBody.section(nil, peek: true, partial: ImapFetchPartial(start: 0, length: maxBytes + 1)))
            guard let bytes = maps.first?.body(), !bytes.isEmpty else { throw MailExportError.incomplete }
            guard bytes.count <= maxBytes else { throw MailExportError.tooLarge }
            return Data(bytes)
        } catch let error as MailExportError { throw error }
        catch { throw Self.failure(error, stage: .fetchBody, folderPath: path) }
    }

    static func originalMessageID(_ data: Data) throws -> String? {
        let bytes = Array(data)
        let range = Self.range(of: [13, 10, 13, 10], in: bytes) ?? Self.range(of: [10, 10], in: bytes)
        let header = range.map { Array(bytes[..<$0.lowerBound]) } ?? bytes
        return Self.headerValue("message-id", in: header)
    }

    static func decodeHTMLTextEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&(?:#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);", options: .caseInsensitive) else { return text }
        let source = text as NSString
        let output = NSMutableString(capacity: source.length), decoder = HtmlEntityDecoder()
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output.append(source.substring(with: NSRange(location: position, length: match.range.location - position)))
            let entity = source.substring(with: match.range)
            decoder.reset()
            var valid = true
            for character in entity {
                if !decoder.push(character) { valid = false; break }
            }
            output.append(valid ? decoder.getValue() : entity)
            position = NSMaxRange(match.range)
        }
        output.append(source.substring(from: position))
        return output as String
    }

    static func threadReferences(references: String?, inReplyTo: String?) -> String? {
        let parent = MailService.conversationTokens(own: nil, references: inReplyTo).map { "<" + $0 + ">" }.joined(separator: " ")
        return MailService.mergeKnownReferences(references, parent.isEmpty ? nil : parent)
    }

    static func threadReferences(in data: Data) -> String? {
        let bytes = Array(data.prefix(256 * 1024))
        let separator = range(of: [13, 10, 13, 10], in: bytes) ?? range(of: [10, 10], in: bytes)
        guard let separator else { return nil }
        let header = Array(bytes[..<separator.lowerBound])
        return threadReferences(references: headerValue("references", in: header), inReplyTo: headerValue("in-reply-to", in: header))
    }

    static func importedEnvelope(_ data: Data) throws -> MailImportedEnvelope {
        guard !data.isEmpty, data.count <= MailService.rawMessageByteLimit else { throw MailImportError.capacity }
        guard let separator = data.range(of: Data([13, 10, 13, 10])) ?? data.range(of: Data([10, 10])),
              separator.lowerBound <= 256 * 1024 else { throw MailImportError.invalidMessage }
        var options = ParserOptions(); options.maxMimeDepth = 64
        let message = try MimeParser(options, MemoryStream(Array(data))).parseMessage()
        guard message.headers.count > 0, message.body != nil else { throw MailImportError.invalidMessage }
        func addresses(_ list: InternetAddressList) -> [MailAddress] {
            list.mailboxes.map { .init(name: $0.name ?? "", address: $0.address) }
        }
        return .init(subject: message.subject ?? "", from: addresses(message.from).first ?? .init(name: "", address: ""),
            to: addresses(message.to), cc: addresses(message.cc), replyTo: addresses(message.replyTo),
            messageID: message.headers[.messageId], references: Self.threadReferences(references: message.headers[.references], inReplyTo: message.headers[.inReplyTo]), date: message.date?.date)
    }

    static func importedBody(_ data: Data) throws -> RemoteMessageBody { try MailSmtpAdapter.localBody(data) }

    public func fetchAttachment(path: String, uid: UInt32, partID: String, maxBytes: Int) async throws -> Data {
        guard let session else { throw MailProtocolError.notConnected }
        guard uid != 0, maxBytes > 0, partID.range(of: #"^[1-9][0-9]*(\.[1-9][0-9]*)*$"#, options: .regularExpression) != nil else {
            throw MailProtocolError.invalidResponse("Invalid attachment part.")
        }
        try await ensureSelected(path)
        guard let structure = try await Self.fetchBodyStructure(session: session, uid: uid),
              let part = structure.enumerateParts().first(where: { $0.0 == partID })?.1,
              Self.isDownloadablePart(part) else {
            throw MailProtocolError.invalidResponse("Attachment structure is unavailable. Reload the message.")
        }
        guard (part.size ?? 0) <= maxBytes else { throw MailProtocolError.messageTooLarge("Attachment exceeds the download limit.") }
        let section = ImapFetchBodySection(part: Self.partPath(partID))
        let maps: [ImapFetchBodyMap]
        do {
            maps = try await session.uidFetchBodySections(
                UniqueIdSet([UniqueId(id: uid)]),
                items: ImapFetchBody.section(section, peek: true, partial: ImapFetchPartial(start: 0, length: maxBytes + 1))
            )
        } catch {
            throw Self.failure(error, stage: .fetchAttachment, folderPath: path)
        }
        guard let bytes = maps.first?.body(section: section), bytes.count <= maxBytes else {
            throw MailProtocolError.messageTooLarge("Attachment exceeds the download limit.")
        }
        return try Self.decodeAttachment(bytes: bytes, encoding: part.encoding ?? "7bit", maxBytes: maxBytes)
    }

    static func decodeAttachment(bytes: [UInt8], encoding: String, maxBytes: Int) throws -> Data {
        let encoding = encoding.lowercased()
        guard ["base64", "quoted-printable", "7bit", "8bit", "binary"].contains(encoding), bytes.count <= maxBytes else {
            throw MailProtocolError.invalidResponse("Unsupported attachment encoding or size.")
        }
        let header = "Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: \(encoding)\r\n\r\n"
        let parsed = try Self.parseMessage(Array(header.utf8) + bytes)
        guard let part = parsed.body as? MimePart, let content = part.content else {
            throw MailProtocolError.invalidResponse("Cannot decode attachment.")
        }
        let output = MemoryStream()
        try content.decodeTo(output)
        let decoded = output.toByteArray()
        guard decoded.count <= maxBytes else { throw MailProtocolError.messageTooLarge("Decoded attachment exceeds the download limit.") }
        return Data(decoded)
    }

    /// 服务器标记搜索（该标记的 UID 升序）；删除保护与对账用。
    public func searchUIDs(path: String, flag: MailFlag) async throws -> [UInt32] {
        guard let session else { throw MailProtocolError.notConnected }
        try await ensureSelected(path)
        // SEARCH 使用 SEEN / FLAGGED / DELETED 关键字；不能复用 STORE 的 \Seen 等标记字面量。
        let query: SearchQuery = switch flag {
        case .seen: .seen
        case .flagged: .flagged
        case .deleted: .deleted
        }
        let response: ImapSearchResponse
        do {
            response = try await session.uidSearch(query)
        } catch {
            throw Self.failure(error, stage: .search, folderPath: path)
        }
        // `uidSearch` 只在带 UID 语义的响应上置位 `isUid`；未置位说明这次应答不是一次
        // 可解读的 UID SEARCH（例如服务器回了本层不认识的 ESEARCH 形态）。
        // 此时**必须报错而不是当成空集**：调用方把「该标记没有邮件」当作安全前提
        // （删除前确认没有别的待删邮件），把不可解读误报成空集会导致连带删除。
        guard response.isUid else {
            throw MailServerDiagnostic(
                stage: .search,
                status: "OK",
                detail: "UID SEARCH for \(flag.rawValue) returned an unreadable response",
                kind: .malformedResponse,
                folder: Self.displayFolderName(path)
            )
        }
        return response.ids.sorted()
    }

    /// 文件夹内全部邮件 UID（升序）。`UID SEARCH ALL` 只回 UID，不下载任何邮件内容。
    public func allUIDs(path: String) async throws -> [UInt32] {
        guard let session else { throw MailProtocolError.notConnected }
        try await ensureSelected(path)
        let response: ImapSearchResponse
        do {
            response = try await session.uidSearch("ALL")
        } catch {
            throw Self.failure(error, stage: .search, folderPath: path)
        }
        // 同 `searchUIDs`：未置位 `isUid` 的应答不可解读，必须报错而不是当成空集——
        // 调用方据此判定扫描上界，误报成空集会让本可同步的邮件被永久跳过。
        guard response.isUid else {
            throw MailServerDiagnostic(
                stage: .search,
                status: "OK",
                detail: "UID SEARCH ALL returned an unreadable response",
                kind: .malformedResponse,
                folder: Self.displayFolderName(path)
            )
        }
        return response.ids.sorted()
    }

    public func storeFlags(path: String, uid: UInt32, add: [MailFlag], remove: [MailFlag]) async throws {
        guard let session else { throw MailProtocolError.notConnected }
        guard uid != 0, !add.isEmpty || !remove.isEmpty else { return }
        try await ensureSelected(path)
        try await Self.storeFlags(session: session, uid: uid, add: add, remove: remove)
    }

    /// 移动到另一文件夹：`COPYUID` 响应码给出目标 UID（RFC 4315）。
    ///
    /// 服务器不回 `COPYUID` 时返回 `uid: nil`，调用方必须重新抓取目标邮件——
    /// `MOVE`（RFC 6851）会在目标文件夹分配**新** UID，沿用源 UID 会指向错误的邮件。
    public func moveMessage(path: String, uid: UInt32, toPath: String) async throws -> RemoteMoveResult {
        guard let session else { throw MailProtocolError.notConnected }
        guard uid != 0 else { throw MailProtocolError.invalidResponse("Invalid UID 0.") }
        try await ensureSelected(path)
        let result: ImapCopyResult
        do {
            result = try await session.uidMove(
                UniqueIdSet([UniqueId(id: uid)]),
                to: Self.sessionMailbox(from: toPath)
            )
        } catch {
            throw Self.failure(error, stage: .move, folderPath: toPath)
        }
        // 选中态可能因 MOVE 改变（部分服务器会回 EXPUNGE 响应），下次操作用不到旧值
        selectedPath = nil
        guard let copyUid = result.copyUid,
              let destination = copyUid.destination,
              let newUID = Array(destination).first?.id else {
            return .unknown
        }
        return RemoteMoveResult(uid: newUID, uidValidity: copyUid.uidValidity)
    }

    public func supportsUIDPlus() async -> Bool {
        guard let session else { return false }
        return await session.capabilities()?.supports("UIDPLUS") ?? false
    }

    public func appendDraft(path: String, data: Data) async throws -> RemoteDraftAppendResult {
        guard let session else { throw MailProtocolError.notConnected }
        guard !data.isEmpty, data.count <= MailService.rawMessageByteLimit else { throw MailAttachmentError.capacity }
        // A missing/malformed APPENDUID is an unknown result, never a retry signal.
        let response: ImapResponse
        do { response = try await session.appendDraft(mailbox: Self.sessionMailbox(from: path), bytes: Array(data)) }
        catch { throw Self.failure(error, stage: .appendDraft, folderPath: path) }
        let pattern = #"\[APPENDUID ([0-9]+) ([0-9]+)\]"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let text = response.text as NSString
        guard let match = regex.firstMatch(in: response.text, range: NSRange(location: 0, length: text.length)),
              let validity = UInt32(text.substring(with: match.range(at: 1))), validity > 0,
              let uid = UInt32(text.substring(with: match.range(at: 2))), uid > 0 else { throw MailServerDraftError.unresolved }
        return .init(uidValidity: validity, uid: uid)
    }

    public func draftUIDs(path: String, messageID: String) async throws -> [UInt32] {
        guard let session else { throw MailProtocolError.notConnected }
        guard !messageID.isEmpty, messageID.utf8.count <= 1024,
              messageID.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e && $0 != 34 && $0 != 92 }) else { throw MailServerDraftError.changed }
        try await ensureSelected(path)
        let found: ImapSearchResponse
        do { found = try await session.uidSearch("DRAFT HEADER Message-ID \"\(messageID)\"") }
        catch { throw Self.failure(error, stage: .search, folderPath: path) }
        guard found.isUid else { throw MailServerDraftError.unresolved }
        guard found.ids.count <= 10_000 else { throw MailServerDraftError.capacity }
        return found.ids.filter { $0 > 0 }.sorted()
    }

    /// 标记 `\Deleted`（不 EXPUNGE）。
    public func markDeleted(path: String, uid: UInt32) async throws {
        try await storeFlags(path: path, uid: uid, add: [.deleted], remove: [])
    }

    /// 清除 `\Deleted` 标记（删除失败回滚）。
    public func unmarkDeleted(path: String, uid: UInt32) async throws {
        try await storeFlags(path: path, uid: uid, add: [], remove: [.deleted])
    }

    /// 只清除指定 UID：上游 `MailFoundation` 尚未暴露 `UID EXPUNGE`。
    ///
    /// RFC 4315 的 `UID EXPUNGE` 可以只删指定 UID；上游 `ImapCommandKind` 是封闭枚举、
    /// 也没有该方法，因此这里明确报错而不是退化成不带 UID 的 `EXPUNGE`——后者会连带
    /// 删掉同文件夹里其他已标 `\Deleted` 的邮件。调用方（`MailSyncService`）据此
    /// 改走「保护其他待删邮件」的显式兜底路径。
    public func expungeUIDs(path: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        throw MailProtocolError.invalidResponse(
            "UID EXPUNGE is not available in the current protocol stack."
        )
    }

    /// 清除该文件夹内全部已标 `\Deleted` 的邮件；调用方必须先确认没有其他待删邮件。
    public func expungeAllDeleted(path: String) async throws {
        guard let session else { throw MailProtocolError.notConnected }
        try await ensureSelected(path)
        do {
            // EXPUNGE 会重排序号空间，选中的文件夹仍然有效但序号已变
            _ = try await session.expunge()
        } catch {
            throw Self.failure(error, stage: .delete, folderPath: path)
        }
    }

    // MARK: - Helpers

    /// 正文拉取的固定开销余量（头部 + MIME 分隔符）。
    private static let headerAllowance = 64 * 1024

    /// 读取 `BODYSTRUCTURE`；服务器不支持或解析失败时返回 nil。
    ///
    /// 必须走 `UID FETCH`：上游 `fetchAttributes` 是普通 `FETCH`（按邮件序号），
    /// 把 UID 当序号提交会取到**另一封**邮件的结构——序号与 UID 只有在该文件夹
    /// 「无删除、从 1 连续分配」时才相等。后续正文部件按 UID 拉取，结构若按序号取，
    /// 会出现结构与正文错配。返回项的 UID 与请求不一致时一律报错，绝不将错就错。
    private static func fetchBodyStructure(
        session: AsyncImapSession,
        uid: UInt32
    ) async throws -> ImapBodyStructure? {
        let responses: [ImapFetchResponse]
        do {
            responses = try await session.uidFetch(
                UniqueIdSet([UniqueId(id: uid)]),
                request: FetchRequest(items: [.bodyStructure, .uniqueId])
            )
        } catch {
            throw Self.failure(error, stage: .fetchBody, folderPath: nil)
        }
        let attributes = responses.compactMap(ImapFetchAttributes.parse)
        guard let first = attributes.first else { return nil }
        if let returnedUID = first.uid, returnedUID != uid {
            throw MailProtocolError.invalidResponse(
                "UID FETCH BODYSTRUCTURE returned UID \(returnedUID) for requested UID \(uid)."
            )
        }
        return first.parsedBodyStructure()
    }

    /// 一次请求取回头部与全部文本部件（`BODY.PEEK[HEADER]` + `BODY.PEEK[<section>]`）。
    private static func fetchSectionBodies(
        session: AsyncImapSession,
        uid: UInt32,
        textPartIds: [String]
    ) async throws -> (header: [UInt8]?, parts: [String: [UInt8]]) {
        let maps: [ImapFetchBodyMap]
        do {
            maps = try await session.uidFetchBodySections(
                UniqueIdSet([UniqueId(id: uid)]),
                items: Self.sectionListRequest(textPartIds: textPartIds)
            )
        } catch {
            throw Self.failure(error, stage: .fetchBody, folderPath: nil)
        }
        guard let map = maps.first else { return (nil, [:]) }

        var parts: [String: [UInt8]] = [:]
        for id in textPartIds {
            let section = ImapFetchBodySection(part: Self.partPath(id))
            if let bytes = map.body(section: section) {
                parts[id] = bytes
            }
        }
        // 请求的是 `BODY.PEEK[HEADER]`，应答键是 `"HEADER"` 而非空段 `""`。
        // 用 `section: nil`（键 `""`）取头部永远取不到，正文一律报「Missing header section」。
        // 兼容极少数按 `BODY[]` 回头的服务器：先按显式 HEADER 段取，再回落空段。
        return (map.body(section: .header) ?? map.body(section: nil), parts)
    }

    /// 只取头部与文本部件的 BODY 段列表。
    private static func sectionListRequest(textPartIds: [String]) -> String {
        var items = [ImapFetchBody.section(ImapFetchBodySection.header, peek: true)]
        items.append(contentsOf: textPartIds.map {
            ImapFetchBody.section(ImapFetchBodySection(part: Self.partPath($0)), peek: true)
        })
        return "(\(items.joined(separator: " ")))"
    }

    /// "2.1" → [2, 1]
    private static func partPath(_ id: String) -> [Int] {
        id.split(separator: ".").compactMap { Int($0) }
    }

    /// 结构里的文本部件（`text/*`，排除附件性质的 disposition），保持出现顺序。
    private static func textParts(of structure: ImapBodyStructure) -> [(id: String, part: ImapBodyPart)] {
        structure.enumerateParts().filter { _, part in
            part.type.caseInsensitiveCompare("text") == .orderedSame
                && !Self.looksLikeAttachment(part)
        }
    }

    private static func looksLikeAttachment(_ part: ImapBodyPart) -> Bool {
        guard let disposition = part.disposition else { return false }
        return disposition.type.caseInsensitiveCompare("attachment") == .orderedSame
    }

    /// CID resources need not declare a disposition or filename. Keep this
    /// separate from the body predicate: an HTML root may itself have a CID.
    private static func isDownloadablePart(_ part: ImapBodyPart) -> Bool {
        looksLikeAttachment(part) || part.id != nil || !filename(of: part).isEmpty
            || (part.type.caseInsensitiveCompare("image") == .orderedSame
                && part.disposition?.type.caseInsensitiveCompare("inline") == .orderedSame)
            || (part.type.caseInsensitiveCompare("message") == .orderedSame
                && part.subtype.caseInsensitiveCompare("rfc822") == .orderedSame)
    }

    /// 实际会下载的字节数（头部以外的部件 octets 之和）。
    ///
    /// 只累计会取回的部件：文本部件按 octets 计入，附件与容器不计入（不会下载）。
    /// 结构里没有 octets 时返回 0——上限由实际字节数在回落路径上兜底。
    private static func wireSize(of structure: ImapBodyStructure) -> Int {
        structure.enumerateParts().reduce(0) { total, item in
            let (_, part) = item
            guard part.type.caseInsensitiveCompare("text") == .orderedSame,
                  !looksLikeAttachment(part) else {
                return total
            }
            return total + (part.size ?? 0)
        }
    }

    /// 文件附件与内嵌资源共用下载判定，大小取 octets。
    private static func attachments(of structure: ImapBodyStructure) -> [RemoteAttachment] {
        structure.enumerateParts().compactMap { partID, part in
            guard isDownloadablePart(part) else { return nil }
            return RemoteAttachment(
                filename: Self.filename(of: part).isEmpty
                    ? (part.type.caseInsensitiveCompare("message") == .orderedSame ? "message.eml" : "attachment")
                    : Self.filename(of: part),
                mimeType: "\(part.type.lowercased())/\(part.subtype.lowercased())",
                sizeBytes: part.size ?? 0,
                contentId: part.id,
                isInline: !looksLikeAttachment(part),
                partID: partID
            )
        }
    }

    /// 附件名：优先 `Content-Disposition` 的 filename，其次 `Content-Type` 的 name。
    private static func filename(of part: ImapBodyPart) -> String {
        if let name = part.disposition?.parameters["FILENAME"], !name.isEmpty {
            return name
        }
        if let name = part.parameters["NAME"], !name.isEmpty {
            return name
        }
        return ""
    }

    /// 用「原始头部 + 文本部件」拼一封结构等价的最小 MIME 邮件。
    ///
    /// 之所以重新拼装：`BODY[HEADER]` 与各部件分属不同 FETCH 段，直接交给 MIME 解析器
    /// 会丢掉部件与容器的对应关系。这里保留头部原样（发件人/主题/日期等），只把
    /// `Content-Type`/`MIME-Version`/`Content-Transfer-Encoding` 换成与所取部件一致的声明，
    /// 已编码部件保留传输编码，未编码的非 ASCII 字节转为 Base64，字符集仍由 MIME 解析器解码。
    private static func assembleMultipartMessage(
        header: [UInt8],
        textSections: [(ImapBodyPart, [UInt8])],
        boundary: String
    ) -> [UInt8] {
        var output: [UInt8] = []
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let range = Self.range(of: separator, in: header)
        let headerBlock = range.map { Array(header[0..<$0.lowerBound]) } ?? header

        for line in Self.headerLines(headerBlock) {
            let lower = String(decoding: line, as: UTF8.self).lowercased()
            if lower.hasPrefix("content-type:")
                || lower.hasPrefix("mime-version:")
                || lower.hasPrefix("content-transfer-encoding:") {
                continue
            }
            output.append(contentsOf: line)
            output.append(contentsOf: [0x0D, 0x0A])
        }

        // 声明为 `multipart/alternative` 而非 `multipart/mixed`：
        // 这里只拼入文本部件（附件单独处理），语义上就是「同一内容的不同格式」。
        // 关键是基类 `Multipart.tryGetValue` 遇到第一个不匹配的 TextPart 就 break，
        // 当 text/plain 排在 text/html 之前时，`MimeMessage.htmlBody` 会恒为 nil；
        // `MultipartAlternative.tryGetValue` 会扫描全部子部件，才能同时取到两种格式。
        let declaration = "MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n"
        output.append(contentsOf: Array(declaration.utf8))
        output.append(contentsOf: separator)

        for (part, bytes) in textSections {
            output.append(contentsOf: Array("--\(boundary)\r\n".utf8))
            var encoding = part.encoding?.uppercased() ?? ""
            let payload: [UInt8]
            if ["", "7BIT", "8BIT", "BINARY"].contains(encoding), bytes.contains(where: { $0 >= 128 }) {
                encoding = "BASE64"
                payload = Array(Data(bytes).base64EncodedData(options: [
                    .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed
                ]))
            } else { payload = bytes }
            var partHeader = "Content-Type: \(part.type.lowercased())/\(part.subtype.lowercased())"
            if let charset = part.parameters["CHARSET"], !charset.isEmpty {
                partHeader += "; charset=\(charset)"
            }
            partHeader += "\r\n"
            if !encoding.isEmpty {
                partHeader += "Content-Transfer-Encoding: \(encoding)\r\n"
            }
            output.append(contentsOf: Array(partHeader.utf8))
            output.append(contentsOf: separator)
            output.append(contentsOf: payload)
            if payload.suffix(2) != [0x0D, 0x0A] {
                output.append(contentsOf: [0x0D, 0x0A])
            }
        }
        output.append(contentsOf: Array("--\(boundary)--\r\n".utf8))
        return output
    }

    /// 读取头部某个字段的值（大小写不敏感，支持折叠续行）；未出现时返回 nil。
    ///
    /// 只扫描传入的头部块（不含正文），避免把正文中形如 `References:` 的行误当头部。
    static func headerValue(_ name: String, in block: [UInt8]) -> String? {
        let prefix = name.lowercased() + ":"
        var collecting = false
        var value = ""
        for line in headerLines(block) {
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix(" ") || text.hasPrefix("\t") {
                if collecting { value += " " + text.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if collecting { break }
            guard text.lowercased().hasPrefix(prefix) else { continue }
            collecting = true
            value = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 长度上限：References 链理论上可很长，超长值对回复无意义且会放大提示词
        return trimmed.count <= 2000 ? trimmed : String(trimmed.prefix(2000))
    }

    private static func headerLines(_ block: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var index = 0
        while index < block.count {
            if block[index] == 0x0D, index + 1 < block.count, block[index + 1] == 0x0A {
                lines.append(current)
                current = []
                index += 2
                continue
            }
            if block[index] == 0x0A {
                lines.append(current)
                current = []
                index += 1
                continue
            }
            current.append(block[index])
            index += 1
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func range(of pattern: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }
        for start in 0...(haystack.count - pattern.count) {
            if Array(haystack[start..<(start + pattern.count)]) == pattern {
                return start..<(start + pattern.count)
            }
        }
        return nil
    }

    /// 归一化正文：无 HTML 部件、但纯文本内容其实是 HTML 源码时按 HTML 呈现。
    ///
    /// 部分发送端（模板生成的营销/通知邮件）把整段 HTML 塞进 `text/plain` 部件，
    /// 或服务器 BODYSTRUCTURE 把 HTML 部件报成 text/plain；若按纯文本展示会看到
    /// `<!DOCTYPE html> ...` 源码。仅在文本确实像 HTML 文档时提升，避免误判普通文本。
    static func normalizedBodies(text: String?, html: String?) -> (text: String?, html: String?) {
        guard html == nil, let text, looksLikeHTML(text) else { return (text, html) }
        return (text, text)
    }

    /// 判定字符串是否为 HTML 文档源码（保守：需以 `<` 开头且含明确的文档/结构标签）。
    static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(2000).lowercased()
        let trimmed = head.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        guard trimmed.hasPrefix("<") else { return false }
        return ["<!doctype", "<html", "<head", "<body", "<div", "<table", "<meta", "<style"]
            .contains { trimmed.contains($0) }
    }

    /// 整封拉取回落路径：服务器不返回 BODYSTRUCTURE 时使用，仍受字节上限约束。
    private static func fetchWholeMessage(
        session: AsyncImapSession,
        uid: UInt32,
        maxBytes: Int,
        reason: String
    ) async throws -> RemoteMessageBody {
        HubLogger.shared.warning("Mail body fetch fell back to the whole message (\(reason)) for UID \(uid)")
        guard maxBytes > 0, maxBytes < Int.max else { throw MailExportError.tooLarge }
        let maps: [ImapFetchBodyMap]
        do {
            maps = try await session.uidFetchBodySections(
                UniqueIdSet([UniqueId(id: uid)]),
                items: ImapFetchBody.section(nil, peek: true, partial: ImapFetchPartial(start: 0, length: maxBytes + 1))
            )
        } catch {
            throw Self.failure(error, stage: .fetchBody, folderPath: nil)
        }
        guard let bytes = maps.first?.body(), !bytes.isEmpty else {
            throw MailProtocolError.invalidResponse("Empty body for UID \(uid).")
        }
        guard bytes.count <= maxBytes else {
            throw MailProtocolError.messageTooLarge(
                "UID \(uid) is \(bytes.count) bytes (limit \(maxBytes))."
            )
        }

        // Preserve the original alongside local part IDs. A server that omits
        // BODYSTRUCTURE cannot later provide a validated server section ID.
        let original = Data(bytes)
        let parsed = try MailSmtpAdapter.localBody(original)
        let bodies = Self.normalizedBodies(text: parsed.textBody, html: parsed.htmlBody)
        let blankLine = Self.range(of: [0x0D, 0x0A, 0x0D, 0x0A], in: bytes)
        let headerBlock = blankLine.map { Array(bytes[0..<$0.lowerBound]) } ?? bytes
        return RemoteMessageBody(
            textBody: bodies.text,
            htmlBody: bodies.html,
            references: Self.threadReferences(references: Self.headerValue("references", in: headerBlock), inReplyTo: Self.headerValue("in-reply-to", in: headerBlock)),
            attachments: parsed.attachments,
            rawMessage: original
        )
    }

    private static func parseMessage(_ bytes: [UInt8]) throws -> MimeMessage {
        do {
            let parser = try MimeParser(MemoryStream(bytes))
            return try parser.parseMessage()
        } catch {
            throw MailProtocolError.invalidResponse(error.localizedDescription)
        }
    }

    private static func storeFlags(
        session: AsyncImapSession,
        uid: UInt32,
        add: [MailFlag],
        remove: [MailFlag]
    ) async throws {
        let set = UniqueIdSet([UniqueId(id: uid)])
        do {
            if !add.isEmpty {
                _ = try await session.uidStore(set, data: "+FLAGS.SILENT (\(Self.flagList(add)))")
            }
            if !remove.isEmpty {
                _ = try await session.uidStore(set, data: "-FLAGS.SILENT (\(Self.flagList(remove)))")
            }
        } catch {
            throw Self.failure(error, stage: .storeFlags, folderPath: nil)
        }
    }

    /// 按需选中文件夹：IMAP 同时只能选中一个邮箱，路径未变化时跳过 SELECT。
    /// `selectedPath` 缓存保存**原始路径**，只在 `SELECT` 成功后更新。
    private func ensureSelected(_ path: String) async throws {
        guard let session else { throw MailProtocolError.notConnected }
        guard selectedPath != path else { return }
        do {
            _ = try await session.select(mailbox: Self.sessionMailbox(from: path))
        } catch {
            throw Self.failure(error, stage: .select, folderPath: path)
        }
        selectedPath = path
    }

    // MARK: - Path / Failure Mapping

    /// 落库原始路径 → 会话层邮箱名（解码为 Unicode）。
    ///
    /// 落库路径是 `LIST` 返回的原始字节名（Modified UTF-7 可能仍编码，如 `&XfJT0ZAB-`）；
    /// `AsyncImapSession` 的公开方法接收 **Unicode** 名并自行按需编码（见
    /// `AsyncImapClient.encodeMailboxNameForWire`）。直接把已编码路径传下去会被二次编码，
    /// 中文等非 ASCII 文件夹必然失败。ASCII 名（如 `INBOX`）解码后不变。
    static func sessionMailbox(from storedPath: String) -> String {
        ImapMailboxEncoding.decode(storedPath)
    }

    /// 文件夹展示名（末段，解码后）；用于诊断上下文，不泄露完整原始路径。
    static func displayFolderName(_ path: String) -> String {
        let decoded = ImapMailboxEncoding.decode(path)
        let last = decoded.split(whereSeparator: { $0 == "/" || $0 == "." }).last
        return last.map(String.init) ?? decoded
    }

    /// 把底层错误集中映射为项目自有诊断，替换各处只取 `localizedDescription` 的处理。
    ///
    /// 规则：
    /// - `CancellationError` 原样上抛（取消不是服务器异常）；
    /// - 已是项目自有错误（`MailProtocolError` / `MailServerDiagnostic`）保留原错误；
    /// - `SessionError.imapError` 带 `NO`/`BAD` → 服务器拒绝；
    /// - `SessionError.imapError` 其余状态（含 `OK` 但无有效数据）→ 响应不可解读；
    /// - 超时、连接关闭、会话状态分别保留对应语义。
    static func failure(_ error: Error, stage: MailOperationStage, folderPath: String?) -> Error {
        if error is CancellationError { return error }
        if let diagnostic = error as? MailServerDiagnostic { return diagnostic }
        if let protocolError = error as? MailProtocolError {
            // 超时等自有语义保持（`MailDeadline` 抛出的 timedOut 属于此类）
            return protocolError
        }
        let folder = folderPath.map(displayFolderName)
        guard let sessionError = error as? SessionError else {
            return MailServerDiagnostic(
                stage: stage,
                status: nil,
                detail: sanitized(error.localizedDescription),
                kind: .transport,
                folder: folder
            )
        }
        switch sessionError {
        case .timeout:
            return MailServerDiagnostic(
                stage: stage, status: nil, detail: "session timeout", kind: .timedOut, folder: folder
            )
        case .connectionClosed(let message):
            return MailServerDiagnostic(
                stage: stage, status: nil, detail: sanitized(message), kind: .connectionClosed, folder: folder
            )
        case .invalidImapState(let expected, let actual):
            return MailServerDiagnostic(
                stage: stage,
                status: nil,
                detail: "invalid state \(String(describing: actual)) (expected \(String(describing: expected)))",
                kind: .invalidState,
                folder: folder
            )
        case .imapError(let status, let text):
            let rejected = status == .no || status == .bad
            return MailServerDiagnostic(
                stage: stage,
                status: status?.rawValue,
                detail: sanitized(text),
                kind: rejected ? .serverRejected : .malformedResponse,
                folder: folder
            )
        default:
            // 其余会话错误（如未授权、命令不支持）：保留可读说明，归为响应不可解读
            return MailServerDiagnostic(
                stage: stage,
                status: nil,
                detail: sanitized(String(describing: sessionError)),
                kind: .malformedResponse,
                folder: folder
            )
        }
    }

    /// 服务器说明脱敏：折叠空白、限长，不保留换行与超长响应。
    static func sanitized(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }

    /// 将 FETCH 摘要映射为协议层 DTO；无有效 UID 的条目丢弃。
    private static func remoteSummary(from summary: MessageSummary) -> RemoteMessageSummary? {
        guard let uid = summary.uniqueId?.id, uid != 0 else { return nil }
        let envelope = summary.envelope
        return RemoteMessageSummary(
            uid: uid,
            messageId: envelope?.messageId,
            subject: MailHeaderText.decoded(envelope?.subject ?? ""),
            from: addresses(from: envelope?.from ?? []),
            replyTo: addresses(from: envelope?.replyTo ?? []),
            to: addresses(from: envelope?.to ?? []),
            cc: addresses(from: envelope?.cc ?? []),
            date: envelope?.date ?? parseInternalDate(summary.internalDate),
            isRead: summary.flags.contains(.seen),
            isStarred: summary.flags.contains(.flagged),
            sizeBytes: summary.size ?? 0,
            snippet: summary.previewText ?? "",
            references: Self.threadReferences(references: nil, inReplyTo: envelope?.inReplyTo)
        )
    }

    /// 展开信封地址（群组地址展开为其成员）。
    private static func addresses(from list: [ImapAddress]) -> [MailAddress] {
        list.flatMap { item -> [MailAddress] in
            switch item {
            case .mailbox(let box):
                return mailboxAddress(box).map { [$0] } ?? []
            case .group(let group):
                return group.members.compactMap { mailboxAddress($0) }
            }
        }
    }

    private static func mailboxAddress(_ box: ImapMailboxAddress) -> MailAddress? {
        guard let address = box.address, !address.isEmpty else { return nil }
        // 显示名同样是原始 ENVELOPE 值，含编码字时在此解码
        return MailAddress(name: MailHeaderText.decoded(box.name ?? ""), address: address)
    }

    /// 部分服务器不带 ENVELOPE date，回落到 INTERNALDATE（IMAP date-time 格式）。
    private static func parseInternalDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }

    /// STORE 使用的系统标记字面量；SEARCH 必须使用独立的搜索关键字。
    private static func flagList(_ flags: [MailFlag]) -> String {
        flags.map { flag in
            switch flag {
            case .seen: return "\\Seen"
            case .flagged: return "\\Flagged"
            case .deleted: return "\\Deleted"
            }
        }.joined(separator: " ")
    }

    /// 取路径最后一段作为展示名。
    private static func lastComponent(_ path: String, delimiter: String?) -> String {
        guard let delimiter, !delimiter.isEmpty else { return path }
        return path.components(separatedBy: delimiter).last ?? path
    }

    /// 依据服务器 special-use 标记推断角色，缺失时按常见命名回落。
    private static func role(for box: ImapMailbox) -> MailFolderRole {
        if let special = box.specialUse {
            switch special {
            case .inbox: return .inbox
            case .sent: return .sent
            case .drafts: return .drafts
            case .trash: return .trash
            case .junk: return .junk
            case .archive: return .archive
            default: break
            }
        }
        let name = box.decodedName.uppercased()
        let folderName: String
        if let delimiter = box.delimiter, !delimiter.isEmpty, name.hasPrefix("INBOX" + delimiter) {
            folderName = String(name.dropFirst(5 + delimiter.count))
        } else { folderName = name }
        switch folderName {
        case "SENT", "SENT ITEMS", "SENT MESSAGES", "已发送", "已发送邮件", "已傳送", "寄件備份": return .sent
        case "DRAFTS", "草稿", "草稿箱", "草稿匣": return .drafts
        default: break
        }
        switch name {
        case "INBOX": return .inbox
        case "TRASH", "DELETED", "已删除", "垃圾箱": return .trash
        case "JUNK", "SPAM", "垃圾邮件": return .junk
        case "ARCHIVE", "归档": return .archive
        default: return .other
        }
    }
}

// MARK: - SMTP Adapter

/// `MailSendClient` 的 MailFoundation 实现（SMTP 发信）。
///
/// 与 IMAP 适配器同处一文件，以维持「MailFoundation 只在此文件被 import」的约定。
///
/// 隐式 TLS 通过网络组件的 startSecure 在读取 SMTP 欢迎信息前启用；
/// STARTTLS 沿用连接后升级路径。两条路径都验证证书，不自动降级。
/// 草稿 APPEND 使用本地会话补丁；已发送副本仍由 MailSyncService 保存到本地。
public actor MailSmtpAdapter: MailSendClient {
    private let host: String
    private let port: Int
    private let security: MailSecurity
    /// EHLO 声明的本机域名（部分服务器要求非空）。
    private let domain: String
    private var connection: SMTPConnection?
    private let implicitTLSChannel: (any MailImplicitTLSChannel)?

    public init(host: String, port: Int, security: MailSecurity, domain: String = "agroom.local") {
        self.host = host
        self.port = port
        self.security = security
        self.domain = domain
        self.implicitTLSChannel = nil
    }

    /// Internal byte-channel injection verifies TLS ordering without real credentials or delivery.
    init(host: String, port: Int, security: MailSecurity, implicitTLSChannel: any MailImplicitTLSChannel) {
        self.host = host
        self.port = port
        self.security = security
        self.domain = "agroom.local"
        self.implicitTLSChannel = implicitTLSChannel
    }

    public func connect() async throws {
        try MailServerConfiguration.validate(port: port, security: security, protocolKind: .smtp)
        let connection = try SMTPConnection.make(host: host, port: UInt16(port), security: security,
                                                 implicitTLSChannel: implicitTLSChannel)
        self.connection = connection
        do {
            try await connection.open(security: security, domain: domain)
            guard self.connection?.id == connection.id else { throw CancellationError() }
        } catch {
            if self.connection?.id == connection.id { self.connection = nil }
            await connection.close()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error is MailProtocolError { throw error }
            throw MailProtocolError.connectionFailed(error.localizedDescription)
        }
    }

    public func authenticate(username: String, password: String) async throws {
        guard let transport = connection?.smtp else { throw MailProtocolError.notConnected }
        let mechanisms = await transport.authMechanisms
        guard let authentication = SmtpSasl.chooseAuthentication(
            username: username,
            password: password,
            mechanisms: Array(mechanisms),
            host: host
        ) else {
            throw MailProtocolError.authenticationFailed("Server advertises no supported SASL mechanism.")
        }
        do {
            _ = try await transport.authenticate(authentication)
        } catch {
            throw MailProtocolError.authenticationFailed(error.localizedDescription)
        }
    }

    public func send(_ message: OutgoingMail) async throws {
        guard let transport = connection?.smtp else { throw MailProtocolError.notConnected }
        let mime: MimeMessage
        do { mime = try Self.mimeMessage(from: message) }
        catch { throw MailProtocolError.sendFailed("The message could not be encoded before SMTP DATA.") }
        let sender = MailboxAddress(
            name: message.from.name.isEmpty ? nil : message.from.name,
            address: message.from.address
        )
        let recipients = message.recipients.map {
            MailboxAddress(name: $0.name.isEmpty ? nil : $0.name, address: $0.address)
        }
        do {
            // 显式传信封地址：Bcc 只进信封、不进报文头部，避免泄漏盲抄地址
            _ = try await transport.sendMessage(mime, sender: sender, recipients: recipients)
        } catch {
            throw Self.sendError(from: error)
        }
    }

    /// SMTP 投递失败 → 协议错误；关键是区分**确定未投递**与**结果未知**。
    ///
    /// 只有服务器对 `MAIL FROM` / `RCPT TO` / `DATA` 给出明确拒收（`SmtpCommandError`
    /// 的 `senderNotAccepted` / `recipientNotAccepted` / `messageNotAccepted`）才能确定
    /// 邮件没有被收下，可以安全重试 → `sendFailed`。
    ///
    /// 其余情况（连接中断、超时、`unexpectedStatusCode`、序列化失败等）都无法排除
    /// 「服务器已经收下 DATA 但回执没回来」→ `sendResultUnknown`，禁止上层按普通失败
    /// 引导重试（会造成重复投递，见 `MailSyncService.send`）。
    static func sendError(from error: Error) -> MailProtocolError {
        guard let command = error as? SmtpCommandError else {
            return .sendResultUnknown(error.localizedDescription)
        }
        switch command.errorCode {
        case .senderNotAccepted, .recipientNotAccepted, .messageNotAccepted:
            return .sendFailed(command.message)
        case .unexpectedStatusCode:
            return .sendResultUnknown(command.message)
        }
    }

    public func disconnect() async {
        let connection = self.connection
        self.connection = nil
        await connection?.close()
    }

    // MARK: - MIME Building

    /// Generated local copies are explicitly distinguished from received originals.
    static func serializedMessage(_ message: OutgoingMail, date: Date) throws -> Data {
        if let existing = message.serializedData { return existing }
        let mime = try mimeMessage(from: message)
        mime.date = DateTimeOffset(date: date, offsetMinutes: 0)
        let stream = MemoryStream()
        try mime.writeTo(stream)
        return Data(stream.toByteArray())
    }

    static func serializedDraft(_ draft: MailDraft, account: MailAccount, messageID: String, date: Date) throws -> Data {
        guard (draft.to + draft.cc + draft.bcc).allSatisfy(\.isValid) else { throw MailServerDraftError.invalid }
        let mime = try mimeMessage(from: .init(from: .init(name: account.displayName, address: account.emailAddress),
            to: draft.to, cc: draft.cc, subject: draft.subject, bodyText: draft.assembledBody,
            htmlBody: try draft.formattedHTML(),
            inReplyTo: draft.inReplyTo, references: draft.references, messageId: messageID, attachments: draft.attachments))
        // Bcc belongs in a private server draft, but SMTP serialization above
        // continues to omit this header and takes Bcc only from the envelope.
        if !draft.bcc.isEmpty { mime.headers[.bcc] = addressHeader(draft.bcc) }
        mime.date = DateTimeOffset(date: date, offsetMinutes: 0)
        let stream = MemoryStream(); try mime.writeTo(stream)
        let data = Data(stream.toByteArray())
        guard !data.isEmpty, data.count <= MailService.rawMessageByteLimit else { throw MailServerDraftError.capacity }
        return data
    }

    static func decodedDraft(_ data: Data, id: UUID, accountID: UUID) throws -> MailDraft {
        guard !data.isEmpty, data.count <= MailService.rawMessageByteLimit else { throw MailServerDraftError.capacity }
        var options = ParserOptions(); options.maxMimeDepth = 64
        let mime = try MimeParser(options, MemoryStream(Array(data))).parseMessage()
        func addresses(_ list: InternetAddressList) -> [MailAddress] { list.mailboxes.map { .init(name: $0.name ?? "", address: $0.address) } }
        var attachments: [MailDraftAttachment] = []
        for (index, part) in localParts(mime).enumerated() {
            let name = localFilename(part), type = part.contentType.mimeType
            attachments.append(.init(filename: MailExportDestination.safeName(name), mimeType: type,
                data: try localAttachment(data, index: index, filename: name, mimeType: type)))
            try MailDraftAttachment.validate(attachments)
        }
        guard let text = mime.textBody ?? MailAIContextService.htmlToText(mime.htmlBody) else { throw MailServerDraftError.invalid }
        return .init(id: id, accountId: accountID, to: addresses(mime.to), cc: addresses(mime.cc), bcc: addresses(mime.bcc),
            subject: mime.subject ?? "", bodyText: text, inReplyTo: mime.headers[.inReplyTo], references: mime.headers[.references],
            attachments: attachments, forwardAttachmentsState: .omitted)
    }

    /// Text alternatives belong together inside the attachment container.
    private static func mimeMessage(from message: OutgoingMail) throws -> MimeMessage {
        try MailDraftAttachment.validate(message.attachments)
        if let raw = message.serializedData {
            guard raw.count <= MailService.rawMessageByteLimit else { throw MailAttachmentError.capacity }
            return try MimeParser(MemoryStream(Array(raw))).parseMessage()
        }
        let mime = MimeMessage()
        mime.headers[.mimeVersion] = "1.0"
        mime.headers[.from] = addressHeader([message.from])
        if !message.to.isEmpty { mime.headers[.to] = addressHeader(message.to) }
        if !message.cc.isEmpty { mime.headers[.cc] = addressHeader(message.cc) }
        if !message.subject.isEmpty { mime.headers[.subject] = message.subject }
        if let inReplyTo = message.inReplyTo { mime.headers[.inReplyTo] = inReplyTo }
        if let references = message.references { mime.headers[.references] = references }
        // 显式写 Message-ID：否则由 MIME/SMTP 层另行生成，凭证里的 ID 与收件方收到的对不上
        if let messageId = message.messageId { mime.headers[.messageId] = messageId }

        func textPart(_ subtype: String, _ text: String) -> TextPart {
            let part = TextPart(subtype, text)
            // Keep UTF-8 text intact on 7-bit relays and wrap long body or HTML lines.
            part.contentTransferEncoding = text.utf8.allSatisfy { $0 < 128 } ? .quotedPrintable : .base64
            return part
        }
        let body: MimeEntity
        let plain = textPart("plain", message.bodyText)
        if let html = message.htmlBody {
            let alternative = MultipartAlternative()
            try alternative.add(plain)
            try alternative.add(textPart("html", html))
            body = alternative
        } else { body = plain }
        if message.attachments.isEmpty { mime.body = body }
        else {
            let mixed = try Multipart("mixed")
            try mixed.add(body)
            for attachment in message.attachments {
                let part = try MimePart(attachment.mimeType)
                part.isAttachment = true; part.fileName = attachment.filename
                part.content = try MimeContent(stream: MemoryStream(Array(attachment.data)))
                part.contentTransferEncoding = .base64
                try mixed.add(part)
            }
            mime.body = mixed
        }
        return mime
    }

    static func localAttachment(_ data: Data, index: Int, filename: String, mimeType: String) throws -> Data {
        guard data.count <= MailService.rawMessageByteLimit, index >= 0 else { throw MailAttachmentError.corrupt }
        var options = ParserOptions(); options.maxMimeDepth = 64
        let message = try MimeParser(options, MemoryStream(Array(data))).parseMessage()
        let parts = localParts(message)
        guard index < parts.count else { throw MailAttachmentError.corrupt }
        let part = parts[index]
        guard localFilename(part) == filename, part.contentType.mimeType.caseInsensitiveCompare(mimeType) == .orderedSame else { throw MailAttachmentError.corrupt }
        let output = MemoryStream()
        if let file = part as? MimePart, let content = file.content { try content.decodeTo(output) }
        else if let nested = part as? MessagePart, let message = nested.message { try message.writeTo(output) }
        else { throw MailAttachmentError.corrupt }
        guard output.length <= MailDraftAttachment.maximumFileBytes else { throw MailAttachmentError.capacity }
        return Data(output.toByteArray())
    }

    static func localBody(_ data: Data) throws -> RemoteMessageBody {
        guard data.count <= MailService.rawMessageByteLimit else { throw MailAttachmentError.capacity }
        var options = ParserOptions(); options.maxMimeDepth = 64
        let message = try MimeParser(options, MemoryStream(Array(data))).parseMessage()
        return RemoteMessageBody(textBody: message.textBody, htmlBody: message.htmlBody,
            references: MailFoundationAdapter.threadReferences(references: message.headers[.references], inReplyTo: message.headers[.inReplyTo]), attachments: localParts(message).enumerated().map { index, entity in
                RemoteAttachment(filename: localFilename(entity), mimeType: entity.contentType.mimeType,
                    sizeBytes: 0, contentId: entity.contentId, isInline: !(entity.contentDisposition?.isAttachment ?? false), partID: "local:\(index)")
            })
    }

    private static func localParts(_ message: MimeMessage) -> [MimeEntity] {
        message.bodyParts.filter {
            ($0.contentDisposition?.isAttachment ?? false) || $0.contentId != nil
                || (($0 as? MimePart)?.fileName != nil) || $0 is MessagePart
                || ($0.contentType.mediaType.caseInsensitiveCompare("image") == .orderedSame
                    && $0.contentDisposition?.disposition.caseInsensitiveCompare("inline") == .orderedSame)
        }
    }

    private static func localFilename(_ entity: MimeEntity) -> String {
        (entity as? MimePart)?.fileName ?? entity.contentDisposition?.fileName
            ?? (entity is MessagePart ? "message.eml" : "attachment")
    }

    private static func addressHeader(_ addresses: [MailAddress]) -> String {
        addresses.map(\.composeText).joined(separator: ", ")
    }
}
// MARK: - Verified implicit TLS channel

/// The channel has no plaintext start operation, making TLS fallback impossible on SMTPS.
protocol MailImplicitTLSChannel: Sendable {
    var incoming: AsyncStream<[UInt8]> { get }
    func startSecure(validateCertificate: Bool) async throws
    func send(_ bytes: [UInt8]) async throws
    func stop() async
}

extension NetworkTransport: MailImplicitTLSChannel {}

private actor SMTPImplicitTLSTransport: AsyncTransport {
    nonisolated let incoming: AsyncStream<[UInt8]>
    private let channel: any MailImplicitTLSChannel
    init(channel: any MailImplicitTLSChannel) {
        self.channel = channel
        self.incoming = channel.incoming
    }
    func start() async throws { try await channel.startSecure(validateCertificate: true) }
    func send(_ bytes: [UInt8]) async throws { try await channel.send(bytes) }
    func stop() async { await channel.stop() }
}

private struct SMTPConnection: Sendable {
    let id = UUID()
    let smtp: AsyncSmtpTransport
    let network: any AsyncTransport

    static func make(host: String, port: UInt16, security: MailSecurity,
                     implicitTLSChannel: (any MailImplicitTLSChannel)?) throws -> SMTPConnection {
        let network: any AsyncTransport
        if security == .tls {
            network = SMTPImplicitTLSTransport(channel: implicitTLSChannel ?? NetworkTransport(host: host, port: port))
        } else {
            network = try AsyncTransportFactory.make(host: host, port: port, backend: .network)
        }
        return SMTPConnection(smtp: AsyncSmtpTransport(transport: network), network: network)
    }

    func open(security: MailSecurity, domain: String) async throws {
        try await withTaskCancellationHandler {
            guard let greeting = try await smtp.connect(), greeting.code == 220 else {
                throw MailProtocolError.invalidResponse("The SMTP server did not provide a valid 220 greeting.")
            }
            guard try await smtp.ehlo(domain: domain) != nil else {
                throw MailProtocolError.invalidResponse("The SMTP server did not answer EHLO.")
            }
            if security == .startTLS {
                _ = try await smtp.startTls(validateCertificate: true)
                guard try await smtp.ehlo(domain: domain) != nil else {
                    throw MailProtocolError.invalidResponse("The SMTP server did not answer EHLO after TLS.")
                }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await network.stop() } }
    }

    func close() async {
        // Closing the raw channel wakes pending reads even while connect/EHLO is in progress.
        await network.stop()
        await smtp.disconnect()
    }
}
