import SwiftUI
import AgRoomCore

// MARK: - Mail Message List

/// 邮件列表栏：按接收时间倒序的邮件行。
/// 未读行加粗并在左侧显示圆点；星标可点击切换（本地立即生效并尽力回写远端）。
struct MailMessageListView: View {
    let messages: [MailMessage]
    let selectedMessageIDs: Set<UUID>
    /// 是否还有下一页；为真时列表底部显示「加载更多」入口。
    let hasMore: Bool
    /// 是否正在续载（显示进度并及时禁用入口，避免重复触发）。
    let isLoadingMore: Bool
    /// 选中项转发到视图模型的异步选中方法。
    let onSelect: (Set<UUID>) -> Void
    let onToggleStar: (MailMessage) -> Void
    let onLoadMore: () -> Void
    var contextMenu: (Set<UUID>) -> AnyView = { _ in AnyView(EmptyView()) }
    var onDelete: (Set<UUID>) -> Void = { _ in }
    var isFiltered = false
    var sourceLabels: [UUID: String] = [:]
    var presentation = MailListPresentation()
    var query = ""
    var senderQuery = ""
    var onReopen: (MailMessage) -> Void = { _ in }

    var body: some View {
        Group {
            if messages.isEmpty {
                ContentUnavailableView(
                    L.string(isFiltered ? "mail.search.empty" : "mail.empty"),
                    systemImage: "tray",
                    description: Text(L.string(isFiltered ? "mail.search.scope" : "mail.empty.desc"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(messages) { message in
                        row(message)
                            .tag(message.id)
                    }
                    if hasMore || isLoadingMore {
                        loadMoreRow
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in contextMenu(ids) }
                .onDeleteCommand { if !selectedMessageIDs.isEmpty { onDelete(selectedMessageIDs) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 底部「加载更多」入口：默认读一页（见 `MailViewModel.messagePageSize`），
    /// 大文件夹需要时可继续取下一页，而不是只能看前 200 封。
    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if isLoadingMore {
                ProgressView().controlSize(.small)
            } else {
                Button(L.string("mail.list.load_more")) { onLoadMore() }
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }

    private var selection: Binding<Set<UUID>> {
        Binding(get: { selectedMessageIDs }, set: { onSelect($0) })
    }

    // MARK: - Row

    private func row(_ message: MailMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // 未读圆点（已读时保留占位，避免文字左右跳动）
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .opacity(message.isRead ? 0 : 1)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                if let source = sourceLabels[message.id] {
                    Text(source).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(source)
                }
                HStack(spacing: 6) {
                    Text(highlight(message.displayFrom, terms: [query, senderQuery]))
                        .font(MeetTypography.listTitle(weight: message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(dateText(message.date))
                        .font(MeetTypography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(highlight(subjectText(message), terms: [query]))
                        .font(MeetTypography.listTitle(weight: message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(MeetTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if presentation.snippetLines > 0 {
                  Text(highlight(message.snippet, terms: [query]))
                    .font(MeetTypography.secondary)
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .lineLimit(presentation.snippetLines)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if !message.isRead, selectedMessageIDs == [message.id],
                   NSEvent.modifierFlags.intersection([.command, .shift, .control]).isEmpty { onReopen(message) }
            })

            Button {
                onToggleStar(message)
            } label: {
                Image(systemName: message.isStarred ? "star.fill" : "star")
                    .font(MeetTypography.control)
                    .frame(width: MeetLayout.rowActionSize, height: MeetLayout.rowActionSize)
                    .foregroundStyle(message.isStarred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L.string("mail.action.star"))
        }
        .padding(.vertical, presentation.density == .compact ? 2 : MeetSpacing.sm)
        .contentShape(Rectangle())
    }

    private func highlight(_ value: String, terms: [String]) -> AttributedString {
        let text = String(value.prefix(4096))
        var result = AttributedString(text)
        for term in terms where !term.isEmpty {
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive, .widthInsensitive], range: start..<text.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: result), let upper = AttributedString.Index(range.upperBound, within: result) {
                    result[lower..<upper].backgroundColor = Color.yellow.opacity(0.40)
                    result[lower..<upper].foregroundColor = Color.primary
                }
                start = range.upperBound
            }
        }
        return result
    }

    private func subjectText(_ message: MailMessage) -> String {
        message.subject.isEmpty ? L.string("mail.noSubject") : message.subject
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        return AppDate.dateString(from: date)
    }
}
