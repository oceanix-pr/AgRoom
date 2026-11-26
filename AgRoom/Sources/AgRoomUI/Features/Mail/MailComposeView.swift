import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgRoomCore

// MARK: - Mail Compose

/// 撰写 / 回复 / 转发的独立窗口内容。
///
/// 与旧 Sheet 的差别：状态全部由 `MailComposeViewModel` 持有，因此最大化、全屏、
/// 折叠 AI 面板与语言重建都不会重新初始化草稿；窗口本身由
/// `MailComposeWindowCoordinator` 创建与管理。
struct MailComposeView: View {
    @Bindable var viewModel: MailComposeViewModel
    @State private var showQuotedReference = false
    @State private var attachmentPanel: NSSavePanel?
    @State private var attachmentSelectionID = UUID()
    @State private var presetManager: MailComposePresetManager?
    @State private var checkingRecipients = false
    @State private var formatting = MailBodyFormatControls()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    editorColumn
                    if viewModel.isAIPanelVisible {
                        Divider()
                        MailAIPanel(viewModel: viewModel)
                            .frame(width: min(420, max(300, geometry.size.width * 0.32)))
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 640, minHeight: 480)
        .task { await viewModel.loadIfNeeded() }
        .task(id: viewModel.fingerprint) { await viewModel.autosaveIfNeeded() }
        .onDisappear { attachmentSelectionID = UUID(); attachmentPanel?.cancel(nil); attachmentPanel = nil }
        .sheet(isPresented: $checkingRecipients) { recipientReview }
        .sheet(item: $presetManager, onDismiss: { Task { await viewModel.loadComposePresets() } }) { model in
            MailComposePresetManagerView(model: model)
        }
        .sheet(item: $viewModel.presetPreview) { preview in
            VStack(alignment: .leading, spacing: 16) {
                Text(preview.preset.name).font(.headline)
                ScrollView { Text(preview.preset.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text(L.string("mail.presets.previewHint")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L.string("common.cancel")) { viewModel.presetPreview = nil }
                    Spacer()
                    if preview.preset.kind == .reply || preview.canReplaceSignature {
                        Button(L.string(preview.preset.kind == .reply ? "mail.presets.replaceBody" : "mail.presets.replaceSignature"), role: .destructive) {
                            viewModel.applyPreset(preview, replacing: true)
                        }
                    }
                    Button(L.string("mail.presets.insert")) { viewModel.applyPreset(preview, replacing: false) }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 620, height: 400)
        }
        .sheet(item: $viewModel.serverSaveReview) { review in
            VStack(alignment: .leading, spacing: 14) {
                Text(L.string("mail.serverDraft.saveTitle")).font(.headline)
                Text(L.format("mail.serverDraft.destination", review.record.account.emailAddress, review.version.folder.name))
                Text(L.string(review.replacesPrevious ? "mail.serverDraft.replaceHint" : "mail.serverDraft.saveHint")).font(.caption).foregroundStyle(.secondary)
                Text(L.format("mail.serverDraft.summary", review.version.draft.to.count + review.version.draft.cc.count + review.version.draft.bcc.count, review.version.draft.attachments.count))
                ScrollView { Text(review.version.draft.subject + "\n\n" + review.version.draft.assembledBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button(L.string("common.cancel")) { viewModel.serverSaveReview = nil }
                    Spacer()
                    Button(L.string("mail.serverDraft.confirmSave")) { viewModel.confirmServerSave(review) }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 640, height: 440)
        }
        .sheet(item: $viewModel.serverReadReview) { review in
            VStack(alignment: .leading, spacing: 14) {
                Text(L.string("mail.serverDraft.readTitle")).font(.headline)
                Text(L.string("mail.serverDraft.readHint")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.string("mail.compose.to") + ": " + review.draft.to.map(\.display).joined(separator: ", "))
                        if !review.draft.cc.isEmpty { Text(L.string("mail.compose.cc") + ": " + review.draft.cc.map(\.display).joined(separator: ", ")) }
                        if !review.draft.bcc.isEmpty { Text(L.string("mail.compose.bcc") + ": " + review.draft.bcc.map(\.display).joined(separator: ", ")) }
                        Text(review.draft.subject).font(.headline)
                        Text(review.draft.assembledBody)
                        ForEach(review.draft.attachments) { Text($0.filename).font(.caption) }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(L.string("common.cancel")) { viewModel.serverReadReview = nil }
                    Spacer()
                    Button(L.string("mail.serverDraft.confirmRead"), role: .destructive) { viewModel.confirmServerRead(review) }
                }
            }.padding(20).frame(width: 640, height: 440)
        }
        .alert(L.string(viewModel.serverConfirmation?.titleKey ?? "mail.serverDraft.cleanupTitle"),
            isPresented: Binding(get: { viewModel.serverConfirmation != nil }, set: { if !$0 { viewModel.serverConfirmation = nil } }), presenting: viewModel.serverConfirmation) { confirmation in
            Button(L.string(confirmation.confirmKey), role: .destructive) { viewModel.confirmServerAction(confirmation) }
            Button(L.string("common.cancel"), role: .cancel) { viewModel.serverConfirmation = nil }
        } message: { confirmation in
            Text(L.string(confirmation.hintKey)
                + (confirmation.isAbandon ? "\n" + (confirmation.record.pending?.messageID ?? "") : ""))
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            composeActions.labelStyle(.titleAndIcon)
            composeActions.labelStyle(.iconOnly)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var composeActions: some View {
        HStack(spacing: 12) {
            Button { Task { await viewModel.send() } } label: {
                Label(L.string("mail.compose.send"), systemImage: "paperplane.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.isBusy || viewModel.attachmentsBlockSending || viewModel.isAutoSaving
                      || viewModel.parsedRecipients.isEmpty || !viewModel.invalidRecipients.isEmpty || viewModel.isSendLocked)
            .help(viewModel.sendButtonHelp.isEmpty ? L.string("mail.compose.send") : viewModel.sendButtonHelp)
            Button { Task { _ = await viewModel.saveDraft() } } label: {
                Label(L.string("mail.compose.saveDraft"), systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("s").help(L.string("mail.compose.saveDraft"))
            .disabled(viewModel.isBusy || viewModel.isAutoSaving || viewModel.isSendLocked)
            Divider().frame(height: 18)
            Menu {
                Button(L.string("mail.compose.attachments.add")) { chooseAttachments() }
                Button(L.string("mail.compose.addImages")) { chooseAttachments(imagesOnly: true) }
            } label: {
                Label(L.string("mail.compose.attachments.add"), systemImage: "paperclip")
            } primaryAction: { chooseAttachments() }
            .fixedSize().help(L.string("mail.compose.attachments.drop"))
            .disabled(viewModel.isBusy || viewModel.isSendLocked || viewModel.isLoadingAttachments)
            Button { checkingRecipients = true } label: {
                Label(L.string("mail.compose.checkRecipients"), systemImage: "person.crop.circle.badge.checkmark")
            }.help(L.string("mail.compose.checkRecipients"))
            Spacer(minLength: 4)
            Button {
                viewModel.isAIPanelVisible.toggle()
            } label: {
                Label(L.string("mail.compose.aiPanel.toggle"), systemImage: "sparkles")
            }
            .foregroundStyle(viewModel.isAIPanelVisible ? Color.accentColor : .secondary)
            .help(L.string("mail.compose.aiPanel.toggle"))
            Button {
                viewModel.onRequestMaximize?()
            } label: {
                Label(L.string("mail.compose.maximize"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .labelStyle(.iconOnly)
            .help(L.string("mail.compose.maximize"))
        }
        .buttonStyle(.borderless)
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Editor

    private var editorColumn: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        envelopeFields
                        if !viewModel.attachments.isEmpty || viewModel.isLoadingAttachments || viewModel.attachmentError != nil
                            || (viewModel.composeKind == .forward && viewModel.forwardAttachmentsState == .pending) { attachmentEditor }
                        Divider()
                        formattingBar
                        if let status = viewModel.presetStatus { Text(status).font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
                        Divider()
                        MailBodyEditor(model: viewModel, controls: formatting)
                            .frame(minHeight: 170, maxHeight: .infinity)
                        if !viewModel.quotedText.isEmpty {
                            quotedReference
                        }
                    }
                    .frame(minHeight: geometry.size.height)
                }
                .disabled(viewModel.isBusy)
            }
            Divider()
            statusBar
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var formattingBar: some View {
        HStack(spacing: 7) {
            styleButton(.bold, icon: "bold", key: "bold", shortcut: "b")
            styleButton(.italic, icon: "italic", key: "italic", shortcut: "i")
            styleButton(.underline, icon: "underline", key: "underline", shortcut: "u")
            Divider().frame(height: 16)
            presetMenu(.signature, icon: "signature")
            presetMenu(.reply, icon: "text.quote")
            if viewModel.canUndoPreset {
                Button { viewModel.undoPreset() } label: {
                    Label(L.string("mail.presets.undo"), systemImage: "arrow.uturn.backward")
                }.labelStyle(.iconOnly).help(L.string("mail.presets.undo"))
            }
            Spacer(minLength: 0)
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6)
        .disabled(viewModel.isBusy || viewModel.isSendLocked)
    }

    private func styleButton(_ style: MailTextStyle, icon: String, key: String, shortcut: KeyEquivalent) -> some View {
        let label = L.string("mail.compose.format." + key)
        return Button { formatting.toggle(style) } label: {
            Label(label, systemImage: icon).labelStyle(.iconOnly).frame(width: 20)
        }.buttonStyle(.borderless).foregroundStyle(formatting.active.contains(style) ? Color.accentColor : .primary)
        .accessibilityAddTraits(formatting.active.contains(style) ? .isSelected : []).help(label).keyboardShortcut(shortcut)
    }

    private func presetMenu(_ kind: MailComposePreset.Kind, icon: String) -> some View {
        Menu {
            ForEach(viewModel.composePresets.items.filter { $0.kind == kind }) { preset in
                Button(preset.name) { viewModel.previewPreset(preset) }
            }
            if kind == .signature {
                Button(L.string("mail.signature.import")) { presetManager = viewModel.makePresetManager(importFromAccount: true) }
            }
            Divider()
            Button(L.string("mail.presets.manage")) { presetManager = viewModel.makePresetManager() }
        } label: { Label(L.string("mail.presets.kind." + kind.rawValue), systemImage: icon) }
        .menuStyle(.borderlessButton).fixedSize().disabled(viewModel.isGeneratingAI)
    }

    private var envelopeFields: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                fieldLabel("mail.compose.from")
                Text(viewModel.attribution)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 40)
            Divider()
            HStack(spacing: 12) {
                fieldLabel("mail.compose.to")
                MailRecipientField(label: L.string("mail.compose.to"), text: $viewModel.toText)
                if !viewModel.showCarbonCopy {
                    Button(L.string("mail.compose.showCc")) { viewModel.showCarbonCopy = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .fixedSize()
                }
            }
            .frame(minHeight: 40)
            if viewModel.showCarbonCopy {
                Divider()
                recipientRow("mail.compose.cc", text: $viewModel.ccText)
                Divider()
                recipientRow("mail.compose.bcc", text: $viewModel.bccText)
            }
            Divider()
            envelopeField("mail.compose.subject", text: $viewModel.subject)
        }
        .font(.system(size: 13))
        .textFieldStyle(.plain)
        .padding(.horizontal, 14)
        .background(Color(nsColor: .textBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in acceptAttachments(urls) }
    }

    private func recipientRow(_ key: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            fieldLabel(key)
            MailRecipientField(label: L.string(key), text: text)
        }.frame(minHeight: 36)
    }

    private func fieldLabel(_ key: String) -> some View {
        Text(L.string(key))
            .foregroundStyle(.secondary)
            .frame(width: 62, alignment: .leading)
    }

    private func envelopeField(_ key: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            fieldLabel(key)
            TextField("", text: text)
                .accessibilityLabel(L.string(key))
        }
        .frame(minHeight: 40)
    }

    private var quotedReference: some View {
        DisclosureGroup(isExpanded: $showQuotedReference) {
            ScrollView {
                Text(viewModel.quotedText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
            .frame(height: 160)
        } label: {
            Label(L.string("mail.compose.quotedReference"), systemImage: "text.quote")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .meetCard()
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !viewModel.invalidRecipients.isEmpty {
                Text(L.string("product.mail.invalidRecipients"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let notice = viewModel.notice {
                noticeView(notice)
            } else if let lock = viewModel.sendLock {
                lockedHint(lock)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, hasNotice ? 10 : 0)
    }

    private var hasNotice: Bool {
        !viewModel.invalidRecipients.isEmpty || viewModel.notice != nil || viewModel.sendLock != nil
    }

    @ViewBuilder
    private func noticeView(_ notice: MailComposeViewModel.Notice) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: notice.kind == .failure ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(notice.message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(notice.kind == .failure ? Color.red : Color.orange)
    }

    /// 终结锁提示：重开已投递草稿时没有 notice，需单独说明为何发送不可用。
    @ViewBuilder
    private func lockedHint(_ lock: MailComposeViewModel.SendLock) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "paperplane.circle.fill")
            Text(lock == .delivered
                ? L.string("mail.compose.deliveredLocked")
                : L.string("mail.compose.unverifiedLocked"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
    }

    // MARK: - Actions

    private var attachmentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.format("mail.attachments.count", viewModel.attachments.count), systemImage: "paperclip")
            if viewModel.attachments.isEmpty { Text(L.string("mail.compose.attachments.drop")).font(.caption).foregroundStyle(.secondary) }
            if !viewModel.attachments.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.attachments) { attachment in
                            HStack {
                                Text(attachment.filename).lineLimit(1).help(attachment.filename)
                                Spacer(minLength: 4)
                                Text(Int64(attachment.data.count).formatted(.byteCount(style: .file).locale(attachmentLocale)))
                                    .foregroundStyle(.secondary)
                                Button { viewModel.removeAttachment(attachment.id) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.plain).help(L.string("mail.compose.attachments.remove"))
                                    .disabled(viewModel.isSendLocked || viewModel.isLoadingAttachments)
                            }.font(.caption).frame(height: 24)
                            .contextMenu {
                                Button(L.string("mail.attachment.save")) { saveAttachment(attachment) }
                            }
                        }
                    }
                }.frame(height: CGFloat(min(viewModel.attachments.count, 5)) * 24)
            }
            if viewModel.isLoadingAttachments {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L.format("mail.compose.attachments.loading", viewModel.attachmentProgress)).font(.caption)
                    Button(L.string("common.cancel")) { viewModel.cancelAttachmentLoading() }
                }
            }
            if let error = viewModel.attachmentError { Text(error).font(.caption).foregroundStyle(.red) }
            if viewModel.composeKind == .forward, viewModel.forwardAttachmentsState == .pending, !viewModel.isSendLocked {
                HStack {
                    Button(L.string("mail.compose.attachments.prepare")) { viewModel.loadForwardAttachments() }
                        .disabled(viewModel.isLoadingAttachments)
                    Button(L.string("mail.compose.attachments.omit")) { viewModel.omitForwardAttachments() }
                }.font(.caption)
            }
            Text(L.format("mail.compose.attachments.limit", MailDraftAttachment.maximumCount,
                          MailDraftAttachment.maximumFileBytes / 1_048_576, MailDraftAttachment.maximumTotalBytes / 1_048_576))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .dropDestination(for: URL.self) { urls, _ in
            acceptAttachments(urls)
        }
    }

    private func acceptAttachments(_ urls: [URL]) -> Bool {
        guard !viewModel.isBusy, !viewModel.isSendLocked, !viewModel.isLoadingAttachments, !urls.isEmpty else { return false }
        viewModel.addAttachmentFiles(urls)
        return true
    }

    private var attachmentLocale: Locale {
        let language = LanguageManager.shared.currentLanguage
        return language == .system ? .current : Locale(identifier: language.rawValue)
    }

    private func chooseAttachments(imagesOnly: Bool = false) {
        let ticket = UUID(); attachmentSelectionID = ticket
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if imagesOnly { panel.allowedContentTypes = [.image] }
        panel.title = L.string(imagesOnly ? "mail.compose.addImages" : "mail.compose.attachments.add"); attachmentPanel = panel
        Task {
            let choice = await ArtifactExportChoice.choose(panel)
            guard ticket == attachmentSelectionID else { return }
            attachmentPanel = nil
            if case .selected = choice { viewModel.addAttachmentFiles(panel.urls) }
        }
    }

    private func saveAttachment(_ attachment: MailDraftAttachment) {
        let ticket = UUID(); attachmentSelectionID = ticket
        let panel = NSSavePanel(); panel.title = L.string("mail.attachment.save")
        panel.nameFieldStringValue = attachment.filename; attachmentPanel = panel
        Task {
            let choice = await ArtifactExportChoice.choose(panel)
            guard ticket == attachmentSelectionID else { return }
            attachmentPanel = nil
            guard case .selected(let url) = choice else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let target = try MailExportDestination(directory: url.deletingLastPathComponent(), filename: url.lastPathComponent)
                _ = try await target.write(attachment.data, suggestedName: attachment.filename)
            } catch { viewModel.reportAttachmentActionError(error) }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.serverDraftRecord != nil {
                Text(L.string(viewModel.serverDraftStatusKey)).font(.caption).foregroundStyle(.secondary)
            }
            if let error = viewModel.serverDraftError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if viewModel.isBusy { ProgressView().controlSize(.small) }
                saveStatus
                Spacer(minLength: 4)
                serverDraftMenu
                Button(L.string("common.close")) { viewModel.onRequestClose?() }.keyboardShortcut(.cancelAction)
            }
        }.padding(.horizontal, 14).padding(.vertical, 7)
    }

    @ViewBuilder
    private var saveStatus: some View {
        if let key = viewModel.autosaveStatusKey {
            Label(L.string(key), systemImage: viewModel.autosaveFailed
                  ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(viewModel.autosaveFailed ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var serverDraftMenu: some View {
        Menu(L.string("mail.serverDraft.menu")) {
            Button(L.string("mail.serverDraft.saveTitle")) { viewModel.reviewServerSave() }
                .disabled(viewModel.isSendLocked || viewModel.serverDraftRecord?.pending != nil || viewModel.serverDraftRecord?.previous != nil || viewModel.serverDraftRecord?.needsReconciliation == true || !viewModel.invalidRecipients.isEmpty)
            Button(L.string("mail.serverDraft.readTitle")) { viewModel.reviewServerRead() }
                .disabled(viewModel.isSendLocked || viewModel.serverDraftRecord?.current == nil || viewModel.serverDraftRecord?.pending != nil || viewModel.serverDraftRecord?.previous != nil || viewModel.serverDraftRecord?.needsReconciliation == true)
            if let record = viewModel.serverDraftRecord {
                Divider()
                Button(L.string("mail.serverDraft.check")) { viewModel.reconcileServerDraft() }
                if record.previous != nil, record.pending == nil, !record.needsReconciliation {
                    Button(L.string("mail.serverDraft.cleanupTitle")) { viewModel.serverConfirmation = .cleanup(record) }
                    Button(L.string("mail.serverDraft.keepPreviousTitle")) { viewModel.serverConfirmation = .keepPrevious(record) }
                }
                if record.pending != nil {
                    Button(L.string("mail.serverDraft.abandonTitle"), role: .destructive) { viewModel.serverConfirmation = .abandon(record) }
                }
                if viewModel.sendLock == .delivered, record.current != nil, record.pending == nil, record.previous == nil, !record.needsReconciliation {
                    Button(L.string("mail.serverDraft.deliveredTitle")) { viewModel.serverConfirmation = .delivered(record) }
                }
            }
        }.disabled(viewModel.isBusy || viewModel.isAutoSaving || viewModel.sendLock == .unverified || viewModel.isGeneratingAI)
        .fixedSize()
    }

    private var recipientReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string("mail.compose.checkRecipients")).font(.headline)
            if viewModel.parsedRecipients.isEmpty {
                Label(L.string("mail.compose.to.required"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    recipientGroup("mail.compose.to", addresses: viewModel.parsedRecipients)
                    recipientGroup("mail.compose.cc", addresses: viewModel.parsedCc)
                    recipientGroup("mail.compose.bcc", addresses: viewModel.parsedBcc)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L.string("mail.compose.checkHint")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L.string("common.close")) { checkingRecipients = false }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 460, height: 330)
    }

    @ViewBuilder private func recipientGroup(_ key: String, addresses: [MailAddress]) -> some View {
        if !addresses.isEmpty {
            Text("\(L.string(key)) (\(addresses.count))").font(.subheadline.weight(.semibold))
            ForEach(addresses.indices, id: \.self) { index in
                let address = addresses[index]
                Label(address.display, systemImage: address.isValid ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(address.isValid ? Color.primary : .red).textSelection(.enabled)
                    .accessibilityValue(L.string(address.isValid ? "mail.compose.addressValid" : "product.mail.invalidRecipients"))
            }
        }
    }
}

private struct MailRecipientField: View {
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var editing = false

    var body: some View {
        let addresses = MailAddress.parseComposeList(text)
        HStack(spacing: 5) {
            if editing || focused || addresses.isEmpty {
                TextField("", text: $text).focused($focused).accessibilityLabel(label)
                    .onAppear { if editing { focused = true } }
                    .onSubmit { focused = false; editing = false }
                    .onChange(of: focused) { _, value in editing = value }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(addresses.indices, id: \.self) { index in
                            let address = addresses[index]
                            HStack(spacing: 4) {
                                Button(address.name.isEmpty ? address.address : address.display) { editing = true }
                                    .lineLimit(1).help(address.display)
                                Button {
                                    var remaining = addresses; remaining.remove(at: index)
                                    text = remaining.map(\.composeText).joined(separator: ", ")
                                } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel(L.format("mail.compose.removeRecipient", address.display))
                            }
                            .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(address.isValid ? Color.primary : .red)
                            .background((address.isValid ? Color.accentColor : .red).opacity(0.12), in: Capsule())
                        }
                    }
                }.scrollIndicators(.hidden)
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help(L.string("mail.compose.editRecipients"))
                    .accessibilityLabel(L.string("mail.compose.editRecipients"))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
