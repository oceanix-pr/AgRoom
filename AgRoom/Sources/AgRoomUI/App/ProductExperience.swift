import AppKit
import QuickLookUI
import SwiftUI
import AgRoomCore

@MainActor
struct ProductRoute: Identifiable, Sendable {
    static let notification = Notification.Name("agroom.product.navigate")
    let id = UUID()
    let space: AppSpace
    let page: String
    var sessionID: UUID? = nil
    var draft: String? = nil
    var workspaceID: UUID? = nil
    var messageID: UUID? = nil
    var taskID: UUID? = nil
    var runID: UUID? = nil
    var draftMode: ChatMode? = nil
    var searchQuery: String? = nil
    var contentID: String? = nil
    var mailReference: MailSourceReference? = nil
    var artifactVersionID: UUID? = nil
    var showTasks = false
    var scheduledDraft: ScheduledTaskDraft? = nil
    var settingsTab: SettingsTab? = nil
    static func open(space: AppSpace, page: String, sessionID: UUID? = nil, draft: String? = nil, workspaceID: UUID? = nil,
                     messageID: UUID? = nil, taskID: UUID? = nil, runID: UUID? = nil, draftMode: ChatMode? = nil) {
        post(ProductRoute(space: space, page: page, sessionID: sessionID, draft: draft, workspaceID: workspaceID,
            messageID: messageID, taskID: taskID, runID: runID, draftMode: draftMode))
    }
    static func post(_ route: ProductRoute) { NotificationCenter.default.post(name: notification, object: route) }

    static func source(_ item: ProductTaskCenterItem, space: AppSpace) -> ProductRoute {
        switch item.source {
        case .chat: .init(space: space, page: "chat", sessionID: item.sessionID, messageID: item.messageID, runID: item.sourceID)
        case .team: .init(space: space, page: "team", taskID: item.sourceID)
        case .scheduled: .init(space: space, page: "scheduled", taskID: item.parentID, runID: item.sourceID)
        case .job: .init(space: space, page: item.origin ?? "chat")
        }
    }
}

extension BackgroundJob.State {
    @MainActor var taskCenterLabel: String? {
        switch self {
        case .awaitingSave, .interruptionAcknowledged: L.string("jobs.state.\(rawValue)")
        default: nil
        }
    }
}

extension TaskRunStatus {
    @MainActor var label: String { L.string("product.task.\(rawValue)") }
    var icon: String {
        switch self {
        case .running: "gearshape"
        case .waitingForConfirmation: "hand.raised"
        case .waitingForInput: "questionmark.bubble"
        case .succeeded: "checkmark.circle"
        case .incomplete: "exclamationmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        case .recoveryRequired: "exclamationmark.triangle"
        }
    }
}

struct RequestContextView: View {
    let report: RequestContextReport
    let messages: [ChatMessage]
    let onQuote: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.string("product.context.title")).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text(L.format("product.context.counts", report.includedHistory.count, report.omittedHistory.count, report.truncatedHistory.count))
                Text(L.format("product.context.request", report.estimatedTokens, report.imageCount, report.toolNames.count, report.requestCount))
                if let budget = report.contextTokenBudget {
                    Text(L.format("model.parameters.request_context_budget", budget))
                }
                if let output = report.requestOutputLimit, let level = report.requestReasoningLevel {
                    Text(L.format("model.parameters.request_generation", output, ModelReasoningProfile.levelLabel(level)))
                }
                Text(L.string("product.context.estimate.help")).foregroundStyle(.secondary)
                ForEach(report.attachments, id: \.self) { name in Text(L.format("product.context.attachment", name)) }
                ForEach(report.attachmentWarnings ?? [], id: \.self) { name in Label(L.format("product.context.attachment.warning", name), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ForEach(report.omittedImages, id: \.self) { name in Label(L.format("product.context.image.omitted", name), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ForEach(Array((report.memoryContents ?? []).enumerated()), id: \.offset) { _, content in
                    Text(L.format("product.context.memory", content)).textSelection(.enabled)
                }
                if let compressed = report.compressedToolResults, compressed > 0 {
                    Text(L.format("product.context.tool.truncated", compressed)).foregroundStyle(.orange)
                }
                if let context = report.resourceContext {
                    RunResourceContextView(context: context)
                }
                Text(L.string("product.context.files.help")).foregroundStyle(.secondary)
                ForEach(messages.filter { report.truncatedHistory.contains($0.id) || report.omittedHistory.contains($0.id) }) { message in
                    HStack(alignment: .top) {
                        Text(String(message.content.prefix(100))).lineLimit(2)
                        Spacer()
                        Button(L.string("product.context.quote")) { onQuote(ChatViewModel.engineText(for: message)) }
                    }
                }
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption).padding(8)
    }
}

struct RunResourceContextView: View {
    let context: RunResourceContext
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if context.excludesMemory {
                Text(L.string("project.memory.current")).foregroundStyle(.orange)
                Text(L.string("project.memory.help")).foregroundStyle(.secondary)
            }
            if let project = context.project {
                DisclosureGroup(L.string("project.title")) {
                    if !project.configuration.instructions.isEmpty { Text(project.configuration.instructions).textSelection(.enabled) }
                    Text(project.configuration.knowledgeBaseIDs.map { L.format("project.knowledge.count", $0.count) } ?? L.string("project.knowledge.all.short"))
                    Text(L.format("project.request.skills", project.configuration.preferredSkillNames.isEmpty ? L.string("project.skills.none") : project.configuration.preferredSkillNames.joined(separator: ", ")))
                }
            }
        }.font(.caption)
    }
}

/// Available tools and actual invocations are different facts, shown in one dedicated tab.
struct RequestToolsView: View {
    let report: RequestContextReport
    let trace: [DispatcherTraceEntry]
    let onSelect: (Int, DispatcherTraceEntry) -> Void
    @State private var search = ""

    private var names: [String] {
        Array(Set((report.availableToolNames ?? report.toolNames) + (report.mcpToolNames ?? []))).sorted()
    }

    private func title(_ name: String) -> String {
        for server in report.mcpServers ?? [] {
            if let tool = server.tools.first(where: { $0.id == name }) { return server.name + " / " + tool.name }
        }
        return ChatView.localizedToolName(name)
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || title(name).localizedCaseInsensitiveContains(search) || name.localizedCaseInsensitiveContains(search)
            || description(name).localizedCaseInsensitiveContains(search)
    }

    private func description(_ name: String) -> String {
        report.mcpServers?.flatMap(\.tools).first(where: { $0.id == name })?.description ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L.string("mcp.tools.search"), text: $search).textFieldStyle(.roundedBorder)
            Text(L.format("chat.tools.counts", names.count, trace.count)).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L.string("chat.tools.used")).font(.headline)
                    if trace.isEmpty { Text(L.string("chat.trace.empty")).font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array(trace.enumerated()).filter { matches($0.element.toolName) }, id: \.offset) { index, entry in
                        Button { onSelect(index, entry) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: entry.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(index + 1). " + title(entry.toolName)).font(.callout)
                                    Text(String(format: "%.2fs", entry.duration)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Divider()
                    Text(L.string("product.context.tools")).font(.headline)
                    Text(L.string("chat.tools.available.help")).font(.caption).foregroundStyle(.secondary)
                    ForEach(names.filter(matches), id: \.self) { name in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(name)).font(.callout)
                            Text(name).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            if !description(name).isEmpty {
                                Text(description(name)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12)
    }
}

struct KnowledgeSourceView: View {
    let item: KnowledgeItem
    let citation: KnowledgeCitation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(item.title).font(.title2); Spacer(); Button(L.string("common.close")) { dismiss() } }
            Text(L.format("product.knowledge.passage", citation.passage)).font(.caption).foregroundStyle(.secondary)
            Text(L.string("product.knowledge.position.help")).font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let offset = min(max(citation.offset, 0), item.content.count)
                        Text(String(item.content.prefix(offset))).textSelection(.enabled)
                        Text(String(item.content.dropFirst(offset))).textSelection(.enabled).id("passage")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onAppear { proxy.scrollTo("passage", anchor: .top) }
            }
        }.padding(20).frame(width: 720, height: 600)
    }
}

struct MemoryEditorSheet: View {
    let memory: MemoryItem
    let service: MemoryService
    let sessionService: SessionService?
    let workspaces: [ChatWorkspace]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var category: MemoryCategory = .other
    @State private var workspaceID: UUID?
    @State private var alwaysInclude = false
    @State private var source: [ChatMessage]?
    @State private var showsSource = false
    @State private var errorText: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("product.memory.edit")).font(.title2)
            TextEditor(text: $content).frame(minHeight: 120)
            Picker(L.string("memory.category.label"), selection: $category) {
                ForEach(MemoryCategory.allCases, id: \.self) { category in Text(category.localizedLabel).tag(category) }
            }
            MemoryScopePicker(selection: $workspaceID, workspaces: workspaces)
            if category == .preference {
                Toggle(L.string("memory.always.include"), isOn: $alwaysInclude)
            }
            if let basis = memory.sourceBasis, let quote = memory.sourceQuote {
                Text(L.string(basis == .stated ? "memory.source.stated" : "memory.source.inferred")).font(.caption)
                Text(verbatim: quote).textSelection(.enabled)
            }
            if memory.sourceSessionID != nil {
                DisclosureGroup(L.string("product.memory.source"), isExpanded: $showsSource) {
                    if let source, !source.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(source) { message in
                                        Text(message.content).textSelection(.enabled).id(message.id)
                                            .padding(8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }.frame(maxHeight: 220)
                                .onAppear { if let id = memory.sourceMessageID { proxy.scrollTo(id, anchor: .center) } }
                        }
                    } else if source == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L.string("product.memory.source.missing")).font(.caption)
                    }
                }
            } else { Text(L.string("product.memory.source.manual")).font(.caption).foregroundStyle(.secondary) }
            if let errorText { Text(errorText).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }.disabled(saving)
                Button(L.string("common.save")) {
                    saving = true
                    Task {
                        do {
                            var updated = memory
                            updated.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            updated.category = category
                            updated.workspaceID = workspaceID
                            updated.alwaysInclude = alwaysInclude && category == .preference
                            try await service.edit(updated)
                            onSaved(); dismiss()
                        } catch MemoryService.StoreError.stale {
                            onSaved()
                            errorText = L.string("memory.edit.stale"); saving = false
                        } catch { errorText = L.string("error.database"); saving = false }
                    }
                }.disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 620)
        .onAppear {
            content = memory.content; category = memory.category
            workspaceID = memory.workspaceID; alwaysInclude = memory.alwaysInclude
        }
        .task(id: showsSource) {
            guard showsSource, source == nil, let id = memory.sourceSessionID else { return }
            let messages = (try? await sessionService?.getMessages(id: id)) ?? []
            if !Task.isCancelled { source = messages }
        }
    }
}

struct FilePreviewSheet: View {
    let url: URL
    var onClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button(L.string("common.close")) { onClose(); dismiss() }.keyboardShortcut(.cancelAction)
            }.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            FileQuickLook(url: url).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.padding(16).frame(width: 760, height: 600)
    }
}

private struct FileQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal) }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QLPreviewView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 600,
            height: proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 500)
    }
}
