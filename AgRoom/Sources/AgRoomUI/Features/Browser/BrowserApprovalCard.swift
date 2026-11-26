import SwiftUI
import AgRoomCore

/// Shows observed business facts; duration options come exclusively from the engine.
struct BrowserApprovalCard: View {
    let pending: PendingConfirmation
    let presentation: ToolApprovalPresentation
    let onDecision: (ConfirmationDecision) -> Void

    @State private var allowTask: Bool
    @State private var detailsHeight: CGFloat = 100

    init(pending: PendingConfirmation, presentation: ToolApprovalPresentation,
         onDecision: @escaping (ConfirmationDecision) -> Void) {
        self.pending = pending
        self.presentation = presentation
        self.onDecision = onDecision
        _allowTask = State(initialValue: ["browser_navigation", "browser_query", "browser_control"].contains(presentation.reasonCode)
            && pending.requirement?.availableApprovalDurations.contains(.round) == true)
    }

    private var requirement: ConfirmationRequirement {
        pending.requirement ?? .init(kind: .hard, scope: .tool)
    }

    private var supportsTaskScope: Bool {
        ["browser_navigation", "browser_query", "browser_control"].contains(presentation.reasonCode)
            && requirement.availableApprovalDurations.contains(.round)
    }

    private var details: String {
        guard let action = presentation.browserAction else { return presentation.executionDetails.joined(separator: "\n") }
        var lines = [L.format("browser.approval.page", action.pageTitle),
                     L.format("browser.approval.site", action.origin ?? L.string("browser.approval.unknown_site"))]
        if let target = action.targetLabel { lines.append(L.format("browser.approval.target", target)) }
        if let destination = action.destination { lines.append(L.format("browser.approval.destination", destination)) }
        if presentation.reasonCode == "browser_fill" { lines.append(L.format("browser.approval.fill_count", action.fields.count)) }
        lines += action.fields.map { "\($0.label): \($0.value)" }
        if action.formTruncated { lines.append(L.string("browser.approval.form_truncated")) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L.string("browser.approval.title." + presentation.reasonCode), systemImage: "globe.badge.chevron.backward")
                .font(.headline)
            ScrollView {
                Text(details)
                    .readingBodyFont().textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        min(240, geometry.size.height.rounded(.up))
                    } action: { height in
                        detailsHeight = max(36, height)
                    }
            }
            .frame(height: detailsHeight)
            Text(L.string("browser.approval.help." + presentation.reasonCode))
                .font(.caption).foregroundStyle(.secondary)

            if let reason = requirement.autoReviewReason {
                Text(ConfirmationCard.autoReviewReasonText(reason)).font(.caption).foregroundStyle(.secondary)
            }
            if supportsTaskScope {
                Toggle(L.string(presentation.reasonCode == "browser_query" ? "browser.approval.allow_query"
                    : presentation.reasonCode == "browser_control" ? "browser.approval.allow_control"
                    : "browser.approval.allow_navigation"), isOn: $allowTask)
                    .toggleStyle(.checkbox)
                Text(L.string("browser.approval.task_lifetime"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup(L.string("product.confirm.details")) {
                ScrollView {
                    Text(pending.argumentsDisplay)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button(L.string("chat.confirm.reject")) { onDecision(.reject) }
                    .keyboardShortcut(.cancelAction)
                // Consequential/unknown page actions intentionally have no default-return approval.
                Button(L.string(allowTask && supportsTaskScope
                    ? "browser.approval.approve_task" : "chat.confirm.approve_once")) {
                    onDecision(.init(approved: true,
                        allowRound: allowTask && supportsTaskScope, persistRule: false))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4)))
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}
