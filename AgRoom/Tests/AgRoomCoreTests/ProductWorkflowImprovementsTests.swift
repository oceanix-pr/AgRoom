import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Existing product workflows")
@MainActor
struct ProductWorkflowImprovementsTests {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    @Test("An answer retains the actual cited excerpt after editing or deleting its source")
    func retainedCitation() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        var item = KnowledgeItem(title: "Quote", content: "Price: 800")
        try await service.save(item)
        let json = try JSONSerialization.data(withJSONObject: ["candidates": [[
            "item_id": item.id.uuidString, "title": item.title, "passage": 1,
            "offset": 0, "content": item.content
        ]]])
        let citation = try #require(KnowledgeCitation.from(result: String(decoding: json, as: UTF8.self)).first)
        let stored = try JSONDecoder().decode(KnowledgeCitation.self, from: JSONEncoder().encode(citation))
        item.content = "Price: 950"
        try await service.save(item)
        #expect(stored.excerpt == "Price: 800")
        #expect(try await service.get(id: item.id)?.content == "Price: 950")
        try await service.delete(id: item.id)
        #expect(try await service.get(id: item.id) == nil && stored.excerpt == "Price: 800")
        let legacy = "[Quote] (entry: \(item.id), passage: 1, character offset: 0)"
        #expect(KnowledgeCitation.from(result: legacy).first?.excerpt == nil)
    }

    @Test("Conversation titles occupy one result while message body hits and HTML mail stay searchable")
    func searchSources() async throws {
        let queue = try database()
        let search = SpaceSearchService(databaseQueue: queue, space: .work)
        var session = ChatSession(title: "Quarterly review")
        session.messages = (0..<60).map { ChatMessage(role: .user, content: "Progress \($0)") }
        try await SessionService(databaseQueue: queue).save(session)
        let knowledge = KnowledgeService(databaseQueue: queue)
        try await knowledge.save(.init(title: "Decisions", content: "Quarterly review outcomes"))
        let page = try await search.search("Quarterly review", limit: 40)
        #expect(page.hits.filter { $0.kind == .conversation }.count == 1)
        #expect(page.hits.contains { $0.kind == .knowledge })
        let messages = try await search.search("Progress", kind: .conversation)
        #expect(messages.hits.count == 40 && messages.hasMore)
        let rest = try await search.search("Progress", kind: .conversation, before: messages.hits.last)
        #expect(rest.hits.count == 20)
        #expect(Set((messages.hits + rest.hits).map(\.id)).count == 60)

        let account = UUID(), folder = MailFolder(accountId: account, path: "INBOX", name: "Inbox", role: .inbox)
        let mail = MailService(databaseQueue: queue)
        try await mail.upsertFolders([folder])
        let message = MailMessage(accountId: account, folderId: folder.id, uid: 1, subject: "Delivery")
        try await mail.upsertMessages([message])
        try await mail.saveBody(.init(messageId: message.id, htmlBody: "<p>交付批号</p>"))
        let mailPage = try await search.search("交付批号", kind: .mail)
        #expect(mailPage.hits.map(\.sourceID) == [message.id.uuidString])
    }

    @Test("Retry scope survives persistence and matches only its original project and directories")
    func retryScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let original = ChatWorkspace(name: "Customer B", path: b.path, space: .work)
        let other = ChatWorkspace(name: "Default A", path: a.path, isDefault: true, space: .work)
        let context = RunResourceContext(space: .work, workspaceID: original.id, excludesMemory: true)
        let scope = TeamRetryScope(resourceContext: context, workspaceName: original.name,
                                   directories: try original.folderURLs.map(TaskDirectoryIdentity.capture))
        var plan = TeamPlan(goal: "Read the delivery date", acceptance: [], subtasks: [.init(title: "Read", objective: "Read requirements")])
        plan.retryScope = scope
        let copy = try JSONDecoder().decode(TeamPlan.self, from: JSONEncoder().encode(plan))
        #expect(copy.retryScope?.matches(original) == true)
        #expect(copy.retryScope?.matches(other) == false)
        #expect(copy.retryScope?.resourceContext.excludesMemory == true)
        var changed = original
        changed.referencedFolders = [.init(path: a.path)]
        #expect(copy.retryScope?.matches(changed) == false)
        let queue = try database()
        let store = TeamTaskStore(databaseQueue: queue)
        let report = TeamTaskReport(taskID: UUID(), goal: plan.goal, status: .failed, subtasks: [], artifacts: [],
            usage: .init(), openQuestions: [], errors: ["fixture"], startedAt: Date(), finishedAt: Date())
        try await store.save(plan: plan, report: report)
        let retry = try await store.planForRetry(id: report.taskID, expectedPlan: plan, revisionTitle: nil)
        #expect(retry.retryScope == scope)
        let backups = SpaceDatabaseBackupStore(queue: queue, space: "work")
        let first = try await backups.export()
        #expect(try await backups.export() == first)
        let table = try #require(first.tables.first { $0.name == "team_tasks" })
        let column = try #require(table.columns.firstIndex(of: "planJSON"))
        let row = try #require(table.rows.first)
        guard case .text(let text) = row[column] else { Issue.record("Expected a portable plan"); return }
        #expect(try JSONDecoder().decode(TeamPlan.self, from: Data(text.utf8)).retryScope == nil)
        #expect(try await store.task(id: report.taskID)?.plan.retryScope == scope)
    }

    @Test("Repeated action-item extraction preserves edits, completed items and reminder identities")
    func repeatedTodos() throws {
        var first = NoteTodo(title: "Send report")
        first.evidenceQuote = "Send report tomorrow"; first.sourceTimestamp = 12
        var second = NoteTodo(title: "Call Alex")
        second.evidenceQuote = first.evidenceQuote; second.sourceTimestamp = first.sourceTimestamp
        var edited = first
        edited.title = "Send the revised report"; edited.completed = true; edited.reminderID = "saved-reminder"
        edited.owner = "Edited owner"; edited.dueDate = Date(timeIntervalSince1970: 1000)
        let merged = NoteAIProcessing.merging([first, second], into: [edited, second])
        #expect(merged == [edited, second])
        let relative = #"[{"title":"Send report","dueDate":"2026-12-01T10:00:00Z","dueDateBasis":"relative","datePhrase":"tomorrow","evidenceQuote":"Send report tomorrow"}]"#
        let unknown = try #require(NoteAIProcessing.decodeTodos(relative, source: "Send report tomorrow", sourceDateKnown: false).first)
        #expect(unknown.dueDate == nil && unknown.datePhrase == "tomorrow")
        #expect(try NoteAIProcessing.decodeTodos(relative, source: "Send report tomorrow", sourceDateKnown: true).first?.dueDate != nil)
    }

    @Test("Skill rewrites receive script logic and reference contents in the model request")
    func rewriteResources() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkillRewriteResourceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = CloudProvider(config: .init(name: "Fixture", endpoint: "https://skill-resources.invalid/v1", model: "fixture"),
                                     apiKey: "synthetic", session: session)
        let package = try await SkillGenerator(provider: provider).rewrite(skillName: "rewrite-fixture",
            currentSKILLMD: "Run the bundled script.", fileList: ["scripts/run.py", "references/rates.md"],
            resourceContent: "File: scripts/run.py\noriginal_total = 41\n\nFile: references/rates.md\nOriginal rate: 7.5%",
            instruction: "Add one to the total and preserve the rate.", knowledgeContext: nil)
        #expect(SkillRewriteResourceProtocol.capture.body.contains("original_total = 41"))
        #expect(SkillRewriteResourceProtocol.capture.body.contains("Original rate: 7.5%"))
        #expect(package.skill.name == "rewrite-fixture" && package.scripts.first?.content == "total = 42")
    }

    @Test("First-use file selections append unique files from separate folders")
    func additiveSources() async throws {
        let setup = FirstTaskSetupModel(space: .work, preferences: ProductPreferencesService(databaseQueue: try database()),
            fetchProviders: { [] }, probe: { _ in .success("fixture") }, isCurrentSpace: { true })
        await setup.load()
        setup.template = "compare"; setup.useSample = false
        let a = URL(fileURLWithPath: "/fixture/a/source.txt"), b = URL(fileURLWithPath: "/fixture/b/source.txt")
        setup.selectFiles([a]); setup.selectFiles([b, a])
        #expect(setup.files == [a, b] && setup.sourcesReady)
        setup.removeFile(at: 0)
        #expect(setup.files == [b] && !setup.sourcesReady)
        setup.template = "mail"
        #expect(await setup.saveForNavigation())
        setup.cancel()
    }

    @Test("First-use task choices render in every supported language",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_FIRST_USE_SNAPSHOT_DIR"] != nil))
    func firstUsePresentation() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGROOM_FIRST_USE_SNAPSHOT_DIR"])
        let oldLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = oldLanguage }
        _ = NSApplication.shared
        for language in AppLanguage.allCases where language != .system {
            LanguageManager.shared.currentLanguage = language
            let queue = try database()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("agroom-first-use-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root)
            let config = LLMProviderConfig(name: "Model fixture", endpoint: "https://first-use.invalid/v1", model: "fixture")
            for template in ["organize", "compare", "mail"] {
                let setup = FirstTaskSetupModel(space: .work, preferences: ProductPreferencesService(databaseQueue: queue),
                    fetchProviders: { [config] }, probe: { _ in .success("fixture") }, isCurrentSpace: { true })
                await setup.load()
                setup.template = template
                let host = NSHostingView(rootView: OnboardingView(hub: hub, setup: setup, onFinish: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.layoutDirection, LanguageManager.shared.layoutDirection)
                    .environment(\.locale, Locale(identifier: language.rawValue))
                    .environment(\.colorScheme, .light))
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 760),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host
                defer { window.close() }
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("first-use-\(template)-\(language.rawValue).png"))
                setup.cancel()
            }
        }
    }

    @Test("Supported regional languages resolve correctly and select their reply language")
    func languageResolution() {
        for (tag, language) in [("es-MX", AppLanguage.spanish), ("fr-CA", .french), ("ar-SA", .arabic), ("ru-RU", .russian), ("zh-MO", .traditionalChinese)] {
            #expect(AppLanguage.resolved(preferredLanguages: [tag]) == language)
            #expect(!language.agentReplyLanguageName.isEmpty)
        }
        #expect(AppLanguage.resolved(preferredLanguages: ["de-DE", "fr-FR"]) == .french)
    }

    @Test("Built-in mini apps translate every control and retain compatibility with three-language definitions")
    func appLanguages() throws {
        let languages = Set(AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue))
        let apps = try [NativeAppTemplates.note(), NativeAppTemplates.textStatistics(), NativeAppTemplates.knowledge(),
                        NativeAppTemplates.databaseMetadata(), NativeAppTemplates.slidingPuzzle(),
                        NativeAppTemplates.quoteEstimate(), NativeAppTemplates.workHours(), NativeAppTemplates.calculator()]
        for app in apps {
            try app.validate()
            #expect(Set(app.i18n.keys) == languages)
            let keys = Set(try #require(app.i18n["en"]).keys)
            for values in app.i18n.values { #expect(Set(values.keys) == keys) }
            var legacy = app
            legacy.i18n = app.i18n.filter { ["en", "zh-Hans", "zh-Hant"].contains($0.key) }
            try legacy.validate()
            #expect(legacy.text(legacy.manifest.nameKey, language: "ar") == legacy.i18n["en"]?[legacy.manifest.nameKey])
        }
    }

    @Test("Every supported language includes the complete UI and system permission strings with matching format arguments")
    func localizationCoverage() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+#0 ']*\d*(?:\.\d+)?(?:hh|ll|[hlLzjtq])?[diuoxXfFeEgGaAcCsSp@%]"#)
        func strings(_ directory: String, _ language: String, _ file: String) throws -> [String: String] {
            let data = try Data(contentsOf: project.appendingPathComponent(directory).appendingPathComponent(language + ".lproj").appendingPathComponent(file))
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        func arguments(_ value: String) -> [String] {
            let text = value as NSString
            return format.matches(in: value, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }.sorted()
        }
        for (directory, file) in [("Sources/AgRoomUI/Resources", "Localizable.strings"), ("Resources/Localized", "InfoPlist.strings")] {
            let english = try strings(directory, "en", file)
            for language in AppLanguage.allCases where language != .system {
                let translated = try strings(directory, language.rawValue, file)
                #expect(Set(translated.keys) == Set(english.keys), "\(language.rawValue): \(file)")
                for (key, source) in english {
                    let value = try #require(translated[key])
                    #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language.rawValue): \(key)")
                    #expect(arguments(value) == arguments(source), "\(language.rawValue): \(key)")
                    #expect(!value.contains("▁"), "\(language.rawValue): \(key)")
                }
            }
        }
    }
}

private final class SkillRewriteResourceProtocol: URLProtocol, @unchecked Sendable {
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        var body: String { lock.withLock { value } }
        func store(_ body: String) { lock.withLock { value = body } }
    }
    static let capture = Capture()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "skill-resources.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.capture.store(String(decoding: body, as: UTF8.self))
        let output = #"{"name":"rewrite-fixture","description":"Calculate","content":"Run scripts/run.py.","allowed_tools":"skill_run_script","scripts":[{"path":"scripts/run.py","content":"total = 42"}]}"#
        let event = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": output], "finish_reason": "stop"]]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(("data: " + String(decoding: event, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
