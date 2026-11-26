import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgRoomCore

@MainActor
struct KnowledgeEmbeddingSettingsView: View {
    let hub: Hub
    @AppStorage(DispatcherSettings.autoMemoryEnabledKey) private var autoMemoryEnabled = true
    @AppStorage(KnowledgeEmbeddingSettings.enabledKey) private var enabled = true
    @AppStorage(KnowledgeEmbeddingSettings.modelPathKey) private var modelPath = KnowledgeEmbeddingSettings.defaultModelURL.path
    @State private var status = ""
    @State private var busy = false
    @State private var jobID: UUID?
    @State private var modelState = ""
    @State private var modelReady = false
    @State private var draftPath = ""
    @State private var indexed = 0
    @State private var total = 0

    var body: some View {
        Form {
            retrievalSection
            memorySection
            indexSection
            modelConfigurationSection
        }
        .formStyle(.grouped)
        .onAppear { draftPath = modelPath }
        .task(id: "\(modelPath):\(enabled)") { await refresh() }
        .task { await observeJobs() }
        .onChange(of: modelPath) { _, _ in
            draftPath = modelPath
            if let jobID { JobCenter.shared.cancel(id: jobID) }
        }
        .onChange(of: enabled) { _, value in
            if !value, let jobID { JobCenter.shared.cancel(id: jobID) }
        }
    }

    private var currentSpaceCaption: String {
        L.format("settings.scope.space", L.string(hub.spaceStore.current.nameKey))
    }

    /// 就绪状态和缺模型时的恢复操作优先展示。
    private var retrievalSection: some View {
        Section {
            Toggle(L.string("embedding.enabled"), isOn: $enabled)
            if modelState.isEmpty && enabled {
                ProgressView().controlSize(.small)
            } else {
                Label(
                    L.string(!enabled ? "product.embedding.disabled" : !modelReady ? "product.embedding.action" : indexed < total ? "product.embedding.preparing" : "product.embedding.ready"),
                    systemImage: enabled && modelReady && indexed == total ? "checkmark.circle" : "info.circle"
                )
            }
            if !modelReady && enabled && !modelState.isEmpty {
                Text(modelState).font(.caption).foregroundStyle(.secondary)
                Button(L.string("embedding.choose")) { chooseModel() }
                Link(L.string("embedding.download"), destination: modelDownloadURL)
            }
        } header: {
            Text(L.string("embedding.title"))
        } footer: {
            Text(L.string("embedding.description") + "\n" + L.string("settings.scope.global"))
        }
    }

    private var memorySection: some View {
        Section {
            Toggle(isOn: $autoMemoryEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.string("settings.memory.auto"))
                    Text(L.string("settings.memory.auto.desc"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(L.string("settings.memory.manage")) {
                ProductRoute.open(space: hub.spaceStore.current, page: HubNavItem.memory.rawValue)
            }
        } header: {
            Text(L.string("settings.memory"))
        } footer: {
            Text(L.string("settings.memory.scope") + "\n" + currentSpaceCaption)
        }
    }

    private var indexSection: some View {
        Section {
            Text(L.format("embedding.index.count", indexed, total))
            HStack {
                Button(L.string("embedding.index.update")) { startIndex(rebuild: false) }
                Button(L.string("embedding.index.rebuild")) { startIndex(rebuild: true) }
                if busy, let jobID {
                    Button(L.string("common.cancel")) { JobCenter.shared.cancel(id: jobID) }
                }
            }
            .disabled(!enabled || (busy && jobID == nil))
            if busy { ProgressView().controlSize(.small) }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        } header: {
            Text(L.string("embedding.index"))
        } footer: {
            Text(currentSpaceCaption + "\n" + L.string("embedding.index.help"))
        }
    }

    private var modelConfigurationSection: some View {
        Section {
            DisclosureGroup(L.string("product.settings.advanced")) {
                LabeledContent(L.string("embedding.model"), value: "Qwen3-Embedding-0.6B · Q8 · 1024")
                LabeledContent(L.string("embedding.runtime"), value: L.string("embedding.runtime.bundled"))
                TextField(L.string("embedding.path"), text: $draftPath)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L.string("embedding.choose")) { chooseModel() }
                    Button(L.string("embedding.apply")) { modelPath = draftPath }
                        .disabled(draftPath == modelPath || draftPath.isEmpty)
                    Button(L.string("embedding.default")) {
                        modelPath = KnowledgeEmbeddingSettings.defaultModelURL.path
                        draftPath = modelPath
                    }
                    Button(L.string("embedding.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: modelPath)])
                    }
                }
                Text(modelState).font(.caption).foregroundStyle(.secondary)
                Text(L.string("embedding.path.help")).font(.caption).foregroundStyle(.secondary)
                Link(L.string("embedding.download"), destination: modelDownloadURL)
                Button(L.string("embedding.test")) { testModel() }
                    .disabled(!enabled || busy)
            }
        } header: {
            Text(L.string("embedding.files"))
        } footer: {
            Text(L.string("settings.scope.global"))
        }
    }

    private var modelDownloadURL: URL {
        URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/blob/main/Qwen3-Embedding-0.6B-Q8_0.gguf")!
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelPath = url.path
        draftPath = modelPath
    }
    private func refresh() async {
        let settings = KnowledgeEmbeddingSettings(isEnabled: enabled, modelPath: modelPath)
        let provider: LocalKnowledgeEmbedder?
        do {
            provider = try await Task.detached { try settings.makeProvider() }.value
            modelState = L.string("embedding.ready")
            modelReady = true
        } catch {
            provider = nil
            modelReady = false
            modelState = KnowledgeIndexJobs.errorText(error)
        }
        guard !Task.isCancelled, let service = hub.makeKnowledgeService() else { return }
        do {
            let counts = try await KnowledgeRetrievalService(service: service, provider: provider).indexStatus()
            try Task.checkCancellation()
            indexed = counts.indexed
            total = counts.total
        } catch is CancellationError { return }
        catch { status = KnowledgeIndexJobs.errorText(error) }
    }
    private func startIndex(rebuild: Bool) {
        guard !busy else { return }
        do {
            guard let service = hub.makeKnowledgeService() else { return }
            let provider = try KnowledgeEmbeddingSettings.load().makeProvider()
            jobID = KnowledgeIndexJobs.submit(service: service, provider: provider, space: hub.spaceStore.current,
                historyStore: hub.makeJobRunStore(for: hub.spaceStore.current), rebuild: rebuild)
            busy = true
            status = L.string("embedding.working")
        } catch { status = KnowledgeIndexJobs.errorText(error) }
    }
    private func testModel() {
        guard !busy else { return }
        busy = true
        let settings = KnowledgeEmbeddingSettings(isEnabled: enabled, modelPath: modelPath)
        jobID = JobCenter.shared.submit(name: L.string("embedding.test"), kind: "knowledge-embedding-test", space: hub.spaceStore.current,
            origin: "knowledge", historyStore: hub.makeJobRunStore(for: hub.spaceStore.current)) { ctx in
            do {
                let provider = try settings.makeProvider()
                _ = try await provider.embed(["如何检索本地知识库？"], isQuery: true)
                ctx.reportResult(await MainActor.run { L.string("embedding.test.ok") })
            } catch is CancellationError { throw CancellationError() }
            catch { throw KnowledgeIndexJobError(message: await MainActor.run { KnowledgeIndexJobs.errorText(error) }) }
        }
    }
    private func observeJobs() async {
        for await jobs in JobCenter.shared.stream() {
            guard !Task.isCancelled else { return }
            guard let jobID, let job = jobs.first(where: { $0.id == jobID }) else { continue }
            if job.state == .awaitingSave {
                busy = false; status = L.string("jobs.history.failed")
                continue
            }
            guard job.state.isFinished else { continue }
            busy = false
            self.jobID = nil
            status = job.state == .cancelled ? L.string("embedding.cancelled") : (job.errorText ?? job.resultText ?? "")
            await refresh()
        }
    }
}

private struct KnowledgeIndexJobError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// 只保留作业标识，服务捕获提交时空间；切换空间/关闭视图会取消自动作业。
@MainActor
enum KnowledgeIndexJobs {
    private static func kind(for space: AppSpace) -> String { "knowledge-index-\(space.rawValue)" }

    static func isIndexJob(_ job: BackgroundJob) -> Bool {
        AppSpace.allCases.contains { job.kind == kind(for: $0) }
    }

    static func errorText(_ error: Error) -> String {
        if let error = error as? KnowledgeEmbeddingError { return L.string("embedding.error.\(error.rawValue)") }
        return L.string("embedding.error.general")
    }
    static func submit(service: KnowledgeService, provider: any KnowledgeEmbeddingProvider,
                       space: AppSpace, historyStore: ProductJobRunStore?, rebuild: Bool = false) -> UUID {
        let kind = kind(for: space)
        if let active = JobCenter.shared.snapshot().first(where: { $0.kind == kind && !$0.state.isFinished }) { return active.id }
        return JobCenter.shared.submit(name: L.string("embedding.index.job"), kind: kind, space: space, origin: "knowledge", historyStore: historyStore) { ctx in
            let indexer = KnowledgeRetrievalService(service: service, provider: provider)
            do {
                if rebuild { try await indexer.resetIndex() }
                try await indexer.synchronize { ctx.reportProgress($0) }
                try await KnowledgeGraphService(service: service).synchronizeSimilarity(modelIdentity: provider.indexIdentity)
                ctx.reportResult(await MainActor.run { L.string("embedding.index.done") })
            } catch is CancellationError { throw CancellationError() }
            catch { throw KnowledgeIndexJobError(message: await MainActor.run { errorText(error) }) }
        }
    }

    static func monitor(hub: Hub) async {
        let space = hub.spaceStore.current
        guard let service = hub.makeKnowledgeService(for: space) else { return }
        var activeID: UUID?
        defer { if let activeID { JobCenter.shared.cancel(id: activeID) } }
        // 自动索引失败不循环重试打扰用户；设置页可显式重试。
        do {
            while !Task.isCancelled {
                if let provider = try? KnowledgeEmbeddingSettings.load().makeProvider() {
                    let indexer = KnowledgeRetrievalService(service: service, provider: provider)
                    let status = try await indexer.indexStatus()
                    let graphPending = try await KnowledgeGraphService(service: service).hasPendingSimilarity(modelIdentity: provider.indexIdentity)
                    if status.indexed < status.total || graphPending {
                        let id = submit(service: service, provider: provider, space: space, historyStore: hub.makeJobRunStore(for: space))
                        activeID = id
                        for await jobs in JobCenter.shared.stream() {
                            try Task.checkCancellation()
                            if let job = jobs.first(where: { $0.id == id }), job.state == .awaitingSave {
                                activeID = nil
                                return
                            }
                            if let job = jobs.first(where: { $0.id == id }), job.state.isFinished {
                                activeID = nil
                                if job.state != .succeeded { return }
                                break
                            }
                        }
                    }
                }
                try await Task.sleep(for: .seconds(20))
            }
        } catch is CancellationError { return }
        catch { HubLogger.shared.warning("Automatic knowledge indexing unavailable; retry from settings") }
    }
}
