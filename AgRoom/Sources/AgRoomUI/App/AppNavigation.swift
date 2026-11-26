import Foundation
import AgRoomCore

// MARK: - App Navigation

/// 跨层页面跳转中枢：UI 层与 App 层（应用菜单、菜单栏状态项）共用的唯一跳转入口。
///
/// 目标空间统一取"当前空间"，在投递时刻由主窗口（持有 `Hub`）解析，
/// 因此调用方无需关心空间状态。
///
/// 主窗口未挂载时（窗口被关闭后从菜单发起）通知没有订阅者，路由会被丢弃；
/// 因此这里先挂起页面，等主窗口挂载后补发，避免"点了菜单没反应"。
@MainActor
public final class AppNavigation {
    public static let shared = AppNavigation()

    /// 当前空间来源：由主窗口（`RootView` 持有 `Hub`）注册
    private var spaceProvider: (@MainActor () -> AppSpace)?
    /// 待处理跳转：主窗口未挂载时保留，挂载后补发
    private var pending: HubNavItem?
    private var pendingCommand: CommandRequest?
    private var pendingCurrentCommand: AppMenuCommand?

    struct CommandRequest {
        static let notification = Notification.Name("agroom.navigation.command")
        let id = UUID()
        let command: AppMenuCommand
        let space: AppSpace
    }

    public func performInCurrentSpace(_ command: AppMenuCommand) {
        if let space = spaceProvider?() { perform(command, space: space) }
        else { pendingCurrentCommand = command }
    }

    public func perform(_ command: AppMenuCommand, space: AppSpace) {
        let request = CommandRequest(command: command, space: space)
        pending = nil; pendingCommand = request
        if spaceProvider?() == space {
            NotificationCenter.default.post(name: CommandRequest.notification, object: request)
        }
    }

    func consume(_ request: CommandRequest) {
        if pendingCommand?.id == request.id { pendingCommand = nil }
    }

    func deliverCommandIfNeeded(space: AppSpace) {
        if let command = pendingCurrentCommand { pendingCurrentCommand = nil; pendingCommand = CommandRequest(command: command, space: space) }
        guard let request = pendingCommand else { return }
        pendingCommand = nil
        guard request.space == space else { return }
        NotificationCenter.default.post(name: CommandRequest.notification, object: request)
    }

    init() {}

    /// 注册当前空间来源（主窗口挂载时调用）
    func registerSpaceProvider(_ provider: @escaping @MainActor () -> AppSpace) {
        spaceProvider = provider
    }

    /// 跳转到主窗口的指定功能页
    public func open(page: HubNavItem) {
        pendingCommand = nil
        pending = page
        guard let space = spaceProvider?() else { return }
        deliver(page: page, space: space)
    }

    /// 主窗口挂载后补发挂起的跳转（空间取挂载时刻的当前空间）
    func deliverPendingIfNeeded(space: AppSpace) {
        guard let page = pending else { return }
        pending = nil
        deliver(page: page, space: space)
    }

    /// 路由已被接收方消费：清除挂起状态（仅当挂起的正是同一条路由）
    func markDelivered(_ route: ProductRoute) {
        guard let pending, pending.rawValue == route.page else { return }
        self.pending = nil
    }

    private func deliver(page: HubNavItem, space: AppSpace) {
        let route = ProductRoute(space: space, page: page.rawValue)
        NotificationCenter.default.post(name: ProductRoute.notification, object: route)
    }
}
