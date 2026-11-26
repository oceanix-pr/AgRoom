import SwiftUI
import AgRoomCore

// MARK: - Queued Messages Card（待发送队列卡片）

/// 批量对话队列卡片（输入框上方）：所见即所发——
/// 头部（计数 + 状态/操作）+ 消息行（单行截断、逐条移除、队头标记）；
/// 超过折叠行数收起为「还有 N 条」，点击展开
struct QueuedMessagesCard: View {
    let items: [ChatViewModel.QueuedMessage]
    let immediateItem: ChatViewModel.QueuedMessage?
    let isRunning: Bool
    let isFull: Bool
    let statusText: String?
    let canSendImmediately: Bool
    let canResume: Bool
    let onRemove: (UUID) -> Void
    let onClear: () -> Void
    let onSendNext: () -> Void
    let onSendImmediately: (UUID) -> Void

    @State private var expanded = false
    /// 折叠时显示的最大行数（超出折叠为「还有 N 条」）
    private static let collapsedRows = 6

    private var visibleItems: [ChatViewModel.QueuedMessage] {
        expanded ? items : Array(items.prefix(Self.collapsedRows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let immediateItem {
                row(immediateItem, isFirst: false, isImmediate: true)
            }
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                row(item, isFirst: index == 0)
            }
            if items.count > Self.collapsedRows && !expanded {
                Button {
                    withAnimation(.snappy) { expanded = true }
                } label: {
                    Text(L.format("chat.queue.more", items.count - Self.collapsedRows))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L.string(items.isEmpty && immediateItem != nil ? "chat.send.immediate" : "chat.queue.title"))
                .font(.caption.weight(.medium))
            // 计数：满员变红提示（输入侧同时禁发）
            if !items.isEmpty {
                Text("\(items.count)/\(ChatViewModel.ChatSendQueue.limit)")
                    .font(.caption2)
                    .foregroundStyle(isFull ? Color.red : Color.secondary)
            }
            if let statusText {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if isRunning {
                Text(L.string("chat.queue.auto_hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if !isRunning {
                // 冻结态（停止/失败后）：队列保留，手动续发
                Button(L.string("chat.queue.send_next")) { onSendNext() }
                    .font(.caption2)
                    .buttonStyle(.link)
                    .disabled(!canResume)
            }
            Spacer(minLength: 8)
            Button(L.string("chat.queue.clear")) { onClear() }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .help(L.string("chat.queue.clear"))
        }
    }

    private func row(_ item: ChatViewModel.QueuedMessage, isFirst: Bool, isImmediate: Bool = false) -> some View {
        HStack(spacing: 6) {
            // 队头标记（冻结态下一条即将发出的就是它；运行中由头部提示自动语义）
            if isImmediate {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityLabel(L.string("chat.send.immediate"))
            } else if isFirst && !isRunning {
                Text(L.string("chat.queue.next"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .center)
            }
            Text(displayText(item))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if !isImmediate {
                Button(L.string("chat.send.immediate")) { onSendImmediately(item.id) }
                    .font(.caption2)
                    .buttonStyle(.link)
                    .disabled(!canSendImmediately)
                    .help(L.string("chat.send.immediate_hint"))
                    .accessibilityIdentifier("chat.queue.sendImmediately.\(item.id.uuidString)")
            }
            Button {
                onRemove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L.string("chat.queue.remove"))
        }
        .contentShape(Rectangle())
    }

    private func displayText(_ item: ChatViewModel.QueuedMessage) -> String {
        if item.text.isEmpty {
            return L.string("chat.queue.attachment_only")
        }
        return item.text
    }
}

// MARK: - Rename Session Sheet

/// 会话重命名弹窗：单输入框 + 确认/取消；提交时去空白，空标题忽略
struct RenameSessionSheet: View {
    let initialTitle: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("chat.session.rename"))
                .font(.headline)

            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.string("common.ok"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            text = initialTitle
            focused = true
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

// MARK: - New Workspace Sheet

/// 新增工作区弹窗：输入名称，确认后在「文件」页 files 目录下创建同名文件夹并登记
struct NewWorkspaceSheet: View {
    @Binding var name: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("workspace.new.title"))
                .font(.headline)

            TextField(L.string("workspace.new.placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)

            Text(L.string("workspace.new.hint"))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.string("common.ok"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        name = trimmed
        onSubmit(trimmed)
        dismiss()
    }
}

// MARK: - Confirmation Card

/// 确认卡决策：一次性批准 / 本轮放行 / 写入跨轮持久规则
struct ConfirmationDecision {
    let approved: Bool
    /// 本轮内该「工具 + 范围」不再询问
    let allowRound: Bool
    /// 写入跨轮持久规则（Shell 命令前缀）
    let persistRule: Bool

    static let approveOnce = ConfirmationDecision(approved: true, allowRound: false, persistRule: false)
    static let reject = ConfirmationDecision(approved: false, allowRound: false, persistRule: false)
}

/// 危险工具调用确认卡片：展示工具名与参数，用户放行或拒绝
/// 进程重启后原审批句柄已失效。保留操作摘要供核对，但不再呈现授权按钮。
struct InterruptedConfirmationCard: View {
    let pending: PendingConfirmation
    let hasSavedSteps: Bool
    let onViewSteps: () -> Void
    let onEndWaiting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L.string("chat.interrupted.title"), systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(L.string("chat.interrupted.message"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(L.format("chat.interrupted.operation", pending.toolName))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if !pending.argumentsDisplay.isEmpty {
                DisclosureGroup(L.string("chat.interrupted.details")) {
                    ScrollView {
                        Text(pending.argumentsDisplay)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            HStack(spacing: 10) {
                if hasSavedSteps {
                    Button(L.string("chat.interrupted.view_steps"), action: onViewSteps)
                        .accessibilityIdentifier("chat.interrupted.view_steps")
                }
                Spacer(minLength: 8)
                Button(L.string("chat.interrupted.end_waiting"), action: onEndWaiting)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.interrupted.end_waiting")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

/// 重启后原 ask_user 恢复句柄已失效；旧问题只能供核对，不能把答案注入新运行。
struct InterruptedQuestionCard: View {
    let form: QuestionForm
    let hasSavedSteps: Bool
    let onViewSteps: () -> Void
    let onEndWaiting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L.string("chat.interrupted.title"), systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(L.string("chat.interrupted.question_message"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !form.title.isEmpty {
                Text(form.title).font(.caption.weight(.semibold))
            }
            if !form.prompt.isEmpty {
                Text(form.prompt)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if !form.fields.isEmpty {
                DisclosureGroup(L.string("chat.interrupted.question_details")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(form.fields) { field in
                            Text(field.label)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 10) {
                if hasSavedSteps {
                    Button(L.string("chat.interrupted.view_steps"), action: onViewSteps)
                        .accessibilityIdentifier("chat.interrupted.view_steps")
                }
                Spacer(minLength: 8)
                Button(L.string("chat.interrupted.end_waiting"), action: onEndWaiting)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat.interrupted.end_waiting")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

struct ConfirmationCard: View {
    let pending: PendingConfirmation
    /// 决策回调：批准/拒绝 + 放行范围（本轮 / 跨轮持久规则）
    let onDecision: (ConfirmationDecision) -> Void

    /// 确认需求：旧快照无该字段时回退为普通确认（按工具范围）
    private var requirement: ConfirmationRequirement {
        pending.requirement ?? ConfirmationRequirement(kind: .normal, scope: .tool)
    }
    /// 硬确认：只提供「允许一次 / 拒绝」，并说明不可本轮放行的原因
    private var isHard: Bool { requirement.kind == .hard }
    /// 普通确认且携带可授权范围键时才展示「本轮允许…」
    private var canAuthorizeRound: Bool { !isHard && requirement.roundKey != nil }
    /// 「始终允许 …」候选（跨轮持久规则）：硬确认一律没有
    private var persistentCandidates: [String] {
        guard !isHard else { return [] }
        return requirement.persistentRuleCandidates ?? []
    }

    @ViewBuilder
    var body: some View {
        if let presentation = pending.requirement?.presentation {
            if ["browser_navigation", "browser_query", "browser_control", "browser_fill", "browser_action"].contains(presentation.reasonCode) {
                BrowserApprovalCard(pending: pending, presentation: presentation, onDecision: onDecision)
                    .id(pending.approvalID ?? pending.messageId)
            } else if presentation.documentation != nil {
                legacyCard
            } else {
                // 已接入可信执行摘要的调用使用脚本专用卡片；旧快照与未接入工具保留原卡片。
                ScriptApprovalCard(pending: pending, presentation: presentation, onDecision: onDecision)
            }
        } else {
            legacyCard
        }
    }

    private var legacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.string("chat.confirm.title"), systemImage: "exclamationmark.shield")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.orange)

            if let source = requirement.presentation?.documentation,
               let alias = source.skillAlias, let description = source.skillDescription {
                Text(L.format("documentation.confirm.skill", alias, description))
                    .readingBodyFont().fontWeight(.medium).textSelection(.enabled)
            } else {
                Text(ConfirmationSummary.text(tool: pending.toolName, arguments: pending.argumentsDisplay, preview: pending.changePreview))
                    .readingBodyFont().fontWeight(.medium).textSelection(.enabled)
            }
            Text(L.format("chat.confirm.message", L.dispatcherName(), pending.toolName))
                .font(.caption)
                .foregroundColor(.secondary)

            if let source = requirement.presentation?.documentation {
                VStack(alignment: .leading, spacing: 5) {
                    Label(L.string("documentation.confirm.title"), systemImage: "doc.text.magnifyingglass")
                        .font(.caption).fontWeight(.semibold)
                    Text(source.url).textSelection(.enabled)
                    Text(L.format("documentation.confirm.scope", source.scope)).textSelection(.enabled)
                    Text(L.format("documentation.confirm.version", source.version == "unspecified" ? L.string("documentation.version.unspecified") : source.version))
                    Text(L.format("documentation.confirm.coverage", source.collectedPages, source.readPages, source.missingPages))
                    Text(L.string(source.partial ? "documentation.confirm.partial" : "documentation.confirm.discovered"))
                    if let count = source.verificationStepCount { Text(L.format("documentation.confirm.verification", count)) }
                    Text(L.string("documentation.confirm.unverified")).foregroundStyle(.secondary)
                }
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.06)).cornerRadius(6)
            }

            // 硬确认原因：解释为何不能「本轮允许」（逐次必问）
            if isHard, let reason = requirement.hardReason {
                Label(Self.hardReasonText(reason), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let reason = requirement.autoReviewReason,
               requirement.hardReason == nil || !["hard_confirmation", "host_execution", "directory_write", "high_risk_command", "irreversible"].contains(reason) {
                Text(Self.autoReviewReasonText(reason))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 变更预览（dry-run）：写类文件工具批准前先看「将要发生什么」
            if let preview = pending.changePreview {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L.string("chat.preview.title"), systemImage: "eye")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(Self.previewSummary(preview))
                        .font(.caption)
                        .fontWeight(.medium)
                    if let diff = preview.diff, !diff.isEmpty {
                        ScrollView {
                            DiffTextView(diff: diff)
                        }
                        .frame(maxHeight: 220)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.blue.opacity(0.06))
                .cornerRadius(6)
            }

            // 完整参数（不截断）：批准前可滚动审阅全部内容
            if !pending.argumentsDisplay.isEmpty {
                DisclosureGroup(L.string("product.confirm.details")) {
                ScrollView {
                    Text(pending.argumentsDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
                }
            }

            Text(L.string("product.confirm.scope.help")).font(.caption).foregroundStyle(.secondary)

            // 放行范围按钮：始终允许（跨轮持久规则）/ 本轮允许（只活一轮）
            // 两者可同时存在；硬确认与不可授权的普通确认都不展示
            if !persistentCandidates.isEmpty || canAuthorizeRound {
                HStack(spacing: 8) {
                    if !persistentCandidates.isEmpty {
                        Button(Self.persistentRuleLabel(persistentCandidates)) {
                            onDecision(ConfirmationDecision(
                                approved: true,
                                allowRound: false,
                                persistRule: true
                            ))
                        }
                        .help(L.string("chat.confirm.allow_always.help"))
                    }
                    if canAuthorizeRound {
                        Button(Self.roundScopeLabel(requirement.scope)) {
                            onDecision(ConfirmationDecision(
                                approved: true,
                                allowRound: true,
                                persistRule: false
                            ))
                        }
                    }
                    Spacer()
                }
            }

            HStack {
                Spacer()

                Button(L.string("chat.confirm.reject")) {
                    onDecision(.reject)
                }
                .keyboardShortcut(.cancelAction)

                Button(L.string("chat.confirm.approve_once")) {
                    onDecision(.approveOnce)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    /// 「始终允许 …」按钮文案：单条前缀直接展示；多条列出（最多 3 条）并给出总数
    static func persistentRuleLabel(_ candidates: [String]) -> String {
        guard let first = candidates.first else { return "" }
        if candidates.count == 1 {
            return L.format("chat.confirm.allow_always", first)
        }
        let shown = candidates.prefix(3).joined(separator: ", ")
        return L.format("chat.confirm.allow_always_multi", shown, candidates.count)
    }

    /// 「本轮允许…」按钮文案：按授权范围本地化
    static func roundScopeLabel(_ scope: ConfirmationRequirement.Scope) -> String {
        switch scope {
        case .script: return L.string("chat.confirm.round.script")
        case .domain: return L.string("chat.confirm.round.domain")
        case .fileArea: return L.string("chat.confirm.round.fileArea")
        case .tool: return L.string("chat.confirm.round.tool")
        }
    }

    /// 硬确认原因文案：解释为何该操作逐次必问
    static func hardReasonText(_ reason: ConfirmationRequirement.HardReason) -> String {
        switch reason {
        case .headlessContext: return L.string("chat.confirm.hard_reason.headless")
        case .highRiskCommand: return L.string("chat.confirm.hard_reason.high_risk")
        case .directoryWrite: return L.string("chat.confirm.hard_reason.directory_write")
        case .hostExecution: return L.string("chat.confirm.hard_reason.host_execution")
        case .pageMutationScript: return L.string("chat.confirm.hard_reason.page_mutation")
        case .arbitraryScript: return L.string("chat.confirm.hard_reason.arbitrary_script")
        case .browserAction: return L.string("browser.approval.action_help")
        case .irreversible: return L.string("chat.confirm.hard_reason.irreversible")
        case .unspecified: return L.string("chat.confirm.hard_reason.unspecified")
        }
    }

    static func autoReviewReasonText(_ reason: String) -> String {
        if reason == "auto_review_disabled" { return L.string("chat.autoReview.reason.disabled") }
        let known: Set<String> = ["disabled", "hard_confirmation", "not_eligible", "unverified_shell",
                                  "code_execution", "browser_action", "external_effect", "file_mutation",
                                  "internal_confirmation", "unverified_scope", "missing_path", "unresolved_path",
                                  "review_timeout", "review_unavailable", "review_invalid_response", "review_digest_mismatch",
                                  "review_basis_mismatch", "review_input_too_large", "review_budget_exhausted", "task_budget_exhausted",
                                  "directory_write", "high_risk_command", "irreversible", "workspace_authorization_unavailable", "recovery_requires_confirmation",
                                  "task_scope_unavailable", "task_scope_inactive", "task_write_prohibited",
                                  "task_code_prohibited", "unverified_executor", "user_request_unavailable",
                                  "evidence_unavailable", "deterministic_disabled", "outside_task_scope",
                                  "unverified_content", "recovery_unavailable", "model_review_disallowed",
                                  "denylisted_tool", "outside_workspace", "host_execution", "mcp_query", "mcp_query_unverified", "browser_structured", "browser_unverified",
                                  "browser_https_required", "browser_evidence_truncated", "browser_evidence_too_large"]
        return L.string("chat.autoReview.reason." + (known.contains(reason) ? reason : "not_eligible"))
    }

    /// 预览摘要文案（按操作类型本地化）
    static func previewSummary(_ preview: FileChangePreview) -> String {
        switch preview.kind {
        case .create:
            return L.format("chat.preview.create", preview.path, preview.newLines ?? 0)
        case .overwrite:
            guard let added = preview.addedLines, let removed = preview.removedLines else {
                return L.format("chat.preview.overwrite_unavailable", preview.path)
            }
            let omitted = preview.diff == nil && (added > 0 || removed > 0)
                ? " " + L.string("chat.preview.details_unavailable") : ""
            guard let old = preview.oldLines, let new = preview.newLines else {
                return L.format("chat.preview.overwrite_changes", preview.path, added, removed) + omitted
            }
            return L.format(
                "chat.preview.overwrite",
                preview.path,
                old,
                new,
                added,
                removed
            ) + omitted
        case .delete:
            return L.format("chat.preview.delete", preview.path)
        case .mkdir:
            return L.format("chat.preview.mkdir", preview.path)
        case .rename:
            return L.format("chat.preview.rename", preview.path, preview.destination ?? "")
        case .copy:
            return L.format("chat.preview.copy", preview.path, preview.destination ?? "")
        case .move:
            return L.format("chat.preview.move", preview.path, preview.destination ?? "")
        }
    }
}

// MARK: - Auto Review Progress Card

/// 自动审核进度卡片：审核在途时替代确认卡显示（原确认卡与完整参数在转人工后重新可见）
struct AutoReviewProgressCard: View {
    /// 正在被审核的工具名
    let toolName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.string("chat.autoReview.reviewing"))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(L.format("chat.autoReview.reviewing_detail", toolName))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Diff Text View

/// 统一 diff 着色渲染：+ 绿 / - 红 / @@ 头灰 / 上下文默认
struct DiffTextView: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(diffBackground(line))
                    .foregroundStyle(diffForeground(line))
            }
        }
        .padding(.vertical, 4)
    }

    private func diffForeground(_ line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@") { return .secondary }
        return .primary
    }

    private func diffBackground(_ line: String) -> Color {
        if line.hasPrefix("+") { return Color.green.opacity(0.08) }
        if line.hasPrefix("-") { return Color.red.opacity(0.08) }
        return .clear
    }
}

// MARK: - Skill Generation Offer Card

/// 对话输入命中明确的技能需求后展示；它是对话流内卡片，不打断为独立弹窗。
struct SkillGenerationOfferCard: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.string("chat.skill_generation.title"), systemImage: "wand.and.stars")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)

            Text(L.string("chat.skill_generation.message"))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()

                Button(L.string("chat.skill_generation.dismiss")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L.string("chat.skill_generation.confirm")) {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Skill Distill Card

/// 连续对话达到 10 轮后的「总结成技能」询问卡片：
/// 每会话只出现一次，确认后自动发送沉淀指令（Agent 调用 skill_create）。
struct SkillDistillCard: View {
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.string("chat.distill.title"), systemImage: "wand.and.stars")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.green)

            Text(L.string("chat.distill.message"))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()

                Button(L.string("chat.distill.dismiss")) {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L.string("chat.distill.confirm")) {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Drop Support

/// 线程安全的 URL 收集器（拖放回调来自任意队列）
final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []

    func append(_ url: URL) {
        lock.withLock { items.append(url) }
    }

    var urls: [URL] {
        lock.withLock { items }
    }
}
