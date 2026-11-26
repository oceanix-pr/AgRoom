import Foundation
import Carbon
import AppKit
import AgRoomCore

// MARK: - Hotkey Manager

/// 全局快捷键：Carbon RegisterEventHotKey（默认 ⌥⌘Space 唤起/隐藏主窗口）
@MainActor
final class HotkeyManager {

    static let shared = HotkeyManager()

    /// 触发时的回调（由 AppDelegate 注入）
    var onToggle: (() -> Void)?
    var onCaptureNote: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var captureHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var registered = false

    private var preferencesObserver: NSObjectProtocol?
    private init() {
        preferencesObserver = NotificationCenter.default.addObserver(forName: GlobalHotkeyPreferences.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                HotkeyManager.shared.unregister()
                HotkeyManager.shared.register()
            }
        }
    }

    /// 注册全局热键：⌥⌘Space（kVK_Space + cmd + option）
    func register() {
        guard !registered else { return }

        // 事件处理器（C 回调 → 共享实例）
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var id = EventHotKeyID(signature: 0, id: 0)
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr { HotkeyManager.dispatch(id.id) }
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            HubLogger.shared.error("Global hotkey event handler setup failed (status \(installStatus))")
            return
        }

        // 热键 ID（签名 "AGHB"）
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x41474842),
            id: 1
        )
        let modifiers = UInt32(GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.toggleModifiers, fallback: GlobalHotkeyPreferences.commandOption))
        let registerStatus = RegisterEventHotKey(
            UInt32(GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.toggleKey, fallback: 49)),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus == noErr {
            registered = true
            let captureID = EventHotKeyID(signature: OSType(0x41474842), id: 2)
            let captureStatus = RegisterEventHotKey(UInt32(GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.captureKey, fallback: 1)), UInt32(GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.captureModifiers, fallback: GlobalHotkeyPreferences.commandControlOption)), captureID, GetApplicationEventTarget(), 0, &captureHotKeyRef)
            UserDefaults.standard.set(Int(captureStatus), forKey: GlobalHotkeyPreferences.statusKey)
            if captureStatus != noErr { HubLogger.shared.warning("Notes capture hotkey registration failed (status \(captureStatus))") }
            HubLogger.shared.info("Global hotkey registered: ⌥⌘Space")
        } else {
            UserDefaults.standard.set(Int(registerStatus), forKey: GlobalHotkeyPreferences.statusKey)
            HubLogger.shared.error("Global hotkey registration failed (status \(registerStatus))")
        }
    }

    func unregister() {
        if let captureHotKeyRef { UnregisterEventHotKey(captureHotKeyRef); self.captureHotKeyRef = nil }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        registered = false
    }

    /// C 回调桥接：跳回主 actor 执行
    nonisolated private static func dispatch(_ id: UInt32) {
        Task { @MainActor in
            if id == 2 { HotkeyManager.shared.onCaptureNote?() } else { HotkeyManager.shared.onToggle?() }
        }
    }
}
