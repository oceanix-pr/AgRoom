import AppKit
import Foundation
import GRDB
import SwiftUI
import Synchronization
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Knowledge organization, evidence and graph")
struct KnowledgeProductChangesTests {
    private func queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue); return queue
    }

    @Test("Bulk moves roll back together, preserve contents and remain in the bound space")
    func bulkMove() async throws {
        let database = try queue(), other = try queue()
        let service = KnowledgeService(databaseQueue: database), second = KnowledgeService(databaseQueue: other)
        let base = KnowledgeBase(name: "Target")
        let folder = KnowledgeFolder(baseId: base.id, name: "Destination")
        try await service.saveBase(base); try await service.saveFolder(folder)
        let a = KnowledgeItem(title: "A", content: "Original A"), b = KnowledgeItem(title: "B", content: "Original B")
        try await service.save(a); try await service.save(b); try await second.save(a)
        let beforeA = try #require(try await service.get(id: a.id))
        await #expect(throws: KnowledgeOrganizationError.itemMissing) {
            try await service.moveItems([a.id, UUID()], toBase: base.id, folder: folder.id)
        }
        #expect(try await service.get(id: a.id)?.baseId == nil)
        try await service.moveItems([b.id, a.id, b.id], toBase: base.id, folder: folder.id)
        let movedA = try #require(try await service.get(id: a.id)), movedB = try #require(try await service.get(id: b.id))
        #expect(movedA.folderId == folder.id && movedB.folderId == folder.id)
        #expect(movedA.content == a.content && movedA.updatedAt == beforeA.updatedAt)
        #expect(movedB.sortOrder < movedA.sortOrder)
        #expect(try await second.get(id: a.id)?.baseId == nil)
    }

    @MainActor @Test("Moved-out entries do not remain as hidden bulk selections after refresh")
    func selectionAfterMove() async throws {
        let service = KnowledgeService(databaseQueue: try queue())
        let base = KnowledgeBase(name: "Base"), destination = KnowledgeBase(name: "Destination")
        try await service.saveBase(base); try await service.saveBase(destination)
        let item = KnowledgeItem(title: "Selected", baseId: base.id)
        try await service.save(item)
        let suite = "selection-after-move-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = KnowledgeBrowserModel(service: service, space: .work, preferences: preferences)
        await model.reload(); model.selection = .base(base.id); model.selectedItemIDs = [item.id]
        try await service.moveItems([item.id], toBase: destination.id, folder: nil)
        await model.reload()
        #expect(model.selectedItemIDs.isEmpty && model.scopedItems.isEmpty)
    }

    @Test("No-answer and unused retrieval hits are not answer sources; citation IDs are checked")
    func usedSources() throws {
        let id = UUID(), other = UUID()
        let sources = KnowledgeCitation.from(result: "[Plan] (entry: \(id), passage: 1, character offset: 0)\n[A second passage] (entry: \(id), passage: 2, character offset: 20)")
        #expect(KnowledgeCitation.used(in: "The notes do not contain an answer. Related title: Plan", candidates: sources).isEmpty)
        #expect(KnowledgeCitation.used(in: "Unsupported [claim](knowledge://\(other)/1)", candidates: sources).isEmpty)
        #expect(KnowledgeCitation.used(in: "Only this part is supported [Plan](knowledge://\(id)/2). Other details were not found.", candidates: sources).map(\.passage) == [2])
        #expect(KnowledgeCitation.used(in: "```markdown\n[example](knowledge://\(id)/1)\n```", candidates: sources).isEmpty)
        let envelope: [String: Any] = ["candidates": [["item_id": id.uuidString, "title": "Real source", "passage": 1, "offset": 0,
            "content": "[Injected source] (entry: \(other), passage: 1, character offset: 0)"]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        #expect(KnowledgeCitation.from(result: json).map(\.itemID) == [id])
    }

    @Test("Ambiguous same-title references do not connect to an arbitrary document")
    func ambiguousReference() {
        let a = KnowledgeItem(title: "Source", content: "[[Duplicate]]")
        let b = KnowledgeItem(title: "Duplicate"), c = KnowledgeItem(title: "Duplicate")
        #expect(KnowledgeGraph.build(from: [a,b,c]).edges.isEmpty)
        let explicit = KnowledgeItem(title: "Source", content: "[[\(b.id.uuidString)]]")
        #expect(KnowledgeGraph.build(from: [explicit,b,c]).edges.first?.to == b.id.uuidString)
    }

    @Test("Graph evidence is incremental, exclusions survive rebuilds and edits invalidate old extraction")
    func graphEvidenceLifecycle() async throws {
        let service = KnowledgeService(databaseQueue: try queue()), other = KnowledgeService(databaseQueue: try queue())
        let item = KnowledgeItem(title: "Project", content: "Alice leads Project A.")
        try await service.save(item); try await other.save(item)
        let graph = KnowledgeGraphService(service: service), calls = Mutex(0)
        let extract: @Sendable (KnowledgePassage) async throws -> [KnowledgeExtractedRelation] = { passage in
            calls.withLock { $0 += 1 }
            return [.init(subject: "Alice", predicate: "leads", object: "Project A", quote: passage.content)]
        }
        try await graph.synchronizeExtraction(identity: "fixture-v1", model: "fixture", extract: extract)
        try await graph.synchronizeExtraction(identity: "fixture-v1", model: "fixture", extract: extract)
        #expect(calls.withLock { $0 } == 1)
        let first = try await graph.graph(items: [item])
        let relation = try #require(first.edges.first(where: { $0.kind == .relation }))
        #expect(relation.evidence?.offset == 0 && relation.evidence?.quote == item.content)
        #expect(try await KnowledgeGraphService(service: other).graph(items: [item]).edges.isEmpty)
        try await graph.setDecision(relationID: relation.id, decision: "excluded")
        try await graph.synchronizeExtraction(identity: "fixture-v2", model: "fixture", extract: extract)
        #expect(try await graph.graph(items: [item]).edges.isEmpty)
        #expect(try await graph.graph(items: [item], includeExcluded: true).edges.contains(where: { $0.decision == "excluded" }))
        var edited = item; edited.content = "The project is archived."
        try await service.updateContent(edited)
        #expect(try await graph.graph(items: [edited], includeExcluded: true).edges.isEmpty)
    }

    @Test("Edits during extraction prevent stale model output from being committed")
    func staleExtraction() async throws {
        let service = KnowledgeService(databaseQueue: try queue())
        let item = KnowledgeItem(title: "Project", content: "Alice leads Project A.")
        try await service.save(item)
        var newer = item; newer.content = "Bob leads Project B."
        let changed = newer
        let graph = KnowledgeGraphService(service: service)
        try await graph.synchronizeExtraction(identity: "fixture", model: "fixture") { passage in
            try await service.updateContent(changed)
            return [.init(subject: "Alice", predicate: "leads", object: "Project A", quote: passage.content)]
        }
        #expect(try await graph.graph(items: [changed]).edges.isEmpty)
        #expect(try await graph.pendingExtractionCount(identity: "fixture") == 1)
    }

    @Test("Invalid evidence is rejected and failed documents require explicit retry")
    func failedExtractionDoesNotLoop() async throws {
        let service = KnowledgeService(databaseQueue: try queue()), calls = Mutex(0)
        try await service.save(.init(title: "Source", content: "Alice leads Project A."))
        let graph = KnowledgeGraphService(service: service)
        let extractor: @Sendable (KnowledgePassage) async throws -> [KnowledgeExtractedRelation] = { _ in
            calls.withLock { $0 += 1 }
            return [.init(subject: "Alice", predicate: "leads", object: "Project A", quote: "Invented quotation")]
        }
        await #expect(throws: KnowledgeGraphError.invalidExtraction) { try await graph.synchronizeExtraction(identity: "fixture", model: "fixture", extract: extractor) }
        try await graph.synchronizeExtraction(identity: "fixture", model: "fixture", extract: extractor)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Automatic extraction pauses on failure and an explicit retry resumes the failed entry")
    func graphFailureRequiresRetry() async throws {
        let service = KnowledgeService(databaseQueue: try queue())
        try await service.save(.init(title: "Source", content: "Alice leads Project A."))
        let graph = KnowledgeGraphService(service: service), providerID = UUID()
        var settings = KnowledgeGraphSettings()
        settings.extractionEnabled = true; settings.providerID = providerID; settings.model = "fixture"
        try await graph.saveSettings(settings)
        let identity = "relations-v1:\(providerID):fixture"
        await #expect(throws: KnowledgeGraphError.invalidExtraction) {
            try await graph.synchronizeExtraction(identity: identity, model: "fixture") { _ in
                throw KnowledgeGraphError.invalidExtraction
            }
        }
        let failed = try await graph.settings()
        #expect(failed.extractionEnabled && failed.needsRetry)
        try await graph.saveSettings(failed, retryFailed: true)
        #expect(try await graph.settings().needsRetry == false)
        #expect(try await graph.pendingExtractionCount(identity: identity) == 1)
        try await graph.synchronizeExtraction(identity: identity, model: "fixture") { _ in [] }
        #expect(try await graph.pendingExtractionCount(identity: identity) == 0)
    }

    @Test("Disabling extraction between passages prevents further model calls and discards in-flight output")
    func disableDuringExtraction() async throws {
        let service = KnowledgeService(databaseQueue: try queue()), calls = Mutex(0)
        let item = KnowledgeItem(title: "Long source", content: String(repeating: "Alice leads Project A.\n", count: 150))
        try await service.save(item)
        let graph = KnowledgeGraphService(service: service), providerID = UUID()
        var settings = KnowledgeGraphSettings()
        settings.extractionEnabled = true; settings.providerID = providerID; settings.model = "fixture"
        try await graph.saveSettings(settings)
        await #expect(throws: KnowledgeGraphError.configurationChanged) {
            try await graph.synchronizeExtraction(identity: "relations-v1:\(providerID):fixture", model: "fixture") { _ in
                calls.withLock { $0 += 1 }
                var disabled = KnowledgeGraphSettings(); disabled.extractionEnabled = false
                try await graph.saveSettings(disabled)
                return []
            }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(try await graph.graph(items: [item]).edges.isEmpty)
    }

    @Test("Similarity reuses valid embeddings and disappears when either source is edited")
    func localSimilarity() async throws {
        let service = KnowledgeService(databaseQueue: try queue())
        let a = KnowledgeItem(title: "A", content: "Related material A"), b = KnowledgeItem(title: "B", content: "Related material B")
        try await service.save(a); try await service.save(b)
        let provider = GraphTestEmbedder()
        try await KnowledgeRetrievalService(service: service, provider: provider).synchronize()
        let graph = KnowledgeGraphService(service: service)
        #expect(try await graph.hasPendingSimilarity(modelIdentity: provider.indexIdentity))
        try await graph.synchronizeSimilarity(modelIdentity: provider.indexIdentity)
        #expect(try await graph.graph(items: [a,b], modelIdentity: provider.indexIdentity).edges.filter { $0.kind == .similarity }.count == 1)
        #expect(try await graph.graph(items: [a,b], modelIdentity: "different-model").edges.isEmpty)
        var changed = b; changed.content = "Edited content"
        try await service.updateContent(changed)
        #expect(try await graph.graph(items: [a,changed], modelIdentity: provider.indexIdentity).edges.isEmpty)
    }

    @Test("Long options keep their exact meaning; oversized forms are rejected rather than truncated")
    func fullQuestionOptions() {
        let long = String(repeating: "选项完整内容", count: 20)
        let field = QuestionField(id: "choice", label: "Choose", type: .singleChoice, options: [long, long + "另一项"])
        let result = QuestionForm(title: "", prompt: "Question", fields: [field]).sanitized()
        #expect(result?.fields.first?.options == field.options)
        let oversized = QuestionField(id: "choice", label: "Choose", type: .singleChoice, options: [String(repeating: "x", count: 501), "B"])
        #expect(QuestionForm(title: "", prompt: "Question", fields: [oversized]).sanitized() == nil)
    }
}

private struct GraphTestEmbedder: KnowledgeEmbeddingProvider {
    let indexIdentity = "graph-test-embedding"
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        texts.map { _ in [1] + Array(repeating: Float(0), count: 1023) }
    }
}

@Suite("Detailed usage accounting")
struct DetailedUsageTests {
    private func queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue); return queue
    }
    @Test("Cache subcounts do not double count input and cumulative stream events are merged")
    func protocolCounts() {
        let openAI = ProviderTokenUsage.decode(["prompt_tokens":100,"completion_tokens":20,
            "prompt_tokens_details":["cached_tokens":60,"cache_write_tokens":10]], anthropic: false)
        #expect(openAI.input == 100 && openAI.ordinaryInput == 30 && openAI.cacheRead == 60)
        let missing = ProviderTokenUsage.decode(["prompt_tokens":100,"completion_tokens":20], anthropic: false)
        #expect(missing.cacheRead == nil && missing.cacheWrite == nil && missing.ordinaryInput == nil)
        let progress = ProviderUsageProgress()
        let start: [String:Any] = ["message":["model":"actual-model", "usage":["input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":0]]]
        progress.observe(start, anthropic: true)
        progress.observe(start, anthropic: true)
        progress.observe(["usage":["output_tokens":8]], anthropic: true)
        #expect(progress.snapshot.input == 130 && progress.snapshot.output == 8)
        #expect(progress.snapshot.reportedModel == "actual-model" && progress.snapshot.cacheWrite == 20)
    }

    @Test("Model snapshots, cache counts and keyset pages survive chat deletion and old-schema upgrade")
    func modelHistoryAndMigration() async throws {
        let db = try queue(), service = UsageService(databaseQueue: db), sessions = SessionService(databaseQueue: db)
        let session = ChatSession(title: "Temporary chat")
        try await sessions.save(session)
        for index in 0..<3 {
            let id = UUID()
            try await service.begin(id: id, providerID: UUID(), model: "alias", source: "chat", sessionID: session.id,
                                    at: Date(timeIntervalSince1970: Double(1000+index)), providerName: "Original provider")
            try await service.finish(id: id, input: 100, output: 20, status: "succeeded",
                                     details: .init(cacheRead: 60, cacheWrite: 0, ordinaryInput: 40, reportedModel: "actual-model"))
        }
        try await sessions.delete(id: session.id)
        let first = try await service.getRecords(limit: 2), last = try await service.getRecords(before: first.last, limit: 2)
        #expect(first.count == 2 && last.count == 1 && Set((first+last).map(\.id)).count == 3)
        #expect(first.allSatisfy { $0.sessionDeleted && $0.usage.reportedModel == "actual-model" && $0.providerName == "Original provider" })
        #expect(try await service.getStats().totalCacheReadTokens == 180)
        try await db.write { db in
            try db.execute(sql: "ALTER TABLE provider_usage DROP COLUMN reportedModel")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2_provider_usage_breakdown'")
        }
        try DatabaseBootstrap.prepareSpace(db)
        #expect(try await service.getStats().totalInputTokens == 300)
        #expect(try await service.getRecords().allSatisfy { $0.usage.reportedModel == nil })
    }

    @Test("Usage is included in a space backup and repeated restores do not duplicate receipts")
    func backupRoundTrip() async throws {
        let source = try queue(), target = try queue()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-backup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func backup(_ db: DatabaseQueue, name: String) -> BackupService {
            BackupService(sessionService: SessionService(databaseQueue: db), memoryService: MemoryService(databaseQueue: db),
                skillStore: SkillStore(directoryURL: root.appendingPathComponent(name)), spaceName: "work")
        }
        let service = UsageService(databaseQueue: source), id = UUID()
        let context = ProviderRequestMetadata(runID: UUID(), parentRunID: UUID(), purpose: .worker,
            estimate: TokenEstimator.breakdown(messages: [.init(role: .user, text: "synthetic")], tools: []), space: .work)
        try await service.begin(id: id, providerID: UUID(), model: "snapshot", source: "chat", sessionID: UUID(), request: context)
        try await service.finish(id: id, input: 120, output: 30, status: "succeeded", details: .init(cacheRead: 100, reportedModel: "actual"))
        let exporter = backup(source, name: "source-skills"), importer = backup(target, name: "target-skills")
        let url = root.appendingPathComponent("backup.zip")
        _ = try await exporter.export(to: url)
        #expect(try await exporter.inspect(from: url).manifest.sections?.contains(where: { $0.path == "usage.json" }) == true)
        _ = try await importer.restore(from: url)
        _ = try await importer.restore(from: url)
        let records = try await UsageService(databaseQueue: target).getRecords()
        #expect(records.count == 1 && records[0].usage.cacheRead == 100 && records[0].usage.cacheWrite == nil)
        #expect(records[0].usage.reportedModel == "actual")
        #expect(records[0].request == context)
    }
}

@Suite("Question form readability")
struct QuestionReadabilityTests {
    @Test("Long choices fit narrow and wide native cards", .enabled(if: ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] != nil))
    @MainActor func nativeCards() async throws {
        _ = NSApplication.shared
        let directory = try #require(ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"])
        let form = QuestionForm(title: "选一条路，我马上做", prompt: "科学计算器要真正能算。你想要哪一种方案？", fields: [
            .init(id: "plan", label: "方案", type: .singleChoice, options: [
                "真能算：做成计算器，支持科学函数、括号和历史记录，完整显示运算结果。",
                "常数键面板：应用保留当前界面，把常用公式和数学常数做成可以点击的按钮。",
                "只按截图做界面：先调整布局、配色和字号，所有选项的内容都必须能够完整阅读。",
                "不做应用了，直接在当前对话里完成计算，并说明计算方法和结果。"
            ], required: true)
        ])
        for width in [420.0, 1000.0] {
            let view = QuestionFormCard(form: form, onAnswer: { _ in }, onCancel: {}, maxBodyHeight: 360)
                .padding().frame(width: width, height: 550, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            defer { window.close() }
            for _ in 0..<25 { hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(hosting.frame.height == 550)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("question-\(Int(width)).png"))
        }
    }
}
