import SwiftUI
import AgRoomCore

// MARK: - Trace Detail Sheet

/// Sheet item 包装（DispatcherTraceEntry 需要配 index 展示序号）
struct TraceDetailContext: Identifiable {
    let entry: DispatcherTraceEntry
    let index: Int
    var id: String { "\(index)-\(entry.toolName)-\(entry.duration)" }
}

/// 轨迹条目详情：完整参数与结果（等宽可滚动），支持分区复制与整条复制
struct TraceDetailSheet: View {
    let entry: DispatcherTraceEntry
    let index: Int
    /// 智体工具名 → 显示名（昵称优先）：ChatView 注入，未命中回退工具名 slug
    var agentDisplayName: ((String) -> String?)? = nil
    @Environment(\.dismiss) private var dismiss

    private func localizedToolName(_ name: String) -> String {
        ChatView.localizedToolName(name, agentDisplayName: agentDisplayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(
                        title: L.string("chat.trace.detail.arguments"),
                        text: entry.argumentsDisplay,
                        copyText: entry.argumentsDisplay
                    )
                    section(
                        title: L.string("chat.trace.detail.result"),
                        text: entry.resultDisplay,
                        copyText: entry.resultDisplay
                    )
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(entry.succeeded ? .green : .red)
            Text("\(index + 1). \(localizedToolName(entry.toolName))")
                .font(.headline)
            Text(String(format: "%.2fs", entry.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L.string("common.close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 参数/结果分区：标题 + 复制按钮 + 等宽滚动内容
    private func section(title: String, text: String, copyText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { Self.copy(copyText) }) {
                    Label(L.string("common.copy"), systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
    }

    private var footer: some View {
        HStack {
            Button(action: copyWholeRecord) {
                Label(L.string("chat.trace.detail.copy_all"), systemImage: "doc.on.doc.fill")
            }
            Spacer()
            Button(L.string("common.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Copy

    /// 整条记录复制格式（纯文本，可直接粘贴）：
    /// [1] skill_load（加载技能）✓ 0.42s / 参数: … / 结果: …
    private func copyWholeRecord() {
        var lines: [String] = []
        let status = entry.succeeded ? "✓" : "✗"
        lines.append("[\(index + 1)] \(entry.toolName)（\(localizedToolName(entry.toolName))）\(status) \(String(format: "%.2fs", entry.duration))")
        if !entry.argumentsDisplay.isEmpty {
            lines.append("")
            lines.append(L.string("chat.trace.detail.arguments") + ":")
            lines.append(entry.argumentsDisplay)
        }
        if !entry.resultDisplay.isEmpty {
            lines.append("")
            lines.append(L.string("chat.trace.detail.result") + ":")
            lines.append(entry.resultDisplay)
        }
        Self.copy(lines.joined(separator: "\n"))
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
