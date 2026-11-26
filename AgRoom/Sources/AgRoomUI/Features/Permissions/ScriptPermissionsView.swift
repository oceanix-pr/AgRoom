import SwiftUI
import AgRoomCore

/// 脚本与权限完整页面：会话权限、执行确认、授权规则、执行记录四区。
/// 只绑定当前空间；会话上下文可选，设置页打开时只展示新会话默认值与本空间管理项。
struct ScriptPermissionsView: View {
    let hub: Hub
    let space: AppSpace
    let viewModel: ChatViewModel?
    let sessionId: UUID?

    @StateObject private var model: ScriptPermissionsViewModel
    @State private var selectedRule: ShellApprovalRule?
    @State private var showingClearConfirm = false
    @Environment(\.dismiss) private var dismiss

    @AppStorage(DispatcherSettings.defaultPermissionModeKey)
    private var defaultPermissionModeRaw = PermissionMode.workspaceWrite.rawValue

    init(hub: Hub, space: AppSpace, viewModel: ChatViewModel? = nil, sessionId: UUID? = nil) {
        self.hub = hub
        self.space = space
        self.viewModel = viewModel
        self.sessionId = sessionId
        _model = StateObject(wrappedValue: ScriptPermissionsViewModel(hub: hub, space: space))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sessionSection
                    pendingSection
                    rulesSection
                    recoverySection
                    recordsSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 680)
        .task { await model.load() }
        .sheet(item: $selectedRule) { rule in
            ApprovalRuleDetailView(rule: rule, space: space) {
                await model.revoke(rule)
            }
        }
        .alert(
            L.string("common.error"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L.string("common.ok"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            L.string("permissions.rules.clearConfirmTitle"),
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L.string("permissions.rules.clear"), role: .destructive) {
                Task { await model.clearAll() }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.string("permissions.rules.clearConfirmMessage"))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.string("permissions.page.title"))
                    .font(.headline)
                Text(L.format("permissions.page.space", L.string(space.nameKey)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(L.string("common.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Session

    private var sessionSection: some View {
        sectionCard(
            title: L.string("permissions.section.session"),
            icon: "person.badge.key"
        ) {
            if let viewModel, let sessionId,
               let session = viewModel.sessions.first(where: { $0.id == sessionId }) {
                let configuration = viewModel.permissionConfiguration(forSession: sessionId)
                let title = session.displayTitle.isEmpty ? L.string("chat.new") : session.displayTitle
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        PermissionControl(
                            configuration: configuration,
                            isReviewing: viewModel.isAutoReviewing(sessionId: sessionId),
                            isSaving: viewModel.isSavingPermission(forSession: sessionId),
                            canSwitch: viewModel.canSwitchMode(forSession: sessionId),
                            onSelectPreset: { preset in
                                guard let current = viewModel.sessions.first(where: { $0.id == sessionId }),
                                      current.restorationToken == session.restorationToken,
                                      current.workspaceId == session.workspaceId,
                                      viewModel.permissionConfiguration(forSession: sessionId) == configuration else { return }
                                viewModel.setPermissionPreset(preset, forSession: sessionId)
                            }
                        )
                        .id("\(sessionId)/\(session.restorationToken ?? "")/\(session.workspaceId ?? "")")
                    }
                    Text(L.string(configuration.preset.descriptionKey))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if configuration.preset == .custom {
                        LabeledContent(L.string("chat.permission.popover.scope"),
                                       value: L.string(configuration.mode.nameKey))
                        LabeledContent(L.string("chat.permission.popover.approval"),
                                       value: L.string(configuration.autoReviewEnabled ? "chat.approval.auto" : "chat.approval.ask"))
                    }
                    if let workspace = viewModel.workspace(forSession: sessionId) {
                        Label(L.format("chat.permission.popover.workspace", viewModel.workspaceName(workspace)),
                              systemImage: "folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Label(L.string("chat.permission.popover.offline"), systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !viewModel.canSwitchMode(forSession: sessionId) {
                        Label(L.string(viewModel.isSavingPermission(forSession: sessionId)
                            ? "chat.permission.preset.saving" : "chat.permission.locked"), systemImage: "lock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.string("permissions.session.defaults.title"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    PermissionControl(
                        configuration: PermissionConfiguration(
                            mode: PermissionMode(rawValue: defaultPermissionModeRaw) ?? .workspaceWrite,
                            autoReviewEnabled: false),
                        options: PermissionPreset.defaultOptions,
                        onSelectPreset: { preset in
                            guard PermissionPreset.defaultOptions.contains(preset),
                                  let configuration = preset.configuration else { return }
                            defaultPermissionModeRaw = configuration.mode.rawValue
                        }
                    )
                    Text(L.string("permissions.session.defaults.note"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Pending confirmation

    private var pendingSection: some View {
        sectionCard(
            title: L.string("permissions.section.pending"),
            icon: "exclamationmark.bubble"
        ) {
            if let viewModel, let pending = viewModel.pendingConfirmation {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.toolName)
                        .font(.subheadline.weight(.medium))
                    Text(ConfirmationSummary.text(
                        tool: pending.toolName,
                        arguments: pending.argumentsDisplay,
                        preview: pending.changePreview
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(6)
                    Button(L.string("permissions.pending.open")) { dismiss() }
                        .font(.caption)
                }
            } else {
                Text(L.string(viewModel == nil
                    ? "permissions.pending.settingsHint"
                    : "permissions.pending.none"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        sectionCard(
            title: L.string("permissions.section.rules"),
            icon: "checkmark.seal"
        ) {
            switch model.rulesState {
            case .loading:
                Text(L.string("permissions.rules.loading"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .missing:
                Text(L.string("permissions.rules.empty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .loaded(let rules):
                if rules.isEmpty {
                    Text(L.string("permissions.rules.empty"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rules) { rule in
                            ruleRow(rule)
                            if rule.id != rules.last?.id { Divider() }
                        }
                    }
                    Button(L.string("permissions.rules.clear")) {
                        showingClearConfirm = true
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            case .corrupt:
                VStack(alignment: .leading, spacing: 6) {
                    Label(L.string("permissions.rules.corrupt"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button(L.string("common.retry")) {
                        Task { await model.load() }
                    }
                    .font(.caption)
                }
            case .unavailable:
                VStack(alignment: .leading, spacing: 6) {
                    Label(L.string("permissions.rules.unavailable"), systemImage: "externaldrive.badge.questionmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button(L.string("common.retry")) {
                        Task { await model.load() }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func ruleRow(_ rule: ShellApprovalRule) -> some View {
        Button {
            selectedRule = rule
        } label: {
            HStack(spacing: 8) {
                Text(rule.label)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(statusText(rule))
                    .font(.caption2)
                    .foregroundColor(statusColor(rule))
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusText(_ rule: ShellApprovalRule) -> String {
        if rule.isExpired { return L.string("permissions.rules.status.expired") }
        if rule.requiresReauthorization { return L.string("permissions.rules.status.reauthorize") }
        return L.string("permissions.rules.status.valid")
    }

    private func statusColor(_ rule: ShellApprovalRule) -> Color {
        if rule.requiresReauthorization { return .orange }
        return .green
    }

    // MARK: - Task Recovery

    private var recoverySection: some View {
        sectionCard(
            title: L.string("permissions.section.recovery"),
            icon: "clock.arrow.circlepath"
        ) {
            Text(L.string("permissions.recovery.note"))
                .font(.caption2)
                .foregroundColor(.secondary)
            if model.recoveryUnavailable {
                Text(L.string("permissions.recovery.unavailable"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(L.string("common.retry")) {
                    Task { await model.load() }
                }
                .font(.caption)
            } else if model.recoverable.isEmpty {
                Text(L.string("permissions.recovery.empty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recoverable) { record in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(L.string("permissions.recovery.restore")) {
                                Task { await model.restore(record) }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - Records

    private var recordsSection: some View {
        sectionCard(
            title: L.string("permissions.section.records"),
            icon: "list.bullet.rectangle"
        ) {
            Text(L.string("permissions.records.note"))
                .font(.caption2)
                .foregroundColor(.secondary)
            if model.auditUnavailable {
                Text(L.string("permissions.records.unavailable"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if model.auditEntries.isEmpty {
                Text(L.string("permissions.records.empty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.auditEntries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(entry.toolName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Text(decisionText(entry.decision))
                                    .font(.caption2)
                                    .foregroundColor(decisionColor(entry.decision))
                                Spacer()
                                Text(entry.time.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text([entry.route, entry.executionProfile, entry.reason]
                                .compactMap { $0 }
                                .filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func decisionText(_ decision: String) -> String {
        let key = "permissions.records.decision." + decision
        let value = L.string(key)
        return value == key ? decision : value
    }

    private func decisionColor(_ decision: String) -> Color {
        switch decision {
        case "approved": return .green
        case "rejected", "revoked": return .red
        default: return .orange
        }
    }

    // MARK: - Actions

    // MARK: - Section card

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
