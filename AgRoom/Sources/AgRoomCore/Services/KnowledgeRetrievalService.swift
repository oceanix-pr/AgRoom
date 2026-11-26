import CryptoKit
import Foundation
import GRDB

public struct KnowledgePassage: Sendable, Identifiable, Equatable {
    public var id: String { "\(itemID.uuidString):\(ordinal)" }
    public let itemID: UUID
    public let title: String
    public let ordinal: Int
    public let startOffset: Int
    public let content: String
}

public struct KnowledgeSearchResult: Sendable {
    public let passages: [KnowledgePassage]
    public let usedSemanticSearch: Bool
    public var semanticVectorBytesRead = 0
    public var semanticTextBytesRead = 0
    public var semanticRowsRead = 0
}

/// 绑定固定空间数据库。索引是可重建派生数据，读取搜索绝不触发写入。
public final class KnowledgeRetrievalService: Sendable {
    private let service: KnowledgeService
    private let provider: (any KnowledgeEmbeddingProvider)?
    public init(service: KnowledgeService, provider: (any KnowledgeEmbeddingProvider)? = nil) {
        self.service = service
        self.provider = provider
    }
    public static func configured(service: KnowledgeService) -> KnowledgeRetrievalService {
        do { return Self(service: service, provider: try KnowledgeEmbeddingSettings.load().makeProvider()) }
        catch { return Self(service: service) } // 配置缺失时搜索仍使用关键词；设置页展示具体状态。
    }

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS knowledge_embedding_documents (
                itemId TEXT PRIMARY KEY REFERENCES knowledge_items(id) ON DELETE CASCADE,
                sourceHash TEXT NOT NULL,
                modelIdentity TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS knowledge_passages (
                itemId TEXT NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                startOffset INTEGER NOT NULL,
                content TEXT NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (itemId, ordinal)
            );
            CREATE INDEX IF NOT EXISTS idx_knowledge_embedding_model ON knowledge_embedding_documents(modelIdentity);
            CREATE TRIGGER IF NOT EXISTS knowledge_embedding_invalidate
            AFTER UPDATE OF title, content, tagsJSON ON knowledge_items
            WHEN OLD.title != NEW.title OR OLD.content != NEW.content OR OLD.tagsJSON != NEW.tagsJSON
            BEGIN
                DELETE FROM knowledge_passages WHERE itemId = NEW.id;
                DELETE FROM knowledge_embedding_documents WHERE itemId = NEW.id;
            END;
            CREATE TRIGGER IF NOT EXISTS knowledge_embedding_delete
            AFTER DELETE ON knowledge_items
            BEGIN
                DELETE FROM knowledge_passages WHERE itemId = OLD.id;
                DELETE FROM knowledge_embedding_documents WHERE itemId = OLD.id;
            END;
            """)
    }

    public struct IndexStatus: Sendable {
        public let total: Int
        public let indexed: Int
    }
    public func indexStatus() async throws -> IndexStatus {
        let identity = provider?.indexIdentity ?? ""
        return try await service.databaseQueue.read { db in
            IndexStatus(total: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_items") ?? 0,
                        indexed: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_embedding_documents WHERE modelIdentity = ?", arguments: [identity]) ?? 0)
        }
    }
    public func resetIndex() async throws {
        try await service.databaseQueue.write { db in
            try db.execute(sql: "DELETE FROM knowledge_passages; DELETE FROM knowledge_embedding_documents;")
        }
    }

    /// 可取消、逐文档原子落盘。修改/删除与在途推理交错时，旧版本结果不落库。
    /// 同一次同步只处理启动时的待处理 ID，失败/取消后下次继续。
    public func synchronize(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let provider else { throw KnowledgeEmbeddingError.modelMissing }
        let identity = provider.indexIdentity
        let ids = try await service.databaseQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT i.id FROM knowledge_items i
                LEFT JOIN knowledge_embedding_documents d ON d.itemId = i.id
                WHERE d.itemId IS NULL OR d.modelIdentity != ? ORDER BY i.id
                """, arguments: [identity])
        }
        for (index, id) in ids.enumerated() {
            try Task.checkCancellation()
            guard let item = try await loadItem(id) else { continue }
            let hash = Self.sourceHash(item)
            let chunks = KnowledgeChunker.split(item)
            var vectors: [Data] = []
            for start in stride(from: 0, to: chunks.count, by: 8) {
                try Task.checkCancellation()
                let batch = Array(chunks[start..<min(start + 8, chunks.count)])
                let texts = batch.map { "\(item.title.prefix(200))\n\(item.tags.joined(separator: ", ").prefix(200))\n\($0.content)" }
                let embedded = try await provider.embed(texts, isQuery: false)
                guard embedded.count == batch.count else { throw KnowledgeEmbeddingError.invalidVector }
                vectors.append(contentsOf: try embedded.map(KnowledgeVector.encode))
            }
            try Task.checkCancellation()
            try await commit(item: item, sourceHash: hash, identity: identity, passages: chunks, vectors: vectors)
            progress(Double(index + 1) / Double(max(ids.count, 1)))
        }
        progress(1)
    }

    private func loadItem(_ id: String) async throws -> KnowledgeItem? {
        try await service.databaseQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_items WHERE id = ?", arguments: [id]) else { return nil }
            return Self.item(row)
        }
    }
    private static func item(_ row: Row) -> KnowledgeItem? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let tags: String = row["tagsJSON"]
        var item = KnowledgeItem(id: id, title: row["title"], content: row["content"],
                                 kind: KnowledgeKind(rawValue: row["kind"]) ?? .document,
                                 tags: (try? JSONDecoder().decode([String].self, from: Data(tags.utf8))) ?? [],
                                 baseId: (row["baseId"] as String?).flatMap(UUID.init(uuidString:)),
                                 folderId: (row["folderId"] as String?).flatMap(UUID.init(uuidString:)))
        item.updatedAt = row["updatedAt"]
        return item
    }
    private static func sourceHash(_ item: KnowledgeItem) -> String {
        // 编码保留字段边界，避免文本拼接产生哈希碰撞。
        let data = (try? JSONEncoder().encode([item.title, item.content] + item.tags)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func commit(item: KnowledgeItem, sourceHash: String, identity: String,
                        passages: [KnowledgePassage], vectors: [Data]) async throws {
        try await service.databaseQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM knowledge_items WHERE id = ?", arguments: [item.id.uuidString]),
                  let current = Self.item(row), Self.sourceHash(current) == sourceHash else { return }
            try db.execute(sql: "DELETE FROM knowledge_passages WHERE itemId = ?", arguments: [item.id.uuidString])
            for (passage, vector) in zip(passages, vectors) {
                try db.execute(sql: "INSERT INTO knowledge_passages (itemId, ordinal, startOffset, content, embedding) VALUES (?, ?, ?, ?, ?)",
                               arguments: [item.id.uuidString, passage.ordinal, passage.startOffset, passage.content, vector])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO knowledge_embedding_documents (itemId, sourceHash, modelIdentity) VALUES (?, ?, ?)",
                           arguments: [item.id.uuidString, sourceHash, identity])
        }
    }

    public func search(query: String, limit: Int = 5, allowedItemIDs: Set<UUID>? = nil,
                       scope: KnowledgeSearchScope = .all) async throws -> KnowledgeSearchResult {
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !query.isEmpty, limit > 0 else { return KnowledgeSearchResult(passages: [], usedSemanticSearch: false) }
        let allowedIDs = try await service.scopedItemIDs(scope, limitedTo: allowedItemIDs)
        if allowedIDs?.isEmpty == true { return KnowledgeSearchResult(passages: [], usedSemanticSearch: false) }
        let tokens = KnowledgeRanker.tokenize(query)
        let identity = provider?.indexIdentity ?? ""
        let semantic: (keys: [PassageKey], scanned: Int, vectorBytes: Int)?
        do {
            if let provider, try await indexStatus().indexed > 0 {
                let vectors = try await provider.embed([query], isQuery: true)
                guard vectors.count == 1 else { throw KnowledgeEmbeddingError.invalidVector }
                let vector = try KnowledgeVector.normalized(vectors[0])
                semantic = try await semanticCandidates(vector: vector, identity: identity, allowedIDs: allowedIDs)
            } else { semantic = nil }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            HubLogger.shared.warning("Knowledge semantic retrieval unavailable; using keyword passages")
            semantic = nil
        }

        // Reads after inference share one snapshot. A moved or edited lexical hit cannot revive a stale passage.
        return try await service.databaseQueue.read { db in
            try Task.checkCancellation()
            let inScope = try KnowledgeService.scopedItemIDs(scope, limitedTo: allowedItemIDs, in: db)
            let items = try KnowledgeService.searchCandidates(tokens: tokens.sorted(), limit: 500, allowedItemIDs: inScope, in: db)
            let lexical = try Self.keywordPassages(items, tokens: tokens)
            guard let semantic else { return Self.fuse(lexical, [], limit: limit, semantic: false) }
            var result = try Self.rankedPassages(lexical: lexical, keys: semantic.keys, identity: identity,
                                                 inScope: inScope, limit: limit, in: db)
            result.semanticRowsRead = semantic.scanned
            result.semanticVectorBytesRead = semantic.vectorBytes
            return result
        }
    }

    private static func keywordPassages(_ items: [KnowledgeItem], tokens: Set<String>) throws -> [KnowledgePassage] {
        var lexical: [(KnowledgePassage, Int)] = []
        for item in items {
            try Task.checkCancellation()
            for passage in KnowledgeChunker.split(item) {
                let fragment = KnowledgeItem(title: item.title, content: passage.content, tags: item.tags)
                let score = KnowledgeRanker.score(item: fragment, tokens: tokens)
                if score > 0 { lexical.append((passage, score)) }
            }
        }
        lexical.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        return lexical.prefix(50).map(\.0)
    }

    private struct PassageKey: Codable, Sendable {
        let itemID: String
        let ordinal: Int
        let sourceHash: String
        var sortID: String { "\(itemID):\(ordinal)" }
    }

    private func semanticCandidates(vector: [Float], identity: String, allowedIDs: Set<UUID>?) async throws
        -> (keys: [PassageKey], scanned: Int, vectorBytes: Int) {
        var best: [(PassageKey, Float)] = []
        var scanned = 0, vectorBytes = 0
        var cursor: PassageKey?
        let allowedJSON = try allowedIDs.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        while true {
            try Task.checkCancellation()
            let after = cursor
            let batch = try await service.databaseQueue.read { db in
                let scope = allowedJSON == nil ? "" : " AND c.itemId IN (SELECT value FROM json_each(?))"
                var args: StatementArguments = [identity, after?.itemID ?? "", after?.ordinal ?? -1]
                if let allowedJSON { args += [allowedJSON] }
                return try Row.fetchAll(db, sql: """
                    SELECT c.itemId, c.ordinal, c.embedding, d.sourceHash
                    FROM knowledge_passages c JOIN knowledge_embedding_documents d ON c.itemId = d.itemId
                    WHERE d.modelIdentity = ? AND (c.itemId, c.ordinal) > (?, ?) \(scope)
                    ORDER BY c.itemId, c.ordinal LIMIT 256
                    """, arguments: args).map { row in
                        (PassageKey(itemID: row["itemId"], ordinal: row["ordinal"], sourceHash: row["sourceHash"]), row["embedding"] as Data)
                    }
            }
            scanned += batch.count
            for (key, data) in batch {
                try Task.checkCancellation()
                vectorBytes += data.count
                let stored = try KnowledgeVector.decode(data)
                let score = zip(vector, stored).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                if score >= 0.4 { best.append((key, score)) }
            }
            best.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.sortID < $1.0.sortID }
            best = Array(best.prefix(50))
            guard batch.count == 256 else { break }
            cursor = batch.last?.0
        }
        try Task.checkCancellation()
        return (best.map(\.0), scanned, vectorBytes)
    }

    /// Validate candidate versions, fuse both lanes, then fetch only the displayed semantic text.
    private static func rankedPassages(lexical: [KnowledgePassage], keys: [PassageKey], identity: String,
                                       inScope: Set<UUID>?, limit: Int, in db: Database) throws -> KnowledgeSearchResult {
        let json = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        let from = """
            FROM json_each(?) k
            JOIN knowledge_passages c ON c.itemId = json_extract(k.value, '$.itemID')
                AND c.ordinal = json_extract(k.value, '$.ordinal')
            JOIN knowledge_embedding_documents d ON d.itemId = c.itemId
                AND d.sourceHash = json_extract(k.value, '$.sourceHash') AND d.modelIdentity = ?
            """
        let valid = try Row.fetchAll(db, sql: "SELECT c.itemId, c.ordinal " + from + " ORDER BY CAST(k.key AS INTEGER)",
                                     arguments: [json, identity]).compactMap { row -> KnowledgePassage? in
            guard let id = UUID(uuidString: row["itemId"]), inScope?.contains(id) != false else { return nil }
            return KnowledgePassage(itemID: id, title: "", ordinal: row["ordinal"], startOffset: 0, content: "")
        }
        let ranked = Self.fuse(lexical, valid, limit: limit, semantic: true)
        let wanted = Set(ranked.passages.map(\.id)).intersection(valid.map(\.id))
        let selected = String(decoding: try JSONEncoder().encode(keys.filter { wanted.contains($0.sortID) }), as: UTF8.self)
        var text: [String: KnowledgePassage] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT c.itemId, c.ordinal, c.startOffset, c.content, i.title " + from +
            " JOIN knowledge_items i ON i.id = c.itemId", arguments: [selected, identity]) {
            guard let id = UUID(uuidString: row["itemId"]) else { continue }
            let passage = KnowledgePassage(itemID: id, title: row["title"], ordinal: row["ordinal"], startOffset: row["startOffset"], content: row["content"])
            text[passage.id] = passage
        }
        var result = KnowledgeSearchResult(passages: ranked.passages.map { text[$0.id] ?? $0 }, usedSemanticSearch: true)
        result.semanticTextBytesRead = text.values.reduce(0) { $0 + $1.content.utf8.count }
        return result
    }
    private static func fuse(_ lexical: [KnowledgePassage], _ dense: [KnowledgePassage], limit: Int, semantic: Bool) -> KnowledgeSearchResult {
        var candidates: [String: (KnowledgePassage, Double)] = [:]
        for lane in [lexical, dense] {
            for (rank, passage) in lane.enumerated() {
                let score = 1.0 / Double(60 + rank + 1)
                candidates[passage.id] = (passage, (candidates[passage.id]?.1 ?? 0) + score)
            }
        }
        let ordered = candidates.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        var result: [KnowledgePassage] = []
        var perItem: [UUID: Int] = [:]
        for (passage, _) in ordered {
            guard perItem[passage.itemID, default: 0] < 2 else { continue }
            result.append(passage)
            perItem[passage.itemID, default: 0] += 1
            if result.count >= limit { break }
        }
        return KnowledgeSearchResult(passages: result, usedSemanticSearch: semantic)
    }
}

/// 按自然段/句界切分，字符窗口上限控制资源；保留原文字符偏移供来源定位。
enum KnowledgeChunker {
    static func split(_ item: KnowledgeItem) -> [KnowledgePassage] {
        let characters = Array(item.content)
        guard !characters.isEmpty else {
            return [KnowledgePassage(itemID: item.id, title: item.title, ordinal: 0, startOffset: 0, content: "")]
        }
        var start = 0
        var passages: [KnowledgePassage] = []
        while start < characters.count {
            var end = min(start + 1200, characters.count)
            if end < characters.count {
                let lower = start + 600
                if let boundary = (lower..<end).reversed().first(where: { characters[$0] == "\n" || characters[$0] == "。" }) {
                    end = boundary + 1
                }
            }
            passages.append(KnowledgePassage(itemID: item.id, title: item.title, ordinal: passages.count,
                                             startOffset: start, content: String(characters[start..<end])))
            if end == characters.count { break }
            start = end - 120
        }
        return passages
    }
}
