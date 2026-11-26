import SwiftUI
import AgRoomCore

struct ArtifactDiffView: View {
    let comparison: TaskArtifactComparison
    var height: CGFloat? = 300
    var onExpand: (() -> Void)? = nil
    @State private var sideBySide = false
    @State private var selectedHunk = 0

    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            HStack {
                Text(L.string(comparison.interleaved ? "product.artifact.diff.step" : "product.artifact.diff.range"))
                    .font(MeetTypography.secondary).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if comparison.state == .available {
                    Picker(L.string("product.artifact.diff.layout"), selection: $sideBySide) {
                        Text(L.string("product.artifact.diff.unified")).tag(false)
                        Text(L.string("product.artifact.diff.split")).tag(true)
                    }.pickerStyle(.segmented).frame(width: 190, height: 26)
                }
                if let onExpand {
                    Button(action: onExpand) {
                        Label(L.string("product.artifact.diff.expand"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                        .help(L.string("product.artifact.diff.expand"))
                        .accessibilityLabel(L.string("product.artifact.diff.expand"))
                }
            }.fixedSize(horizontal: false, vertical: true)
            if comparison.interleaved {
                Text(L.string("product.artifact.diff.interleaved")).font(MeetTypography.secondary).foregroundStyle(.orange)
            }
            if comparison.state == .available {
                diffContent
            } else {
                Text(L.string(Self.stateKey(comparison.state)))
                    .font(MeetTypography.secondary).foregroundStyle(.secondary).padding(.vertical, MeetSpacing.sm)
            }
            if comparison.truncated {
                Text(L.string("product.artifact.diff.truncated")).font(MeetTypography.secondary).foregroundStyle(.secondary)
            }
        }
    }

    private var diffContent: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if sideBySide {
                    HStack(spacing: 0) {
                        Text(L.string("product.artifact.diff.before")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L.string("product.artifact.diff.after")).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(MeetTypography.secondary).foregroundStyle(.secondary).padding(8)
                }
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(comparison.hunks) { hunk in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(L.format("product.artifact.diff.hunk", hunk.oldStart, hunk.newStart))
                                    .font(MeetTypography.secondary).foregroundStyle(.secondary)
                                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.04))
                                if sideBySide {
                                    ForEach(Array(Self.alignedLines(hunk.lines).enumerated()), id: \.offset) { _, pair in
                                        HStack(alignment: .top, spacing: 0) {
                                            sourceLine(pair.0, side: false).frame(maxWidth: .infinity, alignment: .leading)
                                            sourceLine(pair.1, side: true).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .background {
                                            HStack(spacing: 0) {
                                                background(pair.0).frame(maxWidth: .infinity)
                                                background(pair.1).frame(maxWidth: .infinity)
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                        sourceLine(line, side: nil).frame(maxWidth: .infinity, alignment: .leading).background(background(line))
                                    }
                                }
                            }.id(hunk.id)
                        }
                    }
                }
                if comparison.hunks.count > 1 {
                    HStack {
                        Text(L.format("product.artifact.diff.position", selectedHunk + 1, comparison.hunks.count))
                            .font(MeetTypography.secondary).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            selectedHunk = max(0, selectedHunk - 1)
                            proxy.scrollTo(selectedHunk, anchor: .top)
                        } label: { Image(systemName: "chevron.up") }
                            .disabled(selectedHunk == 0).help(L.string("product.artifact.diff.previous"))
                            .accessibilityLabel(L.string("product.artifact.diff.previous"))
                        Button {
                            selectedHunk = min(comparison.hunks.count - 1, selectedHunk + 1)
                            proxy.scrollTo(selectedHunk, anchor: .top)
                        } label: { Image(systemName: "chevron.down") }
                            .disabled(selectedHunk >= comparison.hunks.count - 1).help(L.string("product.artifact.diff.next"))
                            .accessibilityLabel(L.string("product.artifact.diff.next"))
                    }.controlSize(.small).padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }.frame(height: inlineHeight, alignment: .topLeading)
    }

    private var inlineHeight: CGFloat? {
        guard let height else { return nil }
        let rows = comparison.hunks.reduce(0) { total, hunk in
            total + (sideBySide ? Self.alignedLines(hunk.lines).count : hunk.lines.count)
        }
        let content = CGFloat(rows * 20 + comparison.hunks.count * 32)
        let controls = CGFloat((sideBySide ? 28 : 0) + (comparison.hunks.count > 1 ? 36 : 0))
        return min(height, max(80, content + controls))
    }

    private func sourceLine(_ line: FileDiffLine?, side: Bool?) -> some View {
        HStack(alignment: .top, spacing: 4) {
            if side != true { lineNumber(line?.oldLine) }
            if side != false { lineNumber(line?.newLine) }
            Text(line?.kind == .addition ? "+" : line?.kind == .removal ? "−" : " ")
                .foregroundStyle(line?.kind == .addition ? Color.green : line?.kind == .removal ? Color.red : Color.secondary)
                .frame(width: 10)
            Text(line.map { $0.text.isEmpty ? " " : $0.text } ?? " ")
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if line?.lacksFinalNewline == true {
                Text(L.string("product.artifact.diff.no_final_newline")).font(.caption2).foregroundStyle(.secondary)
            }
        }.font(.system(size: 11, design: .monospaced)).padding(.horizontal, 4).padding(.vertical, 2)
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
    }

    private func background(_ line: FileDiffLine?) -> Color {
        switch line?.kind {
        case .addition: Color.green.opacity(0.10)
        case .removal: Color.red.opacity(0.10)
        case .context: Color.clear
        case nil: Color.primary.opacity(0.03)
        }
    }

    static func stateKey(_ state: TaskArtifactComparison.State) -> String {
        switch state {
        case .available: "product.artifact.diff.available"
        case .unchanged: "product.artifact.diff.unchanged"
        case .baselineMissing: "product.artifact.diff.baseline_missing"
        case .contentUnavailable: "product.artifact.diff.content_unavailable"
        case .binary: "product.artifact.diff.binary"
        case .tooLarge: "product.artifact.diff.too_large"
        }
    }

    static func alignedLines(_ lines: [FileDiffLine]) -> [(FileDiffLine?, FileDiffLine?)] {
        var result: [(FileDiffLine?, FileDiffLine?)] = [], old: [FileDiffLine] = [], new: [FileDiffLine] = []
        func flush() {
            for i in 0..<max(old.count, new.count) { result.append((i < old.count ? old[i] : nil, i < new.count ? new[i] : nil)) }
            old.removeAll(keepingCapacity: true); new.removeAll(keepingCapacity: true)
        }
        for line in lines {
            switch line.kind {
            case .removal: old.append(line)
            case .addition: new.append(line)
            case .context: flush(); result.append((line, line))
            }
        }
        flush()
        return result
    }
}

struct ArtifactDiffSheet: View {
    let artifact: TaskArtifact
    let comparison: TaskArtifactComparison
    let onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            HStack {
                Text(artifact.name).font(.headline)
                Spacer()
                Button(L.string("common.close")) { onClose(); dismiss() }.keyboardShortcut(.cancelAction)
            }.fixedSize(horizontal: false, vertical: true)
            Text(artifact.path).font(MeetTypography.secondary).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            ArtifactDiffView(comparison: comparison, height: nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(20).frame(minWidth: 760, idealWidth: 1000, minHeight: 560, idealHeight: 700)
    }
}
