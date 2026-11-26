import SwiftUI
import AgRoomCore

struct MailCoverageBar: View {
    let folderName: String
    let coverage: MailSyncCoverage?
    let isSyncing: Bool
    let onEarlier: () -> Void
    let onRebuild: () -> Void
    @State private var showingDetails = false
    @State private var confirmingRebuild = false

    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing: 6) {
                if isSyncing {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: coverage?.isComplete == true ? "checkmark.circle" : "info.circle")
                }
                Text(L.string("product.mail.coverage.title")).lineLimit(1)
                Spacer(minLength: 4)
                if let coverage, coverage.checkedAt != nil, let remoteCount = coverage.remoteCount {
                    Text("\(coverage.cachedCount) / \(remoteCount)")
                        .font(.caption2).monospacedDigit().lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(coverageDescription)
        .accessibilityLabel(L.string("product.mail.coverage.title"))
        .accessibilityValue(coverageDescription)
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) { details }
    }

    private var coverageDescription: String {
        guard let coverage, coverage.checkedAt != nil else { return L.string("product.mail.coverage.unknown") }
        return L.format(coverage.isComplete ? "product.mail.coverage.complete" : "product.mail.coverage.partial",
            coverage.cachedCount, coverage.remoteCount ?? 0)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.string("product.mail.coverage.title")).font(.headline)
                Text(folderName).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(coverageDescription).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let oldest = coverage?.oldestDate, let newest = coverage?.newestDate {
                Text(AppDate.dateString(from: oldest) + " – " + AppDate.dateString(from: newest))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L.string("product.mail.coverage.help"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if coverage?.isComplete != true {
                Button(L.string("product.mail.history")) {
                    showingDetails = false
                    onEarlier()
                }.disabled(isSyncing || coverage == nil)
            }
            Button(L.string("product.mail.rebuild")) { confirmingRebuild = true }.disabled(isSyncing || coverage == nil)
        }
        .controlSize(.small).padding(16).frame(width: 340, alignment: .leading)
        .confirmationDialog(L.string("product.mail.rebuild"), isPresented: $confirmingRebuild, titleVisibility: .visible) {
            Button(L.string("product.mail.rebuild"), role: .destructive) {
                showingDetails = false
                onRebuild()
            }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: { Text(L.string("product.mail.rebuild.help")) }
    }
}
