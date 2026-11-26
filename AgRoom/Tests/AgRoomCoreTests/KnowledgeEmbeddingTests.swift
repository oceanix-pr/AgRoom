import Foundation
import GRDB
import Testing
@testable import AgRoomCore

private struct TestKnowledgeEmbedder: KnowledgeEmbeddingProvider {
    var indexIdentity = "test-model-v1"
    var fail = false
    var beforeEmbed: (@Sendable () async throws -> Void)?
    func embed(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        try await beforeEmbed?()
        if fail { throw KnowledgeEmbeddingError.inferenceFailed }
        return texts.map { text in
            var vector = [Float](repeating: 0, count: 1024)
            vector[isQuery || text.contains("续约") ? 0 : 1] = 1
            return vector
        }
    }
}

@Suite("Knowledge embeddings and hybrid retrieval")
struct KnowledgeEmbeddingTests {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return queue
    }

    @Test("Semantic retrieval finds synonyms without lexical overlap and isolates identical IDs across spaces")
    func independentSemanticRecallAndIsolation() async throws {
        let first = KnowledgeService(databaseQueue: try database())
        let second = KnowledgeService(databaseQueue: try database())
        let id = UUID()
        try await first.save(KnowledgeItem(id: id, title: "续约策略", content: "提高续约率的方法"))
        try await second.save(KnowledgeItem(id: id, title: "私人内容", content: "另一个空间"))
        let firstIndex = KnowledgeRetrievalService(service: first, provider: TestKnowledgeEmbedder())
        let secondIndex = KnowledgeRetrievalService(service: second, provider: TestKnowledgeEmbedder())
        try await firstIndex.synchronize()
        let result = try await firstIndex.search(query: "减少客户流失")
        #expect(result.usedSemanticSearch)
        #expect(result.passages.first?.itemID == id)
        #expect(result.passages.first?.title == "续约策略")
        #expect(try await secondIndex.indexStatus().indexed == 0)
        #expect(try await secondIndex.search(query: "减少客户流失").passages.isEmpty)
    }

    @Test("Keyword fallback returns a hit deep in a long document rather than its opening")
    func deepPassageFallback() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        try await service.save(KnowledgeItem(title: "操作手册", content: String(repeating: "前言无关内容。", count: 400) + "\n退款流程：联系支持后申请退回。"))
        let result = try await KnowledgeRetrievalService(service: service).search(query: "退款流程")
        #expect(!result.usedSemanticSearch)
        #expect(result.passages.first?.content.contains("退款流程") == true)
        #expect((result.passages.first?.startOffset ?? 0) > 500)
    }

    @Test("Edits and deletes invalidate vectors; a model identity change excludes old vectors")
    func invalidationAndVersioning() async throws {
        let queue = try database()
        let service = KnowledgeService(databaseQueue: queue)
        var item = KnowledgeItem(title: "续约策略", content: "提高续约率")
        try await service.save(item)
        let index = KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder())
        try await index.synchronize()
        #expect(try await index.indexStatus().indexed == 1)
        let changed = KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder(indexIdentity: "v2"))
        #expect(try await changed.indexStatus().indexed == 0)
        #expect(try await changed.search(query: "减少客户流失").passages.isEmpty)
        item.content = "已变更内容"
        try await service.save(item)
        #expect(try await index.indexStatus().indexed == 0)
        #expect(try await index.search(query: "减少客户流失").passages.isEmpty)
        try await index.synchronize()
        try await service.delete(id: item.id)
        #expect(try await index.indexStatus().total == 0)
        let count = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_passages") }
        #expect(count == 0)
    }

    @Test("An edit during inference cannot commit stale document vectors")
    func concurrentEdit() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let item = KnowledgeItem(title: "续约资料", content: "旧内容")
        try await service.save(item)
        var replacement = item
        replacement.content = "新正文"
        let updated = replacement
        let provider = TestKnowledgeEmbedder(beforeEmbed: { try await service.save(updated) })
        let index = KnowledgeRetrievalService(service: service, provider: provider)
        try await index.synchronize()
        #expect(try await index.indexStatus().indexed == 0)
    }

    @Test("Inference failure preserves keyword search, cancellation propagates and no index is falsely committed")
    func failureAndCancellation() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        try await service.save(KnowledgeItem(title: "续约指南", content: "续约步骤"))
        try await KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder()).synchronize()
        let failed = KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder(fail: true))
        let result = try await failed.search(query: "续约")
        #expect(!result.usedSemanticSearch)
        #expect(!result.passages.isEmpty)
        let cancelled = KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder(indexIdentity: "cancelled", beforeEmbed: { throw CancellationError() }))
        await #expect(throws: CancellationError.self) { try await cancelled.synchronize() }
        #expect(try await cancelled.indexStatus().indexed == 0)
    }

    @Test("Scoped search discards items moved while embedding, including when keyword fallback is used", arguments: [false, true])
    func movedDuringQuery(failInference: Bool) async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let base = KnowledgeBase(name: "Selected")
        try await service.saveBase(base)
        let item = KnowledgeItem(title: "续约词", content: "scope fixture", baseId: base.id)
        try await service.save(item)
        try await KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder()).synchronize()
        let provider = TestKnowledgeEmbedder(fail: failInference, beforeEmbed: {
            try await service.moveItems([item.id], toBase: nil, folder: nil)
        })
        let result = try await KnowledgeRetrievalService(service: service, provider: provider).search(query: "续约词", scope: .base(base.id))
        #expect(result.passages.isEmpty)
    }

    @Test("Vector validation rejects bad dimensions, zero and NaN values")
    func invalidVectors() throws {
        #expect(throws: KnowledgeEmbeddingError.invalidVector) { try KnowledgeVector.normalized([1, 2]) }
        #expect(throws: KnowledgeEmbeddingError.invalidVector) { try KnowledgeVector.normalized(Array(repeating: 0, count: 1024)) }
        #expect(throws: KnowledgeEmbeddingError.invalidVector) { try KnowledgeVector.normalized(Array(repeating: .nan, count: 1024)) }
        var vector = [Float](repeating: 0, count: 1024)
        vector[2] = 5
        #expect(try KnowledgeVector.decode(KnowledgeVector.encode(vector))[2] == 1)
    }

    @Test("Scoped UI retrieval cannot include documents from another library")
    func scopedRetrieval() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        let a = KnowledgeItem(title: "续约资料 A", content: "续约")
        let b = KnowledgeItem(title: "续约资料 B", content: "续约")
        try await service.save(a)
        try await service.save(b)
        let index = KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder())
        try await index.synchronize()
        let result = try await index.search(query: "减少客户流失", allowedItemIDs: [a.id])
        #expect(result.passages.map(\.itemID) == [a.id])
        #expect(result.semanticRowsRead == 1)
        let unscoped = try await index.search(query: "减少客户流失")
        #expect(unscoped.semanticRowsRead == 2)
        let empty = try await index.search(query: "减少客户流失", allowedItemIDs: [])
        #expect(empty.semanticRowsRead == 0 && empty.passages.isEmpty)
    }

    @Test("Semantic scan uses a cursor across batches and filters scope before decoding vectors")
    func keysetAndScopeScan() async throws {
        let service = KnowledgeService(databaseQueue: try database())
        var ids: [UUID] = []
        for index in 0..<300 {
            let item = KnowledgeItem(title: "续约 \(index)", content: "续约策略 \(index)")
            ids.append(item.id)
            try await service.save(item)
        }
        let retrieval = KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder())
        try await retrieval.synchronize()
        let all = try await retrieval.search(query: "减少客户流失")
        #expect(all.semanticRowsRead == 300)
        #expect(all.semanticVectorBytesRead > all.semanticTextBytesRead)
        #expect(all.semanticTextBytesRead == all.passages.reduce(0) { $0 + $1.content.utf8.count })
        let scoped = try await retrieval.search(query: "减少客户流失", allowedItemIDs: [ids[0], ids[299]])
        #expect(scoped.semanticRowsRead == 2)
        #expect(Set(scoped.passages.map(\.itemID)) == Set([ids[0], ids[299]]))
    }

    @Test("Derived vectors survive database reopening without changing original knowledge")
    func persistedIndexReopens() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-reopen-\(UUID()).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let id = UUID()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try DatabaseBootstrap.prepareSpace(queue)
            let service = KnowledgeService(databaseQueue: queue)
            try await service.save(KnowledgeItem(id: id, title: "续约策略", content: "提高续约率"))
            try await KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder()).synchronize()
        }
        let queue = try DatabaseQueue(path: url.path)
        try DatabaseBootstrap.prepareSpace(queue)
        let service = KnowledgeService(databaseQueue: queue)
        let index = KnowledgeRetrievalService(service: service, provider: TestKnowledgeEmbedder())
        #expect(try await index.indexStatus().indexed == 1)
        #expect(try await index.search(query: "减少客户流失").passages.first?.itemID == id)
        #expect(try await service.getAll().first?.content == "提高续约率")
    }

    @Test("Real external Qwen model runs with the bundled runtime", .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_EMBEDDING_MODEL"] != nil))
    func realModel() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["AGROOM_TEST_EMBEDDING_MODEL"])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("Sources/AgRoom/EmbeddingRuntime/arm64/llama-embedding")
        let provider = try LocalKnowledgeEmbedder(modelURL: URL(fileURLWithPath: path), executableURL: executable)
        let query = try await provider.embed(["怎样减少客户流失？"], isQuery: true)[0]
        let documents = try await provider.embed(["提高客户续约率和满意度。", "红烧肉需要慢火炖煮。"], isQuery: false)
        let similarities = documents.map { doc in zip(query, doc).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        #expect(similarities[0] > similarities[1])
        let service = KnowledgeService(databaseQueue: try database())
        let relevant = KnowledgeItem(title: "Renewal strategy", content: "Improve customer renewal rates and satisfaction to retain subscribers.")
        try await service.save(relevant)
        try await service.save(KnowledgeItem(title: "Recipe", content: "Cook pork over low heat."))
        let index = KnowledgeRetrievalService(service: service, provider: provider)
        try await index.synchronize()
        let result = try await index.search(query: "怎样减少客户流失？")
        #expect(result.usedSemanticSearch)
        #expect(result.passages.first?.itemID == relevant.id)
    }
}
