import Foundation
import GRDB

public struct NativeAppKnowledgeSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let preview: String
    public init(id: UUID, title: String, preview: String) { self.id = id; self.title = title; self.preview = preview }
}

public struct NativeAppKnowledgeDetail: Sendable {
    public let content: String
    public let isTruncated: Bool
    public init(content: String, isTruncated: Bool) { self.content = content; self.isTruncated = isTruncated }
}

public struct NativeAppKnowledgePage: Sendable {
    public let items: [NativeAppKnowledgeSummary]
    public let hasMore: Bool
    public init(items: [NativeAppKnowledgeSummary], hasMore: Bool) { self.items = items; self.hasMore = hasMore }
}

/// Structured, bounded reads from exactly one space connection. No model prose is
/// parsed into UI data, and no secret or cross-space capability is exposed to DSL.
public struct NativeAppResources: Sendable {
    public let space: AppSpace
    private let knowledge: KnowledgeService
    public init(space: AppSpace, knowledge: KnowledgeService) { self.space = space; self.knowledge = knowledge }

    public func queryKnowledge(search: String, offset: Int, limit: Int) async throws -> NativeAppKnowledgePage {
        let boundedLimit = min(50, max(1, limit))
        let boundedOffset = min(10_000, max(0, offset))
        let term = String(search.prefix(256)).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        try Task.checkCancellation()
        return try await knowledge.databaseQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, substr(title, 1, 512) AS title, substr(content, 1, 180) AS preview
                FROM knowledge_items
                WHERE ? = '' OR title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\'
                ORDER BY updatedAt DESC, id ASC LIMIT ? OFFSET ?
                """, arguments: [term, "%" + term + "%", "%" + term + "%", boundedLimit + 1, boundedOffset])
            let items = rows.prefix(boundedLimit).compactMap { row -> NativeAppKnowledgeSummary? in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return NativeAppKnowledgeSummary(id: id, title: row["title"], preview: row["preview"])
            }
            return NativeAppKnowledgePage(items: items, hasMore: rows.count > boundedLimit && boundedOffset + boundedLimit < 10_000)
        }
    }

    public func knowledgeContent(id: UUID) async throws -> NativeAppKnowledgeDetail {
        try Task.checkCancellation()
        return try await knowledge.databaseQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT substr(content, 1, 32768) AS content, length(content) > 32768 AS truncated FROM knowledge_items WHERE id = ?", arguments: [id.uuidString]) else {
                throw NativeAppError(.missing)
            }
            return NativeAppKnowledgeDetail(content: row["content"], isTruncated: row["truncated"])
        }
    }

    public func makeSaveCommand(title: String, content: String) throws -> (DispatcherEngine, ToolCallRaw) {
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil)
        let context = ExecutionContext(space: space, permissionPolicy: policy, deadline: Date().addingTimeInterval(300))
        let engine = DispatcherEngine(tools: [NativeAppKnowledgeCreateTool(service: knowledge)], systemPrompt: "",
            permissionPolicy: policy, executionContext: context)
        let data = try JSONEncoder().encode(["title": title, "content": content])
        return (engine, ToolCallRaw(id: UUID().uuidString, name: "nativeapp_knowledge_create", argumentsJSON: String(decoding: data, as: UTF8.self)))
    }
}

private struct NativeAppKnowledgeCreateTool: DispatcherTool {
    let service: KnowledgeService
    var requiresConfirmation: Bool { true }
    var definition: ToolDefinition {
        ToolDefinition(name: "nativeapp_knowledge_create", description: "Create a new knowledge entry in this space. Never overwrite an existing entry.",
            parametersSchemaJSON: #"{"type":"object","properties":{"title":{"type":"string"},"content":{"type":"string"}},"required":["title","content"]}"#)
    }
    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let title = ToolArguments.string(args, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = ToolArguments.string(args, "content")
        guard !title.isEmpty, title.utf8.count <= 512, content.utf8.count <= 32 * 1024 else {
            throw NativeAppError(.invalidDefinition, path: "title/content")
        }
        try Task.checkCancellation()
        let item = KnowledgeItem(title: title, content: content)
        try await service.save(item)
        return item.id.uuidString
    }
}
