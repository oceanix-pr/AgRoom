import AppKit
import WebKit
import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Product experience")
struct ProductExperienceTests {
    @Test("Browser extraction never writes into a space selected while JavaScript is pending")
    @MainActor
    func browserKnowledgeSaveIsSpaceBound() async throws {
        let personalQueue = try DatabaseQueue()
        let workQueue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(personalQueue)
        try DatabaseBootstrap.prepareSpace(workQueue)
        let personal = KnowledgeService(databaseQueue: personalQueue)
        let work = KnowledgeService(databaseQueue: workQueue)
        let services: [AppSpace: KnowledgeService] = [.personal: personal, .work: work]
        var currentSpace = AppSpace.personal

        let discarded = try await BrowserKnowledgeSaveOperation.run(
            originSpace: .personal,
            source: "https://example.com/private",
            isCurrent: { currentSpace == .personal },
            title: { "Private page" },
            body: {
                currentSpace = .work
                await Task.yield()
                return "Private page body"
            },
            service: { services[$0] }
        )
        if case .discarded = discarded {} else { Issue.record("A switched space must discard the extraction") }
        #expect(try await personal.getAll().isEmpty)
        #expect(try await work.getAll().isEmpty)

        let saved = try await BrowserKnowledgeSaveOperation.run(
            originSpace: .personal,
            source: "https://example.com/private",
            isCurrent: { currentSpace == .personal },
            title: { "Private page" },
            body: { "Private page body" },
            service: { services[$0] }
        )
        if case .discarded = saved {} else { Issue.record("This call must still be discarded while work is selected") }

        currentSpace = .personal
        let accepted = try await BrowserKnowledgeSaveOperation.run(
            originSpace: .personal,
            source: "https://example.com/private",
            isCurrent: { currentSpace == .personal },
            title: { "Private page" },
            body: { "Private page body" },
            service: { services[$0] }
        )
        if case .saved = accepted {} else { Issue.record("The original space should accept a completed extraction") }
        #expect(try await personal.getAll().count == 1)
        #expect(try await work.getAll().isEmpty)
    }

    @Test("An OCR result cannot be saved into the space selected after capture")
    @MainActor
    func ocrKnowledgeSaveIsSpaceBound() async throws {
        let personalQueue = try DatabaseQueue()
        let workQueue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(personalQueue)
        try DatabaseBootstrap.prepareSpace(workQueue)
        let personal = KnowledgeService(databaseQueue: personalQueue)
        let work = KnowledgeService(databaseQueue: workQueue)
        let item = KnowledgeItem(title: "Private OCR", content: "Private image text", kind: .document, tags: ["ocr"])
        var currentSpace = AppSpace.work

        _ = try await ImageKnowledgeSaveOperation.run(item: item, originSpace: .personal,
            isCurrent: { currentSpace == .personal }, service: personal)
        #expect(try await personal.getAll().isEmpty)
        #expect(try await work.getAll().isEmpty)

        currentSpace = .personal
        _ = try await ImageKnowledgeSaveOperation.run(item: item, originSpace: .personal,
            isCurrent: { currentSpace == .personal }, service: personal)
        #expect(try await personal.getAll().map(\.id) == [item.id])
        #expect(try await work.getAll().isEmpty)
    }

    @Test("A skill generated before a space switch cannot install or replace files afterward")
    @MainActor
    func skillGenerationWriteIsSpaceBound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-skill-write-gate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = SkillStore(directoryURL: root.appendingPathComponent("personal/skills"))
        let work = SkillStore(directoryURL: root.appendingPathComponent("work/skills"))
        var currentSpace = AppSpace.work

        #expect(throws: CancellationError.self) {
            try SkillGenerationWriteGate.perform(originSpace: .personal, currentSpace: { currentSpace }) {
                try personal.save(Skill(name: "private-skill", description: "Private", content: "Private instructions"))
            }
        }
        #expect(try personal.list().isEmpty)
        #expect(try work.list().isEmpty)

        currentSpace = .personal
        try SkillGenerationWriteGate.perform(originSpace: .personal, currentSpace: { currentSpace }) {
            try personal.save(Skill(name: "private-skill", description: "Private", content: "Private instructions"))
        }
        #expect(try personal.list().map(\.name) == ["private-skill"])
        #expect(try work.list().isEmpty)
    }

    @Test("AI polish cannot overwrite a same-named skill after a space switch")
    @MainActor
    func skillPolishIsSpaceBound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-skill-polish-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = SkillStore(directoryURL: root.appendingPathComponent("personal/skills"))
        let work = SkillStore(directoryURL: root.appendingPathComponent("work/skills"))
        try personal.save(Skill(name: "shared-skill", description: "Personal", content: "Personal instructions"))
        try work.save(Skill(name: "shared-skill", description: "Work", content: "Work instructions"))
        let personalBefore = try personal.readFile(name: "shared-skill", relativePath: "SKILL.md")
        let workBefore = try work.readFile(name: "shared-skill", relativePath: "SKILL.md")
        var currentSpace = AppSpace.work

        #expect(throws: CancellationError.self) {
            try SkillPolishSheet.applyPolishedContent("Polished personal instructions", to: personal,
                skillName: "shared-skill", path: "SKILL.md", originSpace: .personal,
                currentSpace: { currentSpace })
        }
        #expect(try personal.readFile(name: "shared-skill", relativePath: "SKILL.md") == personalBefore)
        #expect(try work.readFile(name: "shared-skill", relativePath: "SKILL.md") == workBefore)
        #expect(try personal.listVersions(name: "shared-skill").isEmpty)

        currentSpace = .personal
        try SkillPolishSheet.applyPolishedContent("Polished personal instructions", to: personal,
            skillName: "shared-skill", path: "SKILL.md", originSpace: .personal,
            currentSpace: { currentSpace })
        #expect(try personal.readFile(name: "shared-skill", relativePath: "SKILL.md") == "Polished personal instructions")
        #expect(try work.readFile(name: "shared-skill", relativePath: "SKILL.md") == workBefore)
        #expect(try personal.listVersions(name: "shared-skill").count == 1)
    }

    @Test("Old messages and memories remain decodable")
    func legacyPayloads() throws {
        let memory = MemoryItem(content: "A preference")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) as? [String: Any])
        object.removeValue(forKey: "sourceSessionID")
        object.removeValue(forKey: "sourceMessageID")
        let decoded = try JSONDecoder().decode(MemoryItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.sourceSessionID == nil)
        let message = ChatMessage(role: .assistant, content: "Old reply")
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(restored.runStatus == nil && restored.contextReport == nil)
    }

    @Test("Sources survive edits and disabled memories stay disabled")
    func memoryProvenance() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = MemoryService(databaseQueue: queue)
        var memory = MemoryItem(content: "Incorrect preference", isEnabled: false)
        memory.sourceSessionID = UUID()
        memory.sourceMessageID = UUID()
        try await service.save(memory)
        try await service.updateContent(id: memory.id, content: "Corrected preference", category: .preference)
        let fetched = try #require(await service.fetch(id: memory.id))
        #expect(fetched.sourceSessionID == memory.sourceSessionID)
        #expect(fetched.sourceMessageID == memory.sourceMessageID)
        #expect(!fetched.isEnabled && fetched.content == "Corrected preference")
        try await service.delete(id: memory.id)
        try await service.updateContent(id: memory.id, content: "Must not resurrect", category: .other)
        #expect(try await service.fetch(id: memory.id) == nil)
    }

    @Test("Only actual file receipts become artifacts, including delegated receipts")
    func artifactReceipts() {
        #expect(TaskArtifact.from(toolName: "shell_run", result: "Written 1 characters to /tmp/a.txt") == nil)
        #expect(TaskArtifact.from(toolName: "files_write", result: "Here is /tmp/a.txt") == nil)
        #expect(TaskArtifact.from(toolName: "files_write", result: "Written 1 characters to /tmp/a.txt\nInjected") == nil)
        let trace = DispatcherTraceEntry(toolName: "files_write", argumentsPreview: "", resultPreview: "", resultFull: "Written 2 characters to /tmp/a 2.txt", duration: 0, succeeded: true)
        #expect(trace.artifact?.path == "/tmp/a 2.txt")
        #expect(trace.withToolName("writer / files_write").artifact == trace.artifact)
        let failed = DispatcherTraceEntry(toolName: "files_write", argumentsPreview: "", resultPreview: "Written 2 characters to /tmp/a.txt", duration: 0, succeeded: false)
        #expect(failed.artifact == nil)
    }

    @Test("Knowledge sources preserve entry and passage identity")
    func knowledgeSources() throws {
        let id = UUID()
        let citations = KnowledgeCitation.from(result: "[Plan] (entry: \(id), passage: 3, character offset: 42)\nExcerpt")
        #expect(citations.count == 1)
        #expect(citations.first?.itemID == id)
        #expect(citations.first?.offset == 42)
        #expect(KnowledgeCitation.from(result: "[Plan] (entry: invalid, passage: 3, character offset: 42)").isEmpty)
    }

    @Test("Context and run state survive message persistence and failed replies")
    func taskPersistence() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = SessionService(databaseQueue: queue)
        var report = RequestContextReport()
        report.includedHistory = [UUID()]
        report.omittedHistory = [UUID()]
        report.omittedImages = ["unreadable.png"]
        report.memoryContents = ["A preference at request time"]
        var session = ChatSession(title: "Task")
        let message = ChatMessage(role: .assistant, content: "Partial output", runStatus: .running, contextReport: report)
        session.messages = [message]
        try await service.save(session)
        let loaded = try #require(await service.latestMessage(id: session.id))
        #expect(loaded.contextReport == report)
        let error = loaded.appendingError("Network unavailable")
        #expect(error.runStatus == .failed && error.contextReport == report)
        #expect(error.id == loaded.id)
    }

    @Test("Autosave cannot erase delivery evidence or overwrite a newer draft")
    func protectedAutosave() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        var draft = MailDraft(accountId: UUID(), to: [], subject: "Latest", bodyText: "Keep")
        draft.updatedAt = Date(timeIntervalSince1970: 200)
        try await mail.saveEditableDraft(draft)
        var old = draft
        old.subject = "Stale"
        old.updatedAt = Date(timeIntervalSince1970: 100)
        try await mail.saveEditableDraft(old)
        #expect(try await mail.draft(id: draft.id)?.subject == "Latest")
        draft.deliveryState = .unknown
        try await mail.saveDraft(draft)
        await #expect(throws: MailSyncError.self) { try await mail.saveEditableDraft(old) }
        #expect(try await mail.draft(id: draft.id)?.deliveryState == .unknown)
    }

    @Test("Attachment decoding honors transfer encoding and rejects oversized payloads")
    func attachmentDecoding() throws {
        let decoded = try MailFoundationAdapter.decodeAttachment(bytes: Array("aGVsbG8=".utf8), encoding: "base64", maxBytes: 100)
        #expect(String(data: decoded, encoding: .utf8) == "hello")
        #expect(throws: MailProtocolError.self) {
            try MailFoundationAdapter.decodeAttachment(bytes: Array(repeating: 1, count: 101), encoding: "binary", maxBytes: 100)
        }
        #expect(throws: MailProtocolError.self) {
            try MailFoundationAdapter.decodeAttachment(bytes: [], encoding: "base64\r\nInjected: yes", maxBytes: 100)
        }
    }

    @MainActor @Test("Mail system folders keep their order when inbox subfolders appear")
    func mailFolderOrdering() {
        let accountId = UUID()
        let folders = [
            MailFolder(accountId: accountId, path: "A-Notifications", name: "Notifications"),
            MailFolder(accountId: accountId, path: "Archive", name: "Archive", role: .archive),
            MailFolder(accountId: accountId, path: "Drafts", name: "Drafts", role: .drafts),
            MailFolder(accountId: accountId, path: "INBOX", name: "Inbox", role: .inbox),
            MailFolder(accountId: accountId, path: "Junk", name: "Junk", role: .junk),
            MailFolder(accountId: accountId, path: "Sent", name: "Sent", role: .sent),
            MailFolder(accountId: accountId, path: "Trash", name: "Trash", role: .trash),
            MailFolder(accountId: accountId, path: "Virus Items", name: "Virus Items")
        ]
        let expected = ["INBOX", "Drafts", "Sent", "Archive", "Junk", "Trash", "A-Notifications", "Virus Items"]
        let flat = MailViewModel.FolderNode.tree(from: folders)
        #expect(flat.map(\.folder.path) == expected)
        #expect(flat.allSatisfy { $0.children == nil })

        let child = MailFolder(accountId: accountId, path: "INBOX/EFGP", name: "EFGP", parentPath: "INBOX")
        let tree = MailViewModel.FolderNode.tree(from: folders + [child])
        #expect(tree.map(\.folder.path) == expected)
        #expect(tree.first?.children?.map(\.id) == [child.id])
    }

    @MainActor @Test("Mail hierarchy keeps containers and orphan folders with natural sibling ordering")
    func mailFolderHierarchy() throws {
        let accountId = UUID()
        let container = MailFolder(accountId: accountId, path: "Projects", name: "Projects", isContainer: true)
        let second = MailFolder(accountId: accountId, path: "Projects/2", name: "Project 2", parentPath: "Projects")
        let tenth = MailFolder(accountId: accountId, path: "Projects/10", name: "Project 10", parentPath: "Projects")
        let nestedSent = MailFolder(accountId: accountId, path: "Projects/ZSent", name: "Sent", role: .sent, parentPath: "Projects")
        let grandchild = MailFolder(accountId: accountId, path: "Projects/2/Notes", name: "Notes", parentPath: second.path)
        let orphan = MailFolder(accountId: accountId, path: "Missing/Notes", name: "Notes", parentPath: "Missing")
        let folders = [tenth, grandchild, container, orphan, nestedSent, second]
        let tree = MailViewModel.FolderNode.tree(from: folders)
        #expect(tree.map(\.id) == [orphan.id, container.id])
        let node = try #require(tree.first { $0.id == container.id })
        #expect(node.isContainer)
        #expect(node.children?.map(\.id) == [nestedSent.id, second.id, tenth.id])
        #expect(node.children?.first { $0.id == second.id }?.children?.map(\.id) == [grandchild.id])
    }

    @Test("Common recipient addresses validate without accepting malformed or injected text")
    func addresses() {
        #expect(MailAddress(name: "A", address: "a+b@example.com").isValid)
        for address in ["plain text", "@example.com", "a@", "a@@example.com", "a@-host.com", "a@host..com", "a\r\nBcc:b@host.com"] {
            #expect(!MailAddress(name: "", address: address).isValid)
        }
    }

    @Test("Scoped job histories are physically separated")
    func scopedJobs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = JobCenter(historyFileURL: directory.appendingPathComponent("JobHistory.json"))
        let snapshots = center.stream()
        let first = center.submit(name: "Personal export", kind: "test", space: .personal, origin: "settings") { $0.reportResultURL(URL(fileURLWithPath: "/tmp/personal.zip")) }
        let second = center.submit(name: "Work export", kind: "test", space: .work, origin: "settings") { $0.reportResultURL(URL(fileURLWithPath: "/tmp/work.zip")) }
        for await jobs in snapshots {
            if jobs.first(where: { $0.id == first })?.state == .succeeded && jobs.first(where: { $0.id == second })?.state == .succeeded { break }
        }
        let personal = try String(contentsOf: directory.appendingPathComponent("personal/JobHistory.json"), encoding: .utf8)
        let work = try String(contentsOf: directory.appendingPathComponent("work/JobHistory.json"), encoding: .utf8)
        #expect(personal.contains("Personal export") && !personal.contains("Work export"))
        #expect(work.contains("Work export") && !work.contains("Personal export"))
        let reloaded = JobCenter(historyFileURL: directory.appendingPathComponent("JobHistory.json"))
        #expect(reloaded.history().count == 2)
    }

    @Test("Selected attachment downloads safely and subsequent previews use the cache")
    func attachmentDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let accounts = MailAccountService(databaseQueue: queue, space: .personal)
        let mail = MailService(databaseQueue: queue)
        let account = MailAccount(displayName: "Test", emailAddress: "a@example.com", imapHost: "imap.example.com", smtpHost: "smtp.example.com", username: "a@example.com")
        try await accounts.save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox")
        try await mail.upsertFolders([folder])
        let message = MailMessage(accountId: account.id, folderId: folder.id, uid: 8)
        try await mail.upsertMessages([message])
        let attachment = MailAttachment(messageId: message.id, filename: "../../report.txt", sizeBytes: 16, partID: "2")
        try await mail.saveAttachments([attachment])
        let client = MockMailClient()
        let service = MailSyncService(accountService: accounts, mail: mail, space: .personal, coordinator: MailAccountCoordinator(), attachmentDirectory: directory, clientFactory: { _ in client }, passwordProvider: { _ in "test" })
        let first = try await service.downloadAttachment(messageId: message.id, attachmentID: attachment.id)
        #expect(first.lastPathComponent == "report.txt")
        #expect(FileAreaService.isInside(first, root: directory))
        #expect(try String(contentsOf: first, encoding: .utf8) == "attachment bytes")
        let second = try await service.downloadAttachment(messageId: message.id, attachmentID: attachment.id)
        #expect(first == second)
        #expect(await client.attachmentDownloadCount == 1)
        #expect(try await mail.attachments(messageId: message.id).first?.localPath == first.path)
    }

    @Test("Abandonment is space-bound and retains uncertain operation evidence")
    func abandonRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DaemonHandoffStore(baseDirectory: directory)
        let snapshot = EngineRunSnapshot(messages: [], thoughts: [], trace: [], stepsUsed: 1, totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0, callFingerprintCounts: [:], consecutiveFailedRounds: 0, restrictedToolNames: nil, activeSkillWorkspace: nil, loopNoticeInjected: false, preApprovedTools: [])
        let settings = DaemonRunSettings(maxTokens: 100, temperature: 0, reasoningEffortRaw: nil, maxSteps: 3, replyLanguageInstruction: "English", personaInstruction: nil, workspacePath: "")
        let record = DaemonRunRecord(space: .work, sessionId: UUID(), assistantMessageId: UUID(), state: .recoveryRequired(reason: "unknown operation"), snapshot: snapshot, settings: settings)
        #expect(store.writeRecord(record))
        let journal = OperationJournal(directory: store.runDirectory(id: record.id, origin: .space(record.space)))
        #expect(journal.recordIntent(operationID: "send", toolName: "mail_send", argumentDigest: "redacted"))
        #expect(!store.abandonRecovery(id: record.id, space: .personal))
        #expect(store.abandonRecovery(id: record.id, space: .work))
        #expect(!store.records(in: .work).contains {
            if case .recoveryRequired = $0.record.state { return true }
            return false
        })
        #expect(OperationJournal(directory: store.runDirectory(id: record.id, origin: .space(record.space))).unresolvedOperationIDs() == ["send"])
        #expect(!store.abandonRecovery(id: record.id, space: .work))
    }

    @MainActor @Test("Copied conversations remap context identities without crossing branches")
    func contextBranchIdentity() throws {
        let question = ChatMessage(role: .user, content: "Requirement")
        var report = RequestContextReport()
        report.includedHistory = [question.id]
        var source = ChatSession()
        source.messages = [question, ChatMessage(role: .assistant, content: "Answer", contextReport: report)]
        let branch = try #require(source.branch(titleSuffix: " branch"))
        #expect(branch.messages[1].contextReport?.includedHistory == [branch.messages[0].id])
        #expect(source.messages[1].contextReport?.includedHistory == [question.id])
    }

    @MainActor @Test("Confirmation summaries explain side effects")
    func confirmationText() {
        let text = ConfirmationSummary.text(tool: "files_write", arguments: #"{"path":"/tmp/report.md","content":"ABC"}"#, preview: nil)
        #expect(text.contains("/tmp/report.md"))
        #expect(!text.contains("ABC"))
    }

    @MainActor @Test("Agent tool names keep nested steps but display the agent nickname")
    func agentToolDisplayText() {
        let names = ["agent_xuanxue_master": "玄武大师"]
        func displayName(_ toolName: String) -> String? { names[toolName] }

        // 直接委派：昵称替换 ASCII slug
        #expect(ChatView.agentDisplayText("agent_xuanxue_master", displayName: displayName) == "玄武大师")
        // 模型里的工具名由 name 生成、昵称只用于展示：两者对得上才真正显示昵称
        let agent = Agent(name: "xuanxue master", nickname: "玄武大师")
        #expect(ChatView.agentDisplayText(agent.toolName, displayName: { $0 == agent.toolName ? agent.displayName : nil }) == "玄武大师")
        // 进度转发与挂起链：保留内层工具后缀
        #expect(ChatView.agentDisplayText("agent_xuanxue_master > skill_load", displayName: displayName) == "玄武大师 > skill_load")
        #expect(ChatView.agentDisplayText("agent_xuanxue_master → ask_user", displayName: displayName) == "玄武大师 → ask_user")
        // 未注入/未命中/空白昵称：回退 slug，旧轨迹与已删除智体仍可读
        #expect(ChatView.agentDisplayText("agent_xuanxue_master > skill_load") == "xuanxue master > skill_load")
        #expect(ChatView.agentDisplayText("agent_xuanxue_master", displayName: { _ in "  " }) == "xuanxue master")
        #expect(ChatView.agentDisplayText("skill_load", displayName: displayName) == "skill_load")
        #expect(ChatView.agentToolBaseName("agent_xuanxue_master > skill_load") == "agent_xuanxue_master")
        #expect(ChatView.agentToolBaseName("skill_load") == nil)
    }
}

@Suite("Browser page correctness", .serialized)
struct BrowserPageCorrectnessTests {
    @MainActor
    @Test("Page reuse preserves query, fragment, scheme and port identity")
    func fullURLIdentity() throws {
        let original = try #require(URL(string: "https://example.test/record?id=1"))
        #expect(BrowserService.samePage(original, original))
        for raw in ["https://example.test/record?id=2", "https://example.test/record?id=1#details",
                    "http://example.test/record?id=1", "https://example.test:8443/record?id=1"] {
            let candidate = try #require(URL(string: raw))
            #expect(!BrowserService.samePage(original, candidate))
        }
    }

    @MainActor
    @Test("Navigation invalidates approval and a loaded page is never evicted to meet the tab budget")
    func snapshotAndRetention() async throws {
        let service = BrowserService(space: .work, dataStore: .nonPersistent())
        let tab = service.addTab()
        tab.recordRead()
        try tab.validateSnapshot()
        let snapshotVersion = try #require(tab.readSnapshotVersion)
        let key = "browser-page#\(tab.id.uuidString)#\(snapshotVersion.uuidString)"
        try tab.validateSnapshot(authorizationKey: key)
        tab.invalidateSnapshot()
        #expect(throws: (any Error).self) { try tab.validateSnapshot(authorizationKey: key) }
        #expect(BrowserInteractionSnapshotCache.shared.snapshot(tabID: tab.id, space: .work) == nil)
        // Reserve an active operation before exceeding the budget; it must survive.
        tab.operationCount = 1
        for _ in 0..<(BrowserService.maxRetainedTabs + 2) { _ = service.addTab() }
        #expect(service.lookupTab(id: tab.id) === tab)
        service.closeTab(tab)
        #expect(service.lookupTab(id: tab.id) == nil)
    }

    @MainActor
    @Test("Real page read redacts secrets and refuses a replaced element")
    func realPageReadAndStaleTarget() async throws {
        _ = NSApplication.shared
        let service = BrowserService(space: .personal, dataStore: .nonPersistent())
        let tab = service.addTab()
        tab.webView.loadHTMLString("""
            <html><body><input id="password" type="password" value="SYNTHETIC_SECRET">
            <input id="otp" name="otp" value="SYNTHETIC_OTP"><button id="target">Continue</button>
            </body></html>
            """, baseURL: URL(string: "https://fixture.test"))
        let deadline = Date().addingTimeInterval(15)
        while tab.webView.title == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if !tab.webView.isLoading, tab.webView.url != nil { break }
        }
        let read = try await service.readPage(tabId: tab.id)
        #expect(!read.contains("SYNTHETIC_SECRET"))
        #expect(!read.contains("SYNTHETIC_OTP"))
        #expect(read.contains("[redacted]"))
        let exposedSnapshot = try await tab.webView.evaluateJavaScript("typeof window.__ahReadElements")
        #expect(exposedSnapshot as? String == "undefined")
        let modalSupport = try await tab.webView.evaluateJavaScript("typeof window.showModalDialog")
        #expect(modalSupport as? String == "undefined")
        for _ in 0..<(BrowserService.maxRetainedTabs + 2) { _ = service.addTab() }
        #expect(service.lookupTab(id: tab.id) === tab)

        let raw = try await tab.webView.evaluateJavaScript("document.getElementById('target').getAttribute('data-ah-id')")
        let elementText = try #require(raw as? String)
        let elementID = try #require(Int(elementText))
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('target').outerHTML = '<button>Delete</button>'")
        await #expect(throws: (any Error).self) {
            try await service.clickElement(tabId: tab.id, elementId: elementID)
        }
    }
}
