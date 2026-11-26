import SwiftUI
import AppKit
import QuickLookUI
import AgRoomCore

// MARK: - Mail Message Detail

/// 邮件详情栏：头部元信息 + 操作工具条 + 正文 + 附件元数据。
/// 正文按需拉取（`isLoadingBody` 期间显示进度）；HTML 正文经 `MailHTMLView` 安全渲染。
struct MailMessageDetailView: View {
    let message: MailMessage?
    /// 正文缓存（未拉取时为 nil）。
    let mailBody: MailBody?
    let attachments: [MailAttachment]
    let downloadingAttachments: Set<UUID>
    let onDownload: (MailAttachment) async -> URL?
    let onRetryBody: () -> Void
    @State private var previewURL: URL?
    @State private var attachmentRequest = UUID()
    let isLoadingBody: Bool
    /// 可移动到的目标文件夹（当前账号下，排除自身所在文件夹）。
    let moveTargets: [MailFolder]
    let onToggleRead: (MailMessage) -> Void
    let onToggleStar: (MailMessage) -> Void
    let onReply: (MailMessage) -> Void
    /// AI 回复：打开回复窗口并直接展开 AI 面板。
    let onAIReply: (MailMessage) -> Void
    let onForward: (MailMessage) -> Void
    let onDelete: (MailMessage) -> Void
    let onMove: (MailMessage, UUID) -> Void
    var deleteTitleKey = "mail.action.delete"
    var sourceDescription: String? = nil
    var preferredMoveTargets: [MailFolder] = []
    var inlineImages: MailInlineImageSource? = nil
    var onReplyAll: ((MailMessage) -> Void)? = nil
    var onSaveAttachments: (([MailAttachment]) -> Void)? = nil
    var onComposeTo: ((MailAddress) -> Void)? = nil
    var onSearchAddress: ((String) -> Void)? = nil
    var onChooseMove: ((MailMessage) -> Void)? = nil
    var moveDisabledReason: String? = nil
    var deleteDisabledReason: String? = nil
    var actionsDisabled = false
    var attachmentsAreLocalOnly = false
    var searchQuery = ""
    var onEnqueue: ((MailAttachment) -> Void)? = nil
    @State private var findText = ""
    @State private var findRequest = UUID()
    @State private var findBackwards = false
    @State private var findMatched: Bool?

    var body: some View {
        if let message {
            content(message)
        } else {
            ContentUnavailableView(
                L.string("mail.noSelection"),
                systemImage: "envelope.open",
                description: Text(L.string("mail.noSelection.desc"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Content

    private func content(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(message)
            Divider()
            HStack {
                TextField(L.string("mail.find.placeholder"), text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { findBackwards = false; findRequest = UUID() }
                Button { findBackwards = true; findRequest = UUID() } label: { Image(systemName: "chevron.up") }
                    .help(L.string("mail.find.previous")).accessibilityLabel(L.string("mail.find.previous"))
                Button { findBackwards = false; findRequest = UUID() } label: { Image(systemName: "chevron.down") }
                    .help(L.string("mail.find.next")).accessibilityLabel(L.string("mail.find.next"))
            }.padding(.horizontal, 14).padding(.vertical, 6).disabled(isLoadingBody || mailBody == nil)
            if !findText.isEmpty, findMatched == false {
                Text(L.string("mail.find.noMatch")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
            }

            if isLoadingBody {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.string("mail.loading"))
                        .font(MeetTypography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let mailBody, mailBody.htmlBody != nil || mailBody.textBody != nil {
                MailHTMLView(html: mailBody.htmlBody, text: mailBody.textBody, inlineImages: inlineImages,
                    findQuery: findText, findRequest: findRequest, findBackwards: findBackwards, onFindResult: { findMatched = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.primary.opacity(0.035))
                if let inlineImages, inlineImages.downsampledCount > 0 {
                    Text(L.string("mail.inline.previewHint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 8)
                }
                if let inlineImages, inlineImages.failureCount > 0 {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L.format("mail.inline.failed", inlineImages.failureCount))
                            ForEach(inlineImages.failureReasons, id: \.self) { reason in
                                Text(L.string("mail.inline.error." + reason.rawValue))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        // A body reload also repairs metadata omitted by older
                        // versions and refreshes the visible attachment list.
                        Button(L.string("mail.inline.retry"), action: onRetryBody)
                    }.padding(.horizontal, 14).padding(.bottom, 8)
                }
            } else {
                ContentUnavailableView(
                    L.string("mail.bodyUnavailable"),
                    systemImage: "doc.questionmark"
                )
                Button(L.string("product.mail.body.retry"), action: onRetryBody)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !attachments.isEmpty {
                Divider()
                attachmentList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { findText = searchQuery }
        .onChange(of: searchQuery) { _, value in findText = value }
        .onChange(of: message.id) { _, _ in
            findText = searchQuery; findMatched = nil; findRequest = UUID()
            attachmentRequest = UUID(); previewURL = nil
        }
        .onChange(of: findText) { _, _ in findMatched = nil; findBackwards = false; findRequest = UUID() }
        .onDisappear { attachmentRequest = UUID(); previewURL = nil }
    }

    // MARK: - Header

    private func header(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sourceDescription { Text(sourceDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text(message.subject.isEmpty ? L.string("mail.noSubject") : message.subject)
                .font(MeetTypography.sectionTitle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(message.displayFrom)
                    .font(MeetTypography.secondary)
                    .lineLimit(1)
                if !message.fromAddress.isEmpty, message.fromAddress != message.displayFrom {
                    Text("<\(message.fromAddress)>")
                        .font(MeetTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(message.date.map { AppDate.string(from: $0) } ?? "")
                    .font(MeetTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contextMenu { addressActions(.init(name: message.fromName, address: message.fromAddress)) }

            if !message.to.isEmpty {
                recipientLine(L.string("mail.field.to"), message.to)
            }
            if !message.cc.isEmpty {
                recipientLine(L.string("mail.field.cc"), message.cc)
            }

            ViewThatFits(in: .horizontal) {
                actionRow(message)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: true, vertical: false)
                actionRow(message)
                    .labelStyle(.iconOnly)
            }
            .padding(.top, 2)
            .disabled(actionsDisabled)
            ForEach(Array(Set([moveDisabledReason, deleteDisabledReason].compactMap { $0 })).sorted(), id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func actionRow(_ message: MailMessage) -> some View {
        HStack(spacing: 12) {
                Button {
                    onToggleRead(message)
                } label: {
                    Label(
                        message.isRead ? L.string("mail.action.markUnread") : L.string("mail.action.markRead"),
                        systemImage: message.isRead ? "envelope.badge" : "envelope.open"
                    )
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .help(message.isRead ? L.string("mail.action.markUnread") : L.string("mail.action.markRead"))
                .accessibilityLabel(message.isRead ? L.string("mail.action.markUnread") : L.string("mail.action.markRead"))

                Button {
                    onToggleStar(message)
                } label: {
                    Label(
                        L.string(message.isStarred ? "mail.action.unstar" : "mail.action.star"),
                        systemImage: message.isStarred ? "star.fill" : "star"
                    )
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .help(L.string(message.isStarred ? "mail.action.unstar" : "mail.action.star"))
                .accessibilityLabel(L.string(message.isStarred ? "mail.action.unstar" : "mail.action.star"))

                Menu {
                    Button(L.string("mail.action.reply")) { onReply(message) }
                    if let onReplyAll { Button(L.string("mail.action.replyAll")) { onReplyAll(message) } }
                } label: {
                    Label(L.string("mail.action.reply"), systemImage: "arrowshape.turn.up.left")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                } primaryAction: {
                    onReply(message)
                }
                .menuStyle(.borderlessButton)
                .help(L.string("mail.action.reply"))
                .accessibilityLabel(L.string("mail.action.reply"))

                Button {
                    onAIReply(message)
                } label: {
                    Label(L.string("mail.action.aiReply"), systemImage: "sparkles")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .help(L.string("mail.action.aiReply"))
                .accessibilityLabel(L.string("mail.action.aiReply"))

                Button {
                    onForward(message)
                } label: {
                    Label(L.string("mail.action.forward"), systemImage: "arrowshape.turn.up.right")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .help(L.string("mail.action.forward"))
                .accessibilityLabel(L.string("mail.action.forward"))

                if let onChooseMove {
                    Button { onChooseMove(message) } label: {
                        Label(L.string("mail.action.move"), systemImage: "folder").frame(minWidth: 28, minHeight: 28)
                    }.disabled(moveDisabledReason != nil).help(moveDisabledReason ?? L.string("mail.move.title"))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(L.string("mail.move.title"))
                } else if !moveTargets.isEmpty {
                    Menu {
                        if !preferredMoveTargets.isEmpty {
                            Section(L.string("mail.folder.preferredTargets")) {
                                ForEach(preferredMoveTargets) { folder in Button(folder.displayName) { onMove(message, folder.id) } }
                            }
                            Divider()
                        }
                        ForEach(moveTargets.filter { folder in !preferredMoveTargets.contains(where: { $0.id == folder.id }) }) { folder in
                            Button(folder.displayName) { onMove(message, folder.id) }
                        }
                    } label: {
                        Label(L.string("mail.action.move"), systemImage: "folder")
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L.string("mail.action.move"))
                    .accessibilityLabel(L.string("mail.action.move"))
                }

                Button(role: .destructive) {
                    onDelete(message)
                } label: {
                    Label(L.string(deleteTitleKey), systemImage: "trash")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .help(L.string(deleteTitleKey))
                .disabled(deleteDisabledReason != nil)
                .accessibilityLabel(L.string(deleteTitleKey))

                Spacer(minLength: 0)

                if mailBody?.htmlBody != nil {
                    Label(L.string("mail.remoteContentBlocked"), systemImage: "shield.lefthalf.filled")
                        .font(MeetTypography.caption)
                        .foregroundStyle(.secondary)
                        .help(L.string("mail.remoteContentBlocked.help"))
                        .accessibilityLabel(L.string("mail.remoteContentBlocked"))
                }
        }
        .buttonStyle(.borderless)
        .font(MeetTypography.caption)
        .lineLimit(1)
    }

    private func recipientLine(_ title: String, _ addresses: [MailAddress]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(MeetTypography.caption)
                .foregroundStyle(.secondary)
            Text(addresses.map(\.display).joined(separator: ", "))
                .font(MeetTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .contextMenu {
                    ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                        Menu(address.display) { addressActions(address) }
                    }
                }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Attachments

    @ViewBuilder
    private func addressActions(_ address: MailAddress) -> some View {
        if !address.address.isEmpty {
            Button(L.string("mail.address.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address.address, forType: .string)
            }
            if let onComposeTo { Button(L.string("mail.address.compose")) { onComposeTo(address) } }
            if let onSearchAddress { Button(L.string("mail.address.findFrom")) { onSearchAddress(address.address) } }
        }
    }

    private var attachmentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L.format("mail.attachments.count", attachments.count))
                    .font(MeetTypography.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let onEnqueue {
                    Button(L.string("mail.downloads.enqueueAll")) { for attachment in attachments { onEnqueue(attachment) } }
                }
                if let onSaveAttachments { Button(L.string("mail.attachment.saveAll")) { onSaveAttachments(attachments) } }
            }
            ForEach(attachments) { attachment in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(MeetTypography.caption)
                        .foregroundStyle(.secondary)
                    if downloadingAttachments.contains(attachment.id) {
                        ProgressView().controlSize(.mini)
                    }
                    Text(attachment.filename.isEmpty ? attachment.mimeType : attachment.filename)
                        .font(MeetTypography.caption)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(L.string(attachmentPreviewKey(attachment))) {
                        prepareAttachment(attachment, action: .preview)
                    }.disabled(downloadingAttachments.contains(attachment.id))
                    if attachment.localPath != nil {
                        Button(L.string("files.reveal")) {
                            prepareAttachment(attachment, action: .reveal)
                        }.disabled(downloadingAttachments.contains(attachment.id))
                    }
                    Text(sizeText(attachment.sizeBytes))
                        .font(MeetTypography.caption)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    if attachment.localPath == nil {
                        Text(L.string(attachmentsAreLocalOnly ? "mail.attachment.offlineHint" : "mail.attachment.prepareHint"))
                    }
                    Group {
                        if let onEnqueue { Button(L.string("mail.downloads.enqueue")) { onEnqueue(attachment) } }
                        Button(L.string(attachmentPreviewKey(attachment))) { prepareAttachment(attachment, action: .preview) }
                        Button(L.string("mail.attachment.open")) {
                            prepareAttachment(attachment, action: .open)
                        }
                        if let onSaveAttachments {
                            Button(L.string("mail.attachment.save")) { onSaveAttachments([attachment]) }
                        }
                        if attachment.localPath != nil {
                            Button(L.string("files.reveal")) {
                                prepareAttachment(attachment, action: .reveal)
                            }
                        }
                    }
                    .disabled(downloadingAttachments.contains(attachment.id))
                    Divider()
                    Button(L.string("mail.attachment.copyName")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(attachment.filename, forType: .string)
                    }.disabled(attachment.filename.isEmpty)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let url = previewURL { FilePreviewSheet(url: url) }
        }
    }

    private enum AttachmentAction { case preview, open, reveal }
    private func prepareAttachment(_ attachment: MailAttachment, action: AttachmentAction) {
        guard message?.id == attachment.messageId else { return }
        let token = attachmentRequest
        Task { @MainActor in
            guard let url = await onDownload(attachment), attachmentRequest == token, !Task.isCancelled else { return }
            switch action {
            case .preview: previewURL = url
            case .open: NSWorkspace.shared.open(url)
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func attachmentPreviewKey(_ attachment: MailAttachment) -> String {
        if attachment.localPath != nil { return "product.artifact.preview" }
        return attachmentsAreLocalOnly ? "mail.attachment.preparePreview" : "product.mail.attachment.download"
    }

    private func sizeText(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
