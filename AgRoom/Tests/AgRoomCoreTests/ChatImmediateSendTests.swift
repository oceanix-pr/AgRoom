import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Chat immediate and queued sending", .serialized)
struct ChatImmediateSendTests {
    @MainActor private final class Probe {
        var requests: [ChatEngineRequest] = []
        var held: Set<String> = []
        var continuations: [String: CheckedContinuation<Void, Never>] = [:]
        let calls = CallCounter()

        func build(_ request: ChatEngineRequest) async -> DispatcherEngine {
            requests.append(request)
            let gateName = request.goalProgress == nil ? request.taskRequest : "goal-segment"
            if held.contains(gateName) {
                await withCheckedContinuation { continuations[gateName] = $0 }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SendFixtureProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Send-Scenario": request.taskRequest]
            let provider = CloudProvider(config: .init(name: "Send fixture", endpoint: "https://chat-send.invalid/v1", model: "fixture"),
                apiKey: "synthetic", session: URLSession(configuration: configuration))
            return DispatcherEngine(provider: provider, tools: [ApprovalTool(calls: calls), AskUserTool()], systemPrompt: "Disposable send fixture", maxSteps: 3)
        }

        func release(_ text: String) {
            held.remove(text)
            continuations.removeValue(forKey: text)?.resume()
        }

        func releaseAll() {
            held.removeAll()
            let pending = Array(continuations.values)
            continuations.removeAll()
            for item in pending { item.resume() }
        }
    }

    private struct Fixture {
        let root: URL
        let queue: DatabaseQueue
        let model: ChatViewModel
        let probe: Probe
        var service: SessionService { SessionService(databaseQueue: queue) }
    }

    private func fixture(held: Set<String> = [], autoReview: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-send-" + UUID().uuidString)
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), skillDirectoryRoot: root.appendingPathComponent("skills"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("registry.json"),
            fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        let probe = Probe()
        probe.held = held
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false,
            handoffStore: DaemonHandoffStore(baseDirectory: root.appendingPathComponent("handoffs")), draftDefaults: nil,
            makeEngine: { await probe.build($0) }, generateTitle: { _, _ in "Fixture" })
        await model.load()
        model.preferredAutoReview = autoReview
        model.newSession()
        return Fixture(root: root, queue: queue, model: model, probe: probe)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test("Immediate messages wait for cancellation cleanup, retain the queue and stay in their originating session", arguments: [false, true])
    func interruptAndPrioritize(queuedItem: Bool) async throws {
        let f = try await fixture(held: ["first", "urgent"])
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        let id = try #require(f.model.activeSessionId)
        f.model.inputText = "first"; f.model.send()
        try await wait { f.probe.continuations["first"] != nil }
        let oldRun = try #require(f.model.currentRunID)
        f.model.inputText = "queued-one"; f.model.send()
        f.model.inputText = "urgent"
        f.model.excludesMemoryForNextTurn = true
        if queuedItem {
            f.model.send()
            let item = try #require(f.model.activeQueue.last)
            f.model.sendQueuedImmediately(id: item.id)
            f.model.sendQueuedImmediately(id: item.id) // A second click cannot reserve or dispatch twice.
        } else {
            f.model.send(mode: .immediate)
        }
        #expect(f.model.isStoppingHere && f.model.currentRunID == oldRun)
        #expect(f.probe.requests.count == 1)
        #expect(f.model.activeImmediateSend?.text == "urgent")
        #expect(f.model.activeImmediateSend?.memoryExcluded == true)
        #expect(f.model.activeQueue.map(\.text) == ["queued-one"])

        f.model.newSession()
        let other = try #require(f.model.activeSessionId)
        f.model.inputText = "other-session"; f.model.send()
        try await wait { f.probe.requests.count == 2 && !f.model.isRunningHere }
        f.model.inputText = "Unsent draft in the other session"
        f.probe.release("first")
        try await wait { f.probe.continuations["urgent"] != nil }
        #expect(f.model.activeSessionId == other && f.model.inputText == "Unsent draft in the other session")
        #expect(f.probe.requests.filter { $0.sessionID == id }.map(\.taskRequest) == ["first", "urgent"])
        #expect(f.probe.requests.last?.settings.resourceContext?.excludesMemory == true)
        let saved = try #require(try await f.service.fetch(id: id))
        #expect(saved.messages[1].runStatus == .cancelled)
        #expect(saved.messages.filter { $0.role == .user }.map(\.content) == ["first", "urgent"])
        f.probe.release("urgent")
        try await wait { f.probe.requests.count == 4 && !f.model.isAnyRunning }
        #expect(f.probe.requests.filter { $0.sessionID == id }.map(\.taskRequest) == ["first", "urgent", "queued-one"])
        #expect(f.model.session(id: other)?.messages.filter { $0.role == .user }.map(\.content) == ["other-session"])
    }

    @Test("A full queue retains rejected drafts but still accepts an immediate message")
    func fullQueue() async throws {
        let f = try await fixture(held: ["first"])
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        f.model.inputText = "first"; f.model.send()
        try await wait { f.probe.continuations["first"] != nil }
        for index in 0..<ChatViewModel.ChatSendQueue.limit {
            f.model.inputText = "queued-\(index)"; f.model.send()
        }
        #expect(f.model.isQueueFull && !f.model.canSendAfterCurrent && f.model.canSendImmediately)
        f.model.inputText = "urgent"; f.model.send()
        #expect(f.model.inputText == "urgent")
        f.model.send(mode: .immediate)
        #expect(f.model.inputText.isEmpty && f.model.activeImmediateSend?.text == "urgent")
        #expect(f.model.activeQueue.count == ChatViewModel.ChatSendQueue.limit)
        // Clearing cancels the reserved intent too; cancellation completion must not resurrect it.
        f.model.clearQueue()
        f.probe.release("first")
        try await wait { f.model.currentRunID == nil }
        #expect(f.probe.requests.count == 1 && f.model.activeImmediateSend == nil && f.model.activeQueue.isEmpty)
    }

    @Test("A failed cancellation save retains the immediate message and resumes only after a successful save retry")
    func failedSave() async throws {
        let f = try await fixture(held: ["first"])
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        f.model.inputText = "first"; f.model.send()
        try await wait { f.probe.continuations["first"] != nil }
        try await f.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_cancel_save BEFORE INSERT ON chat_messages BEGIN SELECT RAISE(FAIL,'fixture'); END")
        }
        f.model.inputText = "urgent"; f.model.send(mode: .immediate)
        f.probe.release("first")
        try await wait { f.model.currentRunID == nil }
        #expect(f.model.isActiveSessionPersistFailed && f.model.activeImmediateSend?.text == "urgent")
        #expect(f.probe.requests.count == 1)
        let id = try #require(f.model.activeSessionId)
        let cancelledAnswer = try #require(f.model.session(id: id)?.messages.last)
        #expect(!f.model.canEditAnswers(in: id))
        f.model.retryAnswer(messageId: cancelledAnswer.id)
        #expect(f.model.currentRunID == nil && f.model.activeImmediateSend?.text == "urgent")
        f.model.dequeueNext()
        #expect(f.probe.requests.count == 1)
        try await f.queue.write { try $0.execute(sql: "DROP TRIGGER fail_cancel_save") }
        await f.model.retryPersistActiveSession()
        try await wait { f.probe.requests.count == 2 && f.model.currentRunID == nil }
        #expect(f.model.activeImmediateSend == nil && !f.model.isActiveSessionPersistFailed)
        let sessionID = try #require(f.model.activeSessionId)
        let saved = try #require(try await f.service.fetch(id: sessionID))
        #expect(saved.messages.filter { $0.role == .user }.map(\.content) == ["first", "urgent"])
        #expect(saved.messages[1].runStatus == .cancelled)
    }

    @Test("An ordinary stop preserves and freezes queued messages")
    func ordinaryStop() async throws {
        let f = try await fixture(held: ["first"])
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        f.model.inputText = "first"; f.model.send()
        try await wait { f.probe.continuations["first"] != nil }
        f.model.inputText = "queued"; f.model.send()
        f.model.stop(); f.probe.release("first")
        try await wait { f.model.currentRunID == nil }
        #expect(f.probe.requests.count == 1 && f.model.activeQueue.map(\.text) == ["queued"])
        f.model.dequeueNext()
        try await wait { f.probe.requests.count == 2 && f.model.currentRunID == nil }
    }

    @Test("A reply finishing during an immediate-send click dispatches the new message exactly once after its save")
    func finishingRace() async throws {
        let f = try await fixture(held: ["urgent"])
        let id = try #require(f.model.activeSessionId)
        let gate = SendSaveGate()
        defer { gate.release(); f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        try await f.queue.write { db in
            db.add(function: DatabaseFunction("hold_send_save", argumentCount: 0) { _ in gate.enterOnce(); return 1 })
            try db.execute(sql: """
                CREATE TRIGGER hold_finished BEFORE INSERT ON chat_messages
                WHEN json_extract(NEW.payload, '$.runStatus') = 'succeeded'
                BEGIN SELECT hold_send_save(); END
                """)
        }
        f.model.inputText = "first"; f.model.send()
        try await wait { gate.entered }
        let oldRun = try #require(f.model.currentRunID)
        #expect(!f.model.isRunningHere && f.model.hasUnfinishedTurnHere && f.model.isAnyRunning)
        f.model.inputText = "urgent"; f.model.send(mode: .immediate)
        #expect(f.probe.requests.count == 1 && f.model.currentRunID == oldRun)
        gate.release()
        try await wait { f.probe.continuations["urgent"] != nil }
        #expect(f.probe.requests.map(\.taskRequest) == ["first", "urgent"])
        #expect(f.model.session(id: id)?.messages[1].runStatus == .succeeded)
        f.probe.release("urgent")
        try await wait { f.model.currentRunID == nil }
        #expect(f.model.session(id: id)?.messages.filter { $0.role == .user && $0.content == "urgent" }.count == 1)
    }

    @Test("A background conversation shows its own manual approval badge with either review setting", arguments: [false, true])
    func backgroundApprovalBadge(autoReview: Bool) async throws {
        let f = try await fixture(held: ["approval"], autoReview: autoReview)
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        let source = try #require(f.model.activeSessionId)
        f.model.inputText = "approval"
        f.model.send()
        try await wait { f.probe.continuations["approval"] != nil }
        f.model.newSession()
        let other = try #require(f.model.activeSessionId)
        #expect(!f.model.isAwaitingApproval(source))

        f.probe.release("approval")
        try await wait { f.model.isAwaitingApproval(source) }
        #expect(!f.model.isAutoReviewing(sessionId: source))
        #expect(!f.model.isAwaitingApproval(other))
        #expect(f.model.pendingConfirmation == nil)

        f.model.activeSessionId = source
        #expect(f.model.isAwaitingApproval(source))
        f.model.confirmPending(approved: true)
        #expect(!f.model.isAwaitingApproval(source))
        try await wait { f.model.currentRunID == nil }
        #expect(await f.probe.calls.value == 1)
    }

    @Test("Approval waits accept queued messages and can be interrupted without approving the old tool", arguments: [false, true])
    func suspendedApproval(immediate: Bool) async throws {
        let f = try await fixture(held: ["urgent"])
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        f.model.inputText = "approval"; f.model.send()
        try await wait { f.model.pendingConfirmation != nil && !f.model.isRunningHere }
        #expect(f.model.hasUnfinishedTurnHere && !f.model.canResumeSendQueue)
        f.model.inputText = "urgent"
        f.model.send(mode: immediate ? .immediate : .afterCurrent)
        if !immediate {
            #expect(f.model.pendingConfirmation != nil && f.probe.requests.count == 1)
            #expect(f.model.activeQueue.map(\.text) == ["urgent"])
            f.model.confirmPending(approved: false, alwaysAllow: false, persistRule: false)
        }
        try await wait { f.probe.continuations["urgent"] != nil }
        f.model.confirmPending(approved: true, alwaysAllow: true, persistRule: true) // Stale approval has no effect.
        let executions = await f.probe.calls.value
        #expect(f.model.pendingConfirmation == nil && executions == 0)
        let sessionID = try #require(f.model.activeSessionId)
        #expect(!f.model.isAwaitingApproval(sessionID))
        let saved = try #require(try await f.service.fetch(id: sessionID))
        #expect(saved.pendingConfirmation == nil)
        if immediate { #expect(saved.messages[1].runStatus == .cancelled) }
        f.probe.release("urgent")
        try await wait { f.model.currentRunID == nil }
    }

    @Test("An immediate user message cancels a question wait and keeps the remaining queue")
    func suspendedQuestion() async throws {
        let f = try await fixture(held: ["urgent"])
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        let id = try #require(f.model.activeSessionId)
        f.model.inputText = "question"; f.model.send()
        try await wait { f.model.pendingQuestion != nil && !f.model.isRunningHere }
        #expect(!f.model.isAwaitingApproval(id))
        f.model.inputText = "queued"; f.model.send()
        #expect(f.model.sendQueueStatus == L.string("chat.queue.waiting_input") && !f.model.canResumeSendQueue)
        f.model.inputText = "urgent"; f.model.send(mode: .immediate)
        try await wait { f.probe.continuations["urgent"] != nil }
        #expect(f.model.pendingQuestion == nil && f.model.activeQueue.map(\.text) == ["queued"])
        f.model.answerQuestion(.init(values: ["choice": .text("A")]))
        let saved = try #require(try await f.service.fetch(id: id))
        #expect(saved.pendingQuestion == nil && saved.messages[1].runStatus == .cancelled)
        f.probe.release("urgent")
        try await wait { f.probe.requests.count == 3 && f.model.currentRunID == nil }
    }

    @Test("Immediate sending pauses an active goal before starting the user turn")
    func interruptGoal() async throws {
        let f = try await fixture(held: ["goal-segment", "urgent"])
        defer { f.probe.releaseAll(); try? FileManager.default.removeItem(at: f.root) }
        let id = try #require(f.model.activeSessionId)
        let definition = GoalDefinition(title: "Fixture goal", objective: "Collect the supplied evidence", criteria: [.init(text: "Review the evidence")])
        #expect(await f.model.startGoal(definition, expectedSessionID: id))
        try await wait { f.probe.continuations["goal-segment"] != nil }
        f.model.inputText = "urgent"; f.model.send(mode: .immediate)
        f.probe.release("goal-segment")
        try await wait { f.probe.continuations["urgent"] != nil }
        #expect(f.model.activeGoal?.status == .paused && f.model.activeGoal?.attemptCount == 1)
        #expect(f.probe.requests.count == 2 && f.probe.requests.last?.goalProgress == nil)
        f.probe.release("urgent")
        try await wait { f.model.currentRunID == nil }
        #expect(f.probe.requests.count == 2)
    }

    @Test("Priority release is bound to both session and run; failure keeps the reserved message and its attachments")
    func priorityIdentityAndRollback() {
        var queue = ChatViewModel.ChatSendQueue()
        let session = UUID(), other = UUID(), run = ChatRunID()
        let attachment = URL(fileURLWithPath: "/private/tmp/synthetic-chat-send.txt")
        let urgent = ChatViewModel.QueuedMessage(text: "urgent", attachments: [attachment], engineInstruction: nil)
        queue.enqueue(.init(text: "ordinary", attachments: [], engineInstruction: nil), for: session)
        let accepted = queue.requestImmediate(urgent, for: session, after: run)
        #expect(accepted)
        queue.releaseImmediate(for: other, after: run)
        queue.releaseImmediate(for: session, after: ChatRunID())
        #expect(queue.reserveNext(for: session) == nil)
        #expect(queue.attachmentURLs.contains(attachment))
        queue.releaseImmediate(for: session, after: run)
        #expect(queue.reserveNext(for: session)?.id == urgent.id)
        queue.rollbackReservation(for: session)
        #expect(queue.immediate(for: session)?.message.id == urgent.id)
        #expect(queue.reserveNext(for: session)?.id == urgent.id)
        queue.commitReservation(for: session)
        #expect(queue.reserveNext(for: session)?.text == "ordinary")
    }

    @Test("Queue controls render in three languages at narrow and wide sizes")
    func nativePresentation() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AGROOM_CHAT_SEND_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        let items = [ChatViewModel.QueuedMessage(text: "Compare the two reports and list the differences", attachments: [], engineInstruction: nil),
                     ChatViewModel.QueuedMessage(text: "继续检查这份资料", attachments: [], engineInstruction: nil)]
        let urgent = ChatViewModel.QueuedMessage(text: "Use the corrected date for this request", attachments: [], engineInstruction: nil)
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for width in [420.0, 760.0] {
                for stopping in [false, true] {
                    for dark in [false, true] {
                        let card = QueuedMessagesCard(items: items, immediateItem: stopping ? urgent : nil,
                            isRunning: true, isFull: false,
                            statusText: stopping ? L.string("chat.queue.stopping_then_send") : nil,
                            canSendImmediately: !stopping, canResume: false,
                            onRemove: { _ in }, onClear: {}, onSendNext: {}, onSendImmediately: { _ in })
                        let content = card.padding(16).frame(width: width, height: 190, alignment: .top)
                            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
                        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 190),
                            styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.contentView = NSHostingView(rootView: content)
                        window.orderFront(nil)
                        try await Task.sleep(for: .milliseconds(100))
                        let view = try #require(window.contentView)
                        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let name = "queue-\(language.rawValue)-\(Int(width))-\(stopping ? "stopping" : "running")-\(dark ? "dark" : "light").png"
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                        window.close()
                    }
                }
            }
        }
    }
}

private final class SendSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    var entered: Bool { lock.withLock { started } }
    func enterOnce() {
        let first = lock.withLock { if started { return false }; started = true; return true }
        if first { _ = semaphore.wait(timeout: .now() + 10) }
    }
    func release() { semaphore.signal() }
}

private actor CallCounter {
    var value = 0
    func increment() { value += 1 }
}

private struct ApprovalTool: DispatcherTool {
    let calls: CallCounter
    var definition: ToolDefinition {
        .init(name: "fixture_write", description: "Synthetic confirmation", parametersSchemaJSON: #"{"type":"object","properties":{}}"#)
    }
    var requiresConfirmation: Bool { true }
    func execute(argumentsJSON: String) async throws -> String { await calls.increment(); return "written" }
}

private final class SendFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chat-send.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let messages = object["messages"] as? [[String: Any]] ?? []
            let scenario = request.value(forHTTPHeaderField: "X-Send-Scenario") ?? ""
            let needsCall = ["approval", "question"].contains(scenario) && !messages.contains { $0["role"] as? String == "tool" }
            let arguments = scenario == "question"
                ? #"{"title":"Choice","prompt":"Choose one","fields":[{"id":"choice","label":"Choice","type":"single_choice","options":["A","B"]}]}"# : "{}"
            let delta: [String: Any] = needsCall
                ? ["tool_calls": [["index": 0, "id": "call-1", "type": "function", "function": ["name": scenario == "question" ? "ask_user" : "fixture_write", "arguments": arguments]]]]
                : ["content": "Fixture reply"]
            let event: [String: Any] = ["choices": [["index": 0, "delta": delta, "finish_reason": needsCall ? "tool_calls" : "stop"]],
                                       "usage": ["prompt_tokens": 10, "completion_tokens": 3]]
            let body = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
