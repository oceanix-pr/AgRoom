import Foundation
import Observation
import AgRoomCore

struct ProductModelPriceDraft: Identifiable {
    let providerID: UUID
    let model: String
    var currency: String
    var input: String
    var output: String
    var imageInput: String
    var cachedTextInput: String
    var cachedImageInput: String
    var saved: ProductModelPrice?
    var isImage: Bool { CloudProvider.isImageGenerationModel(model) || saved?.imageRates != nil }
    var id: String { providerID.uuidString + ":" + model }

    init(target: ProductModelPrice, saved: ProductModelPrice?) {
        providerID = target.providerID; model = target.model
        self.saved = saved
        currency = saved?.currency ?? ProductModelPrice.defaultCurrency
        input = saved.map { String($0.imageRates?.textInputPerMillion ?? $0.inputPerMillion) } ?? ""
        output = saved.map { String($0.imageRates?.imageOutputPerMillion ?? $0.outputPerMillion) } ?? ""
        imageInput = saved?.imageRates.map { String($0.imageInputPerMillion) } ?? ""
        cachedTextInput = saved?.imageRates?.cachedTextInputPerMillion.map(String.init(describing:)) ?? ""
        cachedImageInput = saved?.imageRates?.cachedImageInputPerMillion.map(String.init(describing:)) ?? ""
    }

    var isEdited: Bool {
        let original = ProductModelPriceDraft(target: ProductModelPrice(providerID: providerID, model: model), saved: saved)
        return currency != original.currency || input != original.input || output != original.output
            || imageInput != original.imageInput || cachedTextInput != original.cachedTextInput || cachedImageInput != original.cachedImageInput
    }

    var isEmpty: Bool {
        [input, output, imageInput, cachedTextInput, cachedImageInput].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var value: ProductModelPrice? {
        if !isEdited { return saved }
        guard let input = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let output = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var rates: ProductImageTokenPrices?
        if isImage {
            guard let imageInput = Double(imageInput.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            func optionalRate(_ value: String) -> Double? { Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard [cachedTextInput, cachedImageInput].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || optionalRate($0) != nil }) else { return nil }
            rates = .init(textInputPerMillion: input, imageInputPerMillion: imageInput, imageOutputPerMillion: output,
                cachedTextInputPerMillion: optionalRate(cachedTextInput), cachedImageInputPerMillion: optionalRate(cachedImageInput))
        }
        let price = ProductModelPrice(providerID: providerID, model: model, currency: currency,
            inputPerMillion: input, outputPerMillion: output, imageRates: rates)
        return price.isValid ? price : nil
    }

    var isValid: Bool { isEmpty || value != nil }
}

/// One view instance owns one fixed-space preferences service. Late catalog replies
/// are discarded, and edits typed while a lookup runs remain manual drafts.
@MainActor @Observable
final class ProductCostModel {
    private let service: ProductPreferencesService?
    private let pricing: ModelPricingService
    private var generation = UUID()
    private var attempted = Set<String>()
    private var dismissedIDs = Set<String>()
    private(set) var prices: [ProductModelPrice] = []
    var drafts: [ProductModelPriceDraft] = []
    private(set) var loading = false
    private(set) var fetching = false
    private(set) var saving = false
    private(set) var fetchFailed = false
    private(set) var errorKey: String?

    init(service: ProductPreferencesService?, pricing: ModelPricingService = ModelPricingService()) {
        self.service = service
        self.pricing = pricing
    }

    var canSave: Bool {
        !loading && !fetching && !saving && drafts.allSatisfy(\.isValid)
            && drafts.compactMap(\.value).sorted { $0.id < $1.id } != prices.sorted { $0.id < $1.id }
    }

    func canDelete(id: String) -> Bool {
        service != nil && !loading && !fetching && !saving && drafts.contains { $0.id == id }
    }

    var canRestoreDeleted: Bool { !loading && !fetching && !saving && !dismissedIDs.isEmpty }
    var hasDeletedModels: Bool { !dismissedIDs.isEmpty }

    func loadAndFill(providers: [LLMProviderConfig], targets: [ProductModelPrice], refresh: Bool = false) async {
        let ticket = UUID()
        generation = ticket; loading = true; fetching = false; saving = false
        defer { if generation == ticket { loading = false; fetching = false } }
        guard let service else { errorKey = "error.database"; return }
        do {
            let snapshot = try await service.loadModelPrices()
            guard isCurrent(ticket) else { return }
            let saved = snapshot.prices
            prices = saved
            dismissedIDs = snapshot.dismissedIDs
            let configs = providers.reduce(into: [UUID: LLMProviderConfig]()) { $0[$1.id] = $1 }
            let applicable = saved.filter { price in
                !dismissedIDs.contains(price.id) && configs[price.providerID].map { price.applies(to: $0) } != false
            }
            if applicable != saved {
                await persist(applicable, ticket: ticket)
                guard isCurrent(ticket), errorKey == nil else { return }
            }
            updateDrafts(targets: targets)
            loading = false; errorKey = nil
            let candidates = drafts.filter { draft in
                guard !draft.isEdited, let provider = configs[draft.providerID] else { return false }
                if let saved = draft.saved {
                    guard saved.source != nil else { return false }
                    let age = saved.fetchedAt.map { Date().timeIntervalSince($0) } ?? .infinity
                    guard refresh || (draft.isImage && saved.imageRates == nil) || age >= 86_400 || age < 0 else { return false }
                }
                return refresh || !attempted.contains(attemptKey(draft.id, provider))
            }
            guard !candidates.isEmpty else { return }
            fetching = true; fetchFailed = false
            let result = try await pricing.prices(for: candidates.map {
                ProductModelPrice(providerID: $0.providerID, model: $0.model)
            }, providers: providers)
            guard isCurrent(ticket) else { return }
            for draft in candidates {
                if let provider = configs[draft.providerID] { attempted.insert(attemptKey(draft.id, provider)) }
            }
            fetchFailed = !result.failedIDs.isEmpty
            var merged = prices.reduce(into: [String: ProductModelPrice]()) { $0[$1.id] = $1 }
            for price in result.prices {
                guard let draft = drafts.first(where: { $0.id == price.id }), !draft.isEdited,
                      draft.saved == nil || draft.saved?.source != nil else { continue }
                merged[price.id] = price
            }
            let values = merged.values.sorted { $0.id < $1.id }
            if values != prices.sorted(by: { $0.id < $1.id }) { await persist(values, ticket: ticket) }
        } catch {
            guard isCurrent(ticket) else { return }
            errorKey = "error.database"
        }
    }

    func save() async {
        guard canSave else { return }
        await persist(drafts.compactMap(\.value), ticket: generation)
    }

    func delete(id: String) async {
        guard canDelete(id: id) else { return }
        await persist(prices.filter { $0.id != id }, dismissedIDs: dismissedIDs.union([id]), ticket: generation)
    }

    func restoreDeleted(providers: [LLMProviderConfig], targets: [ProductModelPrice]) async {
        guard canRestoreDeleted else { return }
        let ticket = generation
        await persist(prices, dismissedIDs: [], ticket: ticket)
        guard isCurrent(ticket), errorKey == nil else { return }
        await loadAndFill(providers: providers, targets: targets, refresh: true)
    }

    func invalidate() {
        generation = UUID()
        loading = false; fetching = false; saving = false
    }

    private func persist(_ values: [ProductModelPrice], dismissedIDs nextDismissed: Set<String>? = nil, ticket: UUID) async {
        guard let service, isCurrent(ticket) else { return }
        let updatedDismissedIDs = nextDismissed ?? dismissedIDs
        saving = true
        defer { if generation == ticket { saving = false } }
        do {
            try await service.saveModelPrices(values, replacing: prices,
                dismissedIDs: updatedDismissedIDs, replacingDismissedIDs: dismissedIDs)
            guard isCurrent(ticket) else { return }
            prices = values
            dismissedIDs = updatedDismissedIDs
            drafts.removeAll { updatedDismissedIDs.contains($0.id) }
            // Automatic lookups only reach unedited rows; other unsaved edits survive.
            for index in drafts.indices {
                let old = drafts[index]
                let saved = values.first { $0.id == old.id }
                if old.value == saved || !old.isEdited {
                    drafts[index] = ProductModelPriceDraft(target: ProductModelPrice(providerID: old.providerID, model: old.model), saved: saved)
                } else {
                    drafts[index].saved = saved
                }
            }
            errorKey = nil
        } catch is ModelPriceConflict {
            guard isCurrent(ticket) else { return }
            errorKey = "product.price.conflict"
        } catch {
            guard isCurrent(ticket) else { return }
            errorKey = "error.database"
        }
    }

    private func updateDrafts(targets: [ProductModelPrice]) {
        var rows = (targets + prices).reduce(into: [String: ProductModelPrice]()) { $0[$1.id] = $1 }
        for draft in drafts where draft.isEdited {
            rows[draft.id] = ProductModelPrice(providerID: draft.providerID, model: draft.model)
        }
        let old = drafts.reduce(into: [String: ProductModelPriceDraft]()) { $0[$1.id] = $1 }
        drafts = rows.values.filter { !dismissedIDs.contains($0.id) }.sorted { $0.id < $1.id }.map { target in
            let saved = prices.first { $0.id == target.id }
            if var draft = old[target.id], draft.isEdited {
                draft.saved = saved
                return draft
            }
            return ProductModelPriceDraft(target: target, saved: saved)
        }
    }

    private func isCurrent(_ ticket: UUID) -> Bool { generation == ticket && !Task.isCancelled }
    private func attemptKey(_ id: String, _ provider: LLMProviderConfig) -> String { id + "|" + provider.endpoint }
}
