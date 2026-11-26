import AppKit
import Observation
import Testing
@testable import AgRoomUI

@Suite("Menu bar robot")
@MainActor
struct MenuBarRobotTests {
    @Test("任务结束后重新计算一分钟闲置；普通状态刷新不延后睡眠")
    func idleStartsAfterLastWork() {
        var machine = MenuBarRobotStateMachine()
        let idle = MenuBarRobotActivity()
        #expect(machine.update(activity: idle, hasConfiguredProvider: true, now: 0) == .ready)
        #expect(machine.update(activity: idle, hasConfiguredProvider: true, now: 40) == .ready)
        #expect(machine.update(activity: idle, hasConfiguredProvider: true, now: 60) == .sleeping)
        #expect(machine.update(activity: .init(isWorking: true), hasConfiguredProvider: true, now: 61) == .working)
        #expect(machine.update(activity: .init(isWorking: true), hasConfiguredProvider: true, now: 100) == .working)
        #expect(machine.update(activity: idle, hasConfiguredProvider: true, now: 101) == .ready)
        #expect(machine.update(activity: idle, hasConfiguredProvider: true, now: 160) == .ready)
        #expect(machine.update(activity: idle, hasConfiguredProvider: true, now: 161) == .sleeping)
        machine.wake(at: 162)
        #expect(machine.update(activity: idle, hasConfiguredProvider: true, now: 162) == .ready)
    }

    @Test("等待处理优先；没有模型也能如实显示本地任务，配置恢复后不立即睡眠")
    func attentionAndConfiguration() {
        var machine = MenuBarRobotStateMachine()
        #expect(machine.update(activity: .init(), hasConfiguredProvider: nil, now: 0) == .ready)
        #expect(machine.update(activity: .init(), hasConfiguredProvider: false, now: 5) == .unconfigured)
        #expect(machine.update(activity: .init(isWorking: true), hasConfiguredProvider: false, now: 200) == .working)
        #expect(machine.update(activity: .init(isWorking: true, needsAttention: true),
                               hasConfiguredProvider: false, now: 201) == .waiting)
        #expect(machine.update(activity: .init(needsAttention: true), hasConfiguredProvider: true, now: 400) == .waiting)
        #expect(machine.update(activity: .init(), hasConfiguredProvider: true, now: 401) == .ready)
        #expect(machine.update(activity: .init(), hasConfiguredProvider: true, now: 460) == .ready)
        #expect(machine.update(activity: .init(), hasConfiguredProvider: false, now: 461) == .unconfigured)
        #expect(machine.update(activity: .init(), hasConfiguredProvider: true, now: 800) == .ready)
    }

    @Observable
    final class ActivitySource: MenuBarActivitySource {
        var menuBarActivity = MenuBarRobotActivity()
    }

    @Test("后台来源的变化可被观察，不依赖当前会话或轮询")
    func observesBackgroundActivity() async {
        let registry = ChatRunRegistry()
        let first = ActivitySource()
        let background = ActivitySource()
        registry.registerActivitySource(first)
        registry.registerActivitySource(background)
        first.menuBarActivity = .init(isWorking: true)
        await confirmation("background attention invalidates observation") { changed in
            withObservationTracking {
                _ = registry.menuBarActivity
            } onChange: {
                changed()
            }
            background.menuBarActivity = .init(needsAttention: true)
        }
        #expect(registry.menuBarActivity == .init(isWorking: true, needsAttention: true))
    }

    @Test("其他会话收尾不会掩盖后台运行与待确认；注册表不延长模型寿命")
    func aggregateActivities() {
        let registry = ChatRunRegistry()
        var first: ActivitySource? = ActivitySource()
        let second = ActivitySource()
        registry.registerActivitySource(first!)
        registry.registerActivitySource(second)
        first?.menuBarActivity = .init(isWorking: true)
        second.menuBarActivity = .init(isWorking: true)
        first?.menuBarActivity = .init()
        #expect(registry.menuBarActivity.isWorking)
        first?.menuBarActivity = .init(needsAttention: true)
        second.menuBarActivity = .init()
        #expect(registry.menuBarActivity.needsAttention)
        #expect(!registry.menuBarActivity.isWorking)
        weak var weakFirst = first
        first = nil
        #expect(weakFirst == nil)
        #expect(registry.menuBarActivity == .init())
    }

    @Test("减少动态效果停在静态表情且不继续安排帧唤醒")
    func reducedMotionStopsFrameScheduling() {
        for state in MenuBarRobotState.allCases {
            #expect(MenuBarRobotAnimation.frame(state: state, elapsed: 7.9, animated: false) == 0)
            #expect(MenuBarRobotAnimation.nextFrameDelay(state: state, elapsed: 7.9, animated: false) == nil)
        }
        #expect(MenuBarRobotAnimation.nextFrameDelay(state: .ready, elapsed: 0, animated: true) == 7.85)
        #expect(MenuBarRobotAnimation.frame(state: .ready, elapsed: 7.9, animated: true) == 1)
        #expect(MenuBarRobotAnimation.nextFrameDelay(state: .unconfigured, elapsed: 0, animated: true) == nil)
        #expect(MenuBarRobotAnimation.nextFrameDelay(state: .waiting, elapsed: 0, animated: true) == nil)
    }

    @Test("所有动画帧共用透明模板画布，镂空眼睛不依赖菜单栏底色")
    func transparentTemplateFrames() throws {
        for state in MenuBarRobotState.allCases {
            for frame in 0..<16 {
                let image = MenuBarRobotDrawing.image(state: state, frame: frame)
                #expect(image.isTemplate)
                #expect(image.size == MenuBarRobotDrawing.size)
            }
        }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 20, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        MenuBarRobotDrawing.image(state: .ready).draw(in: NSRect(origin: .zero, size: MenuBarRobotDrawing.size))
        NSGraphicsContext.restoreGraphicsState()
        #expect(try #require(bitmap.colorAt(x: 12, y: 10)).alphaComponent > 0.9)
        #expect(try #require(bitmap.colorAt(x: 8, y: 12)).alphaComponent < 0.1)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
    }
}
