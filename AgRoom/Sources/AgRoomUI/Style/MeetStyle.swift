import SwiftUI
import AppKit
import Observation

// MARK: - Shared Typography and Layout

/// 全局外观偏好只保存字号，不持有空间内容。值对象同时供 SwiftUI 与 TextKit 使用。
struct ReadingTypography: Hashable, Sendable {
    static let preferenceKey = "agroom.reading.pointSize"
    static let defaultSize = 15
    static let sizeRange = 14...30
    static let availableSizes = Array(sizeRange)
    static let presetSizes = [14, 15, 17, 20, 24, 30]

    let pointSize: Int

    init(pointSize: Int = Self.defaultSize) {
        self.pointSize = Self.availableSizes.contains(pointSize) ? pointSize : Self.defaultSize
    }

    var bodySize: CGFloat { CGFloat(pointSize) }
    var codeSize: CGFloat { max(12, bodySize - 2) }

    func headingSize(level: Int) -> CGFloat {
        bodySize + [8, 5, 2, 0, 0, 0][min(5, max(0, level - 1))]
    }
}

/// Appearance only: this singleton never owns a space service or user content.
@MainActor @Observable
final class InterfaceTypographyPreferences {
    static let shared = InterfaceTypographyPreferences()
    private static let key = "agroom.interface.largeText"
    var isLarge: Bool {
        didSet { UserDefaults.standard.set(isLarge, forKey: Self.key) }
    }
    var scale: CGFloat { isLarge ? 1.2 : 1 }
    private init() { isLarge = UserDefaults.standard.bool(forKey: Self.key) }
}

@MainActor
enum MeetTypography {
    private static func size(_ base: CGFloat) -> CGFloat { base * InterfaceTypographyPreferences.shared.scale }
    static var pageTitle: Font { .system(size: size(20), weight: .semibold) }
    static var sectionTitle: Font { .system(size: size(15), weight: .semibold) }
    static var listTitle: Font { listTitle(weight: .medium) }
    static func listTitle(weight: Font.Weight) -> Font { .system(size: size(14), weight: weight) }
    static var navigation: Font { .system(size: size(15)) }
    static var secondary: Font { .system(size: size(12)) }
    static var caption: Font { .system(size: size(11)) }
    static var control: Font { .system(size: size(13)) }
}

struct ReadingTextSizeEditor: View {
    @AppStorage(ReadingTypography.preferenceKey) private var pointSize = ReadingTypography.defaultSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $pointSize, in: ReadingTypography.sizeRange) {
                Text(L.format("settings.reading.size.value", pointSize)).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(pointSize) }, set: { pointSize = Int($0.rounded()) }),
                   in: Double(ReadingTypography.sizeRange.lowerBound)...Double(ReadingTypography.sizeRange.upperBound), step: 1)
                .accessibilityLabel(L.string("settings.reading.size"))
            HStack {
                ForEach(ReadingTypography.presetSizes, id: \.self) { size in
                    Button { pointSize = size } label: {
                        Text("\(size)").monospacedDigit().frame(maxWidth: .infinity)
                    }
                    .tint(pointSize == size ? .accentColor : .secondary)
                    .accessibilityLabel(L.format("settings.reading.size.value", size))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L.string("settings.reading.preview.title"))
                    .font(.system(size: ReadingTypography(pointSize: pointSize).headingSize(level: 3), weight: .semibold))
                Text(L.string("settings.reading.preview.body"))
                    .font(.system(size: ReadingTypography(pointSize: pointSize).bodySize))
                Text(L.string("settings.reading.preview.code"))
                    .font(.system(size: ReadingTypography(pointSize: pointSize).codeSize, design: .monospaced))
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Button(L.string("settings.reading.reset")) { pointSize = ReadingTypography.defaultSize }
                .disabled(pointSize == ReadingTypography.defaultSize)
        }
    }
}

private struct ReadingBodyFont: ViewModifier {
    @AppStorage(ReadingTypography.preferenceKey) private var pointSize = ReadingTypography.defaultSize
    var monospaced: Bool
    func body(content: Content) -> some View {
        content.font(.system(size: ReadingTypography(pointSize: pointSize).bodySize,
                             design: monospaced ? .monospaced : .default))
    }
}

extension View {
    func readingBodyFont(monospaced: Bool = false) -> some View {
        modifier(ReadingBodyFont(monospaced: monospaced))
    }
}

struct ReadingTextSizeControl: View {
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "textformat.size") }
            .help(L.string("settings.reading.size"))
            .accessibilityLabel(L.string("settings.reading.size"))
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L.string("settings.reading.size")).font(.headline)
                    ReadingTextSizeEditor()
                }.padding(20).frame(width: 340)
            }
    }
}

/// Option avoids taking over WebKit/image preview's own Command +/- shortcuts.
public struct ReadingTextCommands: Commands {
    @AppStorage(ReadingTypography.preferenceKey) private var pointSize = ReadingTypography.defaultSize
    public init() {}
    public var body: some Commands {
        CommandMenu(L.string("reading.menu")) {
            Button(L.string("reading.increase")) { pointSize = min(ReadingTypography.sizeRange.upperBound, pointSize + 1) }
                .keyboardShortcut("+", modifiers: [.command, .option])
                .disabled(pointSize >= ReadingTypography.sizeRange.upperBound)
            Button(L.string("reading.decrease")) { pointSize = max(ReadingTypography.sizeRange.lowerBound, pointSize - 1) }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(pointSize <= ReadingTypography.sizeRange.lowerBound)
            Button(L.string("settings.reading.reset")) { pointSize = ReadingTypography.defaultSize }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}

enum MeetSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum MeetRadius {
    static let card: CGFloat = 8
    static let message: CGFloat = 12
}

enum MeetLayout {
    static let minimumChatWidth: Double = 320
    static let rowActionSize: CGFloat = 26
    static let artifactListMaxWidth: CGFloat = 840
}

// MARK: - Shared Components

extension Color {
    /// 选中行底色较深时切换白色，保证可读性（MeetMemo adaptedForSelection）
    func adaptedForSelection(_ isSelected: Bool) -> Color {
        isSelected ? .white : self
    }
}

/// 胶囊状态徽章（MeetMemo 风格）
struct StatusBadge: View {
    let text: String
    let color: Color
    var icon: String? = nil
    var isSelected: Bool = false
    var verticalPadding: CGFloat = 2

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
        }
        .font(MeetTypography.secondary)
        .foregroundStyle(color.adaptedForSelection(isSelected))
        .padding(.horizontal, 6)
        .padding(.vertical, verticalPadding)
        .background(color.opacity(isSelected ? 0.4 : 0.12))
        .clipShape(Capsule())
    }
}

/// 卡片使用语义背景与细描边，随系统外观切换。
struct MeetCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: MeetRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: MeetRadius.card)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }
}

extension View {
    func meetCard() -> some View {
        modifier(MeetCardModifier())
    }
}

// MARK: - Column Header（列标题栏统一高度）

/// 三栏布局各列标题栏的统一高度：
/// 对话列表头 / 单个对话标题栏 / 技能列表头 / 技能编辑器头部共用，保证横向对齐
enum ColumnHeaderMetrics {
    static let height: CGFloat = 44
}

extension View {
    /// 固定列标题栏高度（内容垂直居中）：应用于各列头部 HStack，确保不同页面/列的标题栏高度一致
    func columnHeader() -> some View {
        frame(height: ColumnHeaderMetrics.height, alignment: .center)
    }
}

/// MeetMemo 语义状态色
enum MeetStatusColor {
    /// 处理中/信息类
    static let processing = Color.blue
    /// 完成/启用
    static let positive = Color.green
    /// 失败/危险
    static let negative = Color.red
    /// 资源类（图片/文档/API）
    static let resource = Color.orange
    /// 文本类（笔记/Wiki/Prompt）
    static let textual = Color.purple
}

// MARK: - Hover Highlight Button Style

/// 悬停高亮按钮样式：图标+文字按钮（消息操作栏等）的整块热区在悬停时
/// 显示浅色圆角底 + 强调色前景，点击有按压反馈（默认 plain 样式无任何效果）
struct HoverHighlightButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
            )
            .foregroundColor(hovering ? .accentColor : .secondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}
