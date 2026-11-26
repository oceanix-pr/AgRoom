import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Local mini app actions")
struct NativeAppLocalActionsTests {
    @Test("Decimal arithmetic has precedence, unary signs and bounded parsing without code evaluation")
    func arithmetic() throws {
        for (expression, expected) in [("0.1 + 0.2", "0.3"), ("2 + 3 × 4", "14"), ("(2 + 3) × -4", "-20"),
                                        ("−.5 ÷ 2", "-0.25"), ("2--3", "5"), ("1e2 / 4", "25"), ("-0", "0")] {
            #expect(try NativeAppLocalActions.transform(.calculate, current: "old", value: .string(expression)) == .string(expected))
        }
        for expression in ["", "1+", "2(3)", "1,000", "1e", "NaN", "inf", "sqrt(4)", "__import__('os')", "1;2", "2**3", "1 2"] {
            #expect(throws: NativeAppLocalActionError.self) {
                try NativeAppLocalActions.transform(.calculate, current: "old", value: .string(expression))
            }
        }
        #expect(throws: NativeAppLocalActionError.divisionByZero) {
            try NativeAppLocalActions.transform(.calculate, current: "old", value: .string("1 / (2 - 2)"))
        }
        #expect(throws: NativeAppLocalActionError.tooComplex) {
            try NativeAppLocalActions.transform(.calculate, current: "old", value: .string(String(repeating: "(", count: 20) + "1" + String(repeating: ")", count: 20)))
        }
        #expect(throws: NativeAppLocalActionError.outOfRange) {
            try NativeAppLocalActions.transform(.calculate, current: "old", value: .string("1e999"))
        }
        #expect(try NativeAppLocalActions.transform(.removeLast, current: "👨‍👩‍👧‍👦", value: .string("")) == .string(""))
        #expect(throws: NativeAppLocalActionError.tooComplex) {
            try NativeAppLocalActions.transform(.append, current: String(repeating: "a", count: 32768), value: .string("1"))
        }
    }

    @MainActor @Test("The full keypad works in preview with no approvals and preserves results on errors")
    func keypad() async throws {
        let definition = try NativeAppTemplates.calculator()
        #expect(definition.scripts == nil)
        #expect(try NativeAppDefinition.decode(definition.encoded()) == definition)
        let model = NativeAppRuntime(definition: definition, space: .work, preview: true)
        await model.activate()
        for key in ["digit-1", "decimal", "digit-2", "add", "digit-3", "equals"] { model.perform(key) }
        #expect(model.values["result"] == .string("4.2"))
        model.perform("answer"); model.perform("multiply"); model.perform("digit-2"); model.perform("equals")
        #expect(model.values["result"] == .string("8.4"))
        model.perform("clear"); model.perform("digit-1"); model.perform("divide"); model.perform("digit-0"); model.perform("equals")
        #expect(model.error != nil)
        #expect(model.values["result"] == .string("8.4"))
        model.perform("backspace"); model.perform("digit-2"); model.perform("equals")
        #expect(model.values["result"] == .string("0.5"))
        #expect(model.error == nil && model.pending == nil && !model.isBusy && !model.isDirty)

        var invalid = definition
        invalid.actions["equals"]?.stateKey = "missing"
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = definition
        invalid.actions["equals"]?.script = "execute"
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = definition
        invalid.actions["clear"]?.operation = .calculate
        #expect(throws: NativeAppError.self) { try invalid.validate() }

        if let directory = ProcessInfo.processInfo.environment["AGROOM_NATIVE_APP_SNAPSHOT_DIR"] {
            let host = NSHostingView(rootView: NativeAppRenderer(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("calculator.png"))
        }
    }

    @MainActor @Test("Local calculators prepare recoverable drafts without any Python or workspace scope")
    func calculatorDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calculator-draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = NativeAppDraftStore(directoryURL: root, space: .personal)
        let tool = NativeAppPrepareTool(space: .personal, makeStore: { nil }, publish: { definition, updating in
            try await drafts.save(definition, updatingAppID: updating)
        })
        let definition = try NativeAppTemplates.calculator()
        let args = try JSONSerialization.data(withJSONObject: ["definition_json": String(decoding: definition.encoded(), as: UTF8.self)])
        _ = try await tool.execute(argumentsJSON: String(decoding: args, as: UTF8.self))
        #expect(try await drafts.catalog().drafts.first?.definition == definition)
    }

    @MainActor @Test("App schema sections and long JSON examples arrive intact below the dispatcher result limit")
    func schemaPaging() async throws {
        let tool = NativeAppSchemaTool(space: .personal, makeStore: { nil })
        for section in ["core", "python", "example"] {
            var full = "", offset = 0
            repeat {
                let arguments = try JSONSerialization.data(withJSONObject: ["section": section, "example": "calculator", "offset": offset])
                let response = try await tool.execute(argumentsJSON: String(decoding: arguments, as: UTF8.self))
                #expect(response.count < 6000)
                let start = try #require(response.firstIndex(of: "\n"))
                let end = try #require(response.range(of: "\n[end of page]", options: .backwards)?.lowerBound)
                let page = String(response[response.index(after: start)..<end])
                full += page; offset += page.count
                if response[..<start].contains("next_offset=none") { break }
                try #require(offset < NativeAppDefinition.maximumBytes)
            } while true
            switch section {
            case "core": #expect(full == NativeAppGenerator.designInstructions && full.contains("transformState"))
            case "python": #expect(full == NativeAppGenerator.pythonInstructions)
            default: #expect(try NativeAppDefinition.decode(Data(full.utf8)) == NativeAppTemplates.calculator())
            }
        }
    }
}
