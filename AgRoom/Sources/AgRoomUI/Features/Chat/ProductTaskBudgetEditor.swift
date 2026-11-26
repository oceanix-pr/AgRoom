import SwiftUI
import AgRoomCore

struct ProductTaskBudgetEditor: View {
    let service: ProductPreferencesService?
    let price: ProductModelPrice?
    let imageModel: Bool
    let onSaved: (ProductTaskBudget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProductTaskBudget
    @State private var saving = false
    @State private var errorText: String?

    init(service: ProductPreferencesService?, initial: ProductTaskBudget, price: ProductModelPrice? = nil, imageModel: Bool = false, onSaved: @escaping (ProductTaskBudget) -> Void) {
        self.service = service; self.onSaved = onSaved
        self.price = price
        self.imageModel = imageModel
        self._draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string("product.budget.title")).font(.title2.bold())
            Toggle(L.string("product.budget.enabled"), isOn: $draft.enabled)
            Form {
                TextField(L.string("product.budget.tokens"), value: $draft.maxTokens, format: .number)
                TextField(L.string("product.budget.tools"), value: $draft.maxToolCalls, format: .number)
                TextField(L.string("product.budget.minutes"), value: $draft.minutes, format: .number)
            }.disabled(!draft.enabled || saving)
            if draft.enabled, draft != draft.normalized {
                Text(L.string("product.budget.range")).font(.caption).foregroundStyle(.orange)
            }
            if imageModel {
                Text(L.string("chat.image.budget_hint")).font(.caption).foregroundStyle(.secondary)
            } else if draft.enabled, let price, price.isValid {
                let upper = Double(draft.normalized.maxTokens) * max(price.inputPerMillion, price.outputPerMillion) / 1_000_000
                Text(L.format("product.budget.price", price.currency + " " + String(format: "%.4f", upper))).font(.callout)
            } else { Text(L.string("product.budget.price.unknown")).font(.caption).foregroundStyle(.secondary) }
            Text(L.string("product.budget.help")).font(.caption).foregroundStyle(.secondary)
            if let errorText { Text(errorText).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }.disabled(saving)
                Button(L.string("common.save")) {
                    saving = true
                    Task {
                        do {
                            guard let service else { throw SpaceServiceError.encodingFailed }
                            let value = draft.normalized
                            try await service.save(value, key: "task-budget")
                            onSaved(value); dismiss()
                        } catch { errorText = L.string("error.database"); saving = false }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || (draft.enabled && draft != draft.normalized))
            }
        }.padding(24).frame(width: 520)
    }
}
