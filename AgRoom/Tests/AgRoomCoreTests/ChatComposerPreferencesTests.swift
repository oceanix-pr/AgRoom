import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Chat composer preferences")
struct ChatComposerPreferencesTests {
    private func service() throws -> ProductPreferencesService {
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        return ProductPreferencesService(databaseQueue: queue)
    }

    private func snapshot(_ prompt: String) -> ChatComposerPreferencesSnapshot {
        ChatComposerPreferencesSnapshot(quickPrompts: [prompt])
    }

    @Test("Missing preferences use defaults and each refresh uses its bound space service")
    func defaultsAndSpaceIsolation() async throws {
        let personal = try service(), work = try service()
        let model = ChatComposerPreferencesModel()
        #expect(await model.reload(from: personal, isCurrent: { true }) == nil)
        #expect(model.snapshot == ChatComposerPreferencesSnapshot())

        var budget = ProductTaskBudget()
        budget.enabled = true
        let price = ProductModelPrice(providerID: UUID(), model: "fixture", inputPerMillion: 2)
        try await personal.saveQuickPrompts(["Personal prompt"])
        try await personal.save(budget, key: "task-budget")
        try await personal.save([price], key: "model-prices")
        #expect(await model.reload(from: personal, isCurrent: { true }) == nil)
        #expect(model.snapshot == ChatComposerPreferencesSnapshot(
            quickPrompts: ["Personal prompt"], taskBudget: budget, modelPrices: [price]
        ))
        let workModel = ChatComposerPreferencesModel()
        #expect(await workModel.reload(from: work, isCurrent: { true }) == nil)
        #expect(workModel.snapshot == ChatComposerPreferencesSnapshot())
    }

    @Test("Cancelled reads cannot publish a late value or an alert", arguments: [true, false])
    func cancelledRead(returnsValue: Bool) async {
        let model = ChatComposerPreferencesModel(), pending = ControlledComposerPreferencesRead()
        let original = snapshot("Existing prompt")
        _ = await model.reload(isCurrent: { true }, read: { original })
        let task = Task { await model.reload(isCurrent: { true }, read: { try await pending.read() }) }
        await pending.waitUntilStarted()
        task.cancel()
        pending.finish(returnsValue ? .success(snapshot("Cancelled prompt")) : .failure(privateFailure))
        #expect(await task.value == nil)
        #expect(model.snapshot == original)
    }

    @Test("A cancellation error is not a user-facing storage failure")
    func cancellationError() async {
        let model = ChatComposerPreferencesModel()
        #expect(await model.reload(isCurrent: { true }, read: { throw CancellationError() }) == nil)
        #expect(model.snapshot == ChatComposerPreferencesSnapshot())
    }

    @Test("An older refresh cannot replace the latest value or show its error", arguments: [true, false])
    func supersededRead(returnsValue: Bool) async {
        let model = ChatComposerPreferencesModel(), pending = ControlledComposerPreferencesRead()
        let old = Task { await model.reload(isCurrent: { true }, read: { try await pending.read() }) }
        await pending.waitUntilStarted()
        let latest = snapshot("Latest prompt")
        #expect(await model.reload(isCurrent: { true }, read: { latest }) == nil)
        pending.finish(returnsValue ? .success(snapshot("Old prompt")) : .failure(privateFailure))
        #expect(await old.value == nil)
        #expect(model.snapshot == latest)
    }

    @Test("Leaving the page or changing space invalidates pending replies", arguments: [true, false])
    func leftContext(invalidatePage: Bool) async {
        let model = ChatComposerPreferencesModel(), pending = ControlledComposerPreferencesRead()
        var current = true
        let task = Task { await model.reload(isCurrent: { current }, read: { try await pending.read() }) }
        await pending.waitUntilStarted()
        if invalidatePage { model.invalidate() } else { current = false }
        pending.finish(.failure(privateFailure))
        #expect(await task.value == nil)
        #expect(model.snapshot == ChatComposerPreferencesSnapshot())
    }

    @Test("Saving a budget prevents an older refresh from reverting it")
    func savedBudgetWins() async {
        let model = ChatComposerPreferencesModel(), pending = ControlledComposerPreferencesRead()
        let task = Task { await model.reload(isCurrent: { true }, read: { try await pending.read() }) }
        await pending.waitUntilStarted()
        var budget = ProductTaskBudget()
        budget.enabled = true
        budget.maxTokens = 42_000
        model.updateTaskBudget(budget)
        pending.finish(.success(ChatComposerPreferencesSnapshot()))
        #expect(await task.value == nil)
        #expect(model.snapshot.taskBudget == budget)
    }

    @Test("A real budget decoding failure preserves the entire snapshot and private stored data")
    func genuineReadFailure() async throws {
        let preferences = try service(), model = ChatComposerPreferencesModel()
        try await preferences.saveQuickPrompts(["Original prompt"])
        #expect(await model.reload(from: preferences, isCurrent: { true }) == nil)
        let original = model.snapshot
        let privateValue = "PRIVATE-PREFERENCE-CONTENT"
        try await preferences.saveQuickPrompts(["New prompt"])
        try await preferences.save(privateValue, key: "task-budget")
        let error = await model.reload(from: preferences, isCurrent: { true })
        #expect(error == L.string("product.chat.preferences.load.failed"))
        #expect(error?.contains(privateValue) == false)
        #expect(model.snapshot == original)
        #expect(try await preferences.load(String.self, key: "task-budget") == privateValue)
        let log = try #require(HubLogger.shared.entries.last { $0.message.hasPrefix("Chat preferences load failed:") })
        #expect(!log.message.contains(privateValue))
    }

    private var privateFailure: NSError {
        NSError(domain: "PrivatePreferenceFailure", code: 73,
                userInfo: [NSLocalizedDescriptionKey: "PRIVATE-PREFERENCE-CONTENT"])
    }
}

/// Controlled suspension without blocking the main actor or a database queue.
@MainActor
private final class ControlledComposerPreferencesRead {
    private var continuation: CheckedContinuation<ChatComposerPreferencesSnapshot, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func read() async throws -> ChatComposerPreferencesSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ result: Result<ChatComposerPreferencesSnapshot, any Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
