import SwiftUI
import AgRoomCore

/// 脚本/代码执行专用确认卡：先回答「做什么、访问什么、为什么问、批准多久」，
/// 再提供互斥的授权有效期与一次批准/拒绝。
/// 资源范围只读取 Core 的可信摘要，不从模型文案或工具名推测。
struct ScriptApprovalCard: View {
    let pending: PendingConfirmation
    let presentation: ToolApprovalPresentation
    let onDecision: (ConfirmationDecision) -> Void

    @State private var duration: ConfirmationRequirement.ApprovalDuration = .once

    private var requirement: ConfirmationRequirement {
        pending.requirement ?? ConfirmationRequirement(kind: .normal, scope: .tool)
    }

    private var availableDurations: [ConfirmationRequirement.ApprovalDuration] {
        requirement.availableApprovalDurations
    }

    private var isHard: Bool { requirement.kind == .hard }
    private var isHost: Bool {
        [.hostCommand, .hostBuild, .hostLanguageService].contains(presentation.executionKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(isRemoteMCP ? L.string("mcp.approval.summary") : ConfirmationSummary.text(
                tool: pending.toolName, arguments: pending.argumentsDisplay, preview: pending.changePreview
            ))
            .readingBodyFont()
            .fontWeight(.medium)
            .textSelection(.enabled)

            reasonLine
            if isRemoteMCP {
                Text(presentation.executionDetails.joined(separator: "\n"))
                    .font(.callout)
                    .textSelection(.enabled)
                Text(L.string("mcp.approval.scope"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                resourceSection
                capabilitySection
            }

            if !presentation.constraintSources.isEmpty {
                Text(L.format("permissions.constraints.title", constraintText))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let preview = pending.changePreview {
                changePreview(preview)
            }

            if availableDurations.count > 1 {
                durationPicker
            }

            detailsSection
            decisionButtons
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardTint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(cardTint.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .onChange(of: pending.argumentsDisplay) { _, _ in
            duration = .once
        }
        .onChange(of: availableDurations) { _, newValue in
            if !newValue.contains(duration) { duration = .once }
        }
    }

    private var cardTint: Color { isHard || isHost ? .red : .orange }
    private var isRemoteMCP: Bool { presentation.executionKind == .remoteMCP }

    private var header: some View {
        Label(
            L.format("chat.confirm.script.title", executionKindText),
            systemImage: isHard || isHost ? "exclamationmark.shield.fill" : "shield.lefthalf.filled"
        )
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(cardTint)
    }

    private var executionKindText: String {
        L.string("permissions.kind." + presentation.executionKind.rawValue)
    }

    @ViewBuilder
    private var reasonLine: some View {
        if isRemoteMCP {
            Text(L.string(isHard ? "permissions.reason.mcp_remote_call" : "permissions.reason.mcp_query"))
                .font(.caption).foregroundStyle(.secondary)
            if let reason = requirement.autoReviewReason {
                Text(ConfirmationCard.autoReviewReasonText(reason))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if isHard, let reason = requirement.hardReason {
            Label(ConfirmationCard.hardReasonText(reason), systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let reason = requirement.autoReviewReason {
            Text(ConfirmationCard.autoReviewReasonText(reason))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text(reasonText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var reasonText: String {
        let key = "permissions.reason." + presentation.reasonCode
        let value = L.string(key)
        return value == key ? L.string("permissions.reason.other") : value
    }

    private var resourceSection: some View {
        let access = isHost ? ToolApprovalPresentation.ResourceAccess.host : presentation.resourceAccess
        return VStack(alignment: .leading, spacing: 4) {
            if let directory = presentation.startingDirectory {
                resourceRow("permissions.scope.start_directory", [directory])
            }
            resourceRow("permissions.scope.read", access.readable)
            resourceRow("permissions.scope.write", access.writable)
            resourceRow("permissions.scope.outputs", presentation.resourceAccess.outputs)
            resourceRow("permissions.scope.temporary", presentation.resourceAccess.temporary)
            if let container = presentation.resourceAccess.executorContainer, !container.isEmpty {
                resourceRow("permissions.scope.container", [container])
            }
            if !presentation.resourceAccess.verified {
                Label(L.string("permissions.capability.unverified"), systemImage: "questionmark.diamond")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }

    private var capabilitySection: some View {
        HStack(spacing: 16) {
            capabilityLabel("permissions.capability.network", presentation.network.allowed)
            capabilityLabel("permissions.capability.processes", presentation.childProcesses.allowed)
        }
    }

    private func capabilityLabel(_ titleKey: String, _ allowed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(L.string(titleKey))
                .foregroundColor(.secondary)
            Text(L.string(allowed
                ? "permissions.capability.allowed"
                : "permissions.capability.blocked"))
                .foregroundColor(allowed ? .orange : .green)
                .fontWeight(.medium)
        }
        .font(.caption)
    }

    private func resourceRow(_ titleKey: String, _ items: [String]) -> some View {
        Group {
            if !items.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(L.string(titleKey))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 46, alignment: .leading)
                    Text(items.map(displayScope).joined(separator: "、"))
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func displayScope(_ value: String) -> String {
        switch value {
        case ToolApprovalPresentation.ScopeToken.hostAccessibleFiles:
            return L.string("permissions.scope.host_files")
        case ToolApprovalPresentation.ScopeToken.systemBaseline:
            return L.string("permissions.scope.system_baseline")
        case ToolApprovalPresentation.ScopeToken.runTemporary:
            return L.string("permissions.scope.run_temporary")
        case ToolApprovalPresentation.ScopeToken.executorContainer:
            return L.string("permissions.scope.executor_container")
        case ToolApprovalPresentation.ScopeToken.skillPackage:
            return L.string("permissions.scope.skill_package")
        case ToolApprovalPresentation.ScopeToken.skillScratch:
            return L.string("permissions.scope.skill_scratch")
        case ToolApprovalPresentation.ScopeToken.pythonOutput:
            return L.string("permissions.scope.python_output")
        default:
            return value
        }
    }

    private var constraintText: String {
        presentation.constraintSources.map { source in
            let key = "permissions.constraint." + source
            let localized = L.string(key)
            return localized == key ? source : localized
        }.joined(separator: " / ")
    }

    private func changePreview(_ preview: FileChangePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L.string("chat.preview.title"), systemImage: "eye")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text(ConfirmationCard.previewSummary(preview))
                .font(.caption)
                .fontWeight(.medium)
            if let diff = preview.diff, !diff.isEmpty {
                ScrollView {
                    DiffTextView(diff: diff)
                }
                .frame(maxHeight: 180)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(6)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(6)
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.string("chat.confirm.duration"))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Picker("", selection: $duration) {
                ForEach(availableDurations, id: \.self) { option in
                    Text(durationLabel(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if duration == .persistent, let candidates = requirement.persistentRuleCandidates,
               !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.string("chat.confirm.rule_preview"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(candidates.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    if let expires = presentation.rulePreview?.expiresAt {
                        Text(L.format(
                            "chat.confirm.rule_expires",
                            expires.formatted(date: .abbreviated, time: .shortened)
                        ))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(6)
            }
        }
    }

    private func durationLabel(_ option: ConfirmationRequirement.ApprovalDuration) -> String {
        switch option {
        case .once: return L.string("chat.confirm.duration.once")
        case .round: return L.string("chat.confirm.duration.round")
        case .persistent: return L.string("chat.confirm.duration.persistent")
        }
    }

    private var detailsSection: some View {
        DisclosureGroup(L.string("chat.confirm.details_full")) {
            VStack(alignment: .leading, spacing: 8) {
                if !presentation.executionDetails.isEmpty {
                    Text(presentation.executionDetails.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !pending.argumentsDisplay.isEmpty {
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
        }
        .font(.caption)
    }

    private var decisionButtons: some View {
        HStack {
            Spacer()
            Button(L.string("chat.confirm.reject")) {
                onDecision(.reject)
            }
            .keyboardShortcut(.cancelAction)

            Button(primaryLabel) {
                onDecision(decision(for: duration))
            }
            .buttonStyle(.borderedProminent)
            .tint(isHard || isHost ? .red : .accentColor)
            .modifier(DefaultActionModifier(enabled: !isHard && !isHost))
        }
    }

    private var primaryLabel: String {
        if isHost {
            return L.string("chat.confirm.approve_host")
        }
        if isHard || availableDurations.count == 1 {
            return L.string("chat.confirm.approve_once")
        }
        switch duration {
        case .once: return L.string("chat.confirm.approve_once")
        case .round: return L.string("chat.confirm.approve_round")
        case .persistent:
            guard let first = requirement.persistentRuleCandidates?.first else {
                return L.string("chat.confirm.approve_once")
            }
            return L.format("chat.confirm.approve_persistent", first)
        }
    }

    private func decision(for duration: ConfirmationRequirement.ApprovalDuration) -> ConfirmationDecision {
        switch duration {
        case .once:
            return .approveOnce
        case .round:
            return ConfirmationDecision(approved: true, allowRound: true, persistRule: false)
        case .persistent:
            return ConfirmationDecision(approved: true, allowRound: false, persistRule: true)
        }
    }
}

/// 只在普通确认上保留回车批准；宿主、硬确认必须由用户显式点击。
private struct DefaultActionModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
