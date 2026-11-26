import AppKit
import Observation
import AgRoomCore
import AgRoomUI

/// App 层拥有状态项与动画生命周期；不读取任何空间数据库。
@MainActor
final class MenuBarRobotController: NSObject, NSMenuDelegate {
    private weak var button: NSStatusBarButton?
    private weak var hub: Hub?
    private var machine = MenuBarRobotStateMachine()
    private var state: MenuBarRobotState = .ready
    private var stateEnteredAt = ProcessInfo.processInfo.systemUptime
    private var hasConfiguredProvider: Bool?
    private var backgroundWorking = false
    private var backgroundNeedsAttention = false
    private var animationsEnabled = true
    private var reducedMotion = false
    private var screenAsleep = false
    private var menuOpen = false
    private var stopped = false
    private var animationTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var providerTask: Task<Void, Never>?
    private var jobsTask: Task<Void, Never>?
    private var providerRevision = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var eventMonitor: Any?

    private struct FrameKey: Hashable {
        let state: MenuBarRobotState
        let frame: Int
    }
    private var frames: [FrameKey: NSImage] = [:]
    private var displayedFrame: FrameKey?

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        loadMotionPreferences()
        installObservers()
        observeActivity()
        jobsTask = Task { [weak self] in
            for await jobs in JobCenter.shared.stream() {
                guard !Task.isCancelled else { break }
                let working = jobs.contains(where: \.isActive)
                let attention = jobs.contains { $0.state == .awaitingSave }
                guard self?.backgroundWorking != working || self?.backgroundNeedsAttention != attention else { continue }
                self?.backgroundWorking = working
                self?.backgroundNeedsAttention = attention
                self?.refresh()
            }
        }
    }

    func bind(hub: Hub) {
        self.hub = hub
        refreshProviderConfiguration()
    }

    func stop() {
        stopped = true
        animationTask?.cancel()
        idleTask?.cancel()
        providerTask?.cancel()
        jobsTask?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if let space = hub?.spaceStore.current {
            for item in menu.items where item.representedObject as? String == AppMenuCommand.noteRecording.rawValue { item.title = L.string(NotesRecordingStatus.shared.isRecording(space: space) ? "notes.stop" : "notes.record") }
        }
        wake()
        restartAnimation()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        restartAnimation()
    }

    private func observeActivity() {
        guard !stopped else { return }
        withObservationTracking {
            _ = LanguageManager.shared.version
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeActivity() }
        }
    }

    private func activity() -> MenuBarRobotActivity {
        var activity = ChatRunRegistry.shared.menuBarActivity
        // 先读取全部观察态，避免布尔短路让未读的任务来源漏掉后续订阅。
        let scheduledWorking = !ScheduledTaskCenter.shared.runningTaskIDs.isEmpty
        let scheduledNeedsAttention = ScheduledTaskCenter.shared.hasUnsavedResults
        let daemonWorking = DaemonSupervisor.shared.hasBlockedSessions
        let recoveryRequired = DaemonSupervisor.shared.recoverySessionIds.values.contains { !$0.isEmpty }
        activity.isWorking = activity.isWorking || NotesRecordingStatus.shared.anyRecording || backgroundWorking
            || scheduledWorking || daemonWorking
        activity.needsAttention = activity.needsAttention || recoveryRequired || backgroundNeedsAttention || scheduledNeedsAttention
        return activity
    }

    private func refresh() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let next = machine.update(activity: activity(), hasConfiguredProvider: hasConfiguredProvider, now: now)
        let changed = state != next
        if changed {
            state = next
            stateEnteredAt = now
            restartAnimation()
        } else if displayedFrame == nil {
            restartAnimation()
        }
        let status = L.string(NotesRecordingStatus.shared.anyRecording ? "notes.recording" : state.localizationKey)
        button?.toolTip = "\(L.string("app.name")) · \(status)"
        button?.setAccessibilityLabel("\(L.string("app.name")) · \(status)")

        if state == .ready {
            if idleTask == nil {
                idleTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(MenuBarRobotStateMachine.sleepDelay)) }
                    catch { return }
                    self?.idleTask = nil
                    self?.refresh()
                }
            }
        } else {
            idleTask?.cancel()
            idleTask = nil
        }
    }

    private func wake() {
        machine.wake(at: ProcessInfo.processInfo.systemUptime)
        idleTask?.cancel()
        idleTask = nil
        refresh()
    }

    private func refreshProviderConfiguration() {
        providerTask?.cancel()
        providerRevision += 1
        let revision = providerRevision
        guard let service = hub?.providerService else {
            hasConfiguredProvider = hub == nil ? nil : false
            refresh()
            return
        }
        providerTask = Task { [weak self] in
            do {
                // 只读已保存配置；不加载 Keychain、不做联网探测或消耗 Token。
                let providers = try await service.getAll()
                guard let self, !Task.isCancelled, self.providerRevision == revision else { return }
                self.hasConfiguredProvider = providers.contains {
                    $0.isEnabled && !$0.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                self.refresh()
            } catch {
                // 暂时读取失败不覆盖已知配置状态，也不误报为没有模型。
                guard !Task.isCancelled else { return }
                HubLogger.shared.warning("Menu bar provider configuration refresh failed")
            }
        }
    }

    private var animated: Bool {
        animationsEnabled && !reducedMotion && !screenAsleep && !menuOpen
    }

    private func restartAnimation() {
        animationTask?.cancel()
        guard !stopped else { return }
        let delay = displayFrame()
        guard let delay else { return }
        animationTask = Task { [weak self] in
            var nextDelay = delay
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(nextDelay)) }
                catch { return }
                guard !Task.isCancelled, let delay = self?.displayFrame() else { return }
                nextDelay = delay
            }
        }
    }

    @discardableResult
    private func displayFrame() -> TimeInterval? {
        let elapsed = ProcessInfo.processInfo.systemUptime - stateEnteredAt
        let key = FrameKey(state: state, frame: MenuBarRobotAnimation.frame(
            state: state, elapsed: elapsed, animated: animated
        ))
        if displayedFrame != key {
            let image = frames[key] ?? MenuBarRobotDrawing.image(state: key.state, frame: key.frame)
            frames[key] = image
            button?.image = image
            displayedFrame = key
        }
        return MenuBarRobotAnimation.nextFrameDelay(state: state, elapsed: elapsed, animated: animated)
    }

    private func loadMotionPreferences() {
        animationsEnabled = UserDefaults.standard.object(forKey: MenuBarRobotSettings.animationEnabledKey) as? Bool ?? true
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func observe(
        _ name: Notification.Name, center: NotificationCenter = .default,
        action: @escaping @MainActor (MenuBarRobotController) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func installObservers() {
        observe(ProviderConfigService.configurationDidChange) { $0.refreshProviderConfiguration() }
        observe(NSApplication.didBecomeActiveNotification) {
            $0.wake()
            $0.refreshProviderConfiguration()
        }
        observe(UserDefaults.didChangeNotification) {
            let wasAnimated = $0.animated
            $0.loadMotionPreferences()
            if wasAnimated != $0.animated { $0.restartAnimation() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: workspace) {
            $0.loadMotionPreferences()
            $0.restartAnimation()
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observe(name, center: workspace) {
                $0.screenAsleep = true
                $0.restartAnimation()
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observe(name, center: workspace) {
                $0.screenAsleep = false
                $0.wake()
                $0.restartAnimation()
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.wake() }
            return event
        }
    }
}
