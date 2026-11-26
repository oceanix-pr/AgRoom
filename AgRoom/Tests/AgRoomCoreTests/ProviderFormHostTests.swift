import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Provider form persistence", .serialized)
@MainActor
struct ProviderFormHostTests {
    private enum HostFailure: Error { case missingModelField, missingSaveButton, saveTimeout }

    private func mount<Content: View>(_ form: Content) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: form)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func accessibilityNodes(in view: NSView) -> [any NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject, depth: Int = 0) -> [any NSAccessibilityProtocol] {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var nodes: [any NSAccessibilityProtocol] = []
            if let node = object as? any NSAccessibilityProtocol {
                nodes.append(node)
                for child in node.accessibilityChildren() ?? [] {
                    nodes += visit(child as AnyObject, depth: depth + 1)
                }
            }
            if let native = object as? NSView {
                for child in native.subviews { nodes += visit(child, depth: depth + 1) }
            }
            return nodes
        }
        return visit(view)
    }

    private func modelField(in window: NSWindow, candidates: Set<String>) async throws -> NSTextField {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let view = window.contentView,
               let field = descendants(view).compactMap({ $0 as? NSTextField }).first(where: {
                   $0.isEditable && !($0 is NSSecureTextField) && candidates.contains($0.stringValue)
               }) {
                // Let SwiftUI finish presenting the form before checking the actual control.
                try await Task.sleep(for: .milliseconds(150))
                return field
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostFailure.missingModelField
    }

    private func save(in window: NSWindow) throws {
        let title = L.string("common.save")
        if let view = window.contentView,
           let button = accessibilityNodes(in: view).first(where: {
               $0.accessibilityRole() == .button && $0.accessibilityLabel() == title
           }), button.accessibilityPerformPress() { return }
        if let view = window.contentView,
           let button = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) {
            button.performClick(nil)
            return
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        guard window.performKeyEquivalent(with: event) else { throw HostFailure.missingSaveButton }
    }

    private func waitForSave(_ completed: () -> Bool) async throws {
        for _ in 0..<100 {
            if completed() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostFailure.saveTimeout
    }

    @Test("Editing, saving and reopening keeps the actual model instead of the matching preset default")
    func savedModelSurvivesEditingAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-form-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("global.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareGlobal(queue)
        let service = ProviderConfigService(databaseQueue: queue)
        let original = LLMProviderConfig(name: "Synthetic DeepSeek", endpoint: ProviderPreset.deepseek.endpoint,
            model: "deepseek-v4-pro", alias: "Synthetic display alias")
        try await service.save(original, apiKey: nil)
        let spaceQueue = try DatabaseQueue()
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: spaceQueue), providerService: service)

        var saved = false
        let window = mount(ProviderFormSheet(hub: hub, provider: original) { saved = true })
        defer { window.close() }
        let candidates: Set<String> = [original.model, "deepseek-flash", ProviderPreset.deepseek.defaultModel]
        let field = try await modelField(in: window, candidates: candidates)
        #expect(field.stringValue == original.model)

        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("deepseek-flash", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        try save(in: window)
        try await waitForSave { saved }
        window.orderOut(nil)

        let reopenedQueue = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareGlobal(reopenedQueue)
        let reopenedService = ProviderConfigService(databaseQueue: reopenedQueue)
        let restored = try #require(try await reopenedService.getAll().first)
        #expect(restored.model == "deepseek-flash" && restored.alias == original.alias)

        var savedAgain = false
        let reopened = mount(ProviderFormSheet(hub: hub, provider: restored) { savedAgain = true })
        defer { reopened.close() }
        let reopenedField = try await modelField(in: reopened, candidates: candidates)
        #expect(reopenedField.stringValue == restored.model)
        try save(in: reopened)
        try await waitForSave { savedAgain }
        #expect(try await reopenedService.getAll().first?.model == "deepseek-flash")
    }

    @Test("The context budget control saves a shared workflow value and restores it when reopened")
    func contextBudgetControlPersists() async throws {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareGlobal(queue)
        let provider = LLMProviderConfig(name: "Synthetic Terra", endpoint: "https://metadata.invalid/v1/chat/completions", model: "fixture")
        try await ProviderConfigService(databaseQueue: queue).save(provider, apiKey: nil)
        let metadata = Data(#"{"data":[{"id":"fixture","context_window":1050000,"max_output_tokens":128000,"temperature":false}]}"#.utf8)
        let service = ModelParameterService(databaseQueue: queue, fetch: { _ in metadata })
        _ = try await service.refresh(provider: provider, force: true)
        try await service.save(.init(contextTokenBudget: 128_000), provider: provider, mode: .chat)
        let window = mount(Form {
            ModelParameterSettingsView(providers: [provider], service: service)
        }.formStyle(.grouped))
        window.setContentSize(NSSize(width: 850, height: 850))
        defer { window.close() }
        let field = try await modelField(in: window, candidates: ["128000"])
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("256000", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)

        var saved: ModelParameterPreferences?
        for _ in 0..<100 {
            saved = try await service.load(provider: provider, mode: .chat).preferences
            if saved?.contextTokenBudget == 256_000 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(saved?.contextTokenBudget == 256_000)
        #expect(try await service.load(provider: provider, mode: .coding).preferences.contextTokenBudget == 256_000)
        window.orderOut(nil)
        let reopened = mount(Form {
            ModelParameterSettingsView(providers: [provider], service: service)
        }.formStyle(.grouped))
        reopened.setContentSize(NSSize(width: 850, height: 850))
        defer { reopened.close() }
        _ = try await modelField(in: reopened, candidates: ["256000"])

        if let directory = ProcessInfo.processInfo.environment["AGROOM_MODEL_PARAMETERS_SNAPSHOT_DIR"],
           let view = reopened.contentView {
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("model-parameters.png"))
        }
    }
}
