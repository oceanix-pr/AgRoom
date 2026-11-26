import SwiftUI
import AgRoomCore

enum KnowledgeTreeAction {
    case newBase
    case newFolder(base: UUID, parent: UUID?)
    case rename(KnowledgeNodeID)
    case delete(KnowledgeNodeID)
    case move(KnowledgeNodeID)
    case reorder(KnowledgeNodeID, earlier: Bool)
}

struct KnowledgeTreeSidebar: View {
    @Bindable var model: KnowledgeBrowserModel
    let onAction: (KnowledgeTreeAction) -> Void
    let onDrop: ([String], UUID?, UUID?) -> Bool

    private var unfiled: [KnowledgeItemSummary] { (try? model.snapshot.scopedItems(.unfiled)) ?? [] }
    private var showsUnfiledItems: Bool {
        model.selection == .unfiled || (model.selectedItemID != nil && model.selectedBaseID == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("knowledge.base.section"))
                    .font(MeetTypography.sectionTitle)
                Spacer()
                Button { onAction(.newBase) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help(L.string("knowledge.base.new"))
                    .accessibilityLabel(L.string("knowledge.base.new"))
                    .disabled(model.isMutating)
            }
            .padding(.horizontal, MeetSpacing.md)
            .columnHeader()
            Divider()
            List(selection: $model.selection) {
                Label {
                    HStack {
                        Text(L.string("knowledge.folder.all"))
                            .foregroundStyle(model.selection == .all ? Color.white : Color.primary)
                        Spacer()
                        count(model.snapshot.items.count)
                    }
                } icon: { Image(systemName: "tray.full") }
                .font(MeetTypography.navigation)
                .tag(KnowledgeSelection.all)
                .padding(.vertical, MeetSpacing.xs)

                Label {
                    HStack {
                        Text(L.string("knowledge.unfiled"))
                            .foregroundStyle(model.selection == .unfiled ? Color.white : Color.primary)
                        Spacer()
                        count(unfiled.count)
                    }
                } icon: { Image(systemName: "tray") }
                .font(MeetTypography.navigation)
                .tag(KnowledgeSelection.unfiled)
                .padding(.vertical, MeetSpacing.xs)
                .dropDestination(for: String.self) { values, _ in onDrop(values, nil, nil) }

                if showsUnfiledItems {
                    ForEach(unfiled) { item in
                        treeRow(.init(selection: .item(item.id), title: item.title,
                                      icon: item.kind == .wiki ? "text.book.closed" : "doc.text",
                                      depth: 1, expandable: false, count: nil))
                    }
                }
                Section {
                    ForEach(model.visibleRows) { row in treeRow(row) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onMoveCommand { direction in
                guard let node = model.selection.nodeID,
                      let row = model.visibleRows.first(where: { $0.selection == model.selection }), row.expandable else { return }
                if direction == .right, !model.expanded.contains(node) { model.toggle(node) }
                if direction == .left, model.expanded.contains(node) { model.toggle(node) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder private func treeRow(_ row: KnowledgeTreeRow) -> some View {
        if let node = row.selection.nodeID {
            let content = rowLabel(row)
                .tag(row.selection)
                .help(row.title)
                .contextMenu { actions(for: node) }
            switch node {
            case .base(let id):
                content.dropDestination(for: String.self) { values, _ in onDrop(values, id, nil) }
            case .folder(let id):
                content
                    .draggable(dragValue(node))
                    .dropDestination(for: String.self) { values, _ in
                        onDrop(values, model.snapshot.foldersByID[id]?.baseId, id)
                    }
            case .item:
                content.draggable(dragValue(node))
            }
        }
    }

    private func rowLabel(_ row: KnowledgeTreeRow) -> some View {
        HStack(spacing: MeetSpacing.sm) {
            if row.expandable, let node = row.selection.nodeID {
                Button { model.toggle(node) } label: {
                    Image(systemName: model.expanded.contains(node) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.selection == row.selection ? Color.white.opacity(0.85) : Color.secondary)
                .accessibilityLabel(L.string(model.expanded.contains(node) ? "knowledge.collapse" : "knowledge.expand"))
            } else {
                Color.clear.frame(width: 12, height: 24)
            }
            Image(systemName: row.icon)
                .font(MeetTypography.listTitle)
                .foregroundStyle(model.selection == row.selection ? Color.white : color(for: row.selection))
                .frame(width: 18)
            Text(row.title)
                .font(isBase(row.selection) ? MeetTypography.navigation.weight(.semibold) : MeetTypography.navigation)
                .foregroundStyle(model.selection == row.selection ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: MeetSpacing.xs)
            if let value = row.count {
                Text(value.formatted()).font(MeetTypography.secondary)
                    .foregroundStyle(model.selection == row.selection ? Color.white.opacity(0.85) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .padding(.vertical, MeetSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func count(_ value: Int) -> some View {
        Text(value.formatted()).font(MeetTypography.secondary).foregroundStyle(.secondary).monospacedDigit()
    }

    private func isBase(_ selection: KnowledgeSelection) -> Bool {
        if case .base = selection { true } else { false }
    }

    private func color(for selection: KnowledgeSelection) -> Color {
        switch selection {
        case .base: MeetStatusColor.resource
        case .folder: MeetStatusColor.textual
        default: .secondary
        }
    }

    private func dragValue(_ node: KnowledgeNodeID) -> String {
        let kind: String
        let id: UUID
        switch node {
        case .base(let value): kind = "base"; id = value
        case .folder(let value): kind = "folder"; id = value
        case .item(let value): kind = "item"; id = value
        }
        return "agroom-knowledge:\(model.space.rawValue):\(kind):\(id.uuidString)"
    }

    @ViewBuilder private func actions(for node: KnowledgeNodeID) -> some View {
        Group {
            switch node {
            case .base(let id):
                Button(L.string("knowledge.folder.new")) { onAction(.newFolder(base: id, parent: nil)) }
                Button(L.string("knowledge.base.rename")) { onAction(.rename(node)) }
            case .folder(let id):
                if let folder = model.snapshot.foldersByID[id] {
                    Button(L.string("knowledge.folder.new_sub")) { onAction(.newFolder(base: folder.baseId, parent: id)) }
                }
                Button(L.string("knowledge.folder.rename")) { onAction(.rename(node)) }
                Button(L.string("knowledge.move")) { onAction(.move(node)) }
            case .item:
                Button(L.string("knowledge.move")) { onAction(.move(node)) }
            }
            Divider()
            Button(L.string("knowledge.order.earlier")) { onAction(.reorder(node, earlier: true)) }
            Button(L.string("knowledge.order.later")) { onAction(.reorder(node, earlier: false)) }
            Divider()
            Button(L.string("common.delete"), role: .destructive) { onAction(.delete(node)) }
        }
        .disabled(model.isMutating)
    }
}

struct KnowledgeMoveRequest: Identifiable {
    let id = UUID()
    let node: KnowledgeNodeID
    var itemIDs: [UUID]? = nil

    init(node: KnowledgeNodeID) { self.node = node }
    init(items: [UUID]) { self.node = .item(items[0]); self.itemIDs = items }
}

struct KnowledgeMoveSheet: View {
    let snapshot: KnowledgeBrowserSnapshot
    let node: KnowledgeNodeID
    var itemCount: Int = 1
    let onMove: (UUID?, UUID?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination: KnowledgeSelection?
    @State private var isMoving = false
    @State private var errorMessage: String?

    private var excluded: Set<UUID> {
        if case .folder(let id) = node { snapshot.descendantIDs(of: id) } else { [] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            Text(L.string("knowledge.move")).font(MeetTypography.pageTitle)
            if itemCount > 1 { Text(L.format("knowledge.selection.count", itemCount)).font(MeetTypography.control) }
            Text(L.string("knowledge.move.help")).font(MeetTypography.control).foregroundStyle(.secondary)
            List(selection: $destination) {
                if case .item = node {
                    Label(L.string("knowledge.unfiled"), systemImage: "tray").tag(KnowledgeSelection.unfiled)
                        .foregroundStyle(destination == .unfiled ? Color.white : Color.primary)
                }
                ForEach(snapshot.bases) { base in
                    Label(base.name, systemImage: "books.vertical").tag(KnowledgeSelection.base(base.id))
                        .foregroundStyle(destination == .base(base.id) ? Color.white : Color.primary)
                    ForEach(snapshot.folders.filter { $0.baseId == base.id && !excluded.contains($0.id) }) { folder in
                        Label(snapshot.ancestors(of: folder.id).map(\.name).joined(separator: " / "), systemImage: "folder")
                            .padding(.leading, MeetSpacing.lg)
                            .tag(KnowledgeSelection.folder(folder.id))
                            .foregroundStyle(destination == .folder(folder.id) ? Color.white : Color.primary)
                    }
                }
            }
            .font(MeetTypography.navigation)
            .disabled(isMoving)
            if let errorMessage { Text(errorMessage).font(MeetTypography.control).foregroundStyle(.red) }
            HStack {
                if isMoving { ProgressView().controlSize(.small) }
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isMoving)
                Button(L.string("knowledge.move")) { move() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(destination == nil || isMoving)
            }
        }
        .padding(MeetSpacing.xl)
        .frame(width: 480, height: 430)
        .interactiveDismissDisabled(isMoving)
    }

    private func move() {
        guard let destination else { return }
        let baseID: UUID?
        let folderID: UUID?
        switch destination {
        case .unfiled: baseID = nil; folderID = nil
        case .base(let id): baseID = id; folderID = nil
        case .folder(let id): baseID = snapshot.foldersByID[id]?.baseId; folderID = id
        default: return
        }
        isMoving = true
        Task {
            do { try await onMove(baseID, folderID); dismiss() }
            catch {
                errorMessage = (error as? KnowledgeOrganizationError).map { L.string("knowledge.error.\($0.rawValue)") }
                    ?? L.string("knowledge.error.operation")
                isMoving = false
            }
        }
    }
}
