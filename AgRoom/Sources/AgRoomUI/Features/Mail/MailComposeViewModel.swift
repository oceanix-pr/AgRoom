import Foundation
import Observation
import UniformTypeIdentifiers
import AgRoomCore

// MARK: - Compose Close

/// 关闭撰写窗口前的判定结果（由窗口协调器执行对应动作）。
enum MailComposeCloseAction: Equatable {
    /// 可直接关闭（已保存 / 正在发送 / 已终结）。
    case closeNow
    /// 有未保存修改：交由协调器询问（保存并关闭 / 不保存 / 取消）。
    case ask
}

/// AI 面板模式。
enum MailAIPanelMode: String, CaseIterable {
    /// 按撰写类型生成内容（新写 / 回复）。
    case generate
    /// 依据当前正文与修改意见润色。
    case polish
}

// MARK: - Mail Compose View Model

/// 撰写窗口的编辑状态（收件人、正文、自动保存、AI 与发送）。
///
/// 从 `MailComposeView` 提取出来的理由：独立窗口会经历缩放、全屏、面板折叠与语言重建，
/// 这些都不应重新初始化草稿；同时 AI 生成、自动保存与发送需要同一份可撤销的编辑状态。
///
/// 空间绑定：`space` 在 init 时固定，之后不再读 `hub.spaceStore.current`，因此主窗口
/// 切换空间 / 账号 / 选中邮件都不会改变本窗口的发件人与上下文。
@MainActor
@Observable
final class MailComposeViewModel {

    // MARK: - Send Types

    /// 发送终结锁：进入后本窗口不再允许重发（重复投递不可撤销）。
    enum SendLock: Equatable {
        /// 已确认投递（可能仅本地归档失败）。
        case delivered
        /// 结果未知，需用户到服务器「已发送」核实。
        case unverified
    }

    /// 发送 / 存草稿的结果提示。
    struct Notice: Equatable {
        enum Kind: Equatable {
            case failure
            case resultUnknown
            case delivered
        }
        let kind: Kind
        let message: String
    }

    /// AI 生成状态（见设计表：待生成 / 准备上下文 / 生成中 / 已完成 / 已停止 / 失败）。
    enum AIState: Equatable {
        case idle
        case preparing
        case generating
        case done
        case stopped
        case failed(String)
    }

    /// 原邮件上下文读取状态。
    enum SourceStatus: Equatable {
        case none
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Identity（固定绑定）

    let draftID: UUID
    let space: AppSpace
    /// 窗口归属展示（空间 · 账号），写入窗口标题。
    let attribution: String
    /// 发件人展示（只读，来自创建窗口时的账号）。
    let fromDescription: String
    private(set) var composeKind: MailComposeKind
    /// 被回复 / 被转发的原邮件本地 ID（AI 与引用都按它读取）。
    private(set) var sourceMessageId: UUID?

    private let hub: Hub
    /// 草稿的固定骨架（id / 账号 / 来源 / 回复头 / 投递凭证），编辑字段另行持有。
    private var base: MailDraft

    // MARK: - Editable Fields

    var toText: String
    var ccText: String
    var bccText: String
    var subject: String
    /// 用户书写的回复正文（不含原文引用）。
    private var writtenText: String
    private(set) var bodyStyles: [MailStyleSpan]
    var bodyText: String {
        get { writtenText }
        set {
            let retained = MailBodyEditor.retainedStyles(bodyStyles, from: writtenText, to: newValue)
            setStyledBody(newValue, styles: retained)
        }
    }
    func setStyledBody(_ text: String, styles: [MailStyleSpan]) {
        writtenText = text
        bodyStyles = styles
    }
    /// 原文引用块。
    private(set) var quotedText: String
    var showCarbonCopy: Bool
    private(set) var attachments: [MailDraftAttachment]
    private(set) var forwardAttachmentsState: MailForwardAttachmentsState
    private(set) var isLoadingAttachments = false
    private(set) var attachmentError: String?
    private(set) var attachmentProgress = 0
    private var attachmentTask: Task<Void, Never>?
    private var attachmentGeneration = UUID()
    var makeAttachmentSyncService: @MainActor () -> MailSyncService?

    // MARK: - Status

    private(set) var isBusy = false
    private(set) var isAutoSaving = false
    private(set) var autosaveFailed = false
    private(set) var hasSavedSnapshot = false
    /// 已成功投递：草稿已被服务端流程清理，此后禁止再自动保存回写。
    private(set) var didSendSuccessfully = false
    private(set) var sendLock: SendLock?
    var notice: Notice?
    private var lastSavedFingerprint = ""

    struct PresetPreview: Identifiable {
        let id = UUID()
        let preset: MailComposePreset
        let originalBody: String
        let originalStyles: [MailStyleSpan]
        let canReplaceSignature: Bool
    }
    private(set) var composePresets = MailComposePresets()
    private(set) var presetStatus: String?
    var presetPreview: PresetPreview?
    private var presetGeneration = UUID()
    private var windowClosed = false
    private var attemptedDefaultSignature = false
    private var managedSignature: String?
    private var presetUndo: (before: String, styles: [MailStyleSpan], signature: String?, after: String, afterStyles: [MailStyleSpan])?
    var canUndoPreset: Bool { presetUndo?.after == bodyText && presetUndo?.afterStyles == bodyStyles && !isBusy && !isSendLocked && !isGeneratingAI }

    private(set) var serverDraftRecord: MailServerDraftRecord?
    private(set) var serverDraftError: String?
    var serverSaveReview: MailServerDraftSaveReview?
    var serverReadReview: MailServerDraftReadReview?
    enum ServerConfirmation: Identifiable {
        case cleanup(MailServerDraftRecord), abandon(MailServerDraftRecord), keepPrevious(MailServerDraftRecord), delivered(MailServerDraftRecord)
        var record: MailServerDraftRecord { switch self { case .cleanup(let record), .abandon(let record), .keepPrevious(let record), .delivered(let record): record } }
        var id: UUID { record.revision }
        var isAbandon: Bool { if case .abandon = self { return true }; return false }
        private var stem: String { switch self { case .cleanup: "cleanup"; case .abandon: "abandon"; case .keepPrevious: "keepPrevious"; case .delivered: "delivered" } }
        var titleKey: String { "mail.serverDraft." + stem + "Title" }
        var hintKey: String { "mail.serverDraft." + stem + "Hint" }
        var confirmKey: String { "mail.serverDraft." + stem + "Confirm" }
    }
    var serverConfirmation: ServerConfirmation?
    private var serverTask: Task<Void, Never>?
    private var serverGeneration = UUID()
    private var serverReviewFingerprint = ""
    private var serverLocalSnapshot: MailDraft?
    private var serverSavedFingerprint: String?
    var serverDraftStatusKey: String {
        guard let record = serverDraftRecord else { return "mail.serverDraft.localOnly" }
        if record.retiredAt != nil { return "mail.serverDraft.retired" }
        if record.retiringAfterSend == true { return "mail.serverDraft.deliveredCleanupFailed" }
        if record.needsReconciliation || record.pending != nil { return "mail.serverDraft.unresolved" }
        if record.previous != nil { return "mail.serverDraft.cleanupPending" }
        if record.current == nil { return "mail.serverDraft.localOnly" }
        return serverSavedFingerprint == fingerprint ? "mail.serverDraft.saved" : "mail.serverDraft.localChanges"
    }

    // MARK: - AI

    var isAIPanelVisible: Bool
    var aiMode: MailAIPanelMode = .generate
    var aiRequirement: String = ""
    var aiLanguage: MailAILanguage = .auto
    var aiTone: MailAITone = .auto
    var aiLength: MailAILength = .auto
    var includeThread = false
    private(set) var aiState: AIState = .idle
    private(set) var aiRaw = ""
    private(set) var aiSubjectSuggestion: String?
    private(set) var sourceStatus: SourceStatus = .none
    private(set) var sourceContext: MailAIOriginal?
    private(set) var availableProviders: [LLMProviderConfig] = []
    var selectedProviderId: UUID?
    private(set) var aiModelLabel = ""
    /// 应用 AI 结果前的一版正文，用于一次撤销。
    private(set) var undoBodySnapshot: String?
    private var undoBodyStyles: [MailStyleSpan] = []

    // MARK: - Callbacks

    /// 请求最大化 / 还原（由窗口协调器实现）。
    var onRequestMaximize: (() -> Void)?
    /// 请求关闭窗口（发送成功、用户点关闭等）。
    var onRequestClose: (() -> Void)?

    // MARK: - Private

    /// AI 生成世代：新一次生成开始后，旧回调据此失效。
    private var generationCounter = 0
    private var generationTask: Task<Void, Never>?

    // MARK: - Init

    init(draft: MailDraft, space: AppSpace, hub: Hub, fromDescription: String, isAIPanelVisible: Bool) {
        self.draftID = draft.id
        self.space = space
        self.hub = hub
        self.base = draft
        self.composeKind = draft.composeKind
        self.sourceMessageId = draft.sourceMessageId
        self.attribution = "\(L.string("space." + space.rawValue)) · \(fromDescription)"
        self.fromDescription = fromDescription
        self.toText = Self.text(from: draft.to)
        self.ccText = Self.text(from: draft.cc)
        self.bccText = Self.text(from: draft.bcc)
        self.subject = draft.subject
        self.writtenText = draft.bodyText
        self.bodyStyles = draft.bodyStyles
        self.quotedText = draft.quotedText
        self.showCarbonCopy = !draft.cc.isEmpty || !draft.bcc.isEmpty
        self.attachments = draft.attachments; self.forwardAttachmentsState = draft.forwardAttachmentsState
        self.makeAttachmentSyncService = { hub.makeMailSyncService(for: space) }
        self.isAIPanelVisible = isAIPanelVisible
        self.sendLock = Self.initialSendLock(for: draft)
        self.hasSavedSnapshot = draft.deliveryState != .none || draft.deliveredAt != nil
        // 初始指纹与当前内容一致：打开窗口不触发一次多余的自动保存
        self.lastSavedFingerprint = self.fingerprint
    }

    /// 重开草稿时的初始发送锁：由库中持久化的投递状态决定能否重发。
    private static func initialSendLock(for draft: MailDraft) -> SendLock? {
        if draft.deliveredAt != nil { return .delivered }
        switch draft.deliveryState {
        case .accepted, .localSaveFailed:
            return .delivered
        case .sending, .unknown:
            return .unverified
        case .none, .prepared:
            return nil
        }
    }

    // MARK: - Derived

    /// 内容指纹：包含引用部分，任一部分变化都触发自动保存。
    var fingerprint: String {
        let fields = [toText, ccText, bccText, subject, bodyText, quotedText, String(showCarbonCopy)]
        let files = attachments.map { $0.id.uuidString + $0.sha256 + $0.filename + $0.mimeType }.joined(separator: ",")
        let styles = bodyStyles.map { "\($0.range.location):\($0.range.length):\($0.style.rawValue)" }.joined(separator: ",")
        return (fields + [forwardAttachmentsState.rawValue, files, styles]).joined(separator: "\u{1F}")
    }

    var attachmentsBlockSending: Bool { isLoadingAttachments || (composeKind == .forward && forwardAttachmentsState == .pending) }

    var parsedRecipients: [MailAddress] { MailAddress.parseComposeList(toText) }

    var parsedCc: [MailAddress] { showCarbonCopy ? MailAddress.parseComposeList(ccText) : [] }

    var parsedBcc: [MailAddress] { showCarbonCopy ? MailAddress.parseComposeList(bccText) : [] }

    var invalidRecipients: [MailAddress] {
        (parsedRecipients + parsedCc + parsedBcc).filter { !$0.isValid }
    }

    /// 已终结（不可重发）：发送与 AI 应用据此禁用。
    var isSendLocked: Bool { sendLock != nil }

    /// 是否能应用 AI 候选（生成中/发送中/已终结都不允许）。
    var canApplyAI: Bool { !candidate.body.isEmpty && !isSendLocked && !isBusy }

    var candidate: MailAICandidate {
        MailAIService.candidate(from: aiRaw, kind: activeAIKind)
    }

    /// 当前生效的 AI 场景：润色模式固定为 polish，否则按撰写类型。
    var activeAIKind: MailAIKind {
        if aiMode == .polish { return .polish }
        return composeKind == .new ? .compose : .reply
    }

    var isGeneratingAI: Bool { aiState == .generating || aiState == .preparing }

    var sendButtonHelp: String {
        if isSendLocked { return L.string("mail.compose.locked.help") }
        return parsedRecipients.isEmpty ? L.string("mail.compose.to.required") : ""
    }

    var autosaveStatusKey: String? {
        if autosaveFailed { return "product.mail.autosave.failed" }
        if isAutoSaving { return "product.mail.autosaving" }
        if hasSavedSnapshot { return "product.mail.saved" }
        return nil
    }

    // MARK: - Lifecycle

    /// 窗口出现时调用：读取原邮件上下文并按需生成引用。
    func loadIfNeeded() async {
        await loadServerDraftRecord()
        await loadComposePresets(applyDefault: true)
        await loadProviders()
        if composeKind.hasSource {
            await prepareSourceIfNeeded()
        }
        if composeKind == .forward, !isSendLocked { loadForwardAttachments() }
    }

    /// 关闭窗口时调用：取消在途任务（不影响已在投递中的发送任务）。
    func onWindowClosed() {
        serverGeneration = UUID(); serverTask?.cancel(); serverTask = nil
        serverSaveReview = nil; serverReadReview = nil; serverConfirmation = nil
        windowClosed = true; presetGeneration = UUID(); presetPreview = nil
        cancelAttachmentLoading()
        generationCounter += 1
        generationTask?.cancel()
        generationTask = nil
    }

    func makePresetManager(importFromAccount: Bool = false) -> MailComposePresetManager {
        .init(hub: hub, space: space, importAccountID: importFromAccount ? base.accountId : nil)
    }

    func loadComposePresets(applyDefault: Bool = false) async {
        guard !windowClosed else { return }
        let token = UUID(); presetGeneration = token
        let initialBody = bodyText
        let shouldApply = applyDefault && !attemptedDefaultSignature
        if applyDefault { attemptedDefaultSignature = true }
        do {
            guard let service = hub.makeMailService(for: space) else { throw MailComposePresetError.changed }
            let values = try await service.composePresets()
            let saved = shouldApply ? try await service.draft(id: draftID) : nil
            guard presetGeneration == token, !windowClosed, !Task.isCancelled else { return }
            composePresets = values; presetStatus = nil
            guard shouldApply, saved == nil, base.bodyText.isEmpty, initialBody.isEmpty, bodyText.isEmpty,
                  !isBusy, !isSendLocked, !isGeneratingAI,
                  let signature = values.defaultSignature(accountID: base.accountId) else { return }
            let suffix = "\n\n-- \n" + signature.body
            bodyText = suffix; managedSignature = suffix
            presetUndo = ("", [], nil, suffix, [])
        } catch {
            if presetGeneration == token, !windowClosed, !Task.isCancelled { presetStatus = MailErrorText.message(for: error) }
        }
    }

    func previewPreset(_ preset: MailComposePreset) {
        guard !windowClosed, !isBusy, !isSendLocked, !isGeneratingAI,
              composePresets.items.contains(preset) else { return }
        presetStatus = nil
        presetPreview = .init(preset: preset, originalBody: bodyText, originalStyles: bodyStyles,
                              canReplaceSignature: managedSignature.map { bodyText.hasSuffix($0) } ?? false)
    }

    func applyPreset(_ preview: PresetPreview, replacing: Bool) {
        guard !windowClosed, !isBusy, !isSendLocked, !isGeneratingAI else { return }
        guard bodyText == preview.originalBody, bodyStyles == preview.originalStyles else {
            presetPreview = nil; presetStatus = L.string("mail.presets.bodyChanged"); return
        }
        let old = bodyText
        let oldSignature = managedSignature
        let suffix = managedSignature.flatMap { bodyText.hasSuffix($0) ? $0 : nil }
        switch preview.preset.kind {
        case .signature:
            let next = "\n\n-- \n" + preview.preset.body
            if replacing {
                guard preview.canReplaceSignature, let suffix else { presetStatus = L.string("mail.presets.bodyChanged"); presetPreview = nil; return }
                bodyText = String(bodyText.dropLast(suffix.count)) + next
            } else if !bodyText.hasSuffix(next) { bodyText += next }
            managedSignature = next
        case .reply:
            let content = suffix.map { String(bodyText.dropLast($0.count)) } ?? bodyText
            bodyText = (replacing ? preview.preset.body : content + (content.isEmpty ? "" : "\n\n") + preview.preset.body) + (suffix ?? "")
        }
        if bodyText != old { presetUndo = (old, preview.originalStyles, oldSignature, bodyText, bodyStyles) }
        presetPreview = nil
    }

    func undoPreset() {
        guard canUndoPreset, let undo = presetUndo else { return }
        setStyledBody(undo.before, styles: undo.styles)
        managedSignature = undo.signature; presetUndo = nil
    }

    private func loadServerDraftRecord() async {
        let token = serverGeneration
        do {
            let record = try await hub.makeMailService(for: space)?.serverDraftRecord(id: draftID)
            guard token == serverGeneration, !windowClosed, !Task.isCancelled else { return }
            serverDraftRecord = record
            if var saved = record?.current?.draft {
                var local = composedDraft(); saved.updatedAt = .distantPast; local.updatedAt = .distantPast
                if saved == local { serverSavedFingerprint = fingerprint }
            }
        } catch { if token == serverGeneration, !windowClosed { serverDraftError = MailErrorText.message(for: error) } }
    }

    private var canStartServerAction: Bool { !windowClosed && !isBusy && !isAutoSaving && !isSendLocked && !isGeneratingAI && !attachmentsBlockSending }
    private var canRunServerMaintenance: Bool { !windowClosed && !isBusy && !isAutoSaving && sendLock != .unverified && !isGeneratingAI }

    func reviewServerSave() {
        guard canStartServerAction, invalidRecipients.isEmpty else { return }
        let snapshot = composedDraft(), identity = fingerprint
        runServerAction {
            guard let mail = self.hub.makeMailService(for: self.space), let sync = self.hub.makeMailSyncService(for: self.space) else { throw MailServerDraftError.changed }
            try await mail.saveEditableDraft(snapshot)
            let review = try await sync.serverDrafts().reviewSave(snapshot)
            guard !self.windowClosed, self.fingerprint == identity else { throw MailServerDraftError.changed }
            self.hasSavedSnapshot = true; self.lastSavedFingerprint = identity
            self.serverReviewFingerprint = identity; self.serverLocalSnapshot = snapshot
            if review.unchanged {
                self.serverDraftRecord = review.record; self.serverSavedFingerprint = identity
            } else { self.serverSaveReview = review }
        }
    }
    func confirmServerSave(_ review: MailServerDraftSaveReview) {
        guard canStartServerAction, serverSaveReview?.id == review.id, fingerprint == serverReviewFingerprint else {
            serverSaveReview = nil; serverDraftError = L.string("mail.serverDraft.error.changed"); return
        }
        serverSaveReview = nil
        let identity = serverReviewFingerprint
        runServerAction {
            guard let sync = self.hub.makeMailSyncService(for: self.space) else { throw MailServerDraftError.changed }
            let result = try await sync.serverDrafts().save(review)
            guard !self.windowClosed else { return }
            self.serverDraftRecord = result; self.serverSavedFingerprint = identity
        }
    }
    func reviewServerRead() {
        guard canStartServerAction else { return }
        let snapshot = composedDraft(), identity = fingerprint
        runServerAction {
            guard let mail = self.hub.makeMailService(for: self.space), let sync = self.hub.makeMailSyncService(for: self.space) else { throw MailServerDraftError.changed }
            try await mail.saveEditableDraft(snapshot)
            let review = try await sync.serverDrafts().reviewRead(draftID: self.draftID)
            guard !self.windowClosed, self.fingerprint == identity else { throw MailServerDraftError.changed }
            self.hasSavedSnapshot = true; self.lastSavedFingerprint = identity
            self.serverReviewFingerprint = identity; self.serverLocalSnapshot = snapshot; self.serverReadReview = review
        }
    }
    func confirmServerRead(_ review: MailServerDraftReadReview) {
        guard canStartServerAction, serverReadReview?.id == review.id, fingerprint == serverReviewFingerprint,
              let local = serverLocalSnapshot else { serverReadReview = nil; serverDraftError = L.string("mail.serverDraft.error.changed"); return }
        serverReadReview = nil
        runServerAction {
            guard let sync = self.hub.makeMailSyncService(for: self.space) else { throw MailServerDraftError.changed }
            let draft = try await sync.serverDrafts().adopt(review, replacing: local)
            guard !self.windowClosed else { return }
            self.cancelAttachmentLoading(); self.stopAI()
            self.base = draft; self.composeKind = draft.composeKind; self.sourceMessageId = draft.sourceMessageId
            self.toText = Self.text(from: draft.to); self.ccText = Self.text(from: draft.cc); self.bccText = Self.text(from: draft.bcc)
            self.showCarbonCopy = !draft.cc.isEmpty || !draft.bcc.isEmpty
            self.subject = draft.subject; self.setStyledBody(draft.bodyText, styles: draft.bodyStyles); self.quotedText = draft.quotedText
            self.attachments = draft.attachments; self.forwardAttachmentsState = draft.forwardAttachmentsState
            self.sourceContext = nil; self.sourceStatus = .none; self.aiRaw = ""; self.aiSubjectSuggestion = nil
            self.managedSignature = nil; self.presetUndo = nil; self.undoBodySnapshot = nil
            self.lastSavedFingerprint = self.fingerprint; self.serverSavedFingerprint = self.fingerprint; self.hasSavedSnapshot = true
        }
    }
    func reconcileServerDraft() {
        guard canRunServerMaintenance else { return }
        runServerAction {
            guard let sync = self.hub.makeMailSyncService(for: self.space) else { throw MailServerDraftError.changed }
            let result = try await sync.serverDrafts().reconcile(draftID: self.draftID)
            if !self.windowClosed { self.serverDraftRecord = result }
        }
    }
    func confirmServerAction(_ confirmation: ServerConfirmation) {
        guard canRunServerMaintenance, serverConfirmation?.id == confirmation.id else { return }
        serverConfirmation = nil
        runServerAction {
            guard let sync = self.hub.makeMailSyncService(for: self.space) else { throw MailServerDraftError.changed }
            let service = sync.serverDrafts()
            let result: MailServerDraftRecord
            switch confirmation {
            case .cleanup(let record): result = try await service.finishCleanup(record)
            case .abandon(let record): result = try await service.abandonUpload(record)
            case .keepPrevious(let record): result = try await service.keepPreviousCopy(record)
            case .delivered(let record): result = try await service.finishDeliveredCleanup(record)
            }
            if !self.windowClosed { self.serverDraftRecord = result }
        }
    }
    private func runServerAction(_ body: @escaping @MainActor () async throws -> Void) {
        guard canRunServerMaintenance else { return }
        let token = UUID(); serverGeneration = token; isBusy = true; serverDraftError = nil
        serverTask = Task {
            defer { if serverGeneration == token { isBusy = false; serverTask = nil } }
            do {
                try await body()
                if serverGeneration == token, !windowClosed, !Task.isCancelled { await loadServerDraftRecord() }
            } catch {
                if serverGeneration == token, !windowClosed, !Task.isCancelled {
                    serverDraftError = MailErrorText.message(for: error)
                    await loadServerDraftRecord()
                }
            }
        }
    }

    func addAttachmentFiles(_ urls: [URL]) {
        guard !isBusy, !isSendLocked, !isLoadingAttachments, !urls.isEmpty else { return }
        let ticket = UUID(); attachmentGeneration = ticket
        isLoadingAttachments = true; attachmentError = nil; attachmentProgress = 0
        let selected = urls.map { ($0, UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType ?? "application/octet-stream") }
        attachmentTask = Task {
            let authorized = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { authorized.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let existing = attachments
                let read = Task.detached {
                    var result: [MailDraftAttachment] = []
                    for (url, type) in selected {
                        try Task.checkCancellation()
                        let data = try MailAttachmentFile.read(url)
                        result.append(.init(filename: MailExportDestination.safeName(url.lastPathComponent), mimeType: type, data: data))
                        try MailDraftAttachment.validate(existing + result)
                    }
                    return result
                }
                let loaded = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                guard ticket == attachmentGeneration, !Task.isCancelled, !isSendLocked else { return }
                attachments += loaded
            } catch { if ticket == attachmentGeneration, !Task.isCancelled {
                attachmentError = error is NativeAppError ? L.string("mail.compose.attachments.error.read") : MailErrorText.message(for: error)
            } }
            if ticket == attachmentGeneration { isLoadingAttachments = false; attachmentTask = nil }
        }
    }

    func loadForwardAttachments() {
        guard composeKind == .forward, forwardAttachmentsState == .pending, !isSendLocked, !isLoadingAttachments else { return }
        guard let sourceMessageId else { attachmentError = L.string("mail.compose.attachments.error.source"); return }
        let ticket = UUID(); attachmentGeneration = ticket
        isLoadingAttachments = true; attachmentError = nil; attachmentProgress = 0
        attachmentTask = Task {
            do {
                guard let mail = hub.makeMailService(for: space), let sync = makeAttachmentSyncService(),
                      let source = try await mail.message(id: sourceMessageId) else { throw MailSyncError.messageNotFound }
                if source.bodyState != .ready { _ = try await sync.loadBody(messageId: sourceMessageId) }
                let metadata = try await mail.attachments(messageId: sourceMessageId)
                guard metadata.count + attachments.count <= MailDraftAttachment.maximumCount else { throw MailAttachmentError.capacity }
                if source.hasAttachments && metadata.isEmpty { throw MailExportError.incomplete }
                var loaded: [MailDraftAttachment] = []
                for item in metadata {
                    try Task.checkCancellation()
                    let url = try await sync.downloadAttachment(messageId: sourceMessageId, attachmentID: item.id)
                    let read = Task.detached { try MailAttachmentFile.read(url) }
                    let data = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                    loaded.append(.init(filename: MailExportDestination.safeName(url.lastPathComponent), mimeType: item.mimeType,
                                        data: data, sourceAttachmentID: item.id))
                    try MailDraftAttachment.validate(attachments + loaded)
                    guard ticket == attachmentGeneration, !Task.isCancelled else { return }
                    attachmentProgress = loaded.count
                }
                guard ticket == attachmentGeneration, !Task.isCancelled, !isSendLocked else { return }
                attachments += loaded; forwardAttachmentsState = .loaded
            } catch { if ticket == attachmentGeneration, !Task.isCancelled { attachmentError = MailErrorText.message(for: error) } }
            if ticket == attachmentGeneration { isLoadingAttachments = false; attachmentTask = nil }
        }
    }

    func cancelAttachmentLoading() {
        attachmentGeneration = UUID(); attachmentTask?.cancel(); attachmentTask = nil; isLoadingAttachments = false
    }

    func omitForwardAttachments() {
        guard !isBusy, !isSendLocked else { return }
        cancelAttachmentLoading(); attachments.removeAll { $0.sourceAttachmentID != nil }
        forwardAttachmentsState = .omitted; attachmentError = nil
    }

    func removeAttachment(_ id: UUID) {
        guard !isBusy, !isSendLocked, !isLoadingAttachments else { return }
        attachments.removeAll { $0.id == id }
    }

    func reportAttachmentActionError(_ error: Error) { attachmentError = MailErrorText.message(for: error) }

    // MARK: - Source Context

    /// 按固定的原邮件 ID 读取引用与 AI 上下文。
    ///
    /// `force` 为 true 时忽略已有上下文（例如用户刚打开「包含相关往来」需要补读线程）。
    func prepareSourceIfNeeded(force: Bool = false) async {
        guard let sourceMessageId, composeKind.hasSource else { return }
        if !force, sourceStatus == .ready, sourceContext != nil { return }
        sourceStatus = .loading
        let mail = hub.makeMailService(for: space)
        let sync = hub.makeMailSyncService(for: space)
        guard let mail else {
            sourceStatus = .failed(L.string("mail.error.serviceUnavailable"))
            return
        }
        let service = MailAIContextService(mail: mail, sync: sync)
        do {
            let context = try await service.prepare(
                messageId: sourceMessageId,
                includeThread: includeThread
            )
            guard !Task.isCancelled else { return }
            sourceContext = context
            if quotedText.isEmpty, !context.body.isEmpty {
                quotedText = Self.quoted(context.body)
            }
            sourceStatus = .ready
        } catch is CancellationError {
            sourceStatus = .none
        } catch {
            sourceStatus = .failed(MailErrorText.message(for: error))
        }
    }

    /// 重新读取原文（失败后的重试入口）。
    func retrySource() async {
        sourceStatus = .none
        await prepareSourceIfNeeded()
    }

    // MARK: - AI Generation

    func generateAI() async {
        guard !isSendLocked, !isBusy else { return }
        let requirement = aiRequirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.isEmpty else { return }
        if activeAIKind == .polish, bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        if activeAIKind == .reply, sourceStatus != .ready || (includeThread && (sourceContext?.thread.isEmpty ?? true)) {
            aiState = .preparing
            await prepareSourceIfNeeded(force: true)
            guard sourceStatus == .ready else {
                if case .failed(let message) = sourceStatus { aiState = .failed(message) }
                return
            }
        }
        guard let provider = await makeProvider() else {
            aiState = .failed(L.string("mail.ai.error.noProvider"))
            return
        }

        generationCounter += 1
        let generation = generationCounter
        aiRaw = ""
        aiSubjectSuggestion = nil
        aiState = .generating

        let request = MailAIRequest(
            kind: activeAIKind,
            requirement: requirement,
            language: aiLanguage,
            tone: aiTone,
            length: aiLength,
            existingBody: activeAIKind == .polish ? bodyText : nil,
            original: activeAIKind == .reply ? sourceContext : nil,
            senderName: "",
            senderAddress: ""
        )
        let service = MailAIService(provider: provider)
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await service.generate(request) { delta in
                    Task { @MainActor in
                        self.append(delta: delta, generation: generation)
                    }
                }
                guard generation == self.generationCounter else { return }
                self.aiRaw = raw
                self.aiSubjectSuggestion = self.candidate.subjectSuggestion
                self.aiState = .done
            } catch is CancellationError {
                guard generation == self.generationCounter else { return }
                self.aiState = self.aiRaw.isEmpty ? .idle : .stopped
            } catch {
                guard generation == self.generationCounter else { return }
                self.aiState = .failed(Self.aiErrorMessage(error))
            }
        }
    }

    /// 停止生成：只取消 AI 请求，不丢弃用户正文与已生成片段。
    func stopAI() {
        generationCounter += 1
        generationTask?.cancel()
        generationTask = nil
        if !aiRaw.isEmpty {
            aiSubjectSuggestion = candidate.subjectSuggestion
            aiState = .stopped
        } else {
            aiState = .idle
        }
    }

    private func append(delta: String, generation: Int) {
        guard generation == generationCounter else { return }
        aiRaw += delta
    }

    // MARK: - Apply AI

    /// 应用候选正文：`replace` 覆盖当前回复正文，否则插入到末尾；不触碰原文引用。
    func applyAIBody(replace: Bool) {
        guard canApplyAI else { return }
        let text = candidate.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        undoBodySnapshot = bodyText
        undoBodyStyles = bodyStyles
        let suffix = managedSignature.flatMap { bodyText.hasSuffix($0) ? $0 : nil } ?? ""
        let content = String(bodyText.dropLast(suffix.count))
        let result = replace || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : content + "\n\n" + text
        bodyText = !suffix.isEmpty && !result.hasSuffix(suffix) ? result + suffix : result
    }

    /// 采用 AI 建议的主题（仅新写窗口显示该入口）。
    func applyAISubject() {
        guard let suggestion = aiSubjectSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suggestion.isEmpty else { return }
        subject = suggestion
    }

    /// 撤销上一次 AI 应用。
    func undoAIApply() {
        guard let snapshot = undoBodySnapshot else { return }
        setStyledBody(snapshot, styles: undoBodyStyles)
        undoBodySnapshot = nil
    }

    // MARK: - Providers

    private func loadProviders() async {
        let all = (try? await hub.providerService?.getAll()) ?? []
        availableProviders = all.filter { $0.isEnabled }
        if selectedProviderId == nil {
            let preferred = UserDefaults.standard.string(forKey: "agroom.chat.providerId")
                .flatMap(UUID.init(uuidString:))
            selectedProviderId = availableProviders.first(where: { $0.id == preferred })?.id
                ?? availableProviders.first?.id
        }
        updateModelLabel()
    }

    func selectProvider(_ id: UUID) {
        selectedProviderId = id
        updateModelLabel()
    }

    private func updateModelLabel() {
        let config = availableProviders.first { $0.id == selectedProviderId }
        aiModelLabel = config.map { $0.model.isEmpty ? $0.name : $0.model } ?? ""
    }

    private func makeProvider() async -> CloudProvider? {
        guard let service = hub.providerService else { return nil }
        let all = (try? await service.getAll()) ?? []
        let enabled = all.filter { $0.isEnabled }
        let config = enabled.first { $0.id == selectedProviderId } ?? enabled.first
        guard let config else { return nil }
        let key = KeychainService.loadAPIKey(for: config.id) ?? ""
        return CloudProvider(config: config, apiKey: key, usageRecorder: hub.makeUsageRecorder(for: space, source: "mail-compose"))
    }

    // MARK: - Send / Save

    /// 存草稿（不发送）；返回是否成功。
    func saveDraft(silently: Bool = false) async -> Bool {
        // 已投递：草稿已由发送流程清理，不再回写
        guard !didSendSuccessfully else { return true }
        guard let mail = hub.makeMailService(for: space) else { return false }
        if !silently {
            isBusy = true
            notice = nil
        }
        defer { if !silently { isBusy = false } }
        do {
            let savedFingerprint = fingerprint
            try await mail.saveEditableDraft(composedDraft())
            if !silently {
                hasSavedSnapshot = true
                lastSavedFingerprint = savedFingerprint
                autosaveFailed = false
                NotificationCenter.default.post(name: .mailDataChanged, object: nil)
            }
            return true
        } catch {
            if !silently {
                notice = Notice(kind: .failure, message: MailErrorText.message(for: error))
            }
            return false
        }
    }

    /// 保存并关闭；返回是否成功（失败时保持窗口并展示原因）。
    func saveAndClose() async -> Bool {
        guard await saveDraft() else { return false }
        return true
    }

    /// 发送：由独立协调对象持有任务与固定空间上下文，窗口关闭不影响投递。
    func send() async {
        guard !windowClosed, !isBusy, !isSendLocked, !didSendSuccessfully, !isAutoSaving,
              !attachmentsBlockSending, invalidRecipients.isEmpty, !parsedRecipients.isEmpty else { return }
        isBusy = true
        notice = nil
        defer { isBusy = false }
        let outcome = await MailSendCoordinator.shared.send(composedDraft(), space: space, hub: hub)
        switch outcome {
        case .sent:
            // 草稿已被发送流程清理：标记为已发送，避免收尾时再自动保存回写
            didSendSuccessfully = true
            hasSavedSnapshot = true
            lastSavedFingerprint = fingerprint
            onRequestClose?()
        case .failed(let message):
            notice = Notice(kind: .failure, message: message)
        case .resultUnknown(let message):
            sendLock = .unverified
            notice = Notice(kind: .resultUnknown, message: message)
        case .deliveredLocalSaveFailed(let message):
            sendLock = .delivered
            notice = Notice(kind: .delivered, message: message)
        }
    }

    // MARK: - Autosave

    /// 防抖自动保存（由视图以 `fingerprint` 为 id 触发）。
    func autosaveIfNeeded() async {
        let identity = fingerprint
        guard identity != lastSavedFingerprint else { return }
        do { try await Task.sleep(for: .milliseconds(800)); try Task.checkCancellation() }
        catch { return }
        // 发送中 / 正在保存时先让位，避免与投递或前一次保存交错
        while isAutoSaving || isBusy {
            do { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
            catch { return }
        }
        guard !Task.isCancelled, !isSendLocked, !didSendSuccessfully else { return }
        isAutoSaving = true
        let saved = await saveDraft(silently: true)
        isAutoSaving = false
        if saved {
            hasSavedSnapshot = true
            lastSavedFingerprint = identity
            autosaveFailed = false
        } else {
            autosaveFailed = true
        }
    }

    // MARK: - Close

    /// 关闭前判定：取消在途 AI、保留正在投递的发送任务，按保存状态决定是否需要询问。
    func prepareForClose() async -> MailComposeCloseAction {
        if isGeneratingAI { stopAI() }
        if isBusy || MailSendCoordinator.shared.isSending(draftID: draftID) { return .closeNow }
        if isSendLocked { return .closeNow }
        if fingerprint == lastSavedFingerprint { return .closeNow }
        return .ask
    }

    /// 「不保存本次修改」的说明：自动保存可能已经把内容落盘，需如实提示。
    var discardNote: String { L.string("product.mail.unsaved.help") }

    /// AI 失败文案：邮件专用错误走三语，其余错误沿用既有的邮件错误映射。
    private static func aiErrorMessage(_ error: Error) -> String {
        if let aiError = error as? MailAIService.MailAIError {
            switch aiError {
            case .emptyOutput: return L.string("mail.ai.error.empty")
            case .contextTooLong: return L.string("mail.ai.error.contextTooLong")
            case .providerUnavailable: return L.string("mail.ai.error.noProvider")
            }
        }
        return MailErrorText.message(for: error)
    }

    // MARK: - Draft Assembly

    /// 编辑字段 + 固定骨架组成的可持久化草稿（正文与引用分开保存）。
    private func composedDraft() -> MailDraft {
        var value = base
        value.to = parsedRecipients
        value.cc = parsedCc
        value.bcc = parsedBcc
        value.subject = subject
        value.bodyText = bodyText
        value.bodyStyles = bodyStyles
        value.quotedText = quotedText
        value.attachments = attachments; value.forwardAttachmentsState = forwardAttachmentsState
        value.updatedAt = Date()
        return value
    }

    // MARK: - Helpers

    /// 地址列表 → 输入框文本。
    private static func text(from addresses: [MailAddress]) -> String {
        addresses.map(\.composeText).joined(separator: ", ")
    }

    /// 引用原文（逐行 `>` 前缀）。
    private static func quoted(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }
}
