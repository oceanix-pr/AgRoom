import Foundation
import GRDB
import Testing
import AppKit
import SwiftUI
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Outgoing mail attachments")
struct MailOutgoingAttachmentTests {
    private struct Fixture {
        let queue: DatabaseQueue
        let mail: MailService
        let account: MailAccount
        let inbox: MailFolder
        let sync: MailSyncService
        let mock: MockMailClient
        let sender: MockSendClient
        let root: URL
    }
    private func fixture(sent: Bool = true) async throws -> Fixture {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), accounts = MailAccountService(databaseQueue: queue, space: .work)
        let account = MailAccount(displayName: "Synthetic", emailAddress: "reader@example.test", imapHost: "imap.example.test",
            smtpHost: "smtp.example.test", username: "reader@example.test")
        try await accounts.save(account, password: nil)
        let inbox = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        try await mail.upsertFolders([inbox] + (sent ? [.init(accountId: account.id, path: "Sent", name: "Sent", role: .sent)] : []))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let mock = MockMailClient(), sender = MockSendClient()
        let sync = MailSyncService(accountService: accounts, mail: mail, space: .work, attachmentDirectory: root,
            clientFactory: { _ in mock }, sendClientFactory: { _ in sender }, passwordProvider: { _ in "fixture" })
        return .init(queue: queue, mail: mail, account: account, inbox: inbox, sync: sync, mock: mock, sender: sender, root: root)
    }

    private var attachment: MailDraftAttachment {
        .init(filename: "评审 notes.bin", mimeType: "application/octet-stream", data: Data([0, 255, 13, 10, 20, 0]))
    }

    @Test("Binary MIME round trips Unicode filenames without exposing Bcc")
    func mimeRoundTrip() throws {
        let item = attachment
        let message = OutgoingMail(from: .init(name: "Reader", address: "reader@example.test"),
            to: [.init(name: "Peer", address: "peer@example.test")], bcc: [.init(name: "Hidden", address: "hidden@example.test")],
            subject: "Attachment fixture", bodyText: "Body", messageId: "<attachment@example.test>", attachments: [item])
        let data = try MailSmtpAdapter.serializedMessage(message, date: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try MailSmtpAdapter.localAttachment(data, index: 0, filename: item.filename, mimeType: item.mimeType) == item.data)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("MIME-Version: 1.0") && text.contains("base64"))
        #expect(!text.contains("hidden@example.test"))
        #expect(try MailSmtpAdapter.localBody(data).textBody?.contains("Body") == true)
    }

    @Test("Draft blobs and forward selection survive backup and reject corrupt attachment data")
    func persistenceAndBackup() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = MailDraft(accountId: f.account.id, subject: "Draft", composeKind: .forward,
            attachments: [attachment], forwardAttachmentsState: .loaded)
        try await f.mail.saveEditableDraft(draft)
        let read = try #require(try await f.mail.draft(id: draft.id))
        #expect(read.attachments == draft.attachments && read.forwardAttachmentsState == .loaded)
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let restored = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restored)
        let store = SpaceDatabaseBackupStore(queue: restored, space: "work")
        let plan = try await store.plan(backup, sourceSpace: "work")
        _ = try await store.apply(plan, willCommit: { _ in })
        #expect(try await MailService(databaseQueue: restored).draft(id: draft.id)?.attachments == draft.attachments)
        try await f.queue.write { db in try db.execute(sql: "UPDATE mail_drafts SET attachmentsData = ? WHERE id = ?", arguments: [Data("bad".utf8), draft.id.uuidString]) }
        await #expect(throws: MailAttachmentError.self) { try await f.mail.draft(id: draft.id) }
    }

    @MainActor @Test("Native formatting and named recipient chips survive draft, backup, server MIME and delivery")
    func formattedCompose() async throws {
        _ = NSApplication.shared
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let peer = MailAddress(name: "Yu, Lin", address: "peer@example.test")
        let draft = MailDraft(accountId: f.account.id, to: [peer], bodyText: "🐾 <Hi> there", quotedText: "> an & b",
                              attachments: [attachment])
        let model = MailComposeViewModel(draft: draft, space: .work, hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue)),
                                         fromDescription: f.account.emailAddress, isAIPanelVisible: false)
        #expect(model.parsedRecipients == [peer])
        model.toText += "；second@example.test，invalid"
        #expect(model.parsedRecipients.count == 3 && model.invalidRecipients.map(\.address) == ["invalid"])
        model.toText = peer.composeText
        let controls = MailBodyFormatControls()
        let host = NSHostingView(rootView: MailBodyEditor(model: model, controls: controls))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { model.onWindowClosed(); window.close() }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(controls.editor)
        let range = (draft.bodyText as NSString).range(of: "<Hi>")
        editor.setSelectedRange(range)
        controls.toggle(.bold); controls.toggle(.underline)
        #expect(model.bodyStyles == [.init(range: range, style: [.bold, .underline])])
        model.bodyText += "\n\n-- \n研发团队"
        #expect(await model.saveDraft())
        let saved = try #require(try await f.mail.draft(id: draft.id))
        #expect(saved.bodyStyles == model.bodyStyles && saved.to == [peer])
        let backup = try await SpaceDatabaseBackupStore(queue: f.queue, space: "work").export()
        let restored = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restored)
        let target = SpaceDatabaseBackupStore(queue: restored, space: "work")
        _ = try await target.apply(target.plan(backup, sourceSpace: "work"), willCommit: { _ in })
        #expect(try await MailService(databaseQueue: restored).draft(id: draft.id) == saved)
        let server = try MailSmtpAdapter.serializedDraft(saved, account: f.account, messageID: "<draft@example.test>", date: Date())
        #expect(try MailSmtpAdapter.localBody(server).htmlBody?.contains("<u><strong>&lt;Hi&gt;</strong></u>") == true)
        let sent = try #require(try await f.sync.send(draft: saved))
        let outgoing = try #require(await f.sender.sent.first)
        let wire = try MailSmtpAdapter.localBody(try #require(outgoing.serializedData))
        let plain = try #require(wire.textBody)
        let html = try #require(wire.htmlBody)
        #expect(plain.contains("🐾 <Hi> there"))
        #expect(plain.contains("研发团队") && html.contains("研发团队"))
        #expect(html.contains("&gt; an &amp; b"))
        #expect(try await f.mail.body(messageId: sent.id)?.htmlBody == outgoing.htmlBody)
        var invalid = saved
        invalid.bodyStyles = [.init(range: NSRange(location: 1, length: 1), style: .italic)]
        #expect(throws: MailFormattingError.self) { try invalid.formattedHTML() }
    }

    @Test("The new draft columns migrate idempotently and leave old drafts intact")
    func migration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = MailDraft(accountId: f.account.id, subject: "Old draft")
        try await f.mail.saveDraft(draft)
        try await f.queue.write { db in
            try db.execute(sql: "ALTER TABLE mail_drafts DROP COLUMN attachmentsData")
            try db.execute(sql: "ALTER TABLE mail_drafts DROP COLUMN forwardAttachmentsState")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v10_mail_draft_attachments'")
        }
        try DatabaseBootstrap.prepareSpace(f.queue); try DatabaseBootstrap.prepareSpace(f.queue)
        let restored = try #require(try await f.mail.draft(id: draft.id))
        #expect(restored.subject == draft.subject && restored.attachments.isEmpty)
    }

    @Test("SMTP receives the same bytes retained by the Sent copy, whose attachments and body reopen offline")
    func sendAndOfflineRead() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = MailDraft(accountId: f.account.id, to: [.init(name: "Peer", address: "peer@example.test")],
            subject: "With binary", bodyText: "Retained body", references: "<source@example.test>", attachments: [attachment])
        let sent = try #require(try await f.sync.send(draft: draft))
        let delivered = try #require(await f.sender.sent.first)
        #expect(delivered.attachments == draft.attachments)
        #expect(try await f.mail.rawMessage(id: sent.id)?.data == delivered.serializedData)
        #expect(try await f.mail.draft(id: draft.id) == nil)
        #expect(sent.hasAttachments && sent.references == draft.references)
        let part = try #require(try await f.mail.attachments(messageId: sent.id).first)
        let url = try await f.sync.downloadAttachment(messageId: sent.id, attachmentID: part.id)
        #expect(try Data(contentsOf: url) == attachment.data)
        try await f.queue.write { db in try db.execute(sql: "DELETE FROM mail_bodies WHERE messageId = ?", arguments: [sent.id.uuidString]) }
        #expect(try await f.sync.loadBody(messageId: sent.id).textBody?.contains("Retained body") == true)
        #expect(await f.mock.connectCount == 0)
        #expect(try await f.mail.attachments(messageId: sent.id).first?.id == part.id)
    }

    @Test("Unavailable Sent folders retain a locked delivered draft with all its attachments")
    func deliveredButNotArchived() async throws {
        let f = try await fixture(sent: false); defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = MailDraft(accountId: f.account.id, to: [.init(name: "Peer", address: "peer@example.test")], attachments: [attachment])
        await #expect(throws: MailDeliveredLocalSaveError.self) { try await f.sync.send(draft: draft) }
        let retained = try #require(try await f.mail.draft(id: draft.id))
        #expect(retained.deliveredAt != nil && retained.attachments == draft.attachments)
        await #expect(throws: (any Error).self) { try await f.sync.send(draft: draft) }
        #expect(await f.sender.sent.count == 1)
    }

    @Test("Metadata injection and unprepared forward attachments cannot reach SMTP")
    func invalidAttachmentsDoNotSend() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bad = MailDraftAttachment(filename: "bad\r\nBcc: other@example.test", mimeType: "application/octet-stream", data: Data())
        let draft = MailDraft(accountId: f.account.id, to: [.init(name: "Peer", address: "peer@example.test")], attachments: [bad])
        await #expect(throws: MailAttachmentError.self) { try await f.sync.send(draft: draft) }
        var forward = draft; forward.attachments = []; forward.composeKind = .forward
        await #expect(throws: MailAttachmentError.self) { try await f.sync.send(draft: forward) }
        #expect(await f.sender.sent.isEmpty)
    }

    @MainActor
    @Test("Compose copies selected bytes, restores a draft after the source file is removed, and honours cancellation")
    func composerOwnedBytes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let draft = MailDraft(accountId: f.account.id)
        let model = MailComposeViewModel(draft: draft, space: .work, hub: hub, fromDescription: "reader@example.test", isAIPanelVisible: false)
        let file = f.root.appendingPathComponent("selected.bin"); try attachment.data.write(to: file)
        model.addAttachmentFiles([file]); await wait(model)
        try FileManager.default.removeItem(at: file)
        #expect(model.attachments.first?.data == attachment.data)
        #expect(await model.saveDraft())
        let saved = try #require(try await f.mail.draft(id: draft.id))
        let reopened = MailComposeViewModel(draft: saved, space: .work, hub: hub, fromDescription: "reader@example.test", isAIPanelVisible: false)
        #expect(reopened.attachments == model.attachments)
        try Data("later".utf8).write(to: file)
        reopened.addAttachmentFiles([file]); reopened.cancelAttachmentLoading()
        try await Task.sleep(for: .milliseconds(30))
        #expect(reopened.attachments == saved.attachments)
        model.onWindowClosed(); reopened.onWindowClosed()
    }

    @MainActor
    @Test("Forward preparation carries all originals, a saved removal stays removed, and failed preparation requires an explicit omission")
    func forwardWorkflow() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = MailMessage(accountId: f.account.id, folderId: f.inbox.id, uid: 1, subject: "Original", hasAttachments: true, bodyState: .ready)
        try await f.mail.upsertMessages([source]); try await f.mail.saveBody(.init(messageId: source.id, textBody: "Original body"))
        let file = f.root.appendingPathComponent("original.bin"); try attachment.data.write(to: file)
        let part = MailAttachment(messageId: source.id, filename: "original.bin", mimeType: "application/octet-stream", sizeBytes: attachment.data.count, localPath: file.path)
        try await f.mail.saveAttachments([part])
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let model = MailComposeViewModel(draft: .init(accountId: f.account.id, quotedText: "Original body", composeKind: .forward, sourceMessageId: source.id),
            space: .work, hub: hub, fromDescription: "reader@example.test", isAIPanelVisible: false)
        model.makeAttachmentSyncService = { f.sync }; model.loadForwardAttachments(); await wait(model)
        #expect(model.forwardAttachmentsState == .loaded && model.attachments.first?.data == attachment.data)
        let selected = try #require(model.attachments.first)
        model.removeAttachment(selected.id); #expect(await model.saveDraft())
        let saved = try #require(try await f.mail.draft(id: model.draftID))
        let reopened = MailComposeViewModel(draft: saved, space: .work, hub: hub, fromDescription: "reader@example.test", isAIPanelVisible: false)
        reopened.makeAttachmentSyncService = { f.sync }; reopened.loadForwardAttachments()
        #expect(reopened.attachments.isEmpty && !reopened.attachmentsBlockSending)
        let failed = MailComposeViewModel(draft: .init(accountId: f.account.id, composeKind: .forward, sourceMessageId: UUID()),
            space: .work, hub: hub, fromDescription: "reader@example.test", isAIPanelVisible: false)
        failed.makeAttachmentSyncService = { f.sync }; failed.loadForwardAttachments(); await wait(failed)
        #expect(failed.attachmentError != nil && failed.attachmentsBlockSending)
        failed.omitForwardAttachments(); #expect(!failed.attachmentsBlockSending)
        #expect(await failed.saveDraft())
        #expect(try await f.mail.draft(id: failed.draftID)?.forwardAttachmentsState == .omitted)
        model.onWindowClosed(); reopened.onWindowClosed(); failed.onWindowClosed()
    }

    @MainActor private func wait(_ model: MailComposeViewModel) async {
        for _ in 0..<300 where model.isLoadingAttachments { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoadingAttachments)
    }

    @MainActor
    @Test("Compose attachments render in narrow and regular windows in all three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeComposeAttachmentLayouts() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for width in [640.0, 900.0] {
                let height = width == 640 ? 480.0 : 700.0
                let files = [attachment, MailDraftAttachment(filename: "跨团队评审与附件交付说明 - review-and-delivery-notes.txt", mimeType: "text/plain", data: Data("Notes".utf8))]
                let draft = MailDraft(accountId: f.account.id, to: [.init(name: "Peer", address: "peer@example.test")],
                    subject: "项目评审与交付安排 / Review and delivery", bodyText: "请核对附件。Please review the attached documents.", attachments: files)
                let model = MailComposeViewModel(draft: draft, space: .work, hub: hub, fromDescription: "reader@example.test", isAIPanelVisible: false)
                let host = NSHostingView(rootView: MailComposeView(viewModel: model).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                #expect(abs(host.frame.width - width) < 1 && abs(host.frame.height - height) < 1)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: root.appendingPathComponent("mail-compose-attachments-\(language.rawValue)-\(Int(width)).png"))
                model.onWindowClosed(); window.close()
            }
        }
    }
}
