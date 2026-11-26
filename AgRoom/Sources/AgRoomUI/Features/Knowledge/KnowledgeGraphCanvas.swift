import SwiftUI
import AgRoomCore

// MARK: - Knowledge Graph Canvas

/// 知识图谱可视化：条目/标签二分图，支持缩放、平移、拖拽节点、点击选中聚焦邻居、双击条目跳转编辑
struct KnowledgeGraphCanvas: View {
    let graph: KnowledgeGraph
    /// 双击条目节点时回调（跳转编辑）
    var onOpenEntry: ((UUID) -> Void)? = nil
    var onFocus: ((String?) -> Void)? = nil

    @State private var positions: [String: CGPoint] = [:]
    @State private var selectedNodeId: String?
    @State private var neighborIds: Set<String> = []
    @State private var zoom: CGFloat = 1.0
    @State private var gestureZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var gesturePan: CGSize = .zero
    @State private var dragTranslation: [String: CGSize] = [:]
    @State private var autoFit = true

    /// 布局设计空间尺寸
    private let designSize = CGSize(width: 1000, height: 700)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 边
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let from = currentPosition(of: edge.from),
                              let to = currentPosition(of: edge.to) else { continue }
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        let isFocused = isEdgeFocused(edge)
                        context.stroke(
                            path,
                            with: .color(isFocused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)),
                            style: StrokeStyle(lineWidth: isFocused ? 1.6 : 1, dash: edge.kind == .similarity ? [5, 4] : [])
                        )
                    }
                }

                // 节点
                ForEach(graph.nodes) { node in
                    nodeView(node)
                        .position(currentPosition(of: node.id) ?? designCenter)
                        .gesture(dragGesture(for: node.id))
                }
            }
            .frame(width: designSize.width, height: designSize.height)
            .scaleEffect(zoom * gestureZoom)
            .offset(x: pan.width + gesturePan.width, y: pan.height + gesturePan.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(magnificationGesture)
            .onTapGesture {
                // 点击空白处取消选中
                selectedNodeId = nil
                neighborIds = []
                onFocus?(nil)
            }
            .onAppear { fit(in: geometry.size) }
            .onChange(of: geometry.size) { _, size in if autoFit { fit(in: size) } }
            .overlay(alignment: .topTrailing) {
                Button { fit(in: geometry.size) } label: {
                    Label(L.string("graph.fit"), systemImage: "arrow.up.left.and.arrow.down.right")
                }.font(MeetTypography.control).buttonStyle(.borderless).padding(10)
            }
        }
        .clipped()
        .onAppear {
            layoutIfNeeded()
        }
        .onChange(of: graph) { _, _ in
            layoutIfNeeded()
        }
    }

    private var designCenter: CGPoint {
        CGPoint(x: designSize.width / 2, y: designSize.height / 2)
    }

    private func fit(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        autoFit = true
        zoom = min(1, max(0.2, min(size.width / designSize.width, size.height / designSize.height)))
        pan = .zero
    }

    // MARK: - Layout

    /// 确定性初始布局：条目在外圈，标签在内圈；节点数变化时重排
    private func layoutIfNeeded() {
        if !graph.nodes.isEmpty && Set(positions.keys) == Set(graph.nodes.map(\.id)) { return }
        let entries = graph.nodes.filter { $0.kind == .entry }
        let tags = graph.nodes.filter { $0.kind != .entry }
        let center = designCenter

        var computed: [String: CGPoint] = [:]
        for (index, node) in entries.enumerated() {
            let angle = 2 * Double.pi * Double(index) / Double(max(1, entries.count)) - Double.pi / 2
            computed[node.id] = CGPoint(
                x: center.x + cos(angle) * 270,
                y: center.y + sin(angle) * 250
            )
        }
        for (index, node) in tags.enumerated() {
            let angle = 2 * Double.pi * Double(index) / Double(max(1, tags.count))
            computed[node.id] = CGPoint(
                x: center.x + cos(angle) * 110,
                y: center.y + sin(angle) * 100
            )
        }
        positions = computed
    }

    private func currentPosition(of nodeId: String) -> CGPoint? {
        guard var point = positions[nodeId] else { return nil }
        if let translation = dragTranslation[nodeId] {
            point.x += translation.width
            point.y += translation.height
        }
        return point
    }

    private func isEdgeFocused(_ edge: KnowledgeGraph.Edge) -> Bool {
        guard let selected = selectedNodeId else { return false }
        return edge.from == selected || edge.to == selected
    }

    // MARK: - Node View

    private func nodeView(_ node: KnowledgeGraph.Node) -> some View {
        let isSelected = selectedNodeId == node.id
        let isNeighbor = neighborIds.contains(node.id)
        let dimmed = selectedNodeId != nil && !isSelected && !isNeighbor

        return VStack(spacing: 2) {
            Circle()
                .fill(node.kind == .entry ? Color.accentColor : node.kind == .entity ? Color.purple : Color.secondary.opacity(0.6))
                .frame(width: node.kind == .entry ? 14 : 9, height: node.kind == .entry ? 14 : 9)
                .overlay(
                    Circle().stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
                        .frame(width: node.kind == .entry ? 20 : 15, height: node.kind == .entry ? 20 : 15)
                )
            Text(node.label)
                .font(MeetTypography.secondary)
                .lineLimit(1)
                .frame(maxWidth: 120)
                .help(node.label)
                .foregroundColor(dimmed ? .secondary.opacity(0.4) : .primary)
                .opacity(graph.nodes.count <= 35 || isSelected || isNeighbor ? 1 : 0)
        }
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.kind == .entry, let itemID = node.itemID {
                onOpenEntry?(itemID)
            }
        }
        .onTapGesture {
            selectedNodeId = node.id
            neighborIds = graph.neighbors(of: node.id)
            onFocus?(node.id)
        }
    }

    // MARK: - Gestures

    private func dragGesture(for nodeId: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragTranslation[nodeId] = CGSize(
                    width: value.translation.width / (zoom * gestureZoom),
                    height: value.translation.height / (zoom * gestureZoom)
                )
            }
            .onEnded { value in
                if var point = positions[nodeId] {
                    point.x += value.translation.width / (zoom * gestureZoom)
                    point.y += value.translation.height / (zoom * gestureZoom)
                    positions[nodeId] = point
                }
                dragTranslation[nodeId] = nil
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                autoFit = false
                gesturePan = value.translation
            }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
                gesturePan = .zero
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                autoFit = false
                gestureZoom = value
            }
            .onEnded { value in
                zoom = min(3.0, max(0.4, zoom * value))
                gestureZoom = 1.0
            }
    }
}
