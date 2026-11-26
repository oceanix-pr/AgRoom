import SwiftUI
import AgRoomCore

struct KnowledgeImportContext: Identifiable {
    let id = UUID()
    let baseID: UUID?
    let folderID: UUID?
    var sourceID: UUID? = nil
}

struct KnowledgeSourceMaintenanceView: View {
    let item: KnowledgeItem
    let service: KnowledgeImportService
    let onUpdate: (UUID) -> Void
    @State private var sources: [KnowledgeSource] = []
    @State private var revisions: [KnowledgeRevision] = []
    @State private var statuses: [UUID: KnowledgeSourceStatus] = [:]
    @State private var selected: KnowledgeRevision?
    @State private var busy = false
    @State private var errorText: String?
    @State private var visible = false
    @State private var generation = UUID()
    @State private var expanded = false
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sources.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sources) { source in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(URL(fileURLWithPath: source.path).lastPathComponent).font(.subheadline.bold()).help(source.path)
                                if let status = statuses[source.id] {
                                    Text(L.string("knowledge.source.state.\(status.state.rawValue)")).font(.caption).foregroundStyle(status.state == .current ? Color.secondary : .orange)
                                    if status.edited { Text(L.string("knowledge.source.edited")).font(.caption).foregroundStyle(.orange) }
                                } else if source.missing { Text(L.string("knowledge.source.state.missing")).font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    Button(L.string("knowledge.source.check")) { check(source.id) }.disabled(busy)
                                    Button(L.string("knowledge.source.update")) { onUpdate(source.id) }.disabled(busy)
                                    Text(source.updatedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                                }.font(.caption).controlSize(.small)
                            }
                        }
                        Text(L.string("knowledge.import.retention")).font(.caption).foregroundStyle(.secondary)
                        if !revisions.isEmpty {
                            Text(L.string("knowledge.source.versions")).font(.caption.bold())
                            ForEach(revisions) { revision in
                                Button {
                                    selected = revision
                                } label: {
                                    HStack {
                                        Text(revision.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                        Text(L.string("knowledge.source.origin.\(revision.origin == "manual" ? "manual" : "import")"))
                                        if revision.id == revisions.first?.id { Text(L.string("knowledge.source.version.latest")).foregroundStyle(.secondary) }
                                    }
                                }.buttonStyle(.link).font(.caption)
                            }
                        }
                        if busy { ProgressView().controlSize(.small) }
                        if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: {
                    Button { expanded.toggle() } label: {
                        Text(L.string("knowledge.source.title")).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(10).background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; generation = UUID(); checkTask?.cancel(); checkTask = nil }
        .task(id: "\(item.updatedAt.timeIntervalSinceReferenceDate):\(expanded)") { await load() }
        .sheet(item: $selected) { revision in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(revision.item.title).font(.title2)
                    Spacer()
                    Button(L.string("common.close")) { selected = nil }.keyboardShortcut(.cancelAction)
                }
                Text(L.string("knowledge.source.version.help")).font(.caption).foregroundStyle(.secondary)
                KnowledgeImportText(text: revision.item.content, identity: revision.id.uuidString)
            }.padding(20).frame(width: 740, height: 560)
        }
    }

    private func load() async {
        let ticket = UUID(); generation = ticket
        checkTask?.cancel(); checkTask = nil
        busy = false
        do {
            let values = try await service.sources(itemID: item.id)
            let history = expanded ? try await service.revisions(itemID: item.id) : []
            guard visible, generation == ticket, !Task.isCancelled else { return }
            sources = values; revisions = history; statuses = [:]
        } catch { if visible, generation == ticket { errorText = L.actionableError(error, fallbackKey: "knowledge.error.operation") } }
    }
    private func check(_ sourceID: UUID) {
        guard !busy else { return }
        busy = true; errorText = nil
        let ticket = generation
        checkTask = Task {
            defer { if generation == ticket { busy = false; checkTask = nil } }
            do {
                let status = try await service.checkSource(sourceID)
                guard visible, generation == ticket, !Task.isCancelled else { return }
                statuses[sourceID] = status
            } catch { if visible, generation == ticket { errorText = L.actionableError(error, fallbackKey: "knowledge.error.operation") } }
        }
    }
}
