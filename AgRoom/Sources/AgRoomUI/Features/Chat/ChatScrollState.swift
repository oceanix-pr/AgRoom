import CoreGraphics
import Foundation

// MARK: - 滚动几何快照

/// 聊天滚动容器的单次几何快照，全部来自同一个 `onScrollGeometryChange`。
///
/// 统一在一份数据里取内容高度、视口高度、偏移与底部 inset，
/// 避免分别测量内容底边和视口底边、再用全局坐标跨布局时刻比较。
struct ChatScrollGeometry: Equatable {
    /// 内容总高度（消息 + 附属内容 + 底部锚点 + 外边距）
    var contentHeight: CGFloat
    /// 滚动容器视口高度（窗口、输入框、确认卡变化后随之变化）
    var viewportHeight: CGFloat
    /// 当前内容偏移
    var offsetY: CGFloat
    /// 底部内容 inset
    var insetBottom: CGFloat

    /// 初次布局数据尚未有效时不能据此改变跟随状态。
    var isUsable: Bool {
        contentHeight > 0 && viewportHeight > 0
    }

    /// 未截断的距离：负值表示偏移已越过内容底部（例如正文转入折叠区后高度骤降）。
    var rawDistanceFromBottom: CGFloat {
        contentHeight + insetBottom - viewportHeight - offsetY
    }

    /// 距离内容底部的距离（已滚到底部时为 0）。
    var distanceFromBottom: CGFloat {
        max(0, rawDistanceFromBottom)
    }

    /// 内容仍高于视口、但偏移已越过新的底部：需要重新贴底，否则会残留空白。
    /// 内容短于视口时由 `.defaultScrollAnchor(.bottom, for: .alignment)` 负责对齐。
    var isPastBottom: Bool {
        contentHeight + insetBottom > viewportHeight + 0.5
            && rawDistanceFromBottom < -0.5
    }

    /// 忽略亚像素抖动：布局每帧的微小变化不应反复请求滚动。
    func isApproximatelyEqual(to other: ChatScrollGeometry, tolerance: CGFloat = 0.5) -> Bool {
        abs(contentHeight - other.contentHeight) <= tolerance
            && abs(viewportHeight - other.viewportHeight) <= tolerance
            && abs(offsetY - other.offsetY) <= tolerance
            && abs(insetBottom - other.insetBottom) <= tolerance
    }
}

// MARK: - 滚动请求

/// 一次滚动请求的来源。自动校正不带动画，新消息与回底保留短动画。
enum ChatScrollRequest: Equatable {
    case newMessage
    case contentGrowth
    case layoutCorrection
    case returnToBottom

    var isAnimated: Bool {
        switch self {
        case .newMessage, .returnToBottom:
            return true
        case .contentGrowth, .layoutCorrection:
            return false
        }
    }
}

// MARK: - 滚动状态机

/// 聊天滚动状态机：把「是否跟随底部」「回底按钮可见性」「待执行滚动请求」
/// 从视图里抽出来，便于单测。
///
/// 约定：
/// - 只在主线程访问（与 SwiftUI 布局回调同线程），因此不加 actor 隔离：
///   加了会让 `@State` 默认值构造在非隔离上下文里不可用。
/// - **不是**观察态：字段写入不触发视图失效。必须上屏的按钮可见性由视图
///   在延后一拍的主线程任务里同步到 `@State`。
/// - 几何变化本身永远不暂停跟随：只有「用户交互中且偏移向上」才视为主动上翻；
///   内容增高、窗口缩放、输入框收缩都不改变跟随状态。
final class ChatScrollState {
    /// 稳定底部锚点：自动跟随与回底按钮统一定位到这里，搜索仍按消息 ID 定位
    static let bottomAnchorID = "chatScroll.bottom.anchor"

    /// 用户离开底部、暂停跟随的距离阈值
    static let pauseDistance: CGFloat = 120
    /// 用户回到附近、恢复跟随的距离阈值（与 `pauseDistance` 形成滞回，避免边界抖动）
    static let resumeDistance: CGFloat = 64
    /// 「回到底部」按钮的显示距离，独立于跟随判定
    static let buttonDistance: CGFloat = 400
    /// 偏移方向判定与「已经到位」的最小变化量
    static let scrollEpsilon: CGFloat = 1

    private(set) var sessionID: UUID?
    /// 请求世代：切换会话、搜索定位、离开页面都会递增，拦截迟到的滚动任务
    private(set) var generation = 0
    private(set) var isFollowingBottom = true
    private(set) var isButtonVisible = false
    private(set) var isUserInteracting = false
    /// 程序自身带交互动画的滚动（如点击回底）：期间不排队自动校正，避免打断动画
    private(set) var isAnimatingScroll = false
    private(set) var pendingRequest: ChatScrollRequest?
    private(set) var lastGeometry: ChatScrollGeometry?
    private var isFlushScheduled = false
    private var messageFrames: [UUID: CGRect] = [:]
    private struct ReadingAnchor {
        let id: UUID
        let fraction: CGFloat
        var appliedLayout: [CGFloat] = []
    }
    private var readingAnchor: ReadingAnchor?
    var hasReadingAnchor: Bool { readingAnchor != nil }

    /// Layout callbacks only update this non-observable box; scrolling runs in the existing deferred flush.
    func recordMessageFrame(_ frame: CGRect, id: UUID) {
        guard frame.height.isFinite, frame.minY.isFinite, frame.height > 0 else { return }
        if let viewport = lastGeometry?.viewportHeight, frame.maxY < 0 || frame.minY > viewport {
            messageFrames[id] = nil
        } else {
            messageFrames[id] = frame
        }
    }

    func forgetMessageFrame(_ id: UUID) { messageFrames[id] = nil }

    func beginReadingReflow() {
        readingAnchor = nil
        guard !isFollowingBottom, !isUserInteracting, let viewport = lastGeometry?.viewportHeight else { return }
        let center = viewport / 2
        let frames = messageFrames.filter { $0.value.maxY > 0 && $0.value.minY < viewport }
        guard let target = frames.min(by: {
            abs($0.value.midY - center) < abs($1.value.midY - center)
        }) else { return }
        readingAnchor = ReadingAnchor(id: target.key, fraction: min(1, max(0, (center - target.value.minY) / target.value.height)))
    }

    func readingReflowTarget() -> (id: UUID, anchor: CGFloat)? {
        guard !isFollowingBottom, !isUserInteracting, var target = readingAnchor,
              let frame = messageFrames[target.id], let geometry = lastGeometry else { return nil }
        let layout = [frame.height, geometry.viewportHeight, geometry.contentHeight].map { ($0 * 2).rounded() }
        guard layout != target.appliedLayout else { return nil }
        target.appliedLayout = layout
        readingAnchor = target
        let travel = geometry.viewportHeight - frame.height
        let desired = geometry.viewportHeight / 2 - target.fraction * frame.height
        let anchor = abs(travel) > 0.5 ? min(1, max(0, desired / travel)) : 0.5
        guard abs(frame.minY - anchor * travel) > Self.scrollEpsilon else { return nil }
        return (target.id, anchor)
    }

    // MARK: 会话身份与请求世代

    /// 绑定当前会话。`reset` 为真时（进入页面 / 会话切换）清空几何与跟随状态。
    func bindSession(_ id: UUID?, reset: Bool = false) {
        guard reset || id != sessionID else { return }
        sessionID = id
        generation &+= 1
        isFollowingBottom = true
        isButtonVisible = false
        isUserInteracting = false
        isAnimatingScroll = false
        pendingRequest = nil
        lastGeometry = nil
        isFlushScheduled = false
        messageFrames = [:]
        readingAnchor = nil
    }

    /// 取消在途请求（离开页面等）。旧世代的任务执行前会自行失效。
    func invalidateRequests() {
        generation &+= 1
        pendingRequest = nil
        isFlushScheduled = false
        readingAnchor = nil
    }

    /// 延迟任务执行前核对会话身份与请求世代。
    func isCurrent(sessionID: UUID?, generation: Int) -> Bool {
        self.sessionID == sessionID && self.generation == generation
    }

    // MARK: 几何收集

    /// 收集一次滚动几何。返回是否需要延后一拍做收尾（排队滚动或同步按钮可见性）。
    @discardableResult
    func ingest(_ geometry: ChatScrollGeometry) -> Bool {
        guard geometry.isUsable else { return false }
        if let lastGeometry, lastGeometry.isApproximatelyEqual(to: geometry) {
            return false
        }
        let previous = lastGeometry
        lastGeometry = geometry
        let distance = geometry.distanceFromBottom

        // 只有用户交互中的主动上翻才暂停跟随；内容增高、窗口缩放都不经过这里
        if isUserInteracting {
            if distance <= Self.resumeDistance {
                isFollowingBottom = true
            } else if distance >= Self.pauseDistance,
                      let previous,
                      geometry.offsetY < previous.offsetY - Self.scrollEpsilon {
                isFollowingBottom = false
            }
        }

        let buttonVisible = !isFollowingBottom && distance > Self.buttonDistance
        let buttonChanged = buttonVisible != isButtonVisible
        isButtonVisible = buttonVisible

        // 跟随中且离开底部（或高度收缩后越过底部）→ 请求无动画校正；
        // 已经到位就不再排队，避免「测量—滚动—再测量」循环
        if isFollowingBottom, !isUserInteracting, !isAnimatingScroll,
           distance > Self.scrollEpsilon || geometry.isPastBottom {
            request(.layoutCorrection)
            return true
        }
        return buttonChanged || hasReadingAnchor
    }

    // MARK: 用户交互

    func beginUserInteraction() {
        readingAnchor = nil
        isUserInteracting = true
        isAnimatingScroll = false
    }

    func endUserInteraction() {
        isUserInteracting = false
        // 停手时已在恢复阈值内：恢复跟随（滚轮减速阶段可能没有新的几何回调）
        if let lastGeometry, lastGeometry.distanceFromBottom <= Self.resumeDistance {
            isFollowingBottom = true
        }
    }

    /// 程序自身动画滚动开始 / 结束（由滚动阶段回调驱动）
    func setAnimatingScroll(_ animating: Bool) {
        isAnimatingScroll = animating
    }

    /// 滚动停稳后复查：跟随中但尚未到位（动画被内容变化打断）时补一次无动画校正。
    /// 只在跟随且非交互状态下生效，阅读历史时不会触发。
    func settle() {
        guard isFollowingBottom, !isUserInteracting,
              let lastGeometry,
              lastGeometry.distanceFromBottom > Self.scrollEpsilon
                || lastGeometry.isPastBottom else { return }
        request(.layoutCorrection)
    }

    // MARK: 请求

    /// 合并同一轮布局产生的请求：动画请求不被随后的自动校正覆盖。
    func request(_ request: ChatScrollRequest) {
        if let current = pendingRequest, current.isAnimated, !request.isAnimated {
            return
        }
        pendingRequest = request
    }

    /// 执行前复核：自动跟随请求只在此刻仍跟随、用户未交互、也没有程序动画时执行。
    /// 请求排队后用户可能已开始滚动；不能拿排队时的意图覆盖当前操作。
    /// 用户显式点击回底不受这些条件限制。
    func canExecute(_ request: ChatScrollRequest) -> Bool {
        request == .returnToBottom
            || (isFollowingBottom && !isUserInteracting && !isAnimatingScroll)
    }

    /// 点击回底：立即恢复跟随并请求定位。
    func returnToBottom() {
        readingAnchor = nil
        isFollowingBottom = true
        isButtonVisible = false
        request(.returnToBottom)
    }

    /// 搜索定位历史消息：暂停跟随，并作废在途的自动回底。
    func beginSearchJump() {
        readingAnchor = nil
        isFollowingBottom = false
        pendingRequest = nil
        isFlushScheduled = false
        generation &+= 1
    }

    // MARK: 延后执行

    /// 同一轮布局只允许一个收尾任务。
    func beginFlush() -> Bool {
        guard !isFlushScheduled else { return false }
        isFlushScheduled = true
        return true
    }

    func endFlush() {
        isFlushScheduled = false
    }

    func takePendingRequest() -> ChatScrollRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}
