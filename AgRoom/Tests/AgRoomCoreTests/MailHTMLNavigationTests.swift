import Foundation
import AppKit
import Testing
import WebKit
import SwiftUI
import GRDB
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("HTML mail navigation boundary")
struct MailHTMLNavigationTests {
    @MainActor @Test("Native body find works with JavaScript disabled and refreshes its result for the next query")
    func nativeBodyFind() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 320), configuration: configuration)
        let coordinator = MailHTMLView.Coordinator()
        web.navigationDelegate = coordinator
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web
        defer { coordinator.invalidateFind(); window.close() }
        var found: Bool?
        coordinator.load(document: "<html><head><title>find-ready</title></head><body>First needle. Second NEEDLE.</body></html>", in: web)
        coordinator.find("needle", request: UUID(), backwards: false, in: web, onResult: { found = $0 })
        for _ in 0..<200 where found == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(found == true && web.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        found = nil
        coordinator.find("absent-word", request: UUID(), backwards: false, in: web, onResult: { found = $0 })
        for _ in 0..<200 where found == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(found == false)
        found = nil
        coordinator.find("needle", request: UUID(), backwards: true, in: web, onResult: { found = $0 })
        for _ in 0..<200 where found == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(found == true)
    }
    @MainActor
    @Test("The complete mailbox hosts native multi-selection and renders its controls",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeMailWorkflow() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let account = MailAccount(displayName: "合成工作邮箱", emailAddress: "reader@example.test",
            imapHost: "imap.example.test", smtpHost: "smtp.example.test", username: "reader@example.test")
        try await MailAccountService(databaseQueue: queue, space: .work).save(account, password: nil)
        let mail = MailService(databaseQueue: queue)
        let inbox = MailFolder(accountId: account.id, path: "INBOX", name: "Inbox", role: .inbox)
        try await mail.upsertFolders([inbox,
            .init(accountId: account.id, path: "Trash", name: "Trash", role: .trash),
            .init(accountId: account.id, path: "Archive", name: "Archive", role: .archive)])
        let messages = (1...10).map { index in
            MailMessage(accountId: account.id, folderId: inbox.id, uid: UInt32(index),
                subject: "项目评审与交付安排 \(index)", fromName: "产品设计团队", fromAddress: "design@example.test",
                to: [.init(name: "Reader", address: "reader@example.test")],
                date: Date(timeIntervalSince1970: Double(index)), isRead: index.isMultiple(of: 2),
                snippet: "合成邮件，用于检查多选、菜单与文件夹操作。", bodyState: .ready)
        }
        for message in messages { _ = try await mail.saveLocalMessage(message) }
        for message in messages { try await mail.saveBody(.init(messageId: message.id, textBody: "Synthetic message body.")) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let model = MailViewModel(hub: hub, space: .work)
        await model.loadIfNeeded()
        let host = NSHostingView(rootView: MailView(hub: hub, viewModel: model).frame(width: 1100, height: 680)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { model.cancelPendingWork(); window.close() }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        let list = try #require(tables(in: host).first { $0.numberOfRows == messages.count })
        list.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.selectedMessageIDs == Set(model.messages.prefix(2).map(\.id)))
        #expect(model.selectedMessageId == nil && model.body == nil)
        let point = list.convert(NSPoint(x: 30, y: list.rect(ofRow: 0).midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try #require(list.menu(for: event))
        menu.update()
        #expect(menu.items.contains { $0.title == L.format("mail.action.affectedCount", L.string("mail.action.markRead"), 1) })
        #expect(!menu.items.contains { $0.title == L.string("mail.action.reply") })
        #expect(model.selectedMessageIDs.count == 2 && model.body == nil)
        let outsidePoint = list.convert(NSPoint(x: 30, y: list.rect(ofRow: 3).midY), to: nil)
        let outsideEvent = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: outsidePoint, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        let outsideMenu = try #require(list.menu(for: outsideEvent)); outsideMenu.update()
        #expect(outsideMenu.items.contains { $0.title == L.string("mail.action.replyAll") })
        #expect(model.selectedMessageIDs.count == 2 && model.body == nil)
        let markIndex = try #require(outsideMenu.items.firstIndex { $0.title == L.string("mail.action.markRead") })
        let targetID = model.messages[3].id, unaffectedID = model.messages[1].id
        outsideMenu.performActionForItem(at: markIndex)
        for _ in 0..<30 where model.batchResult == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.batchResult?.succeeded == [targetID])
        #expect(try await mail.message(id: targetID)?.isRead == true)
        #expect(try await mail.message(id: unaffectedID)?.isRead == false)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("mail-workflow-multiple.png"), options: .atomic)
    }
    @Test("only the initial blank document can load inside the mail WebView")
    func initialDocument() {
        let blank = URL(string: "about:blank")
        #expect(MailHTMLNavigationDecision.decide(url: blank, navigationType: .other,
            isMainFrame: true, initialDocumentPending: true) == .allowInitialDocument)
        #expect(MailHTMLNavigationDecision.decide(url: blank, navigationType: .other,
            isMainFrame: true, initialDocumentPending: false) == .cancel)
        #expect(MailHTMLNavigationDecision.decide(url: blank, navigationType: .linkActivated,
            isMainFrame: true, initialDocumentPending: true) == .cancel)
        #expect(MailHTMLNavigationDecision.decide(url: blank, navigationType: .other,
            isMainFrame: false, initialDocumentPending: true) == .cancel)
    }

    @Test("user-clicked web links open externally; automatic navigation does not")
    func links() {
        let secure = URL(string: "https://example.com/path?q=1#part")!
        let plain = URL(string: "http://example.com/")!
        #expect(MailHTMLNavigationDecision.decide(url: secure, navigationType: .linkActivated,
            isMainFrame: true, initialDocumentPending: false) == .openExternally(secure))
        #expect(MailHTMLNavigationDecision.decide(url: plain, navigationType: .linkActivated,
            isMainFrame: true, initialDocumentPending: false) == .openExternally(plain))
        #expect(MailHTMLNavigationDecision.decide(url: secure, navigationType: .other,
            isMainFrame: true, initialDocumentPending: true) == .cancel)
        #expect(MailHTMLNavigationDecision.decide(url: secure, navigationType: .formSubmitted,
            isMainFrame: true, initialDocumentPending: false) == .cancel)
        #expect(MailHTMLNavigationDecision.decide(url: secure, navigationType: .linkActivated,
            isMainFrame: false, initialDocumentPending: false) == .cancel)
    }

    @Test("unsafe and credential-bearing links are denied")
    func rejectedSchemes() {
        for raw in ["javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd",
                    "mailto:user@example.com", "https://user:secret@example.com/"] {
            #expect(MailHTMLNavigationDecision.decide(url: URL(string: raw), navigationType: .linkActivated,
                isMainFrame: true, initialDocumentPending: false) == .cancel)
        }
        #expect(MailHTMLNavigationDecision.decide(url: nil, navigationType: .linkActivated,
            isMainFrame: true, initialDocumentPending: false) == .cancel)
    }

    @MainActor
    @Test("fast message replacement renders the newest HTML and ignores meta refresh")
    func liveWebViewBoundary() async throws {
        _ = NSApplication.shared
        let coordinator = MailHTMLView.Coordinator(openExternal: { _ in
            Issue.record("An automatic navigation must not open the browser")
        })
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.navigationDelegate = coordinator
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }

        coordinator.load(document: "<html><head><title>first</title></head><body>first</body></html>", in: webView)
        coordinator.load(document: "<html><head><title>second</title></head><body>second</body></html>", in: webView)
        #expect(try await waitForTitle("second", in: webView))

        coordinator.load(document: """
            <html><head><title>safe</title>
            <meta http-equiv="refresh" content="0;url=data:text/html,%3Ctitle%3Eescaped%3C/title%3E">
            </head><body>safe</body></html>
            """, in: webView)
        #expect(try await waitForTitle("safe", in: webView))
        try await Task.sleep(for: .milliseconds(300))
        #expect(webView.title == "safe")
        #expect(webView.url?.absoluteString == "about:blank")
    }

    @MainActor
    @Test("a user-clicked web-link policy opens externally and cancels in-view navigation")
    func externalHandoff() {
        let link = URL(string: "https://example.com/read?q=1")!
        var opened: URL?
        let coordinator = MailHTMLView.Coordinator(openExternal: { opened = $0 })
        let decision = MailHTMLNavigationDecision.decide(url: link, navigationType: .linkActivated,
            isMainFrame: true, initialDocumentPending: false)
        #expect(coordinator.policy(for: decision) == .cancel)
        #expect(opened == link)
    }

    @MainActor
    private func waitForTitle(_ expected: String, in webView: WKWebView) async throws -> Bool {
        for _ in 0..<100 {
            if webView.title == expected { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

@Suite("Mail native layout snapshots", .serialized)
struct MailNativeLayoutSnapshots {
    @MainActor
    @Test("Signatures, server draft confirmation and Finder preparation render in all three languages",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func composeEnhancementLayouts() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        let f = try await MailServerDraftTests().fixture()
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: f.queue))
        let signature = MailComposePreset(kind: .signature, name: "项目联络 / Project contact", body: "合成签名 Synthetic signature\n项目组 · Project team")
        var presets = MailComposePresets(); presets.items = [signature]; presets.defaultSignatures[f.account.id.uuidString] = signature.id
        _ = try await f.mail.saveComposePresets(presets, replacing: .init())
        let review = try await f.service.reviewSave(f.draft)
        let message = MailMessage(accountId: f.account.id, folderId: f.folder.id, uid: 1,
            messageId: "<drag-layout@example.test>", subject: "合成邮件 / Synthetic message")
        try await f.mail.upsertMessages([message])
        try await f.mail.saveRawMessage(id: message.id, raw: .init(data: Data("Message-ID: <drag-layout@example.test>\r\nSubject: Layout\r\n\r\nSynthetic mail body\r\n".utf8), kind: .received))
        let previousLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previousLanguage }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            let manager = MailComposePresetManager(hub: hub, space: .work)
            try await captureEnhancement("mail-presets-\(language.rawValue)", content: MailComposePresetManagerView(model: manager),
                width: 700, height: 620, directory: directory, prepare: { manager.select(signature.id) })
            manager.close()
            let composer = MailComposeViewModel(draft: f.draft, space: .work, hub: hub, fromDescription: f.account.emailAddress, isAIPanelVisible: false)
            try await captureEnhancement("mail-server-draft-\(language.rawValue)", content: MailComposeView(viewModel: composer),
                width: 900, height: 720, directory: directory, prepare: { composer.serverSaveReview = review }, sheet: true)
            composer.serverSaveReview = nil; composer.onWindowClosed()
            let drag = MailFinderDragModel(message: message, hub: hub, space: .work)
            try await captureEnhancement("mail-finder-\(language.rawValue)", content: MailFinderDragView(model: drag),
                width: 560, height: 300, directory: directory)
            #expect(drag.error == nil)
            drag.close()
        }
    }

    @MainActor
    private func captureEnhancement<Content: View>(_ name: String, content: Content, width: Double, height: Double,
        directory: URL, prepare: @MainActor () -> Void = {}, sheet: Bool = false) async throws {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        if sheet { window.orderFront(nil) }
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        prepare()
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let rendered: NSView
        if sheet { rendered = try #require(window.attachedSheet?.contentView) }
        else { rendered = host }
        #expect(rendered.bounds.width >= 500 && rendered.bounds.height >= 280)
        let bitmap = try #require(rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds))
        rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
        // The compositor normally supplies the window background. A view-only
        // cache (especially a sheet) leaves it transparent, hiding black text
        // in viewers that use a black canvas. Capture that actual background.
        let context = try #require(CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: bitmap.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        context.setFillColor((NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .white).cgColor); context.fill(rect)
        context.draw(try #require(bitmap.cgImage), in: rect)
        let complete = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        try #require(complete.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
    @MainActor
    @Test("HTML author backgrounds remain intact in light and dark reading layouts",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func authorStyles() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        _ = NSApplication.shared
        let message = MailMessage(accountId: UUID(), folderId: UUID(), uid: 1,
            subject: "Synthetic author-style message", fromAddress: "author@example.com", bodyState: .ready)
        let variants: [(name: String, html: String, color: NSColor)] = [
            ("deep", "<div style='background:#14233c;color:#fff;padding:24px;min-height:100px'>White text on an author-supplied deep background</div>",
                NSColor(red: 20 / 255, green: 35 / 255, blue: 60 / 255, alpha: 1)),
            ("custom", "<div style='background:#f2cf45;color:#123456;padding:24px;min-height:100px'>Author-supplied yellow background and dark text</div>",
                NSColor(red: 242 / 255, green: 207 / 255, blue: 69 / 255, alpha: 1)),
            ("full-body", "<!DOCTYPE html><html><head><style>body { background: #27566b; color: #fff; } p { padding: 24px; }</style></head><body><p>Full HTML mail with an author-supplied body background</p></body></html>",
                NSColor(red: 39 / 255, green: 86 / 255, blue: 107 / 255, alpha: 1))
        ]
        for variant in variants {
            let body = MailBody(messageId: message.id, htmlBody: variant.html)
            for dark in [false, true] {
                for width in [480.0, 760.0] {
                    let content = MailMessageDetailView(message: message, mailBody: body, attachments: [],
                        downloadingAttachments: [], onDownload: { _ in nil }, onRetryBody: {}, isLoadingBody: false,
                        moveTargets: [], onToggleRead: { _ in }, onToggleStar: { _ in }, onReply: { _ in },
                        onAIReply: { _ in }, onForward: { _ in }, onDelete: { _ in }, onMove: { _, _ in })
                        .frame(width: width, height: 500)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: content)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.close() }
                    var bitmap: NSBitmapImageRep?
                    var matchingPixels = 0
                    for _ in 0..<20 {
                        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                        if Self.webView(in: host) != nil { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let webView = try #require(Self.webView(in: host))
                    for _ in 0..<20 {
                        if let captured = try? await webView.takeSnapshot(configuration: nil),
                           let data = captured.tiffRepresentation,
                           let image = NSBitmapImageRep(data: data) {
                            bitmap = image
                            matchingPixels = Self.countColor(variant.color, in: image)
                            if matchingPixels > 100 { break }
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let final = try #require(bitmap)
                    let png = try #require(final.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent("mail-html-web-\(variant.name)-\(Int(width))-\(dark ? "dark" : "light").png"),
                        options: .atomic)
                    if let native = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: native)
                        if let nativePNG = native.representation(using: .png, properties: [:]) {
                            try nativePNG.write(to: directory.appendingPathComponent("mail-html-frame-\(variant.name)-\(Int(width))-\(dark ? "dark" : "light").png"),
                                options: .atomic)
                        }
                    }
                    #expect(matchingPixels > 100, "The authored background must survive the reading layout")
                }
            }
        }
    }

    @MainActor
    private static func webView(in root: NSView) -> WKWebView? {
        if let webView = root as? WKWebView { return webView }
        for child in root.subviews {
            if let webView = Self.webView(in: child) { return webView }
        }
        return nil
    }

    private static func countColor(_ target: NSColor, in image: NSBitmapImageRep) -> Int {
        let color = target.usingColorSpace(.deviceRGB)!
        var matches = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                guard let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(pixel.redComponent - color.redComponent) < 0.08,
                   abs(pixel.greenComponent - color.greenComponent) < 0.08,
                   abs(pixel.blueComponent - color.blueComponent) < 0.08 { matches += 1 }
            }
        }
        return matches
    }

    @MainActor
    @Test("mail list and detail render at narrow and wide widths in three languages and both appearances",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"] != nil))
    func nativeLayouts() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_MAIL_SNAPSHOT_DIR"]))
        _ = NSApplication.shared
        let account = UUID(), folder = UUID()
        let featured = MailMessage(accountId: account, folderId: folder, uid: 1,
            subject: "下周产品评审：跨团队协作、数据核对与交付时间安排 / Product review and delivery plan",
            fromName: "产品与设计协作团队 Product Design Team", fromAddress: "design@example.com",
            to: [.init(name: "测试收件人", address: "reader@example.com")],
            cc: [.init(name: "项目协调人", address: "coord@example.com")],
            date: Date(timeIntervalSince1970: 1_780_000_000), isRead: false, isStarred: true,
            hasAttachments: true,
            snippet: "请核对附件中的决策记录与时间表，并在周五前反馈。Please review the attached notes and proposed schedule.",
            bodyState: .ready)
        let older = MailMessage(accountId: account, folderId: folder, uid: 2,
            subject: "Earlier update with a long subject to check truncation at narrow widths",
            fromName: "Alex Example", fromAddress: "alex@example.com",
            date: Date(timeIntervalSince1970: 1_779_900_000), isRead: true,
            snippet: "A shorter preview from an already read message.")
        let noSubject = MailMessage(accountId: account, folderId: folder, uid: 3,
            fromAddress: "sender@example.com", date: Date(timeIntervalSince1970: 1_779_800_000),
            isRead: false, snippet: "No subject line uses the localized fallback.")
        let body = MailBody(messageId: featured.id, htmlBody: "<p>合成邮件正文。This is synthetic mail content for layout review.</p>")
        let attachments = [MailAttachment(messageId: featured.id,
            filename: "跨团队评审与交付安排 - product-review-notes.pdf", mimeType: "application/pdf", sizeBytes: 2_048_000)]
        let previousLanguage = LanguageManager.shared.currentLanguage
        let previousLarge = InterfaceTypographyPreferences.shared.isLarge
        defer {
            LanguageManager.shared.currentLanguage = previousLanguage
            InterfaceTypographyPreferences.shared.isLarge = previousLarge
        }

        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for large in [false, true] {
                InterfaceTypographyPreferences.shared.isLarge = large
                for width in [760.0, 1100.0] {
                    let listWidth = width == 760 ? 280.0 : 340.0
                    let content = HStack(spacing: 0) {
                        MailMessageListView(messages: [featured, older, noSubject], selectedMessageIDs: [featured.id],
                            hasMore: true, isLoadingMore: false, onSelect: { _ in }, onToggleStar: { _ in }, onLoadMore: {})
                            .frame(width: listWidth)
                        Divider()
                        MailMessageDetailView(message: featured, mailBody: body, attachments: attachments,
                            downloadingAttachments: [], onDownload: { _ in nil }, onRetryBody: {}, isLoadingBody: false,
                            moveTargets: [], onToggleRead: { _ in }, onToggleStar: { _ in }, onReply: { _ in },
                            onAIReply: { _ in }, onForward: { _ in }, onDelete: { _ in }, onMove: { _, _ in })
                    }
                    .font(MeetTypography.control)
                    .frame(width: width, height: 620)
                    .background(Color(nsColor: .windowBackgroundColor))
                    for dark in [false, true] {
                        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620),
                            styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = host
                        defer { window.close() }
                        for _ in 0..<15 {
                            host.layoutSubtreeIfNeeded()
                            window.displayIfNeeded()
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        #expect(abs(host.frame.width - width) < 0.5)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: directory.appendingPathComponent("mail-\(language.rawValue)-\(large ? "large" : "standard")-\(Int(width))-\(dark ? "dark" : "light").png"),
                            options: .atomic)
                    }
                }
            }
        }
    }
}
