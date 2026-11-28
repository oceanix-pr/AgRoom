import AppKit
import SwiftUI
import AgRoomCore

@MainActor
public enum NativeAppLifecycle {
    public static func saveAll() async -> Bool { await NativeAppWindowCoordinator.shared.saveAll() }
    public static func synchronize(space: AppSpace) { NativeAppWindowCoordinator.shared.synchronize(space: space) }
    public static func resumeVisible() { NativeAppWindowCoordinator.shared.resumeVisible() }
}

/// Windows own their fixed-space runtimes, matching the mail window ownership rule.
/// The coordinator keeps no reusable space service or loaded application registry.
@MainActor
final class NativeAppWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = NativeAppWindowCoordinator()
    private struct Key: Hashable { let space: AppSpace; let appID: String }
    private final class Entry {
        let window: NSWindow
        let model: NativeAppRuntime
        var closing = false
        var deciding = false
        var activationID = UUID()
        var activationTask: Task<Void, Never>?
        init(window: NSWindow, model: NativeAppRuntime) { self.window = window; self.model = model }
    }
    private var entries: [Key: Entry] = [:]
    override init() { super.init() }

    func open(snapshot: NativeAppSnapshot, space: AppSpace, hub: Hub) throws {
        guard hub.spaceStore.current == space else { throw NativeAppError(.unavailable) }
        guard let store = hub.makeNativeAppStore(for: space), let resources = hub.makeNativeAppResources(for: space) else {
            throw NativeAppError(.unavailable)
        }
        _ = try open(snapshot: snapshot, space: space, store: store, resources: resources,
            scriptReviewer: { request in
                guard let provider = try await hub.makeActiveProvider(for: space, source: "app-code-review") else { return .unavailable }
                return try await NativeAppScriptModelReviewer(provider: provider).review(request)
            },
            capabilityBridge: NativeAppCapabilityBridge(space: space, resources: resources, mysql: hub.makeMySQLConnectorService(for: space), platform: { name, inputs in
                guard name == "clipboard.writeText", let text = inputs["text"]?.string else { throw NativeAppError(.invalidDefinition) }
                return try await MainActor.run {
                    try Task.checkCancellation()
                    guard hub.spaceStore.current == space else { throw NativeAppError(.spaceMismatch) }
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(text, forType: .string) else { throw NativeAppError(.unavailable) }
                    return HostCapabilityResult()
                }
            }),
            currentSpace: { hub.spaceStore.current })
    }

    @discardableResult
    func open(snapshot: NativeAppSnapshot, space: AppSpace, store: NativeAppStore, resources: NativeAppResources,
              scriptReviewer: NativeAppScriptReviewer? = nil,
              capabilityBridge: NativeAppCapabilityBridge? = nil,
              currentSpace: @escaping @MainActor () -> AppSpace) throws -> NSWindow {
        guard currentSpace() == space, store.space == space, resources.space == space, snapshot.isInstalled else {
            throw NativeAppError(.spaceMismatch)
        }
        let key = Key(space: space, appID: snapshot.definition.id)
        if let entry = entries[key] {
            if entry.window.isMiniaturized { entry.window.deminiaturize(nil) }
            entry.window.makeKeyAndOrderFront(nil)
            if !entry.model.isActive { activate(entry) }
            NSApp.activate(ignoringOtherApps: true)
            return entry.window
        }
        let definition = snapshot.definition
        let model = NativeAppRuntime(definition: definition, space: space, store: store, resources: resources,
            scriptReviewer: scriptReviewer, capabilityBridge: capabilityBridge)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: definition.manifest.width ?? 800,
                                                height: definition.manifest.height ?? 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("agroom.native-app.\(space.rawValue).\(definition.id)")
        window.title = definition.text(definition.manifest.nameKey, language: LanguageManager.shared.activeLanguageCode)
            + " · " + L.string(space.nameKey)
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: NativeAppWindowView(model: model, currentSpace: currentSpace))
        window.delegate = self
        window.center()
        let entry = Entry(window: window, model: model)
        entries[key] = entry
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        activate(entry)
        return window
    }

    func synchronize(space: AppSpace) {
        for (key, entry) in entries where key.space != space {
            entry.window.orderOut(nil)
            if entry.model.isActive || entry.activationTask != nil {
                suspend(entry)
                Task { await entry.model.flush() }
            }
        }
    }

    func discard(space: AppSpace, id: String) {
        guard let entry = entries[Key(space: space, appID: id)] else { return }
        suspend(entry); entry.closing = true; entry.window.close()
    }

    func flush(space: AppSpace, id: String) async -> Bool {
        guard let entry = entries[Key(space: space, appID: id)] else { return true }
        return await entry.model.flush()
    }

    func pauseForDataChange(space: AppSpace, id: String) async throws {
        guard let entry = entries[Key(space: space, appID: id)] else { return }
        suspend(entry)
        guard await entry.model.flush() else {
            activate(entry)
            throw NativeAppError(.storage)
        }
    }

    func resume(space: AppSpace, id: String) {
        if let entry = entries[Key(space: space, appID: id)] { activate(entry) }
    }

    func saveAll() async -> Bool {
        var success = true
        for entry in Array(entries.values) {
            suspend(entry)
            if !(await entry.model.flush()) { success = false }
        }
        return success
    }

    func resumeVisible() {
        for entry in entries.values where entry.window.isVisible { activate(entry) }
    }

    private func activate(_ entry: Entry) {
        guard !entry.closing, !entry.deciding, entry.window.isVisible else { return }
        entry.activationTask?.cancel()
        let id = UUID()
        entry.activationID = id
        entry.activationTask = Task { [weak entry] in
            guard let entry, !Task.isCancelled else { return }
            await entry.model.activate()
            if entry.activationID == id { entry.activationTask = nil }
        }
    }

    private func suspend(_ entry: Entry) {
        entry.activationID = UUID()
        entry.activationTask?.cancel(); entry.activationTask = nil
        entry.model.suspend()
    }

    func refreshTitles() {
        let language = LanguageManager.shared.activeLanguageCode
        for entry in entries.values {
            let definition = entry.model.definition
            entry.window.title = definition.text(definition.manifest.nameKey, language: language)
                + " · " + L.string(entry.model.space.nameKey)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = entries.values.first(where: { $0.window === sender }) else { return true }
        if entry.closing { return true }
        guard !entry.deciding else { return false }
        entry.deciding = true
        suspend(entry)
        Task { @MainActor in
            let saved = await entry.model.flush()
            if saved { entry.closing = true; sender.close() }
            else {
                let alert = NSAlert()
                alert.messageText = L.string("apps.close.failed")
                alert.informativeText = entry.model.error ?? L.string("apps.error.storage")
                alert.addButton(withTitle: L.string("common.cancel"))
                alert.addButton(withTitle: L.string("apps.close.discard"))
                alert.beginSheetModal(for: sender) { response in
                    Task { @MainActor in
                        if response == .alertSecondButtonReturn { entry.closing = true; sender.close() }
                        else { entry.deciding = false; self.activate(entry) }
                    }
                }
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = entries.first(where: { $0.value.window === window })?.key else { return }
        if let entry = entries.removeValue(forKey: key) { suspend(entry) }
    }
}

private struct NativeAppWindowView: View {
    @Bindable var model: NativeAppRuntime
    let currentSpace: @MainActor () -> AppSpace
    @State private var languageManager = LanguageManager.shared
    var body: some View {
        Group {
            if currentSpace() == model.space {
                NativeAppRenderer(model: model)
            } else {
                ContentUnavailableView(L.string("apps.space.hidden"), systemImage: "lock.shield")
            }
        }
        .tint(model.space.tint)
        .environment(languageManager)
        .environment(\.locale, Locale(identifier: languageManager.activeLanguageCode))
        .environment(\.layoutDirection, languageManager.layoutDirection)
        .onChange(of: currentSpace()) { _, space in NativeAppLifecycle.synchronize(space: space) }
        .onChange(of: languageManager.version) { _, _ in
            NativeAppWindowCoordinator.shared.refreshTitles()
        }
    }
}
