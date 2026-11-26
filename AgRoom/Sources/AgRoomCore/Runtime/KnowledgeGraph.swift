import Foundation

// MARK: - Knowledge Graph

/// 知识图谱模型（UI 无关）：条目与标签构成二分图，
/// 边来源：条目—标签归属、条目间 [[显式引用]]
public struct KnowledgeGraph: Sendable, Equatable {

    public struct Node: Identifiable, Sendable, Equatable {
        public enum Kind: Sendable { case entry, tag, entity }
        public let id: String
        public let label: String
        public let kind: Kind
        /// 条目节点对应的条目 id（标签节点为 nil）
        public let itemID: UUID?
    }

    public struct Edge: Identifiable, Sendable, Equatable {
        public enum Kind: Sendable { case tag, reference, similarity, mention, relation }
        public let id: String
        public let from: String
        public let to: String
        public var kind: Kind = .reference
        public var label: String? = nil
        public var evidence: Evidence? = nil
        public var decision: String = "proposed"
    }

    public struct Evidence: Sendable, Equatable {
        public let itemID: UUID
        public let offset: Int
        public let quote: String
        public let model: String
    }

    public let nodes: [Node]
    public let edges: [Edge]

    /// 从条目集合构建图谱
    public static func build(from items: [KnowledgeItem], paths: [UUID: String] = [:]) -> KnowledgeGraph {
        var nodes: [Node] = []
        var edges: [Edge] = []
        var tagNodeIds: [String: String] = [:]
        let byTitle = Dictionary(grouping: items, by: { $0.title.lowercased() })

        // 条目节点
        for item in items {
            let nodeId = item.id.uuidString
            nodes.append(Node(id: nodeId, label: item.title, kind: .entry, itemID: item.id))
        }

        // 标签节点 + 归属边
        for item in items {
            let entryNodeId = item.id.uuidString
            for tag in Set(item.tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) {
                let key = tag.lowercased()
                let tagNodeId: String
                if let existing = tagNodeIds[key] {
                    tagNodeId = existing
                } else {
                    tagNodeId = "tag:\(key)"
                    tagNodeIds[key] = tagNodeId
                    nodes.append(Node(id: tagNodeId, label: tag, kind: .tag, itemID: nil))
                }
                edges.append(Edge(id: "\(entryNodeId)-\(tagNodeId)", from: entryNodeId, to: tagNodeId, kind: .tag))
            }
        }

        // 显式引用边：[[条目名]]
        for item in items {
            let fromNodeId = item.id.uuidString
            for reference in Set(item.explicitReferences) {
                let candidates: [KnowledgeItem]
                if let id = UUID(uuidString: reference) { candidates = items.filter { $0.id == id } }
                else if reference.contains("/") { candidates = items.filter { paths[$0.id]?.lowercased() == reference.lowercased() } }
                else {
                    let matching = byTitle[reference.lowercased()] ?? []
                    let siblings = matching.filter { $0.baseId == item.baseId && $0.folderId == item.folderId }
                    let sameBase = matching.filter { $0.baseId == item.baseId }
                    candidates = !siblings.isEmpty ? siblings : !sameBase.isEmpty ? sameBase : matching
                }
                if candidates.count == 1, let target = candidates.first, target.id != item.id {
                    let toNodeId = target.id.uuidString
                    let edgeId = "ref:\(fromNodeId)-\(toNodeId)"
                    if !edges.contains(where: { $0.id == edgeId }) {
                        edges.append(Edge(id: edgeId, from: fromNodeId, to: toNodeId))
                    }
                }
            }
        }

        return KnowledgeGraph(nodes: nodes, edges: edges)
    }

    /// 某节点的邻居 id 集合（聚焦邻居用）
    public func neighbors(of nodeId: String) -> Set<String> {
        var result = Set<String>()
        for edge in edges {
            if edge.from == nodeId { result.insert(edge.to) }
            if edge.to == nodeId { result.insert(edge.from) }
        }
        return result
    }
}
