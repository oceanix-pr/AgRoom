import SwiftUI
import AgRoomCore

/// 持久授权规则详情：展示完整匹配条件、有效期与撤销入口。
/// 撤销只影响后续执行，不承诺追回已经开始或已完成的调用。
struct ApprovalRuleDetailView: View {
    let rule: ShellApprovalRule
    let space: AppSpace
    let onRevoke: () async -> Void

    @State private var showingRevokeConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.string("permissions.rule.detail.title"))
                        .font(.headline)
                    Text(rule.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("permissions.rule.space", L.string(space.nameKey))
                    detailRow("permissions.rule.workspace", rule.workspaceRoot ?? "—")
                    detailRow("permissions.rule.executable", rule.executablePath ?? "—")
                    detailRow("permissions.rule.arguments", rule.arguments?.joined(separator: " ") ?? "—")
                    if let script = rule.scriptPath {
                        detailRow("permissions.rule.script", script)
                    }
                    detailRow("permissions.rule.workingDirectory", rule.workingDirectory ?? "—")
                    detailRow("permissions.rule.origin", rule.origin)
                    detailRow(
                        "permissions.rule.created",
                        rule.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    detailRow(
                        "permissions.rule.expires",
                        rule.expiresAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
                    )
                    detailRow(
                        "permissions.rule.policyVersion",
                        rule.policyVersion.map(String.init) ?? "—"
                    )
                    if rule.requiresReauthorization {
                        Label(L.string("permissions.rules.status.reauthorize"), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(L.string("permissions.rules.revoke"), role: .destructive) {
                    showingRevokeConfirm = true
                }
                Spacer()
                Button(L.string("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 380)
        .confirmationDialog(
            L.string("permissions.rule.revokeConfirmTitle"),
            isPresented: $showingRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button(L.string("permissions.rules.revoke"), role: .destructive) {
                Task {
                    await onRevoke()
                    dismiss()
                }
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.string("permissions.rule.revokeConfirmMessage"))
        }
    }

    private var statusText: String {
        if rule.isExpired { return L.string("permissions.rules.status.expired") }
        if rule.requiresReauthorization { return L.string("permissions.rules.status.reauthorize") }
        return L.string("permissions.rules.status.valid")
    }

    private var statusColor: Color {
        rule.requiresReauthorization ? .orange : .green
    }

    private func detailRow(_ titleKey: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L.string(titleKey))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
