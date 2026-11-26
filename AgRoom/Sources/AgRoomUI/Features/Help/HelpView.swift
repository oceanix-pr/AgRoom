import SwiftUI
import AgRoomCore

// MARK: - Help View

/// 帮助页：快速开始、功能导览、快捷键、隐私与数据、常见问题。
///
/// 内容只描述已实现的能力（依据各功能页与 Core 的既有实现撰写），
/// 文案全部走三语本地化；模型提示词不参与本地化。
public struct HelpView: View {
    public init(hub: Hub) {}

    public var body: some View {
        HelpContentView { AppNavigation.shared.open(page: $0) }
    }
}

enum HelpCategory: String, CaseIterable {
    case quickstart, tour, shortcuts, privacy, faq

    var titleKey: String { "help." + rawValue }

    var symbol: String {
        switch self {
        case .quickstart: "sparkles"
        case .tour: "map"
        case .shortcuts: "keyboard"
        case .privacy: "lock.shield"
        case .faq: "questionmark.bubble"
        }
    }
}

/// Only the selected category mounts its form, following the settings layout.
/// Content is independent of space services; navigation uses the existing app route.
struct HelpContentView: View {
    @State private var category: HelpCategory
    let onOpen: (HubNavItem) -> Void

    init(initialCategory: HelpCategory = .quickstart, onOpen: @escaping (HubNavItem) -> Void) {
        _category = State(initialValue: initialCategory)
        self.onOpen = onOpen
    }

    // MARK: - 内容模型

    /// 快速开始步骤
    private struct Step {
        let titleKey: String
        let descKey: String
        /// 文案中需要注入调度 Agent 显示名（用户昵称优先）
        let usesDispatcher: Bool
    }

    /// 快捷键条目（按键符号本身不随语言变化）
    private struct Shortcut {
        let keys: String
        let descKey: String
    }

    /// 常见问题条目
    private struct FAQ {
        let titleKey: String
        let descKey: String
    }

    private static let steps: [Step] = [
        Step(titleKey: "help.quickstart.1.title", descKey: "help.quickstart.1.desc", usesDispatcher: false),
        Step(titleKey: "help.quickstart.2.title", descKey: "help.quickstart.2.desc", usesDispatcher: false),
        Step(titleKey: "help.quickstart.3.title", descKey: "help.quickstart.3.desc", usesDispatcher: true),
        Step(titleKey: "help.quickstart.4.title", descKey: "help.quickstart.4.desc", usesDispatcher: false)
    ]

    private static let shortcuts: [Shortcut] = [
        Shortcut(keys: "⌘,", descKey: "help.shortcut.settings"),
        Shortcut(keys: "⌥⌘S", descKey: "help.shortcut.sidebar"),
        Shortcut(keys: "⌘N", descKey: "help.shortcut.newchat"),
        Shortcut(keys: "⌘K", descKey: "help.shortcut.search"),
        Shortcut(keys: "⇧⌘J", descKey: "help.shortcut.tasks"),
        Shortcut(keys: "⇧⌘O", descKey: "help.shortcut.artifacts"),
        Shortcut(keys: "⌘F", descKey: "help.shortcut.find"),
        Shortcut(keys: "⇧⌘E", descKey: "help.shortcut.export"),
        Shortcut(keys: "⌘.", descKey: "help.shortcut.stop"),
        Shortcut(keys: "⌥⌘Space", descKey: "help.shortcut.hotkey"),
        Shortcut(keys: "⌘S", descKey: "help.shortcut.save"),
        Shortcut(keys: "⌘C / ⌘V / ⌘D / ⌫", descKey: "help.shortcut.files")
    ]

    private static let privacyItems: [(icon: String, key: String)] = [
        ("internaldrive", "help.privacy.local"),
        ("square.on.square.dashed", "help.privacy.spaces"),
        ("key", "help.privacy.keychain"),
        ("lock.shield", "help.privacy.endpoint")
    ]

    private static let faqs: [FAQ] = [
        FAQ(titleKey: "help.faq.model.title", descKey: "help.faq.model.desc"),
        FAQ(titleKey: "help.faq.files.title", descKey: "help.faq.files.desc"),
        FAQ(titleKey: "help.faq.skills.title", descKey: "help.faq.skills.desc"),
        FAQ(titleKey: "help.faq.data.title", descKey: "help.faq.data.desc")
    ]

    var body: some View {
        HStack(spacing: 0) {
            categoryList
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L.string(category.titleKey)).font(MeetTypography.pageTitle)
                    Spacer()
                    Button(L.string("help.open_settings")) { onOpen(.settings) }
                        .controlSize(.small)
                }
                .padding(20)
                Divider()
                selectedContent
                    .id(category)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(MeetTypography.control)
    }

    private var categoryList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(HelpCategory.allCases, id: \.self) { item in
                    Button { category = item } label: {
                        Label(L.string(item.titleKey), systemImage: item.symbol)
                            .font(.body)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .background(category == item ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(category == item ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(L.string(item.titleKey))
                    .accessibilityAddTraits(category == item ? [.isSelected] : [])
                }
            }
            .padding(12)
        }
        .frame(width: LanguageManager.shared.activeLanguageCode == "en" ? 230 : 180)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel(L.string("help.categories"))
    }

    private var selectedContent: some View {
        Form {
            switch category {
            case .quickstart:
                Section {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        stepRow(step, number: index + 1)
                    }
                }
            case .tour:
                ForEach(HubNavSection.allCases, id: \.self) { group in
                    Section(L.string(group.labelKey)) {
                        ForEach(group.items.filter { $0.isVisibleInSidebar && $0 != .help }) { item in
                            Button { onOpen(item) } label: { tourRow(item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            case .shortcuts:
                Section {
                    ForEach(Self.shortcuts, id: \.descKey) { shortcut in
                        shortcutRow(shortcut)
                    }
                }
            case .privacy:
                Section {
                    ForEach(Self.privacyItems, id: \.key) { item in
                        Label(L.string(item.key), systemImage: item.icon)
                            .font(.callout)
                    }
                }
            case .faq:
                Section {
                    ForEach(Self.faqs, id: \.titleKey) { faq in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L.string(faq.titleKey))
                                .font(.callout.weight(.medium))
                            Text(L.string(faq.descKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 行视图

    private func stepRow(_ step: Step, number: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.usesDispatcher
                     ? L.format(step.titleKey, L.dispatcherName())
                     : L.string(step.titleKey))
                    .font(.callout.weight(.medium))
                Text(step.usesDispatcher
                     ? L.format(step.descKey, L.dispatcherName())
                     : L.string(step.descKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func tourRow(_ item: HubNavItem) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(item.iconTint.gradient)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: item.iconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(L.string(item.labelKey))
                    .font(.callout.weight(.medium))
                Text(L.string("help.tour.\(item.rawValue)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func shortcutRow(_ shortcut: Shortcut) -> some View {
        HStack(spacing: 10) {
            Text(shortcut.keys)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
            Text(L.string(shortcut.descKey))
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

}
