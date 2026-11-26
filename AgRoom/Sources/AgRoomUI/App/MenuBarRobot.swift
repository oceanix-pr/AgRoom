import AppKit

/// 菜单栏只接收活动标记，不持有空间服务、会话内容或模型凭据。
public struct MenuBarRobotActivity: Equatable, Sendable {
    public var isWorking: Bool
    public var needsAttention: Bool

    public init(isWorking: Bool = false, needsAttention: Bool = false) {
        self.isWorking = isWorking
        self.needsAttention = needsAttention
    }
}

@MainActor
protocol MenuBarActivitySource: AnyObject {
    var menuBarActivity: MenuBarRobotActivity { get }
}

public enum MenuBarRobotSettings {
    public static let animationEnabledKey = "agroom.menuBar.animationEnabled"
}

public enum MenuBarRobotState: String, CaseIterable, Sendable {
    case ready, sleeping, working, unconfigured, waiting

    public var localizationKey: String { "menu.robot.\(rawValue)" }
}

/// 使用单调时间；工作/人工等待/缺少配置都会中断闲置倒计时。
public struct MenuBarRobotStateMachine {
    public static let sleepDelay: TimeInterval = 60
    public private(set) var state: MenuBarRobotState = .ready
    private var idleSince: TimeInterval?

    public init() {}

    public mutating func wake(at now: TimeInterval) {
        idleSince = now
    }

    @discardableResult
    public mutating func update(
        activity: MenuBarRobotActivity, hasConfiguredProvider: Bool?, now: TimeInterval
    ) -> MenuBarRobotState {
        if activity.needsAttention {
            state = .waiting
            idleSince = nil
        } else if activity.isWorking {
            state = .working
            idleSince = nil
        } else if hasConfiguredProvider == false {
            state = .unconfigured
            idleSince = nil
        } else {
            if idleSince == nil { idleSince = now }
            state = now - (idleSince ?? now) >= Self.sleepDelay ? .sleeping : .ready
        }
        return state
    }
}

/// 少量离散矢量帧；普通待命只在眨眼时唤醒，不常驻高频刷新。
public enum MenuBarRobotAnimation {
    public static func frame(state: MenuBarRobotState, elapsed: TimeInterval, animated: Bool) -> Int {
        guard animated else { return 0 }
        let time = max(0, elapsed)
        switch state {
        case .ready: return time.truncatingRemainder(dividingBy: 8) >= 7.85 ? 1 : 0
        case .working: return Int(time / 0.2) % 4
        case .sleeping:
            let breath = Int(time / 0.5) % 8
            return breath + (Int(time / 4) % 3 == 2 ? 8 : 0)
        case .unconfigured, .waiting: return 0
        }
    }

    public static func nextFrameDelay(
        state: MenuBarRobotState, elapsed: TimeInterval, animated: Bool
    ) -> TimeInterval? {
        guard animated else { return nil }
        let time = max(0, elapsed)
        switch state {
        case .ready:
            let phase = time.truncatingRemainder(dividingBy: 8)
            return max(0.01, (phase < 7.85 ? 7.85 : 8) - phase)
        case .working: return max(0.01, 0.2 - time.truncatingRemainder(dividingBy: 0.2))
        case .sleeping: return max(0.01, 0.5 - time.truncatingRemainder(dividingBy: 0.5))
        case .unconfigured, .waiting: return nil
        }
    }
}

/// 延续应用图标的机器人轮廓，给天线、鼾睡标记与双手预留固定画布。
/// 纯黑模板 + 透明眼孔，颜色由菜单栏负责；不使用背景色模拟镂空。
@MainActor
public enum MenuBarRobotDrawing {
    public static let size = NSSize(width: 24, height: 20)

    public static func image(state: MenuBarRobotState, frame: Int = 0) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state: state, frame: max(0, frame))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(state: MenuBarRobotState, frame: Int) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // 打字态的双手和键盘已平衡轮廓；其余表情下移，补偿底部留白。
        if state != .working {
            let placement = NSAffineTransform()
            placement.translateX(by: 0, yBy: -2)
            placement.concat()
        }

        let breaths: [CGFloat] = [0, 0.15, 0.4, 0.65, 0.65, 0.4, 0.15, 0]
        let lift = state == .sleeping ? breaths[frame % 8] : 0
        NSColor.black.setFill()
        NSColor.black.setStroke()

        NSBezierPath(roundedRect: NSRect(x: 11.45, y: 14.5 + lift, width: 1.1, height: 3),
                     xRadius: 0.5, yRadius: 0.5).fill()
        NSBezierPath(ovalIn: NSRect(x: 10.8, y: 16.8 + lift, width: 2.4, height: 2.4)).fill()

        let head = NSBezierPath(roundedRect: NSRect(x: 4, y: 4.4 + lift, width: 16, height: 10.8),
                                xRadius: 5.4, yRadius: 5.4)
        head.windingRule = .evenOdd
        for x: CGFloat in [8.5, 15.3] {
            if state == .unconfigured {
                head.append(cross(center: NSPoint(x: x, y: 9.7 + lift)))
            } else if state == .sleeping || (state == .ready && frame == 1) {
                head.append(closedEye(center: NSPoint(x: x, y: 9.5 + lift)))
            } else {
                head.append(NSBezierPath(
                    roundedRect: NSRect(x: x - 1.05, y: 7.8 + lift, width: 2.1, height: 3.8),
                    xRadius: 1.05, yRadius: 1.05
                ))
            }
        }
        head.fill()

        if state == .working {
            let handHeights: [(CGFloat, CGFloat)] = [(2.3, 1.3), (1.8, 1.8), (1.3, 2.3), (1.8, 1.8)]
            let hands = handHeights[frame % 4]
            for (x, y): (CGFloat, CGFloat) in [(5.1, hands.0), (15.4, hands.1)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 3.5, height: 1.8),
                             xRadius: 0.9, yRadius: 0.9).fill()
            }
            NSBezierPath(roundedRect: NSRect(x: 5.7, y: 0.2, width: 12.6, height: 0.65),
                         xRadius: 0.3, yRadius: 0.3).fill()
        } else if state == .sleeping && frame >= 8 {
            let z = NSBezierPath()
            z.move(to: NSPoint(x: 20.6, y: 18.7))
            z.line(to: NSPoint(x: 22.9, y: 18.7))
            z.line(to: NSPoint(x: 20.6, y: 15.9))
            z.line(to: NSPoint(x: 22.9, y: 15.9))
            z.lineWidth = 0.7
            z.lineJoinStyle = .round
            z.stroke()
        } else if state == .waiting {
            NSBezierPath(roundedRect: NSRect(x: 21.5, y: 11.7, width: 1.1, height: 3.6),
                         xRadius: 0.55, yRadius: 0.55).fill()
            NSBezierPath(ovalIn: NSRect(x: 21.5, y: 9.6, width: 1.1, height: 1.1)).fill()
        }
    }

    private static func cross(center: NSPoint) -> NSBezierPath {
        let points: [(CGFloat, CGFloat)] = [
            (-1.8, -1.1), (-1.1, -1.8), (0, -0.7), (1.1, -1.8), (1.8, -1.1), (0.7, 0),
            (1.8, 1.1), (1.1, 1.8), (0, 0.7), (-1.1, 1.8), (-1.8, 1.1), (-0.7, 0)
        ]
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let position = NSPoint(x: center.x + point.0, y: center.y + point.1)
            if index == 0 { path.move(to: position) } else { path.line(to: position) }
        }
        path.close()
        return path
    }

    private static func closedEye(center: NSPoint) -> NSBezierPath {
        let x = center.x, y = center.y
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x - 1.5, y: y + 0.45))
        path.curve(to: NSPoint(x: x + 1.5, y: y + 0.45),
                   controlPoint1: NSPoint(x: x - 0.7, y: y - 0.2),
                   controlPoint2: NSPoint(x: x + 0.7, y: y - 0.2))
        path.line(to: NSPoint(x: x + 1.5, y: y - 0.35))
        path.curve(to: NSPoint(x: x - 1.5, y: y - 0.35),
                   controlPoint1: NSPoint(x: x + 0.7, y: y - 1),
                   controlPoint2: NSPoint(x: x - 0.7, y: y - 1))
        path.close()
        return path
    }
}
