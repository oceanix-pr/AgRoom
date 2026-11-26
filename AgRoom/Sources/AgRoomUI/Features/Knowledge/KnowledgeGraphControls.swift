import SwiftUI
import AgRoomCore

struct KnowledgeGraphSettingsSheet: View {
    let service: KnowledgeService
    let providerService: ProviderConfigService?
    let recorder: ProviderUsageRecorder?
    let space: AppSpace
    let historyStore: ProductJobRunStore?
    @Environment(\.dismiss) private var dismiss
    @State private var settings = KnowledgeGraphSettings()
    @State private var providers: [LLMProviderConfig] = []
    @State private var providerID: UUID?
    @State private var count = 0
    @State private var confirmation = false
    @State private var retryRequested = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.lg) {
            Text(L.string("graph.build.title")).font(MeetTypography.pageTitle)
            Text(L.string("graph.build.local")).font(MeetTypography.control).fixedSize(horizontal: false, vertical: true)
            Button(L.string("graph.build.local.update")) { updateLocal() }.disabled(busy)
            Divider()
            Toggle(L.string("graph.extraction.enabled"), isOn: $settings.extractionEnabled)
            Text(L.string("graph.extraction.description")).font(MeetTypography.control).foregroundStyle(.secondary)
            Picker(L.string("graph.extraction.provider"), selection: $providerID) {
                Text(L.string("graph.extraction.choose")).tag(UUID?.none)
                ForEach(providers) { provider in
                    Text(provider.name + " · " + provider.model).tag(UUID?.some(provider.id))
                }
            }
            .disabled(!settings.extractionEnabled)
            Text(L.format("graph.extraction.scope", count)).font(MeetTypography.secondary).foregroundStyle(.secondary)
            if settings.needsRetry { Text(L.string("graph.extraction.paused")).foregroundStyle(.orange) }
            if let error { Text(error).font(MeetTypography.control).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L.string("common.cancel")) { dismiss() }
                Spacer()
                Button(L.string("graph.extraction.retry")) { retryRequested = true; confirmation = true }
                    .disabled(busy || !settings.extractionEnabled || providerID == nil)
                Button(L.string("common.save")) {
                    retryRequested = false
                    if settings.extractionEnabled { confirmation = true } else { save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || (settings.extractionEnabled && providerID == nil))
            }
            .font(MeetTypography.control)
        }
        .font(MeetTypography.control)
        .padding(MeetSpacing.xl)
        .frame(width: 520)
        .task {
            do {
                settings = try await KnowledgeGraphService(service: service).settings()
                providerID = settings.providerID
                providers = try await providerService?.getAll().filter(\.isEnabled) ?? []
                count = try await service.browserSnapshot().items.count
            } catch { self.error = L.string("graph.error.general") }
        }
        .confirmationDialog(L.string("graph.extraction.confirm"), isPresented: $confirmation, titleVisibility: .visible) {
            Button(L.string("graph.extraction.start")) { save(retry: retryRequested) }
            Button(L.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.format("graph.extraction.confirm.detail", providers.first(where: { $0.id == providerID })?.model ?? ""))
        }
    }

    private func save(retry: Bool = false) {
        busy = true
        Task {
            do {
                if settings.extractionEnabled {
                    guard let selected = providers.first(where: { $0.id == providerID }) else { throw KnowledgeGraphError.configurationChanged }
                    settings.providerID = selected.id; settings.model = selected.model
                }
                settings.needsRetry = false
                try await KnowledgeGraphService(service: service).saveSettings(settings, retryFailed: retry)
                if settings.extractionEnabled {
                    _ = try await KnowledgeGraphJobs.submit(service: service, settings: settings, providerService: providerService, recorder: recorder, space: space, historyStore: historyStore)
                } else {
                    for job in JobCenter.shared.snapshot() where job.kind == KnowledgeGraphJobs.kind(space) && !job.state.isFinished {
                        JobCenter.shared.cancel(id: job.id)
                    }
                }
                dismiss()
            } catch { self.error = KnowledgeGraphJobs.errorText(error); busy = false }
        }
    }
    private func updateLocal() {
        do {
            let provider = try KnowledgeEmbeddingSettings.load().makeProvider()
            _ = KnowledgeIndexJobs.submit(service: service, provider: provider, space: space, historyStore: historyStore)
            dismiss()
        } catch { self.error = KnowledgeIndexJobs.errorText(error) }
    }
}

struct KnowledgeGraphJobFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum KnowledgeGraphJobs {
    static func kind(_ space: AppSpace) -> String { "knowledge-graph-\(space.rawValue)" }
    static func errorText(_ error: Error) -> String {
        if let error = error as? KnowledgeGraphError { return L.string("graph.error.\(error.rawValue)") }
        return L.string("graph.error.general")
    }
    static func submit(service: KnowledgeService, settings: KnowledgeGraphSettings, providerService: ProviderConfigService?,
                       recorder: ProviderUsageRecorder?, space: AppSpace, historyStore: ProductJobRunStore?) async throws -> UUID {
        if let job = JobCenter.shared.snapshot().first(where: { $0.kind == kind(space) && !$0.state.isFinished }) { return job.id }
        guard settings.extractionEnabled, let id = settings.providerID, let providerService else { throw KnowledgeGraphError.configurationChanged }
        let provider = try await providerService.graphProvider(id: id, model: settings.model, usageRecorder: recorder)
        let extractor = ModelKnowledgeGraphExtractor(provider: provider)
        // Recheck after provider lookup suspends: another caller may have started the same job.
        if let job = JobCenter.shared.snapshot().first(where: { $0.kind == kind(space) && !$0.state.isFinished }) { return job.id }
        return JobCenter.shared.submit(name: L.string("graph.extraction.job"), kind: kind(space), space: space, origin: "knowledge", historyStore: historyStore) { ctx in
            do {
                try await KnowledgeGraphService(service: service).synchronizeExtraction(identity: extractor.identity, model: extractor.model,
                    extract: { try await extractor.extract($0) }, progress: { ctx.reportProgress($0) })
                ctx.reportResult(await MainActor.run { L.string("graph.extraction.done") })
            } catch is CancellationError { throw CancellationError() }
            catch { throw KnowledgeGraphJobFailure(message: await MainActor.run { errorText(error) }) }
        }
    }
    static func monitor(hub: Hub) async {
        let space = hub.spaceStore.current
        guard let service = hub.makeKnowledgeService(for: space) else { return }
        let graph = KnowledgeGraphService(service: service)
        let recorder = hub.makeUsageRecorder(for: space, source: "knowledge-graph")
        var active: UUID?
        defer { if let active { JobCenter.shared.cancel(id: active) } }
        var warned = false
        do {
            while !Task.isCancelled {
                do {
                    let settings = try await graph.settings()
                    if settings.extractionEnabled, !settings.needsRetry, let id = settings.providerID {
                        let identity = "relations-v1:\(id):\(settings.model)"
                        if try await graph.pendingExtractionCount(identity: identity) > 0 {
                            let job = try await submit(service: service, settings: settings, providerService: hub.providerService, recorder: recorder, space: space, historyStore: hub.makeJobRunStore(for: space))
                            active = job
                            for await jobs in JobCenter.shared.stream() {
                                try Task.checkCancellation()
                                if let result = jobs.first(where: { $0.id == job }), result.state.isFinished || result.state == .awaitingSave {
                                    active = nil
                                    break
                                }
                            }
                        }
                    }
                    warned = false
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if !warned { HubLogger.shared.warning("Automatic graph extraction unavailable; review graph settings") }
                    warned = true
                }
                try await Task.sleep(for: .seconds(20))
            }
        } catch is CancellationError { return }
        catch { HubLogger.shared.warning("Automatic graph monitoring unavailable") }
    }
}

struct KnowledgeGraphEvidenceSheet: View {
    let edge: KnowledgeGraph.Edge
    let service: KnowledgeService
    let space: AppSpace
    @Environment(\.dismiss) private var dismiss
    @State private var item: KnowledgeItem?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: MeetSpacing.md) {
            Text(L.string("graph.evidence.title")).font(MeetTypography.pageTitle)
            Text(L.string("graph.decision.\(edge.decision)")).font(MeetTypography.control)
            if let evidence = edge.evidence {
                Text(evidence.quote).readingBodyFont().textSelection(.enabled)
                Text(L.format("graph.evidence.model", evidence.model)).font(MeetTypography.secondary).foregroundStyle(.secondary)
                if let item {
                    Divider()
                    Text(item.title).font(MeetTypography.sectionTitle)
                    ScrollView {
                        MarkdownView(text: item.content, documentID: item.id.uuidString, sourceContext: .scoped(to: space))
                    }.frame(maxHeight: 280)
                }
                Text(L.string("graph.evidence.explanation")).font(MeetTypography.secondary).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(MeetTypography.control) }
            HStack {
                Button(L.string("common.cancel")) { dismiss() }
                Spacer()
                Button(L.string("graph.decision.exclude")) { decide("excluded") }
                Button(L.string("graph.decision.reset")) { decide("proposed") }
                Button(L.string("graph.decision.accept")) { decide("accepted") }.buttonStyle(.borderedProminent)
            }.font(MeetTypography.control).disabled(busy)
        }
        .padding(MeetSpacing.xl).frame(width: 640)
        .task {
            guard let evidence = edge.evidence else { return }
            do { item = try await service.get(id: evidence.itemID) }
            catch { self.error = L.string("graph.error.general") }
        }
    }
    private func decide(_ decision: String) {
        busy = true
        Task {
            do { try await KnowledgeGraphService(service: service).setDecision(relationID: edge.id, decision: decision); dismiss() }
            catch { self.error = L.string("graph.error.general"); busy = false }
        }
    }
}
