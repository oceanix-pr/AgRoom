import Foundation
import Observation
import AgRoomCore

struct ChatComposerPreferencesSnapshot: Equatable, Sendable {
    var quickPrompts: [String] = []
    var taskBudget = ProductTaskBudget()
    var modelPrices: [ProductModelPrice] = []
}

/// One chat view owns its snapshot. Leaving the page invalidates both successful
/// replies and failures, even when the same cached chat model is opened again.
@MainActor @Observable
final class ChatComposerPreferencesModel {
    private(set) var snapshot = ChatComposerPreferencesSnapshot()
    @ObservationIgnored private var loadID: UUID?

    func reload(from service: ProductPreferencesService, isCurrent: () -> Bool) async -> String? {
        await reload(isCurrent: isCurrent) {
            let prompts = try await service.quickPrompts()
            let budget = try await service.load(ProductTaskBudget.self, key: "task-budget") ?? ProductTaskBudget()
            let prices = try await service.load([ProductModelPrice].self, key: "model-prices") ?? []
            return ChatComposerPreferencesSnapshot(quickPrompts: prompts, taskBudget: budget, modelPrices: prices)
        }
    }

    func reload(isCurrent: () -> Bool, read: @MainActor () async throws -> ChatComposerPreferencesSnapshot) async -> String? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        let ticket = UUID()
        loadID = ticket
        do {
            let value = try await read()
            guard !Task.isCancelled, loadID == ticket, isCurrent() else { return nil }
            if snapshot != value { snapshot = value }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, loadID == ticket, isCurrent() else { return nil }
            HubLogger.shared.warning("Chat preferences load failed: \(HubLogger.safeErrorSummary(error))")
            return L.actionableError(error, fallbackKey: "product.chat.preferences.load.failed")
        }
    }

    func updateTaskBudget(_ value: ProductTaskBudget) {
        invalidate()
        snapshot.taskBudget = value
    }

    func invalidate() {
        loadID = nil
    }
}
