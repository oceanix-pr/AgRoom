import AppKit
import Observation
import SwiftUI
import AgRoomCore

struct MailReaderContent {
    let message: MailMessage?
    let body: MailBody?
    let attachments: [MailAttachment]
    let downloading: Set<UUID>
    let isLoading: Bool
    let inlineImages: MailInlineImageSource?
    let onDownload: (MailAttachment) async -> URL?
    let onRetry: () -> Void
}

/// One expanded card owns its body task, attachment state and inline images.
/// Collapsing or scrolling it out releases image bytes and cancels network reads.
@MainActor @Observable
final class MailConversationReader {
    private let hub: Hub
    private let space: AppSpace
    private let accountID: UUID
    private(set) var message: MailMessage
    private(set) var body: MailBody?
    private(set) var attachments: [MailAttachment] = []
    private(set) var downloading: Set<UUID> = []
    private(set) var inlineImages: MailInlineImageSource?
    private(set) var isLoading = false
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var attachmentTasks: [UUID: Task<URL, Error>] = [:]
    private var generation = UUID()
    var onLoaded: () -> Void = {}
    var makeSyncService: @MainActor () -> MailSyncService?

    init(hub: Hub, space: AppSpace, message: MailMessage) {
        self.hub = hub; self.space = space; self.message = message; self.accountID = message.accountId
        self.makeSyncService = { hub.makeMailSyncService(for: space) }
    }

    func update(_ header: MailMessage) {
        guard header.id == message.id, header.accountId == accountID else { cancel(); return }
        if header.uid != message.uid || header.folderId != message.folderId || header.messageId != message.messageId { cancel() }
        message = header
    }

    var content: MailReaderContent {
        .init(message: message, body: body, attachments: attachments, downloading: downloading,
              isLoading: isLoading, inlineImages: inlineImages, onDownload: { await self.download($0) },
              onRetry: { Task { await self.load(force: true) } })
    }

    func load(force: Bool = false) async {
        guard !isLoading, body == nil || force else { return }
        cancel(); error = nil; isLoading = true
        let token = generation, source = message, id = message.id
        let work = Task { [self] in
            defer { if generation == token { isLoading = false; task = nil } }
            do {
                guard let mail = hub.makeMailService(for: space), let header = try await mail.message(id: id), header.accountId == accountID else { throw MailSearchError.unavailable }
                guard header.folderId == source.folderId, header.uid == source.uid, header.messageId == source.messageId else { throw MailSearchError.changed }
                let loaded: MailBody
                if !force, header.bodyState == .ready, let cached = try await mail.body(messageId: id) { loaded = cached }
                else {
                    guard let sync = makeSyncService() else { throw MailSearchError.unavailable }
                    loaded = try await sync.loadBody(messageId: id)
                }
                let parts = try await mail.attachments(messageId: id)
                guard let latest = try await mail.message(id: id), latest.accountId == accountID,
                      latest.folderId == header.folderId, latest.uid == header.uid, latest.messageId == header.messageId else { throw MailSearchError.changed }
                guard generation == token, !Task.isCancelled else { return }
                message = latest; body = loaded; attachments = parts
                inlineImages = MailInlineImageSource(hub: hub, space: space, messageID: id)
                inlineImages?.onAttachmentsRefreshed = { [weak self] parts in
                    guard let self, self.generation == token else { return }
                    self.attachments = parts
                }
                onLoaded()
            } catch is CancellationError { }
            catch { if generation == token { self.error = MailErrorText.message(for: error) } }
        }
        task = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    func download(_ attachment: MailAttachment) async -> URL? {
        guard attachment.messageId == message.id, !downloading.contains(attachment.id), let sync = makeSyncService() else { return nil }
        let token = generation, source = message
        downloading.insert(attachment.id)
        let work = Task {
            guard let current = try await hub.makeMailService(for: space)?.message(id: source.id),
                  current.accountId == accountID, current.folderId == source.folderId,
                  current.uid == source.uid, current.messageId == source.messageId else { throw MailSearchError.changed }
            try Task.checkCancellation()
            return try await sync.downloadAttachment(messageId: source.id, attachmentID: attachment.id)
        }
        attachmentTasks[attachment.id] = work
        defer { if generation == token { downloading.remove(attachment.id); attachmentTasks[attachment.id] = nil } }
        do {
            let url = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            let parts = try await hub.makeMailService(for: space)?.attachments(messageId: source.id)
            guard let latest = try await hub.makeMailService(for: space)?.message(id: source.id),
                  latest.accountId == accountID, latest.folderId == source.folderId,
                  latest.uid == source.uid, latest.messageId == source.messageId else { throw MailSearchError.changed }
            guard generation == token, !Task.isCancelled else { return nil }
            if let parts { attachments = parts }
            return url
        } catch is CancellationError { return nil }
        catch { if generation == token { self.error = MailErrorText.message(for: error) }; return nil }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        for download in attachmentTasks.values { download.cancel() }; attachmentTasks = [:]
        inlineImages?.cancelPending(); inlineImages = nil
        body = nil; attachments = []; downloading = []; isLoading = false
    }
}

struct MailConversationView: View {
    let hub: Hub
    let space: AppSpace
    let anchorID: UUID
    let messages: [MailMessage]
    let isLoading: Bool
    let hasMore: Bool
    let error: String?
    let onMore: () -> Void
    let onRefresh: () -> Void
    let onFocus: (UUID) -> Void
    let onExpand: (MailMessage) -> Void
    let onLoaded: () -> Void
    let focusedID: UUID?
    let sourceLabel: (MailMessage) -> String
    let detail: (MailReaderContent) -> AnyView
    let actions: (UUID) -> AnyView
    @State private var expanded: Set<UUID> = []
    @State private var expandedAnchorID: UUID?
    @State private var didScrollToAnchor = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.string("mail.conversation.localHint")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L.string("mail.conversation.refresh"), action: onRefresh).disabled(isLoading)
            }.padding(10)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 10) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { message in
                            MailConversationCard(hub: hub, space: space, message: message,
                                isExpanded: expanded.contains(message.id), source: sourceLabel(message),
                                isFocused: (focusedID ?? anchorID) == message.id,
                                toggle: {
                                    if expanded.remove(message.id) == nil {
                                        expanded.insert(message.id)
                                        onExpand(message)
                                    }
                                    onFocus(message.id)
                                },
                                onFocus: { onFocus(message.id) }, onLoaded: onLoaded, detail: detail, actions: actions)
                                .id(message.id)
                        }
                        if isLoading { ProgressView().controlSize(.small).padding(10) }
                        else if hasMore { Button(L.string("mail.conversation.more"), action: onMore).padding(10) }
                    }.padding(10)
                }
                .task(id: ConversationAnchorPresentation(id: anchorID, available: messages.contains { $0.id == anchorID })) {
                    if expandedAnchorID != anchorID {
                        expandedAnchorID = anchorID; expanded = [anchorID]; didScrollToAnchor = false
                    }
                    guard !didScrollToAnchor, messages.contains(where: { $0.id == anchorID }) else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(anchorID, anchor: .top); didScrollToAnchor = true
                }
            }
        }
    }
}

private struct ConversationCardLoad: Equatable { let message: MailMessage; let expanded: Bool }
private struct ConversationAnchorPresentation: Equatable { let id: UUID; let available: Bool }

private struct MailConversationCard: View {
    let message: MailMessage
    let isExpanded: Bool
    let source: String
    let isFocused: Bool
    let toggle: () -> Void
    let onFocus: () -> Void
    let onLoaded: () -> Void
    let detail: (MailReaderContent) -> AnyView
    let actions: (UUID) -> AnyView
    @State private var reader: MailConversationReader

    init(hub: Hub, space: AppSpace, message: MailMessage, isExpanded: Bool, source: String, isFocused: Bool,
         toggle: @escaping () -> Void, onFocus: @escaping () -> Void, onLoaded: @escaping () -> Void,
         detail: @escaping (MailReaderContent) -> AnyView, actions: @escaping (UUID) -> AnyView) {
        self.message = message; self.isExpanded = isExpanded; self.source = source; self.toggle = toggle
        self.isFocused = isFocused
        self.onFocus = onFocus; self.onLoaded = onLoaded; self.detail = detail; self.actions = actions
        self._reader = State(initialValue: MailConversationReader(hub: hub, space: space, message: message))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: toggle) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.displayFrom.isEmpty ? L.string("mail.noSubject") : message.displayFrom).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(message.subject.isEmpty ? L.string("mail.noSubject") : message.subject).font(.caption).lineLimit(2)
                            Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let date = message.date { Text(AppDate.string(from: date)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L.format("mail.conversation.card", message.displayFrom, message.subject.isEmpty ? L.string("mail.noSubject") : message.subject))
                    .accessibilityValue(L.string(isExpanded ? "mail.conversation.expanded" : "mail.conversation.collapsed"))
                Menu { actions(message.id) } label: { Image(systemName: "ellipsis.circle").accessibilityLabel(L.string("mail.selection.actions")) }
            }.padding(10).contextMenu { actions(message.id) }
            if isExpanded {
                Divider()
                if let error = reader.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(10) }
                detail(reader.content).frame(height: 500).simultaneousGesture(TapGesture().onEnded { _ in onFocus() })
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Color.accentColor : Color.secondary.opacity(0.2)))
        .task(id: ConversationCardLoad(message: message, expanded: isExpanded)) {
            reader.update(message); reader.onLoaded = onLoaded
            if isExpanded { await reader.load() } else { reader.cancel() }
        }
        .onDisappear { reader.cancel() }
    }
}
