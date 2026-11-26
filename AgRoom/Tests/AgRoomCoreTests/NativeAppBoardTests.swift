import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Native app sliding boards", .serialized)
struct NativeAppBoardTests {
    private func tutorial() throws -> NativeAppBoard {
        try JSONDecoder().decode(NativeAppBoard.self, from: Data(#"{"columns":4,"rows":5,"persistent":true,"pieces":[{"id":"cao","labelKey":"cao","x":1,"y":0,"width":2,"height":2}],"goal":{"piece":"cao","x":1,"y":3}}"#.utf8))
    }

    @Test("Board DSL is versioned, closed, translated and compatible with v3 capabilities")
    func schema() throws {
        let app = try NativeAppTemplates.slidingPuzzle()
        #expect(try NativeAppDefinition.decode(app.encoded()) == app)
        for version in 1...3 {
            var old = app; old.manifest.dslVersion = version
            #expect(throws: NativeAppError.self) { try old.validate() }
        }
        var inherited = try NativeAppTemplates.databaseMetadata()
        inherited.manifest.dslVersion = 4
        #expect(try NativeAppDefinition.decode(inherited.encoded()) == inherited)
        var invalid = app; invalid.boards?["puzzle"]?.pieces[0].x = -1
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.boards?["puzzle"]?.pieces[0].width = Int.max
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.boards?["puzzle"]?.pieces[1].id = "cao"
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.boards?["puzzle"]?.pieces[1].y = 0
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.i18n["zh-Hant"]?.removeValue(forKey: "cao")
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["undo"]?.board = "missing"
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.views.children?[2].board = "missing"
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        var raw = try #require(JSONSerialization.jsonObject(with: app.encoded()) as? [String: Any])
        var boards = try #require(raw["boards"] as? [String: Any])
        var board = try #require(boards["puzzle"] as? [String: Any])
        board["onLoad"] = "runPython"; boards["puzzle"] = board; raw["boards"] = boards
        #expect(throws: NativeAppError.self) { _ = try NativeAppDefinition.decode(JSONSerialization.data(withJSONObject: raw)) }
    }

    @Test("Moves validate the swept path, axes and bounds; winning, undo and redo share one reducer")
    func rules() throws {
        let board = try tutorial()
        try board.validate(path: "test")
        let initial = board.initialProgress
        for (dx, dy) in [(1, 1), (0, 0), (2, 0), (Int.max, 0), (0, Int.min)] {
            #expect(throws: NativeAppBoardError.self) { _ = try board.moving(initial, piece: "cao", dx: dx, dy: dy) }
        }
        let won = try board.moving(initial, piece: "cao", dx: 0, dy: 3)
        #expect(board.isWon(won) && won.moves == 1)
        #expect(throws: NativeAppBoardError.finished) { _ = try board.moving(won, piece: "cao", dx: 0, dy: -1) }
        let undone = try board.undoing(won)
        #expect(undone.positions == initial.positions && undone.moves == 0 && undone.redo.count == 1)
        #expect(try board.redoing(undone) == won)
        let branched = try board.moving(undone, piece: "cao", dx: 1, dy: 0)
        #expect(branched.redo.isEmpty && branched.moves == 1)
        var obstructed = board
        obstructed.pieces.append(.init(id: "blocker", labelKey: "cao", x: 1, y: 2, width: 1, height: 1))
        try obstructed.validate(path: "test")
        // The destination is empty, but the intervening row is occupied.
        #expect(throws: NativeAppBoardError.illegalMove) {
            _ = try obstructed.moving(obstructed.initialProgress, piece: "cao", dx: 0, dy: 3)
        }
        var restricted = board; restricted.pieces[0].axis = .horizontal
        #expect(!restricted.canMove(restricted.initialProgress, piece: "cao", dx: 0, dy: 1))
        var forged = won; forged.undo = []
        forged.moves = 0
        #expect(throws: NativeAppError.self) { try board.validateProgress(forged) }
        forged = won; forged.undo[0] = .init(piece: "cao", from: .init(x: 0, y: 0), to: .init(x: 1, y: 3))
        #expect(throws: NativeAppBoardError.self) { try board.validateProgress(forged) }
    }

    @Test("Bounded history remains reversible after eviction and clears a replaced redo branch")
    func history() throws {
        let board = try tutorial()
        var progress = board.initialProgress
        for index in 0..<260 { progress = try board.moving(progress, piece: "cao", dx: index.isMultiple(of: 2) ? 1 : -1, dy: 0) }
        #expect(progress.moves == 260 && progress.undo.count == NativeAppBoardProgress.maximumHistory)
        let saved = progress
        for _ in 0..<NativeAppBoardProgress.maximumHistory { progress = try board.undoing(progress) }
        try board.validateProgress(progress)
        #expect(progress.moves == 132 && progress.undo.isEmpty)
        for _ in 0..<NativeAppBoardProgress.maximumHistory { progress = try board.redoing(progress) }
        #expect(progress == saved)
    }

    @MainActor @Test("Preview is fully playable, atomic and nonpersistent; stale gestures and suspended input cannot commit")
    func preview() async throws {
        var app = try NativeAppTemplates.slidingPuzzle()
        app.state["counter"] = .init(initial: .number(0), persistent: false)
        app.actions["read-counter"] = .init(type: .setState, stateKey: "counter", value: .init(board: "puzzle.moves"))
        try app.validate()
        let model = NativeAppRuntime(definition: app, space: .work, preview: true)
        await model.activate()
        let before = try #require(model.boardProgress["puzzle"])
        #expect(model.moveBoard("puzzle", piece: "soldier-3", dx: 1, dy: 0))
        let moved = try #require(model.boardProgress["puzzle"])
        model.perform("read-counter")
        #expect(model.values["counter"] == .number(1))
        #expect(!model.moveBoard("puzzle", piece: "soldier-4", dx: -1, dy: 0, expected: before))
        #expect(model.boardProgress["puzzle"] == moved)
        model.perform("undo")
        #expect(model.boardProgress["puzzle"]?.positions == before.positions)
        model.perform("redo")
        #expect(model.boardProgress["puzzle"] == moved)
        model.perform("restart")
        #expect(model.boardProgress["puzzle"] == before)
        #expect(model.pending == nil && model.workspace == nil && !model.isBusy && !model.isDirty)
        model.suspend()
        #expect(!model.moveBoard("puzzle", piece: "soldier-3", dx: 1, dy: 0))
        model.perform("undo")
        #expect(model.boardProgress["puzzle"] == before)
    }

    @MainActor @Test("An independently searched solution completes the classic template through ordinary preview input")
    func classicCompletion() async throws {
        // Fixed trace produced by a separate breadth-first search, not the app reducer.
        let trace = """
        soldier-3:1:0 ma:0:1 guan:-1:0 soldier-2:0:1 huang:-1:0 soldier-4:0:-1 soldier-2:1:0 huang:0:1 guan:2:0
        soldier-1:0:-1 soldier-1:-1:0 soldier-3:0:-2 huang:-1:0 soldier-4:-1:0 soldier-4:0:1 guan:0:1 soldier-3:2:0 soldier-1:2:0
        ma:0:-1 huang:0:-1 soldier-4:-2:0 soldier-2:-2:0 guan:0:1 soldier-1:0:1 soldier-1:1:0 huang:1:0 ma:1:0 zhang:0:2
        cao:-1:0 zhao:-1:0 soldier-3:0:-2 soldier-1:0:-2 huang:1:0 zhao:0:2 cao:1:0 zhang:0:-2 ma:-1:0 soldier-2:0:-2
        soldier-4:1:0 soldier-4:0:-1 guan:-2:0 zhao:0:1 huang:0:1 soldier-2:2:0 cao:0:1 soldier-3:-2:0 soldier-1:0:-1 soldier-1:-1:0
        soldier-2:0:-2 huang:0:-2 zhao:1:0 soldier-4:1:0 soldier-4:0:1 cao:0:1 soldier-3:0:1 soldier-3:1:0 zhang:1:0 ma:0:-2
        cao:-1:0 soldier-3:0:1 soldier-1:0:1 soldier-2:-1:0 huang:0:-1 zhao:0:-1 soldier-4:1:0 soldier-3:0:2 cao:1:0 ma:0:2
        zhang:-1:0 soldier-2:-1:0 soldier-1:-1:0 huang:-1:0 zhao:0:-2 cao:1:0 soldier-1:0:2 soldier-2:0:2 zhang:1:0 ma:0:-2
        soldier-2:-1:0 soldier-1:0:-1 guan:0:-1 soldier-3:-2:0 soldier-4:-2:0 cao:0:1 soldier-1:2:0 soldier-2:2:0 guan:0:-1 soldier-3:0:-1 soldier-4:-1:0 cao:-1:0
        """
        let app = try NativeAppTemplates.slidingPuzzle()
        let model = NativeAppRuntime(definition: app, space: .personal, preview: true)
        await model.activate()
        let moves = trace.split(whereSeparator: \.isWhitespace)
        for entry in moves {
            let parts = entry.split(separator: ":")
            let dx = try #require(Int(parts[1])), dy = try #require(Int(parts[2]))
            try #require(model.moveBoard("puzzle", piece: String(parts[0]), dx: dx, dy: dy))
        }
        #expect(model.resolve(.init(board: "puzzle.won")) == .bool(true))
        #expect(model.resolve(.init(board: "puzzle.moves")) == .number(Double(moves.count)))
        model.perform("undo")
        #expect(model.resolve(.init(board: "puzzle.won")) == .bool(false))
        model.perform("redo")
        #expect(model.resolve(.init(board: "puzzle.won")) == .bool(true))
        model.perform("restart")
        #expect(model.boardProgress["puzzle"] == app.boards?["puzzle"]?.initialProgress)
        #expect(model.pending == nil && !model.isDirty && model.error == nil)
        model.suspend()
    }

    @MainActor @Test("A full draft budget rejects a move atomically and transient boards stay out of persistence")
    func draftBudget() async throws {
        var app = try NativeAppTemplates.slidingPuzzle()
        app.boards = ["puzzle": try tutorial()]
        app.state = ["a": .init(initial: .string(String(repeating: "a", count: 32000)), persistent: true),
                     "b": .init(initial: .string(String(repeating: "b", count: 32000)), persistent: true)]
        try app.validate()
        let model = NativeAppRuntime(definition: app, space: .personal, preview: true)
        await model.activate()
        var rejected = false
        for index in 0..<NativeAppBoardProgress.maximumHistory {
            let before = model.boardProgress["puzzle"]
            if !model.moveBoard("puzzle", piece: "cao", dx: index.isMultiple(of: 2) ? 1 : -1, dy: 0) {
                #expect(model.boardProgress["puzzle"] == before && model.error != nil)
                rejected = true; break
            }
        }
        #expect(rejected)
        model.perform("restart")
        #expect(model.error == nil && model.boardProgress["puzzle"]?.moves == 0)
        model.suspend()
        app.boards?["puzzle"]?.persistent = false
        try app.validate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transient-board-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root, space: .work)
        try await store.install(app, replacing: nil)
        let transient = NativeAppRuntime(definition: app, space: .work, store: store)
        await transient.activate()
        #expect(transient.moveBoard("puzzle", piece: "cao", dx: 1, dy: 0))
        #expect(!transient.isDirty)
        transient.setValue(.string("short"), key: "a")
        #expect(await transient.flush())
        #expect(try await store.workspace(for: app).loadDraft(for: app).boards.isEmpty)
        transient.suspend()
    }

    @MainActor @Test("Progress survives reopen, cosmetic updates and portable backup while preserving space and installation identity")
    func persistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let work = NativeAppStore(directoryURL: root.appendingPathComponent("work/apps"), space: .work)
        let app = try NativeAppTemplates.slidingPuzzle()
        try await store.install(app, replacing: nil); try await work.install(app, replacing: nil)
        let model = NativeAppRuntime(definition: app, space: .personal, store: store)
        await model.activate()
        #expect(model.moveBoard("puzzle", piece: "soldier-3", dx: 1, dy: 0))
        #expect(await model.flush())
        let progress = try #require(model.boardProgress["puzzle"])
        let workspace = try #require(model.workspace)
        model.suspend()
        let reopened = NativeAppRuntime(definition: app, space: .personal, store: store)
        await reopened.activate()
        #expect(reopened.boardProgress["puzzle"] == progress)
        let other = NativeAppRuntime(definition: app, space: .work, store: work)
        await other.activate()
        #expect(other.boardProgress["puzzle"]?.moves == 0)
        // Scalar-only callers must preserve structured progress.
        try await store.saveState([:], for: app)
        #expect(try await workspace.loadDraft(for: app).boards["puzzle"] == progress)
        var corrupt = progress; corrupt.moves = 0
        let badDraft = NativeAppDraftState(values: [:], boards: ["puzzle": corrupt])
        await #expect(throws: NativeAppError.self) { try await workspace.saveDraft(badDraft, for: app) }
        #expect(try await workspace.loadDraft(for: app).boards["puzzle"] == progress)
        let archive = try NativeAppBackup.decode(try await store.backup(id: app.id, space: .personal).encoded())
        let target = NativeAppStore(directoryURL: root.appendingPathComponent("restored/apps"), space: .personal)
        try await target.restore(archive, space: .personal, replacing: nil)
        #expect(try await target.workspace(for: app).loadDraft(for: app).boards["puzzle"] == progress)
        await #expect(throws: NativeAppError(.spaceMismatch)) { try await work.restore(archive, space: .work, replacing: nil) }
        let current = try await store.load(id: app.id)
        var cosmetic = app; cosmetic.manifest.version += 1; cosmetic.i18n["en"]?["cao"] = "Target"
        try await store.install(cosmetic, replacing: current.revision)
        #expect(try await workspace.loadDraft(for: cosmetic).boards["puzzle"] == progress)
        let updated = try await store.load(id: app.id)
        var incompatible = cosmetic; incompatible.manifest.version += 1; incompatible.boards?["puzzle"]?.goal.y = 2
        await #expect(throws: NativeAppError(.incompatibleState)) { try await store.install(incompatible, replacing: updated.revision) }
        try await store.restore(id: app.id, replacing: updated.revision)
        #expect(try await workspace.loadDraft(for: app).boards["puzzle"] == progress)
        let last = try await store.load(id: app.id)
        try await store.remove(id: app.id, revision: last.revision)
        try await store.install(app, replacing: nil)
        await #expect(throws: NativeAppError(.conflict)) { try await workspace.saveDraft(.init(values: [:], boards: ["puzzle": progress]), for: app) }
        reopened.suspend(); other.suspend()
    }

    @MainActor @Test("Paged board guidance and the playable example reach app preparation without Python or installation")
    func generation() async throws {
        let schema = NativeAppSchemaTool(space: .personal, makeStore: { nil })
        let instructions = try await schema.execute(argumentsJSON: #"{"section":"boards"}"#)
        #expect(instructions.contains("Every move") || instructions.contains("Each move"))
        var json = "", offset = 0
        repeat {
            let page = try await schema.execute(argumentsJSON: "{\"section\":\"example\",\"example\":\"slidingPuzzle\",\"offset\":\(offset)}")
            let start = try #require(page.firstIndex(of: "\n"))
            let end = try #require(page.range(of: "\n[end of page]", options: .backwards)?.lowerBound)
            let content = String(page[page.index(after: start)..<end]); json += content; offset += content.count
            if page[..<start].contains("next_offset=none") { break }
        } while offset < NativeAppDefinition.maximumBytes
        let app = try NativeAppDefinition.decode(Data(json.utf8))
        #expect(app == (try NativeAppTemplates.slidingPuzzle()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = NativeAppDraftStore(directoryURL: root, space: .personal)
        let prepare = NativeAppPrepareTool(space: .personal, makeStore: { nil }, publish: { definition, updating in
            try await drafts.save(definition, updatingAppID: updating)
        })
        let arguments = try JSONSerialization.data(withJSONObject: ["definition_json": json])
        _ = try await prepare.execute(argumentsJSON: String(decoding: arguments, as: UTF8.self))
        #expect(try await drafts.catalog().drafts.first?.definition == app)
        #expect(app.scripts == nil && app.capabilities == nil)
    }

    @MainActor @Test("Native board handles real dragging, direction buttons and keyboard input")
    func nativeInput() async throws {
        _ = NSApplication.shared
        let app = try NativeAppTemplates.slidingPuzzle()
        let model = NativeAppRuntime(definition: app, space: .personal, preview: true)
        await model.activate()
        let host = NSHostingView(rootView: NativeAppBoardView(boardID: "puzzle", model: model).padding(20))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { model.suspend(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        // SwiftPM's host may expose frame-only accessibility placeholders. Locate
        // the visible bottom-left square, then send real events to this window.
        let frames = nativeFrames(in: host)
        let squares = frames.filter { $0.width > 60 && abs($0.width - $0.height) < 1 }
            .sorted { abs($0.minY - $1.minY) > 1 ? $0.minY < $1.minY : $0.minX < $1.minX }
        let frame = try #require(squares.first)
        let start = window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY))
        let cell = frame.width + 8
        for (index, step) in [0.0, 0.3, 0.6, 1.0, 1.0].enumerated() {
            let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == 4 ? .leftMouseUp : .leftMouseDragged
            let event = try #require(NSEvent.mouseEvent(with: type, location: .init(x: start.x + cell * step, y: start.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.boardProgress["puzzle"]?.positions["soldier-3"] == .init(x: 1, y: 4))
        #expect(model.boardProgress["puzzle"]?.moves == 1)
        try click(.init(x: start.x + cell * 3, y: start.y), window: window)
        try await Task.sleep(for: .milliseconds(30))
        let directions = frames.filter { $0.height > 20 && $0.height < cell / 2 }.sorted { $0.minX < $1.minX }
        let left = try #require(directions.first)
        try click(window.convertPoint(fromScreen: .init(x: left.midX, y: left.midY)), window: window)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.boardProgress["puzzle"]?.positions["soldier-4"] == .init(x: 2, y: 4))
        try click(.init(x: start.x + cell * 2, y: start.y), window: window)
        try await Task.sleep(for: .milliseconds(30))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        window.sendEvent(key)
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.boardProgress["puzzle"]?.positions["soldier-4"] == .init(x: 3, y: 4))
        #expect(model.boardProgress["puzzle"]?.moves == 3)
    }

    @MainActor private func click(_ point: NSPoint, window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }

    @MainActor private func nativeFrames(in view: NSView) -> [NSRect] {
        var visited = Set<ObjectIdentifier>()
        var frames: [NSRect] = []
        func visit(_ object: AnyObject, depth: Int) {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let node = object as? any NSAccessibilityProtocol {
                let frame = node.accessibilityFrame()
                if frame.width > 0, !frames.contains(frame) { frames.append(frame) }
                for child in node.accessibilityChildren() ?? [] { visit(child as AnyObject, depth: depth + 1) }
            }
            if let native = object as? NSView {
                for child in native.subviews { visit(child, depth: depth + 1) }
            }
        }
        visit(view, depth: 0)
        return frames
    }
}
