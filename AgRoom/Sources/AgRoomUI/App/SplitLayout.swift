import SwiftUI
import AppKit

// MARK: - 可拖动分隔条

/// 分栏分隔条：拖动期间只改相邻栏的显示宽度，拖动结束才写一次偏好。
///
/// 与 `HSplitView` 自带分隔条的关键区别在于**写入时机**：拖动结束是一次明确的用户意图，
/// 而窗口缩放、页面切换、可用宽度不足时的自动挤压都会触发布局回调。
/// 若在布局回调里写偏好，保存下来的往往是「被挤压后的显示宽度」而不是用户拖出的宽度。
/// 因此这里改成：拖动中是普通事件（改 `@State` 显示宽度，安全），
/// 只有 `.onEnded` 才调用 `SplitColumnWidth.persist` 落盘（依据与崩溃栈见该类型注释）。
struct SplitDivider: View {
    /// 相邻栏的显示宽度（页面 `@State`）
    @Binding var columnWidth: Double
    /// 该栏允许的宽度范围
    let range: ClosedRange<Double>
    /// 偏好持久化键
    let persistKey: String
    /// 拖动方向：+1 = 该栏在分隔条左侧（右拖变宽）；-1 = 该栏在分隔条右侧（右拖变窄）
    let direction: Double
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var dragStartWidth: Double?
    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: SplitWidths.dividerWidth)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                // 分隔条会跟随列宽移动，位移必须始终在窗口坐标中计算。
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($isDragging) { _, active, _ in active = true }
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = columnWidth
                            onEditingChanged?(true)
                        }
                        let proposed = width(for: value)
                        if columnWidth != proposed { columnWidth = proposed }
                    }
                    .onEnded { value in
                        let finalWidth = width(for: value)
                        columnWidth = finalWidth
                        finishDrag()
                        SplitColumnWidth.persist(finalWidth, key: persistKey, range: range)
                    }
            )
            .onChange(of: isDragging) {
                // 取消手势不会调用 onEnded，下次拖动须重新取起点。
                if !isDragging { finishDrag() }
            }
            .onDisappear { finishDrag() }
            .accessibilityHidden(true)
    }

    private func finishDrag() {
        guard dragStartWidth != nil else { return }
        dragStartWidth = nil
        onEditingChanged?(false)
    }

    private func width(for value: DragGesture.Value) -> Double {
        let layoutSign = layoutDirection == .rightToLeft ? -1.0 : 1.0
        let proposed = (dragStartWidth ?? columnWidth) + Double(value.translation.width) * direction * layoutSign
        return min(max(proposed, range.lowerBound), range.upperBound)
    }
}

// MARK: - 可用宽度分配

/// 分栏可见宽度分配：把容器的实际可用宽度分给定宽栏与弹性栏。
///
/// 分配原则与「空间不够时优先压缩、绝不写回偏好」对应：
/// 1. 先满足各定宽栏的偏好宽度（各自夹在范围内）；
/// 2. 剩余空间给弹性栏；足够则直接用，空间充裕时弹性栏吃掉多余部分；
/// 3. 空间不足时按各定宽栏的「多余量」比例压缩其**本次显示宽度**，
///    尽量保住弹性栏的最低宽度；被压缩的结果只用于本次布局，不改变调用方持有的偏好值。
enum SplitWidths {
    /// 分隔条占用的布局宽度（1pt 线居中，其余为命中区域）
    static let dividerWidth: CGFloat = 6

    struct Column {
        /// 偏好/期望显示宽度（弹性栏忽略）
        var width: Double
        /// 允许宽度范围（弹性栏只用 `lowerBound` 作为最低宽度）
        var range: ClosedRange<Double>
        /// 是否为弹性栏（取剩余空间）
        var flexible: Bool = false
    }

    /// 返回每栏的本次显示宽度（与 `columns` 一一对应）。
    static func resolve(available: Double, dividers: Int, columns: [Column]) -> [Double] {
        let chrome = Double(dividers) * Double(dividerWidth)
        let usable = max(0, available - chrome)
        var widths = columns.map { column in
            column.flexible
                ? column.range.lowerBound
                : min(max(column.width, column.range.lowerBound), column.range.upperBound)
        }
        guard let flexIndex = columns.firstIndex(where: { $0.flexible }) else { return widths }

        let sizedIndices = columns.indices.filter { !columns[$0].flexible }
        let sizedTotal = sizedIndices.reduce(0.0) { $0 + widths[$1] }
        let slack = usable - sizedTotal
        let flexMin = columns[flexIndex].range.lowerBound

        if slack >= flexMin {
            widths[flexIndex] = slack
            return widths
        }

        // 空间不足：按多余量比例压缩定宽栏，优先保住弹性栏最低宽度
        let spare = sizedIndices.map { widths[$0] - columns[$0].range.lowerBound }
        let totalSpare = spare.reduce(0, +)
        var need = flexMin - slack
        if totalSpare > 0 {
            let take = min(need, totalSpare)
            for (offset, index) in sizedIndices.enumerated() {
                widths[index] -= take * (spare[offset] / totalSpare)
            }
            need -= take
        }
        widths[flexIndex] = max(0, usable - sizedIndices.reduce(0.0) { $0 + widths[$1] })
        return widths
    }
}
