import Foundation

// MARK: - 分栏栏宽记忆（布局回调专用）

/// 分栏栏宽/侧栏宽度的读取与持久化：**只写持久化层，绝不进 SwiftUI 观察链**。
///
/// `HSplitView` / `NavigationSplitView` 的列在拖拽分隔条或窗口改尺寸时，会在 AppKit 的
/// 布局 / 更新约束途中回调 `onGeometryChange`。此时写入任何观察态（`@State`、`@AppStorage`、
/// `@Observable`）都会让 SwiftUI 在同一趟更新里再次请求更新约束，AppKit 直接抛
/// `NSInternalInconsistencyException`（`-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`）
/// 并 `abort()`；崩溃栈特征为
/// `_postWindowNeedsUpdateConstraints ← setNeedsUpdateConstraints: ← NSHostingView.setNeedsUpdate
/// ← SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:) ← NSHostingView.SizeConstraints.update(from:)`。
///
/// 因此栏宽一律走「构造时快照 + 拖动结束落 `UserDefaults`」：
/// 快照喂初始显示宽度，持久层供下次启动读取，中间没有任何观察者参与。
/// **唯一的写入点是用户结束拖动分隔条**（见 `SplitDivider`）；窗口缩放、页面切换、
/// 可用宽度不足时的自动挤压都不写偏好，避免把「被压缩后的显示宽度」错记为偏好。
/// 需要由布局实测值驱动的**可见**状态（按钮出现、缩放比）不能用这里的写法，
/// 应改为延后一拍的主线程任务，见 `ChatView` 的回到底部按钮。
enum SplitColumnWidth {
    /// 读取已记录的栏宽；缺失、非有限值或越界时回退默认值。
    static func snapshot(key: String, defaultValue: Double, range: ClosedRange<Double>) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        guard value.isFinite, range.contains(value) else { return defaultValue }
        return value
    }

    /// 松手时保留最终栏宽的小数部分，重新打开页面时恢复同一位置。
    static func persist(_ width: Double, key: String, range: ClosedRange<Double>) {
        guard width.isFinite else { return }
        let clamped = min(max(width, range.lowerBound), range.upperBound)
        let stored = UserDefaults.standard.object(forKey: key) as? Double
        guard stored != clamped else { return }
        UserDefaults.standard.set(clamped, forKey: key)
    }
}
