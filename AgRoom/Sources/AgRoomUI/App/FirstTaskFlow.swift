import Foundation
import Observation
import AgRoomCore

struct FirstTaskRequest: Sendable {
    let space: AppSpace
    let template: String
    let prompt: String
    let files: [URL]
    let providerID: UUID
    let startedAt: Date
}

/// UI composition owns network probes; the persisted draft contains no credential
/// or file authorization. Each callback belongs to this presentation and space.
@MainActor @Observable
final class FirstTaskSetupModel {
    let space: AppSpace
    var template = "organize" { didSet { if oldValue != template { persistChanges() } } }
    var useSample = true { didSet { if oldValue != useSample { persistChanges() } } }
    var selectedProvider: UUID? {
        didSet { if oldValue != selectedProvider { invalidateProbe(); persistChanges() } }
    }
    private(set) var providers: [LLMProviderConfig] = []
    private(set) var loadingProviders = false
    private(set) var files: [URL] = []
    private(set) var sourceNames: [String] = []
    private(set) var mailSources: MailLocalSourceSummary?
    private(set) var loadingMail = false
    private(set) var testing = false
    private(set) var connected = false
    private(set) var isLoaded = false
    private(set) var starting = false
    var errorText: String?
    private var startedAt = Date()
    private let preferences: ProductPreferencesService?
    private let fetchProviders: @MainActor () async throws -> [LLMProviderConfig]
    private let probe: @MainActor (LLMProviderConfig) async -> Result<String, Error>
    private let isCurrentSpace: @MainActor () -> Bool
    private let fetchMailSources: @MainActor () async throws -> MailLocalSourceSummary
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var providerLoadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Bool, Never>?
    private var probeID = UUID()
    private var presentationID = UUID()
    private var providerLoadID = UUID()
    private var mailLoadID = UUID()
    private var visible = false

    init(hub: Hub, space: AppSpace) {
        self.space = space
        preferences = hub.makeProductPreferencesService(for: space)
        fetchProviders = { try await hub.providerService?.getAll() ?? [] }
        probe = { config in
            guard let service = hub.providerService else { return .failure(SpaceServiceError.encodingFailed) }
            return await service.testConnection(config: config, apiKey: KeychainService.loadAPIKey(for: config.id) ?? "",
                usageRecorder: hub.makeUsageRecorder(for: space, source: "connection-test"))
        }
        isCurrentSpace = { hub.spaceStore.current == space }
        fetchMailSources = {
            guard let service = hub.makeMailService(for: space) else { throw SpaceServiceError.encodingFailed }
            return try await service.localSourceSummary()
        }
    }

    init(space: AppSpace, preferences: ProductPreferencesService,
         fetchProviders: @escaping @MainActor () async throws -> [LLMProviderConfig],
         probe: @escaping @MainActor (LLMProviderConfig) async -> Result<String, Error>,
         fetchMailSources: @escaping @MainActor () async throws -> MailLocalSourceSummary = { .init(enabledAccounts: 0, syncedMessages: 0) },
         isCurrentSpace: @escaping @MainActor () -> Bool) {
        self.space = space
        self.preferences = preferences
        self.fetchProviders = fetchProviders
        self.probe = probe
        self.isCurrentSpace = isCurrentSpace
        self.fetchMailSources = fetchMailSources
    }

    var provider: LLMProviderConfig? { providers.first { $0.id == selectedProvider } }
    var sourcesReady: Bool {
        if template == "mail" { return !loadingMail && (mailSources?.enabledAccounts ?? 0) > 0 && (mailSources?.syncedMessages ?? 0) > 0 }
        return useSample || files.count >= (template == "compare" ? 2 : 1)
    }
    var needsSourceReselection: Bool { template != "mail" && !useSample && files.isEmpty && !sourceNames.isEmpty }
    var canStart: Bool { isLoaded && visible && isCurrentSpace() && connected && sourcesReady && !loadingProviders && !testing && !starting }

    func load() async {
        visible = true
        let ticket = UUID(); presentationID = ticket
        invalidateProbe()
        do {
            guard let preferences else { throw SpaceServiceError.encodingFailed }
            if !isLoaded {
                let saved = try await preferences.load(FirstResultSetupDraft.self, key: "first-result.setup")
                let legacy = saved == nil ? try await preferences.load(String.self, key: "first-result.template") : nil
                guard visible, presentationID == ticket, isCurrentSpace(), !Task.isCancelled else { return }
                let value = saved ?? FirstResultSetupDraft(template: legacy ?? "organize")
                template = ["organize", "compare", "mail"].contains(value.template) ? value.template : "organize"
                selectedProvider = value.providerID
                useSample = value.useSample
                sourceNames = value.sourceNames
                startedAt = value.startedAt
            }
            await reloadProviders()
            guard visible, presentationID == ticket, isCurrentSpace(), !Task.isCancelled else { return }
            isLoaded = true
            persistChanges()
            if template == "mail" { await refreshMailSources() }
        } catch { if presentationID == ticket, visible { errorText = L.string("error.database") } }
    }

    @discardableResult
    func configurationChanged() -> Task<Void, Never> {
        invalidateProbe()
        providers = []
        providerLoadTask?.cancel()
        let ticket = UUID(); providerLoadID = ticket
        loadingProviders = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.reloadProviders(ticket: ticket)
        }
        providerLoadTask = task
        return task
    }

    private func reloadProviders(ticket suppliedTicket: UUID? = nil) async {
        guard visible, isCurrentSpace(), !Task.isCancelled else { return }
        let ticket = suppliedTicket ?? UUID()
        if suppliedTicket == nil { providerLoadID = ticket }
        guard providerLoadID == ticket else { return }
        loadingProviders = true
        defer { if providerLoadID == ticket { loadingProviders = false } }
        do {
            let values = try await fetchProviders().filter { $0.isEnabled && !$0.endpoint.isEmpty && !$0.model.isEmpty }
            guard visible, providerLoadID == ticket, isCurrentSpace(), !Task.isCancelled else { return }
            let previous = provider
            providers = values
            if !values.contains(where: { $0.id == selectedProvider }) { selectedProvider = values.first?.id }
            if provider != previous { invalidateProbe() }
        } catch {
            if visible, isCurrentSpace(), providerLoadID == ticket, !Task.isCancelled {
                providers = []
                errorText = L.string("error.database")
            }
        }
    }

    func testConnection() {
        guard visible, isCurrentSpace(), isLoaded, !loadingProviders, let provider else { return }
        invalidateProbe()
        let ticket = probeID
        testing = true; errorText = nil
        probeTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.probe(provider)
            guard !Task.isCancelled, self.visible, self.isCurrentSpace(), self.probeID == ticket,
                  self.provider == provider else { return }
            self.testing = false
            self.probeTask = nil
            switch result {
            case .success: self.connected = true
            case .failure(let error): self.errorText = L.errorDescription(error)
            }
        }
    }

    private func invalidateProbe() {
        probeID = UUID()
        probeTask?.cancel(); probeTask = nil
        testing = false; connected = false
    }

    func selectFiles(_ urls: [URL]) {
        guard visible, isCurrentSpace() else { return }
        files = urls
        sourceNames = urls.map(\.lastPathComponent)
        persistChanges()
    }

    func refreshMailSources() async {
        guard visible, isCurrentSpace(), isLoaded else { return }
        let ticket = UUID(); mailLoadID = ticket
        loadingMail = true; mailSources = nil
        defer { if mailLoadID == ticket { loadingMail = false } }
        do {
            let result = try await fetchMailSources()
            guard visible, isCurrentSpace(), mailLoadID == ticket, !Task.isCancelled else { return }
            mailSources = result
        } catch { if visible, mailLoadID == ticket { errorText = L.string("error.database") } }
    }

    private func persistChanges() {
        guard isLoaded, let preferences else { return }
        let value = FirstResultSetupDraft(template: template, providerID: selectedProvider, useSample: useSample,
            sourceNames: sourceNames, startedAt: startedAt)
        let previous = saveTask
        saveTask = Task { [weak self] in
            _ = await previous?.value
            do { try await preferences.save(value, key: "first-result.setup"); return true }
            catch { self?.errorText = L.string("error.database"); return false }
        }
    }

    func request() async -> FirstTaskRequest? {
        guard canStart, let provider else { return nil }
        starting = true
        defer { starting = false }
        let ticket = presentationID, taskTemplate = template, sample = useSample, sources = files
        errorText = nil
        persistChanges() // An explicit retry also retries a previous storage failure.
        guard await saveTask?.value != false else { return nil }
        if taskTemplate == "mail" { await refreshMailSources() }
        guard visible, isCurrentSpace(), presentationID == ticket, sourcesReady,
              connected, !testing, selectedProvider == provider.id, template == taskTemplate,
              useSample == sample, files == sources, !Task.isCancelled else { return nil }
        var prompt = L.string("product.template.\(taskTemplate).prompt")
        if taskTemplate != "mail", sample { prompt += "\n\n" + L.string("product.setup.sample.\(taskTemplate)") }
        return FirstTaskRequest(space: space, template: taskTemplate, prompt: prompt,
            files: taskTemplate == "mail" || sample ? [] : sources, providerID: provider.id, startedAt: startedAt)
    }

    func cancel() {
        visible = false; presentationID = UUID(); providerLoadID = UUID(); mailLoadID = UUID(); loadingMail = false
        providerLoadTask?.cancel(); providerLoadTask = nil; loadingProviders = false
        invalidateProbe()
    }
}
