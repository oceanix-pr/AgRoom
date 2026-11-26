import SwiftUI
import AgRoomCore

struct ProductCostView: View {
    let models: [UsageModelGroup]
    let providers: [LLMProviderConfig]
    let interval: DateInterval?
    let revision: UUID?
    @State private var model: ProductCostModel
    @State private var accounting: ProductCostAccountingModel
    @State private var refreshID: UUID?
    @State private var appliedRefreshID: UUID?
    @State private var configuring: Bool
    @State private var showingEstimateHelp = false
    @State private var showingUnsupported = false

    init(service: ProductPreferencesService?, models: [UsageModelGroup], providers: [LLMProviderConfig],
         pricing: ModelPricingService = ModelPricingService(), initiallyExpanded: Bool = false,
         usageService: UsageService? = nil, interval: DateInterval? = nil, revision: UUID? = nil,
         balanceFetcher: @escaping ProductCostAccountingModel.BalanceFetcher = ProductCostAccountingModel.fetchLiveBalance) {
        self.models = models; self.providers = providers
        self.interval = interval; self.revision = revision
        _model = State(initialValue: ProductCostModel(service: service, pricing: pricing))
        _accounting = State(initialValue: ProductCostAccountingModel(service: usageService, fetchBalance: balanceFetcher))
        _configuring = State(initialValue: initiallyExpanded)
    }

    private var targets: [ProductModelPrice] {
        var values: [String: ProductModelPrice] = [:]
        for provider in providers where !provider.model.isEmpty {
            let price = ProductModelPrice(providerID: provider.id, model: provider.model)
            values[price.id] = price
        }
        for group in models {
            guard let raw = group.id.providerID, let id = UUID(uuidString: raw) else { continue }
            let price = ProductModelPrice(providerID: id, model: group.model)
            values[price.id] = price
        }
        return values.values.sorted { $0.id < $1.id }
    }

    private var totals: (amounts: [String: Double], unknown: Int) {
        if accounting.isAvailable {
            return (accounting.snapshot?.amounts ?? [:], accounting.snapshot?.unknownGroups ?? 0)
        }
        var amounts: [String: Double] = [:]
        var unknown = 0
        for group in models {
            guard let price = model.prices.first(where: { $0.providerID.uuidString == group.id.providerID && $0.model == group.model }),
                  providers.first(where: { $0.id == price.providerID }).map({ price.applies(to: $0) }) != false,
                  group.reportedInputRecords == group.records, group.reportedOutputRecords == group.records,
                  let value = price.estimate(usage: group.imageUsage) else { unknown += 1; continue }
            amounts[price.currency, default: 0] += value
        }
        return (amounts, unknown)
    }

    var body: some View {
        let cost = totals
        let spend = spentSection(cost.amounts)
        let balances = remainingSection
        VStack(alignment: .leading, spacing: MeetSpacing.lg) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    heading
                    Spacer()
                    costControls
                }
                VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                    heading
                    costControls
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: MeetSpacing.xl) {
                    spend.frame(minWidth: 180, idealWidth: 220, maxWidth: 240)
                    balances.frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: MeetSpacing.lg) {
                    spend
                    balances
                }
            }
            if cost.unknown > 0 {
                Label {
                    Text(L.format("product.price.unknown", cost.unknown)).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(MeetTypography.secondary)
            }
            if model.fetchFailed {
                Text(L.string("product.price.fetch.failed")).font(.caption).foregroundStyle(.orange)
            }
            if let key = model.errorKey { Text(L.string(key)).font(.caption).foregroundStyle(.red) }
            if let key = accounting.errorKey { Text(L.string(key)).font(.caption).foregroundStyle(.red) }
            Divider()
            DisclosureGroup(L.string("product.price.configure"), isExpanded: $configuring) {
                rateEditor
            }
        }
        .padding(MeetSpacing.lg).frame(maxWidth: .infinity, alignment: .leading).meetCard()
        .task(id: LookupKey(providers: providers, targetIDs: targets.map(\.id), refreshID: refreshID)) {
            let refresh = refreshID != appliedRefreshID
            appliedRefreshID = refreshID
            await model.loadAndFill(providers: providers, targets: targets, refresh: refresh)
        }
        .task(id: AccountingKey(providers: providers, prices: model.prices, interval: interval, revision: revision)) {
            await accounting.load(prices: model.prices, providers: providers, interval: interval)
        }
        .onDisappear { model.invalidate(); accounting.invalidate() }
    }

    private var heading: some View {
        HStack(spacing: MeetSpacing.sm) {
            Text(L.string("product.price.title")).font(MeetTypography.sectionTitle)
            Button {
                showingEstimateHelp.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L.string("product.cost.estimate.help"))
            .accessibilityLabel(L.string("product.cost.estimate.help"))
            .popover(isPresented: $showingEstimateHelp) {
                VStack(alignment: .leading, spacing: MeetSpacing.md) {
                    Text(L.string("product.cost.estimate.help")).font(MeetTypography.sectionTitle)
                    Text(L.string("product.cost.scope"))
                    Text(L.string("product.price.help"))
                    Text(L.string("product.price.auto.help"))
                }
                .font(MeetTypography.control)
                .padding(MeetSpacing.lg)
                .frame(width: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rateEditor: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            ForEach($model.drafts) { $draft in
                VStack(alignment: .leading, spacing: 6) {
                    Text(providerName(draft.providerID) + " · " + draft.model).font(.callout.bold())
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            currencyPicker($draft.currency)
                            rateFields($draft)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            currencyPicker($draft.currency)
                            rateFields($draft)
                        }
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.string(draft.isImage ? "product.price.image.help" : "product.price.ordinary.help"))
                            if !draft.isEdited, let saved = draft.saved, let source = saved.source {
                                HStack {
                                    Link(L.format("product.price.source", source.name), destination: source.url)
                                        .foregroundStyle(Color.accentColor)
                                    if let date = saved.fetchedAt {
                                        Text(source == .openAIReference
                                            ? L.format("product.price.reference.checked", AppDate.string(from: date))
                                            : AppDate.string(from: date))
                                    }
                                }
                            } else if draft.saved == nil && draft.isEmpty {
                                Text(L.string("product.price.missing"))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L.string("common.delete"), role: .destructive) {
                            let id = draft.id
                            Task { await model.delete(id: id) }
                        }.controlSize(.small)
                            .disabled(!model.canDelete(id: draft.id))
                            .help(L.string("product.price.delete.help"))
                    }
                }
            }
            if model.drafts.isEmpty { Text(L.string("product.price.empty")).font(.caption) }
            if !model.drafts.allSatisfy(\.isValid) { Text(L.string("product.price.invalid")).font(.caption).foregroundStyle(.orange) }
            Button(L.string("common.save")) { Task { await model.save() } }
                .disabled(!model.canSave)
            if model.hasDeletedModels {
                Button(L.string("product.price.restore.deleted")) {
                    Task { await model.restoreDeleted(providers: providers, targets: targets) }
                }.disabled(!model.canRestoreDeleted)
            }
        }.padding(.top, 8).disabled(model.loading || model.saving)
    }

    private var remainingSection: some View {
        let enabled = Dictionary(grouping: providers.filter(\.isEnabled)) {
            CloudProvider.supportsBalanceQuery(endpoint: $0.endpoint)
        }
        let stored = Dictionary(grouping: accounting.snapshot?.checkpoint?.balances ?? [], by: \.providerID)
        let accounts = (enabled[true] ?? []).map { provider in
            BalanceAccount(provider: provider, balances: (stored[provider.id] ?? [])
                .filter { $0.applies(to: provider) }.sorted { $0.currency < $1.currency })
        }
        let dates = Set(accounts.flatMap(\.balances).map { AppDate.string(from: $0.observedAt) })
        let unsupported = enabled[false] ?? []
        return VStack(alignment: .leading, spacing: MeetSpacing.md) {
            HStack(spacing: MeetSpacing.sm) {
                Text(L.string("product.cost.remaining")).font(MeetTypography.listTitle(weight: .semibold))
                if accounting.refreshingBalances { ProgressView().controlSize(.mini) }
            }
            if !dates.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 152), spacing: MeetSpacing.lg, alignment: .topLeading)],
                          alignment: .leading, spacing: MeetSpacing.md) {
                    ForEach(accounts) { account in
                        balanceReadings(account, showDates: dates.count > 1)
                    }
                }
            } else if !accounts.isEmpty || unsupported.isEmpty {
                Text(L.string(accounts.isEmpty ? "product.cost.balance.noProviders" : "product.cost.remaining.unknown"))
                    .font(MeetTypography.secondary).foregroundStyle(.secondary)
            }
            if dates.count == 1, let date = dates.first {
                Text(L.format("product.cost.balance.updated", date))
                    .font(MeetTypography.caption).foregroundStyle(.secondary)
            }
            if !unsupported.isEmpty {
                DisclosureGroup(L.format("product.cost.balance.unavailableCount", unsupported.count), isExpanded: $showingUnsupported) {
                    unsupportedAccounts(unsupported)
                }.font(MeetTypography.secondary)
            }
        }
    }

    private struct BalanceAccount: Identifiable {
        let provider: LLMProviderConfig
        let balances: [ProductCostBalance]
        var id: UUID { provider.id }
    }

    private func balanceReadings(_ account: BalanceAccount, showDates: Bool) -> some View {
        VStack(alignment: .leading, spacing: MeetSpacing.xs) {
            Text(account.provider.chatDisplayName)
                .font(MeetTypography.secondary).foregroundStyle(.secondary)
                .lineLimit(2).help(account.provider.chatDisplayName)
            ForEach(account.balances) { balance in
                amountLabel(balance.amount, currency: balance.currency, font: MeetTypography.sectionTitle)
                if showDates {
                    Text(L.format("product.cost.balance.updated", AppDate.string(from: balance.observedAt)))
                        .font(MeetTypography.caption).foregroundStyle(.secondary)
                }
            }
            if account.balances.isEmpty {
                Text(L.string("product.cost.balance.noReading")).font(MeetTypography.control).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func unsupportedAccounts(_ configs: [LLMProviderConfig]) -> some View {
        // Configurations sharing an official billing page share its explanation and link.
        let groups = Dictionary(grouping: configs) { CloudProvider.billingManagementURL(endpoint: $0.endpoint) }
        let destinations = groups.keys.sorted { ($0?.absoluteString ?? "") < ($1?.absoluteString ?? "") }
        return VStack(alignment: .leading, spacing: MeetSpacing.md) {
            ForEach(destinations, id: \.self) { url in
                VStack(alignment: .leading, spacing: MeetSpacing.xs) {
                    Text((groups[url] ?? []).map(\.chatDisplayName).joined(separator: " · "))
                        .font(MeetTypography.control)
                    Text(L.string(url == nil ? "product.cost.balance.unsupported" : "product.cost.openai.unsupported"))
                        .foregroundStyle(.secondary)
                    if let url {
                        Link(L.string("product.cost.billing.open"), destination: url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MeetSpacing.sm)
    }

    private func spentSection(_ amounts: [String: Double]) -> some View {
        VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            Text(L.string("product.cost.spent")).font(MeetTypography.control).foregroundStyle(.secondary)
            ForEach(amounts.sorted(by: { $0.key < $1.key }), id: \.key) { currency, amount in
                amountLabel(String(format: "%.4f", amount), currency: currency, font: MeetTypography.pageTitle)
            }
            if amounts.isEmpty { Text(L.string("usage.unreported")).foregroundStyle(.secondary) }
            if let startedAt = accounting.snapshot?.checkpoint?.startedAt {
                Text(L.format("product.cost.since", AppDate.string(from: startedAt)))
                    .font(MeetTypography.caption).foregroundStyle(.secondary)
            }
        }
        .padding(MeetSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.065), in: RoundedRectangle(cornerRadius: MeetRadius.card))
    }

    private func amountLabel(_ amount: String, currency: String, font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetSpacing.xs) {
            Text(currency).font(MeetTypography.secondary).foregroundStyle(.secondary)
            Text(amount).font(font).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var costControls: some View {
        HStack(spacing: 8) {
            refreshButton
            Button {
                accounting.startRecount(prices: model.prices, providers: providers, interval: interval)
            } label: {
                Label(L.string(accounting.recounting ? "product.cost.recounting" : "product.cost.recount"), systemImage: "arrow.counterclockwise")
            }
            .help(L.string("product.cost.recount.help"))
            .disabled(!accounting.canRecount || model.loading || model.saving)
        }
        .controlSize(.small)
    }

    private var refreshButton: some View {
        HStack(spacing: 8) {
            if model.fetching { ProgressView().controlSize(.small) }
            Button(L.string(model.fetching ? "product.price.fetching" : "product.price.refresh")) { refreshID = UUID() }
                .disabled(model.loading || model.fetching || model.saving || targets.isEmpty)
        }
    }

    private func currencyPicker(_ currency: Binding<String>) -> some View {
        Picker(L.string("product.price.currency"), selection: currency) {
            ForEach(["CNY", "USD", "EUR"], id: \.self) { Text($0).tag($0) }
        }.frame(width: 140)
    }

    private func rateFields(_ draft: Binding<ProductModelPriceDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.wrappedValue.isImage {
                HStack(alignment: .top) {
                    rateField("product.price.image.text", text: draft.input)
                    rateField("product.price.image.input", text: draft.imageInput)
                    rateField("product.price.image.output", text: draft.output)
                }
                HStack(alignment: .top) {
                    rateField("product.price.image.cached_text", text: draft.cachedTextInput)
                    rateField("product.price.image.cached_image", text: draft.cachedImageInput)
                }
            } else {
                HStack {
                    TextField(L.string("product.price.input"), text: draft.input)
                    TextField(L.string("product.price.output"), text: draft.output)
                }.textFieldStyle(.roundedBorder)
            }
        }
    }

    private func rateField(_ key: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L.string(key)).font(.caption).foregroundStyle(.secondary)
            TextField(L.string(key), text: text).textFieldStyle(.roundedBorder)
        }.frame(minWidth: 100)
    }

    private func providerName(_ id: UUID) -> String { providers.first { $0.id == id }?.name ?? id.uuidString }

    private struct LookupKey: Equatable {
        let providers: [LLMProviderConfig]
        let targetIDs: [String]
        let refreshID: UUID?
    }

    private struct AccountingKey: Equatable {
        let providers: [LLMProviderConfig]
        let prices: [ProductModelPrice]
        let interval: DateInterval?
        let revision: UUID?
    }
}
