import Foundation
import Testing
@testable import AgRoomUI

@Suite("Chat scroll follow state")
struct ChatScrollStateTests {
    @Test("字号重排保留历史消息的阅读比例，主动滚动立即接管")
    func readingReflow() throws {
        let state = ChatScrollState()
        let id = UUID()
        state.bindSession(UUID())
        state.ingest(geometry(content: 3000, offset: 2500))
        state.beginUserInteraction()
        state.ingest(geometry(content: 3000, offset: 500))
        state.endUserInteraction()
        state.recordMessageFrame(CGRect(x: 0, y: -200, width: 400, height: 1200), id: id)
        state.beginReadingReflow()
        state.recordMessageFrame(CGRect(x: 0, y: -200, width: 400, height: 2400), id: id)
        let target = try #require(state.readingReflowTarget())
        #expect(target.id == id)
        #expect(abs(target.anchor - 650.0 / 1900.0) < 0.001)
        #expect(state.readingReflowTarget() == nil)
        state.beginUserInteraction()
        #expect(state.readingReflowTarget() == nil)
        #expect(!state.hasReadingAnchor)
    }

    private func geometry(
        content: CGFloat = 1000,
        viewport: CGFloat = 500,
        offset: CGFloat = 500,
        inset: CGFloat = 0
    ) -> ChatScrollGeometry {
        ChatScrollGeometry(
            contentHeight: content,
            viewportHeight: viewport,
            offsetY: offset,
            insetBottom: inset
        )
    }

    @Test("初次布局数据无效时不改变跟随状态")
    func ignoresUnusableGeometry() {
        let state = ChatScrollState()
        let changed = state.ingest(
            ChatScrollGeometry(contentHeight: 0, viewportHeight: 500, offsetY: 0, insetBottom: 0)
        )
        #expect(!changed)
        #expect(state.isFollowingBottom)
        #expect(state.pendingRequest == nil)
        #expect(!state.isButtonVisible)
    }

    @Test("内容增高不误判为主动上翻")
    func contentGrowthKeepsFollowing() {
        let state = ChatScrollState()
        state.ingest(geometry())
        #expect(state.isFollowingBottom)

        // 内容增长 300pt、偏移未动：这不是用户上翻，仍应跟随并排队校正
        state.ingest(geometry(content: 1300, offset: 500))
        #expect(state.isFollowingBottom)
        #expect(state.pendingRequest == .layoutCorrection)
    }

    @Test("亚像素几何变化不重复排队")
    func minorGeometryChangesDoNotQueue() {
        let state = ChatScrollState()
        state.ingest(geometry())
        let changed = state.ingest(geometry(content: 1000.2, offset: 500.1))
        #expect(!changed)
        #expect(state.pendingRequest == nil)
    }

    @Test("高度骤降越过新底部时重新校正")
    func contentShrinkPastBottomRequestsCorrection() {
        let state = ChatScrollState()
        // 内容 1300、视口 500：偏移 800 正好在底部
        state.ingest(geometry(content: 1300, offset: 800))
        #expect(state.takePendingRequest() == nil)

        // 正文转入折叠区后内容只剩 900，原偏移仍在 800：已越过新底部 400pt，
        // 若不重新贴底会在下方残留空白
        state.ingest(geometry(content: 900, offset: 800))
        #expect(state.isFollowingBottom)
        #expect(state.lastGeometry?.distanceFromBottom == 0)
        #expect(state.lastGeometry?.isPastBottom == true)
        #expect(state.pendingRequest == .layoutCorrection)
    }

    @Test("短内容不触发越界校正，交给短内容底部对齐")
    func shortContentDoesNotRequestOverscrollCorrection() {
        let state = ChatScrollState()
        let changed = state.ingest(geometry(content: 300, viewport: 500, offset: 0))
        #expect(!changed)
        #expect(state.isFollowingBottom)
        #expect(state.pendingRequest == nil)
    }

    @Test("用户上翻暂停跟随，滚回底部恢复")
    func userScrollPausesAndResumes() {
        let state = ChatScrollState()
        state.ingest(geometry())

        state.beginUserInteraction()
        // 偏移从 500 降到 300：用户主动上翻 200pt
        state.ingest(geometry(offset: 300))
        #expect(!state.isFollowingBottom)
        #expect(!state.isButtonVisible)
        #expect(state.pendingRequest == nil)

        // 继续上翻到距离底部 500pt：只显示回底按钮，不自动回底
        state.ingest(geometry(offset: 0))
        #expect(!state.isFollowingBottom)
        #expect(state.isButtonVisible)
        #expect(state.pendingRequest == nil)

        // 用户滚回底部附近（距离 40pt）：恢复跟随
        state.ingest(geometry(offset: 460))
        #expect(state.isFollowingBottom)
        #expect(!state.isButtonVisible)
    }

    @Test("阅读历史时内容继续增长不拉回底部")
    func growthDoesNotPullReadingPosition() {
        let state = ChatScrollState()
        state.ingest(geometry())
        state.beginUserInteraction()
        state.ingest(geometry(offset: 100))
        state.endUserInteraction()
        #expect(!state.isFollowingBottom)

        state.ingest(geometry(content: 1400, offset: 100))
        #expect(!state.isFollowingBottom)
        #expect(state.pendingRequest == nil)
    }

    @Test("点击回底恢复跟随并请求定位")
    func returnToBottomRestoresFollowing() {
        let state = ChatScrollState()
        state.ingest(geometry())
        state.beginUserInteraction()
        state.ingest(geometry(offset: 0))
        state.endUserInteraction()
        #expect(!state.isFollowingBottom)
        #expect(state.isButtonVisible)

        state.returnToBottom()
        #expect(state.isFollowingBottom)
        #expect(!state.isButtonVisible)
        #expect(state.pendingRequest == .returnToBottom)
    }

    @Test("搜索定位暂停跟随并作废在途回底")
    func searchCancelsPendingFollow() {
        let state = ChatScrollState()
        state.bindSession(UUID())
        let generation = state.generation
        state.request(.contentGrowth)

        state.beginSearchJump()
        #expect(!state.isFollowingBottom)
        #expect(state.pendingRequest == nil)
        #expect(!state.isCurrent(sessionID: state.sessionID, generation: generation))
    }

    @Test("切换会话让旧世代请求失效并重置跟随")
    func staleSessionRequestsAreRejected() {
        let state = ChatScrollState()
        let first = UUID()
        state.bindSession(first)
        let generation = state.generation

        state.request(.newMessage)
        state.ingest(geometry())
        state.beginUserInteraction()
        state.ingest(geometry(offset: 0))
        #expect(!state.isFollowingBottom)

        let second = UUID()
        state.bindSession(second)
        #expect(!state.isCurrent(sessionID: first, generation: generation))
        #expect(state.isFollowingBottom)
        #expect(state.pendingRequest == nil)
        #expect(state.lastGeometry == nil)
    }

    @Test("离开页面后旧世代任务失效")
    func invalidationRejectsInFlightWork() {
        let state = ChatScrollState()
        state.bindSession(UUID())
        let generation = state.generation
        state.request(.newMessage)

        state.invalidateRequests()
        #expect(!state.isCurrent(sessionID: state.sessionID, generation: generation))
        #expect(state.pendingRequest == nil)
    }

    @Test("同一轮布局请求合并，动画请求不被自动校正覆盖")
    func requestsCoalesce() {
        let state = ChatScrollState()
        state.request(.newMessage)
        state.request(.layoutCorrection)
        #expect(state.pendingRequest == .newMessage)

        state.request(.contentGrowth)
        #expect(state.pendingRequest == .newMessage)

        state.request(.returnToBottom)
        #expect(state.pendingRequest == .returnToBottom)
        #expect(state.takePendingRequest() == .returnToBottom)
        #expect(state.pendingRequest == nil)
    }

    @Test("同一轮布局只排一个收尾任务")
    func flushTicketIsExclusive() {
        let state = ChatScrollState()
        #expect(state.beginFlush())
        #expect(!state.beginFlush())
        state.endFlush()
        #expect(state.beginFlush())
    }

    @Test("程序动画滚动期间不排队自动校正")
    func animatingScrollSuppressesCorrection() {
        let state = ChatScrollState()
        state.setAnimatingScroll(true)

        let changed = state.ingest(geometry(content: 1500, offset: 500))
        #expect(!changed)
        #expect(state.pendingRequest == nil)
        #expect(state.isFollowingBottom)
    }

    @Test("请求执行前复核当前跟随、交互与动画状态")
    func queuedRequestsRecheckCurrentState() {
        let state = ChatScrollState()
        state.ingest(geometry())
        #expect(state.canExecute(.newMessage))

        state.beginUserInteraction()
        #expect(!state.canExecute(.newMessage))
        #expect(state.canExecute(.returnToBottom))

        // 用户在请求排队后继续上翻：停手时已离开底部，迟到的自动请求不得执行
        state.ingest(geometry(offset: 100))
        #expect(!state.isFollowingBottom)
        state.endUserInteraction()
        #expect(!state.canExecute(.layoutCorrection))
        #expect(state.canExecute(.returnToBottom))

        let animating = ChatScrollState()
        animating.setAnimatingScroll(true)
        #expect(!animating.canExecute(.contentGrowth))
        #expect(animating.canExecute(.returnToBottom))
        animating.setAnimatingScroll(false)
        #expect(animating.canExecute(.contentGrowth))
    }

    @Test("停稳复查只在跟随且未到位时补校正")
    func settleOnlyWhenFollowingAndAway() {
        let state = ChatScrollState()
        state.ingest(geometry(content: 1300, offset: 500))
        #expect(state.takePendingRequest() == .layoutCorrection)

        state.setAnimatingScroll(false)
        state.settle()
        #expect(state.pendingRequest == .layoutCorrection)

        let reading = ChatScrollState()
        reading.ingest(geometry())
        reading.beginUserInteraction()
        reading.ingest(geometry(offset: 100))
        reading.endUserInteraction()
        reading.settle()
        #expect(reading.pendingRequest == nil)
    }

    @Test("距离底部计算包含底部 inset")
    func distanceIncludesBottomInset() {
        let geometry = ChatScrollGeometry(
            contentHeight: 1000,
            viewportHeight: 500,
            offsetY: 480,
            insetBottom: 20
        )
        #expect(geometry.distanceFromBottom == 40)
    }
}
