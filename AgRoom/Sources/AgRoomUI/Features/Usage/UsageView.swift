import SwiftUI
import Combine
import AgRoomCore

enum UsageSection: String, CaseIterable {
    case overview, models, cache, requests, sessions
    var titleKey: String { "usage.section." + rawValue }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .models: "cpu"
        case .cache: "arrow.triangle.2.circlepath"
        case .requests: "list.bullet.rectangle"
        case .sessions: "bubble.left.and.bubble.right"
        }
    }
}

struct UsageCategoryList: View {
    @Binding var selection: UsageSection
    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(UsageSection.allCases, id: \.self) { section in
                    Button { selection = section } label: {
                        Label(L.string(section.titleKey), systemImage: section.symbol)
                            .font(.body).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .background(selection == section ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(selection == section ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain).help(L.string(section.titleKey))
                    .accessibilityAddTraits(selection == section ? [.isSelected] : [])
                }
            }.padding(12)
        }
        .frame(width: LanguageManager.shared.usesCompactLabels ? 180 : 250)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel(L.string("usage.categories"))
    }
}

private struct UsageQuery: Hashable {
    let interval: DateInterval?
    let filter: UsageRequestFilter
}

private struct UsageLoadKey: Hashable {
    let query: UsageQuery
    let refreshID: UUID
}

/// Space-bound usage dashboard. All sections share the selected request-start date range.
public struct UsageView: View {
    let hub: Hub
    private let space: AppSpace
    @State private var period: UsagePeriod = .all
    @State private var customStart = Calendar.current.startOfDay(for: Date())
    @State private var customEnd = Date()
    @State private var requestFilter: UsageRequestFilter = .all
    @State private var refreshID = UUID()
    @State private var loadID = UUID()
    @State private var loadedQuery: UsageQuery?
    @State private var loading = false
    @State private var loadingMoreID: UUID?
    @State private var error: String?
    @State private var updatedAt: Date?
    @State private var records: [ProviderUsageRecord] = []
    @State private var hasMore = false
    @State private var usageStats = UsageStats()
    @State private var section: UsageSection = .overview
    @State private var providers: [LLMProviderConfig] = []
    @State private var providersLoadID = UUID()

    public init(hub: Hub) {
        self.hub = hub
        self.space = hub.spaceStore.current
    }

    private var query: UsageQuery {
        UsageQuery(interval: period.interval(customStart: customStart, customEnd: customEnd), filter: requestFilter)
    }

    public var body: some View {
        HStack(spacing: 0) {
            UsageCategoryList(selection: $section)
            Divider()
            content
        }
        .font(MeetTypography.control)
        .task(id: UsageLoadKey(query: query, refreshID: refreshID)) { await load(query) }
        .task { await loadProviders() }
        .onReceive(NotificationCenter.default.publisher(for: ProviderConfigService.configurationDidChange)) { _ in
            Task { await loadProviders() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UsageService.didChange)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in refreshID = UUID() }
        .onDisappear { loadID = UUID(); loadingMoreID = nil; providersLoadID = UUID() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: MeetSpacing.sm) {
                Text(L.string(section.titleKey)).font(MeetTypography.pageTitle)
                Text(L.string(space.nameKey)).font(MeetTypography.secondary).foregroundStyle(space.tint)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                if let updatedAt {
                    Text(L.format("usage.updated", AppDate.timeString(from: updatedAt, includingSeconds: true)))
                        .font(MeetTypography.secondary).foregroundStyle(.secondary)
                }
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L.string("apps.refresh"))
                    .accessibilityLabel(L.string("apps.refresh"))
                    .disabled(loading)
            }
            .padding(.horizontal, MeetSpacing.md)
            .columnHeader()
            Divider()

            ScrollViewReader { scroll in
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: MeetSpacing.xl) {
                            rangeControls
                            if section == .overview || section == .models {
                                ProductCostView(service: hub.makeProductPreferencesService(for: space), models: usageStats.modelGroups, providers: providers,
                                    usageService: hub.makeUsageService(for: space), interval: query.interval, revision: refreshID)
                            }
                            if let error {
                                HStack(spacing: MeetSpacing.sm) {
                                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                    Spacer()
                                    Button(L.string("common.retry")) { refreshID = UUID() }
                                }.padding(MeetSpacing.md).meetCard()
                            }
                            if loadedQuery == query {
                                UsageDashboardContent(stats: usageStats, records: records, interval: query.interval,
                                    availableWidth: max(0, geometry.size.width - MeetSpacing.xl * 2),
                                    section: $section, requestFilter: $requestFilter, hasMore: hasMore,
                                    loadingMore: loadingMoreID != nil, refreshing: loading,
                                    onLoadMore: { Task { await loadMore() } })
                            } else if error == nil {
                                ProgressView(L.string("usage.loading"))
                                    .frame(maxWidth: .infinity, minHeight: 180)
                            }
                        }
                        .padding(MeetSpacing.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                .onChange(of: loadedQuery) { old, new in
                    if let old, let new, old.filter != new.filter {
                        scroll.scrollTo("usage.request_details", anchor: .top)
                    }
                }
            }
        }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(L.string("usage.scope")).foregroundStyle(.secondary)
                    Spacer(minLength: MeetSpacing.lg)
                    periodPicker
                }
                VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                    periodPicker
                    Text(L.string("usage.scope")).foregroundStyle(.secondary)
                }
            }
            if period == .custom {
                HStack(spacing: MeetSpacing.lg) {
                    DatePicker(L.string("usage.period.from"), selection: $customStart, in: ...customEnd, displayedComponents: .date)
                    DatePicker(L.string("usage.period.to"), selection: $customEnd, in: customStart..., displayedComponents: .date)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var periodPicker: some View {
        Picker(L.string("usage.period"), selection: $period) {
            ForEach(UsagePeriod.allCases, id: \.self) { value in
                Text(L.string("usage.period.\(value.rawValue)")).tag(value)
            }
        }.pickerStyle(.menu).fixedSize()
    }

    private func load(_ query: UsageQuery) async {
        let id = UUID()
        loadID = id; loading = true; loadingMoreID = nil; error = nil
        defer { if loadID == id { loading = false } }
        guard let service = hub.makeUsageService(for: space) else { error = L.string("error.database"); return }
        do {
            let stats = try await service.getStats(in: query.interval)
            let page = try await service.getRecords(in: query.interval, filter: query.filter)
            guard !Task.isCancelled, loadID == id, self.query == query, hub.spaceStore.current == space else { return }
            usageStats = stats; records = page; hasMore = page.count == 50
            loadedQuery = query; updatedAt = Date(); error = nil
        } catch {
            guard !Task.isCancelled, loadID == id, self.query == query, hub.spaceStore.current == space else { return }
            self.error = L.string("settings.usage.error")
        }
    }

    private func loadMore() async {
        let query = query, generation = loadID
        guard !loading, loadingMoreID == nil, loadedQuery == query, hasMore,
              let cursor = records.last, let service = hub.makeUsageService(for: space) else { return }
        let id = UUID(); loadingMoreID = id
        defer { if loadingMoreID == id { loadingMoreID = nil } }
        do {
            let page = try await service.getRecords(in: query.interval, filter: query.filter, before: cursor)
            guard !Task.isCancelled, generation == loadID, loadedQuery == query, self.query == query,
                  hub.spaceStore.current == space else { return }
            let existing = Set(records.map(\.id))
            records += page.filter { !existing.contains($0.id) }
            hasMore = page.count == 50; error = nil
        } catch {
            guard !Task.isCancelled, generation == loadID, self.query == query, hub.spaceStore.current == space else { return }
            self.error = L.string("settings.usage.error")
        }
    }

    private func loadProviders() async {
        let ticket = UUID(); providersLoadID = ticket
        do {
            let values = try await hub.providerService?.getAll() ?? []
            guard !Task.isCancelled, providersLoadID == ticket, hub.spaceStore.current == space else { return }
            providers = values
        } catch {
            guard !Task.isCancelled, providersLoadID == ticket, hub.spaceStore.current == space else { return }
            self.error = L.string("error.database")
        }
    }
}

/// The dashboard only renders a supplied snapshot; loading and space services stay in UsageView.
struct UsageDashboardContent: View {
    let stats: UsageStats
    let records: [ProviderUsageRecord]
    let interval: DateInterval?
    let availableWidth: CGFloat
    @Binding var section: UsageSection
    @Binding var requestFilter: UsageRequestFilter
    let hasMore: Bool
    let loadingMore: Bool
    let refreshing: Bool
    let onLoadMore: () -> Void
    @State private var expandedModels: Set<UsageModelGroup.ID> = []
    @State private var expandedRecords: Set<String> = []
    @State private var showingAccounting = false

    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.xl) {
            switch section {
            case .overview:
                overview
                UsageTrendChart(stats: stats, interval: interval)
                UsageModelChart(stats: stats)
            case .models:
                UsageModelChart(stats: stats)
                modelSection
            case .cache:
                cacheSummary
                UsageCacheChart(stats: stats)
                Text(L.string("usage.cache.explanation")).foregroundStyle(.secondary)
            case .requests:
                requestSection
            case .sessions:
                sessions
            }
        }
        .id(section)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            HStack {
                Text(L.string("settings.usage.overview")).font(MeetTypography.sectionTitle)
                Spacer()
                Button { showingAccounting = true } label: {
                    Label(L.string("usage.accounting"), systemImage: "info.circle")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $showingAccounting) {
                    VStack(alignment: .leading, spacing: MeetSpacing.md) {
                        Text(L.string("usage.accounting")).font(MeetTypography.sectionTitle)
                        Text(L.string("settings.usage.overview.desc"))
                        Text(L.string("usage.cache.explanation"))
                        if stats.legacyTurns > 0 { Text(L.string("settings.usage.legacy.desc")) }
                    }
                    .font(MeetTypography.control).padding(MeetSpacing.lg).frame(width: 420)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MeetSpacing.md),
                                     count: max(1, min(3, Int((availableWidth + MeetSpacing.md) / (260 + MeetSpacing.md))))),
                      spacing: MeetSpacing.md) {
                metricCard("usage.reported_total", value: stats.reportedInputRecords + stats.reportedOutputRecords == 0 && stats.totalTurns > 0
                           ? L.string("usage.unreported") : stats.totalTokens.formatted(),
                           detail: L.format("usage.total.breakdown", reported(stats.totalInputTokens, count: stats.reportedInputRecords),
                                            reported(stats.totalOutputTokens, count: stats.reportedOutputRecords)))
                Button { showRequests(.all) } label: {
                    metricCard("settings.usage.requests", value: stats.totalRequests.formatted(),
                               detail: stats.legacyTurns > 0 ? L.format("usage.legacy.count", stats.legacyTurns) : L.string("usage.requests.view"))
                }.buttonStyle(.plain)
                Button { showRequests(.failedOrCancelled) } label: {
                    metricCard("settings.usage.failed", value: stats.failedRequests.formatted(), detail: L.string("usage.failures.view"))
                }.buttonStyle(.plain)
            }
            if stats.unreportedRequests > 0 || stats.unknownCacheRequests > 0 || stats.unfinishedRequests > 0 {
                VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                    Label(L.string("usage.incomplete.title"), systemImage: "info.circle")
                        .font(MeetTypography.listTitle)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: MeetSpacing.lg) { completenessLinks }
                        VStack(alignment: .leading, spacing: MeetSpacing.sm) { completenessLinks }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MeetSpacing.md)
                .background(MeetStatusColor.resource.opacity(0.08), in: RoundedRectangle(cornerRadius: MeetRadius.card))
            }
        }
    }

    @ViewBuilder private var completenessLinks: some View {
        if stats.unreportedRequests > 0 {
            Button(L.format("usage.incomplete.tokens", stats.unreportedRequests)) { showRequests(.unreported) }
        }
        if stats.unknownCacheRequests > 0 {
            Button(L.format("usage.incomplete.cache", stats.unknownCacheRequests)) { showRequests(.incompleteCache) }
        }
        if stats.unfinishedRequests > 0 {
            Button(L.format("usage.unfinished.count", stats.unfinishedRequests)) { showRequests(.unfinished) }
        }
    }

    private func showRequests(_ filter: UsageRequestFilter) {
        requestFilter = filter
        section = .requests
    }

    private func metricCard(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            Text(L.string(title)).font(MeetTypography.control).foregroundStyle(.secondary)
            Text(value).font(MeetTypography.pageTitle).monospacedDigit().foregroundStyle(.primary)
            Text(detail).font(MeetTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(MeetSpacing.lg).meetCard().contentShape(Rectangle())
    }

    private var cacheSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MeetSpacing.xl) {
                cacheHeading
                Spacer(minLength: MeetSpacing.md)
                cacheCount("usage.cache.read", value: stats.totalCacheReadTokens, count: stats.reportedCacheReadRecords)
                cacheCount("usage.cache.write", value: stats.totalCacheWriteTokens, count: stats.reportedCacheWriteRecords)
            }
            VStack(alignment: .leading, spacing: MeetSpacing.md) {
                cacheHeading
                HStack(spacing: MeetSpacing.xl) {
                    cacheCount("usage.cache.read", value: stats.totalCacheReadTokens, count: stats.reportedCacheReadRecords)
                    cacheCount("usage.cache.write", value: stats.totalCacheWriteTokens, count: stats.reportedCacheWriteRecords)
                }
            }
        }
        .padding(MeetSpacing.lg).meetCard()
    }

    private var cacheHeading: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.xs) {
            Text(L.string("usage.cache.section")).font(MeetTypography.listTitle)
            Text(L.string("usage.cache.included")).font(MeetTypography.secondary).foregroundStyle(.secondary)
        }
    }

    private func cacheCount(_ key: String, value: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: MeetSpacing.xs) {
            Text(L.string(key)).font(MeetTypography.secondary).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: MeetSpacing.sm) {
                Text(reported(value, count: count)).monospacedDigit()
                if count > 0 && count < stats.totalTurns {
                    Text(L.string("usage.report.partial")).font(MeetTypography.secondary).foregroundStyle(.secondary)
                }
            }
        }.help(L.format("usage.report.coverage", count, stats.totalTurns))
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            Text(L.string("usage.by_model")).font(MeetTypography.sectionTitle)
            if availableWidth < 900 { tableScrollHint }
            if stats.modelGroups.isEmpty {
                emptyState("usage.range.empty")
            } else {
                ScrollView(.horizontal) {
                    Grid(horizontalSpacing: MeetSpacing.lg, verticalSpacing: 0) {
                        GridRow {
                            columnHeading("usage.model.column")
                            columnHeading("settings.usage.input", trailing: true)
                            columnHeading("settings.usage.output", trailing: true)
                            columnHeading("usage.cache.read", trailing: true)
                            columnHeading("usage.cache.write", trailing: true)
                            columnHeading("usage.records.column", trailing: true)
                        }
                        Divider().gridCellColumns(6)
                        ForEach(stats.modelGroups) { group in
                            GridRow {
                                Button { toggle(group.id, in: &expandedModels) } label: {
                                    HStack(spacing: MeetSpacing.sm) {
                                        Image(systemName: expandedModels.contains(group.id) ? "chevron.down" : "chevron.right")
                                            .font(MeetTypography.secondary).foregroundStyle(.secondary).frame(width: 12)
                                        VStack(alignment: .leading, spacing: MeetSpacing.xs) {
                                            Text(modelName(group.model)).font(MeetTypography.listTitle).lineLimit(1).help(modelName(group.model))
                                            Text(group.providerName ?? L.string("usage.provider.unknown"))
                                                .font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1)
                                            Text(group.sources.count > 1
                                                 ? L.format("usage.model.source_counts", group.sources.filter(\.isReportedModel).reduce(0) { $0 + $1.requests },
                                                            group.sources.filter { !$0.isReportedModel }.reduce(0) { $0 + $1.requests })
                                                 : L.string(group.sources.first?.isReportedModel == true ? "usage.model.confirmed" : "usage.model.request_only"))
                                                .font(MeetTypography.secondary).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(minWidth: 180, alignment: .leading).padding(.vertical, MeetSpacing.md)
                                }
                                .buttonStyle(.plain).help(L.string("usage.model.sources"))
                                .accessibilityLabel(modelName(group.model) + ", " + L.string("usage.model.sources"))
                                modelCount(group.input, reported: group.reportedInputRecords, total: group.records)
                                modelCount(group.output, reported: group.reportedOutputRecords, total: group.records)
                                modelCount(group.cacheRead, reported: group.reportedCacheReadRecords, total: group.records)
                                modelCount(group.cacheWrite, reported: group.reportedCacheWriteRecords, total: group.records)
                                Text(group.records.formatted()).monospacedDigit().gridColumnAlignment(.trailing)
                            }
                            if expandedModels.contains(group.id) {
                                ForEach(group.sources) { source in
                                    GridRow {
                                        HStack {
                                            StatusBadge(text: L.string(source.isReportedModel ? "usage.model.confirmed" : "usage.model.request_only"),
                                                        color: source.isReportedModel ? MeetStatusColor.positive : .secondary)
                                            Spacer(minLength: 0)
                                        }.padding(.leading, MeetSpacing.xl).padding(.vertical, MeetSpacing.sm)
                                        modelCount(source.input, reported: source.reportedInputRecords, total: source.requests)
                                        modelCount(source.output, reported: source.reportedOutputRecords, total: source.requests)
                                        modelCount(source.cacheRead, reported: source.reportedCacheReadRecords, total: source.requests)
                                        modelCount(source.cacheWrite, reported: source.reportedCacheWriteRecords, total: source.requests)
                                        Text(source.requests.formatted()).monospacedDigit()
                                    }.foregroundStyle(.secondary)
                                }
                                if group.unknownCacheRecords > 0 {
                                    GridRow {
                                        Text(L.format("usage.incomplete.cache", group.unknownCacheRecords))
                                            .font(MeetTypography.secondary).foregroundStyle(.secondary)
                                            .padding(.leading, MeetSpacing.xl).padding(.bottom, MeetSpacing.sm)
                                            .frame(maxWidth: .infinity, alignment: .leading).gridCellColumns(6)
                                    }
                                }
                            }
                            Divider().gridCellColumns(6)
                        }
                    }
                    .frame(minWidth: max(0, availableWidth - MeetSpacing.md * 2), alignment: .leading)
                    .padding(MeetSpacing.md)
                }.defaultScrollAnchor(.leading).fixedSize(horizontal: false, vertical: true).meetCard()
            }
        }
    }

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack { requestHeading; Spacer(); requestPicker }
                VStack(alignment: .leading, spacing: MeetSpacing.sm) { requestHeading; requestPicker }
            }
            if availableWidth < 900 { tableScrollHint }
            if records.isEmpty {
                emptyState(stats.totalTurns == 0 ? "usage.range.empty" : "usage.request.empty")
            } else {
                ScrollView(.horizontal) {
                    Grid(horizontalSpacing: MeetSpacing.lg, verticalSpacing: 0) {
                        GridRow {
                            columnHeading("usage.request.time").frame(minWidth: 170, alignment: .leading)
                            columnHeading("usage.model.column")
                            columnHeading("usage.request.status")
                            columnHeading("usage.reported_total", trailing: true)
                            columnHeading("usage.request.duration", trailing: true)
                        }
                        Divider().gridCellColumns(5)
                        ForEach(records) { record in
                            GridRow {
                                Button { toggle(record.id, in: &expandedRecords) } label: {
                                    HStack(spacing: MeetSpacing.sm) {
                                        Image(systemName: expandedRecords.contains(record.id) ? "chevron.down" : "chevron.right")
                                            .font(MeetTypography.secondary).foregroundStyle(.secondary).frame(width: 12)
                                        VStack(alignment: .leading, spacing: MeetSpacing.xs) {
                                            Text(AppDate.dateString(from: record.startedAt))
                                            Text(AppDate.timeString(from: record.startedAt, includingSeconds: true))
                                                .font(MeetTypography.secondary).foregroundStyle(.secondary)
                                        }.monospacedDigit().fixedSize(horizontal: true, vertical: false)
                                    }.frame(minWidth: 170, maxWidth: .infinity, alignment: .leading).padding(.vertical, MeetSpacing.md)
                                }.buttonStyle(.plain).accessibilityLabel(L.string("usage.request_details") + ", " + AppDate.string(from: record.startedAt))
                                VStack(alignment: .leading, spacing: MeetSpacing.xs) {
                                    Text(modelName(record.usage.reportedModel ?? record.requestedModel)).font(MeetTypography.listTitle).lineLimit(1)
                                        .help(modelName(record.usage.reportedModel ?? record.requestedModel))
                                    Text(record.providerName ?? L.string("usage.provider.unknown"))
                                        .font(MeetTypography.secondary).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                                StatusBadge(text: statusName(record.status), color: statusColor(record.status)).gridColumnAlignment(.leading)
                                VStack(alignment: .trailing, spacing: MeetSpacing.xs) {
                                    Text(record.usage.reportedTotal?.formatted() ?? L.string("usage.unreported")).monospacedDigit()
                                    if record.usage.reportedTotal != nil && !record.usage.hasCompleteTokenCounts {
                                        Text(L.string("usage.report.partial")).font(MeetTypography.secondary).foregroundStyle(.secondary)
                                    }
                                }.gridColumnAlignment(.trailing)
                                Text(duration(record)).monospacedDigit().gridColumnAlignment(.trailing)
                            }
                            if expandedRecords.contains(record.id) {
                                GridRow {
                                    requestDetails(record).gridCellColumns(5).gridCellUnsizedAxes(.horizontal)
                                }
                            }
                            Divider().gridCellColumns(5)
                        }
                    }
                    .frame(minWidth: max(0, availableWidth - MeetSpacing.md * 2), alignment: .leading)
                    .padding(MeetSpacing.md)
                }.defaultScrollAnchor(.leading).fixedSize(horizontal: false, vertical: true).meetCard()
                if hasMore {
                    HStack {
                        Spacer()
                        if loadingMore { ProgressView().controlSize(.small) }
                        Button(L.string("usage.load_more"), action: onLoadMore).disabled(loadingMore || refreshing)
                        Spacer()
                    }
                }
            }
        }.id("usage.request_details")
    }

    private var tableScrollHint: some View {
        Label(L.string("usage.table.scroll"), systemImage: "arrow.left.and.right")
            .font(MeetTypography.secondary).foregroundStyle(.secondary)
    }

    private var requestHeading: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.xs) {
            Text(L.string("usage.request_details")).font(MeetTypography.sectionTitle)
            Text(L.format("usage.records.shown", records.count)).font(MeetTypography.secondary).foregroundStyle(.secondary)
        }
    }

    private var requestPicker: some View {
        Picker(L.string("usage.filter"), selection: $requestFilter) {
            ForEach(UsageRequestFilter.allCases, id: \.self) { filter in
                Text(L.string("usage.filter.\(filter.rawValue)")).tag(filter)
            }
        }.pickerStyle(.menu).fixedSize()
    }

    private func requestDetails(_ record: ProviderUsageRecord) -> some View {
        VStack(alignment: .leading, spacing: MeetSpacing.sm) {
            LabeledContent(L.string("usage.model.requested"), value: modelName(record.requestedModel))
            LabeledContent(L.string("usage.model.reported"), value: record.usage.reportedModel ?? L.string("usage.unreported"))
            LabeledContent(L.string("settings.usage.input"), value: count(record.usage.input))
            LabeledContent(L.string("usage.input.ordinary"), value: count(record.usage.ordinaryInput))
            LabeledContent(L.string("usage.cache.read"), value: count(record.usage.cacheRead))
            LabeledContent(L.string("usage.cache.status"), value: L.string(record.usage.cacheRead.map { $0 > 0 ? "usage.cache.hit" : "usage.cache.miss" } ?? "usage.unreported"))
            LabeledContent(L.string("usage.cache.write"), value: count(record.usage.cacheWrite))
            LabeledContent(L.string("settings.usage.output"), value: count(record.usage.output))
            if let reasoning = record.usage.reasoning {
                LabeledContent(L.string("usage.output.reasoning"), value: reasoning.formatted())
            }
            LabeledContent(L.string("usage.source"), value: sourceName(record.source))
            if let request = record.request {
                if let purpose = request.purpose {
                    LabeledContent(L.string("usage.request.purpose"), value: L.string("usage.request.purpose." + purpose.rawValue))
                }
                if let runID = request.runID {
                    LabeledContent(L.string("usage.request.run"), value: runID.uuidString).font(.caption)
                }
                if let parent = request.parentRunID {
                    LabeledContent(L.string("usage.request.parent_run"), value: parent.uuidString).font(.caption)
                }
                if let root = request.rootRunID, root != request.runID {
                    LabeledContent(L.string("usage.request.root_run"), value: root.uuidString).font(.caption)
                }
                if let estimate = request.estimate {
                    Divider()
                    Text(L.string("usage.estimate.title")).font(MeetTypography.listTitle)
                    Text(L.string("usage.estimate.help")).font(MeetTypography.secondary).foregroundStyle(.secondary)
                    ForEach(estimateRows(estimate), id: \.0) { key, value in
                        LabeledContent(L.string("usage.estimate." + key), value: value.formatted())
                    }
                }
            }
            LabeledContent(L.string("usage.request.session"), value: record.sessionDeleted ? L.string("usage.session.deleted")
                : (record.sessionTitle ?? L.string("settings.usage.auxiliary")))
            if record.status != "succeeded" && record.usage.reportedTotal != nil {
                Text(L.string("usage.partial")).font(MeetTypography.secondary).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled).frame(maxWidth: 700, alignment: .leading)
        .padding(MeetSpacing.lg).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: MeetRadius.card))
        .padding(.bottom, MeetSpacing.sm)
    }

    private func estimateRows(_ value: RequestTokenEstimate) -> [(String, Int)] {
        [("system", value.system), ("tools", value.toolSchema), ("history", value.history),
         ("conversation", value.conversation), ("evidence", value.sourceEvidence), ("task", value.taskState),
         ("results", value.otherToolResults), ("continuation", value.continuation),
         ("images", value.images), ("framing", value.framing), ("total", value.total)]
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            Text(L.string("settings.usage.by_session")).font(MeetTypography.sectionTitle)
            Text(L.string("usage.sessions.order")).font(MeetTypography.secondary).foregroundStyle(.secondary)
            if stats.bySession.isEmpty { emptyState("usage.range.empty") }
            ForEach(stats.bySession.sorted { $0.inputTokens + $0.outputTokens > $1.inputTokens + $1.outputTokens }) { session in
                VStack(alignment: .leading, spacing: MeetSpacing.sm) {
                    HStack {
                        Text(session.id == "auxiliary" ? L.string("settings.usage.auxiliary") : (session.isDeleted ? L.string("usage.session.deleted")
                            : (session.title.isEmpty ? L.string("settings.usage.unnamed") : session.title)))
                            .font(MeetTypography.listTitle).lineLimit(2)
                        Spacer()
                        Text((session.inputTokens + session.outputTokens).formatted()).monospacedDigit()
                    }
                    Text(L.format("usage.total.breakdown", session.inputTokens.formatted(), session.outputTokens.formatted()))
                        .font(MeetTypography.secondary).foregroundStyle(.secondary)
                    ProgressView(value: Double(session.inputTokens + session.outputTokens), total: Double(max(1, stats.totalTokens)))
                        .accessibilityLabel(L.string("usage.chart.session_share"))
                }.padding(MeetSpacing.lg).meetCard()
            }
        }
    }

    private func modelCount(_ value: Int, reported: Int, total: Int) -> some View {
        VStack(alignment: .trailing, spacing: MeetSpacing.xs) {
            Text(reported == 0 ? L.string("usage.unreported") : value.formatted()).monospacedDigit()
            if reported > 0 && reported < total {
                Text(L.string("usage.report.partial")).font(MeetTypography.secondary).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 72, alignment: .trailing).gridColumnAlignment(.trailing)
        .help(L.format("usage.report.coverage", reported, total))
    }

    private func columnHeading(_ key: String, trailing: Bool = false) -> some View {
        Text(L.string(key)).font(MeetTypography.secondary).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .padding(.bottom, MeetSpacing.sm)
    }

    private func emptyState(_ key: String) -> some View {
        Text(L.string(key)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(MeetSpacing.lg).meetCard()
    }

    private func toggle<T: Hashable>(_ id: T, in set: inout Set<T>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
    private func reported(_ value: Int, count: Int) -> String { count == 0 && stats.totalTurns > 0 ? L.string("usage.unreported") : value.formatted() }
    private func count(_ value: Int?) -> String { value?.formatted() ?? L.string("usage.unreported") }
    private func modelName(_ value: String) -> String { value.isEmpty ? L.string("usage.model.unknown") : value }
    private func duration(_ record: ProviderUsageRecord) -> String {
        guard let finished = record.finishedAt else { return L.string(record.status == "started" ? "usage.duration.unfinished" : "usage.unreported") }
        return L.format("usage.duration.value", max(0, finished.timeIntervalSince(record.startedAt)).formatted(.number.precision(.fractionLength(1))))
    }
    private func statusName(_ status: String) -> String {
        L.string(["started", "succeeded", "failed", "cancelled"].contains(status) ? "usage.status.\(status)" : "usage.unreported")
    }
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "succeeded": MeetStatusColor.positive
        case "failed": MeetStatusColor.negative
        case "started": MeetStatusColor.processing
        default: .secondary
        }
    }
    private func sourceName(_ source: String) -> String {
        switch source {
        case "chat", "knowledge-design", "knowledge-graph", "legacy", "scheduled", "app-code-review": L.string("usage.source.\(source)")
        case "conversation-title": L.string("usage.source.title")
        case "memory-extraction": L.string("usage.source.memory")
        case "conversation-summary": L.string("usage.source.summary")
        default: L.string("settings.usage.auxiliary")
        }
    }
}
