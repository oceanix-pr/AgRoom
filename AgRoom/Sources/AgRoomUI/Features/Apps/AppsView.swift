import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgRoomCore

public struct AppsView: View {
    let hub: Hub
    private let space: AppSpace
    private let sourceID: String?
    @Environment(\.globalSearchText) private var search
    @State private var apps: [NativeAppSummary] = []
    @State private var retainedApps: [NativeAppSummary] = []
    @State private var pendingDrafts: [NativeAppPendingDraft] = []
    @State private var invalidDraftIDs: [UUID] = []
    @State private var discardingDraft: UUID?
    @State private var invalidIDs: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var draft: NativeAppDraft?
    @State private var dataRestore: NativeAppRestoreDraft?
    @State private var mutation: CatalogMutation?
    @State private var busy = false
    @State private var draftCenter = NativeAppDraftCenter.shared

    public init(hub: Hub, sourceID: String? = nil) { self.hub = hub; self.space = hub.spaceStore.current; self.sourceID = sourceID }

    private struct CatalogMutation: Identifiable {
        enum Kind { case remove, restore }
        let id = UUID()
        let snapshot: NativeAppSnapshot
        let kind: Kind
    }
    private var visibleApps: [NativeAppSummary] {
        let language = LanguageManager.shared.activeLanguageCode
        return apps.filter { search.isEmpty || $0.name(language: language).localizedCaseInsensitiveContains(search)
            || $0.summary(language: language).localizedCaseInsensitiveContains(search) }
            .sorted { $0.name(language: language).localizedStandardCompare($1.name(language: language)) == .orderedAscending }
    }

    public var body: some View {
        content
        .disabled(busy)
        .task(id: sourceID) {
            await reload()
            guard !Task.isCancelled, hub.spaceStore.current == space else { return }
            if let sourceID {
                do {
                    guard let store = hub.makeNativeAppStore(for: space) else { throw SpaceSearchError.unavailable }
                    let snapshot = try await store.load(id: sourceID)
                    guard !Task.isCancelled, hub.spaceStore.current == space else { return }
                    try NativeAppWindowCoordinator.shared.open(snapshot: snapshot, space: space, hub: hub)
                } catch { self.error = L.errorDescription(error) }
            } else { consumeDraft() }
        }
        .onChange(of: draftCenter.version) { _, _ in Task { await reload(); consumeDraft() } }
        .sheet(item: $draft, onDismiss: { consumeDraft() }) { draft in
            NativeAppInstallSheet(definition: draft.definition, space: space, store: hub.makeNativeAppStore(for: space)) { snapshot, open in
                Task {
                    var cleanupFailed = false
                    if let id = draft.pendingID {
                        do {
                            guard let store = hub.makeNativeAppDraftStore(for: space) else { throw NativeAppError(.unavailable) }
                            try await store.discard(id: id)
                        }
                        catch { cleanupFailed = true }
                    }
                    await reload()
                    if open {
                        do { try NativeAppWindowCoordinator.shared.open(snapshot: snapshot, space: space, hub: hub) }
                        catch { self.error = L.errorDescription(error) }
                    }
                    if cleanupFailed { error = L.string("apps.drafts.cleanupFailed") }
                }
            }
        }
        .sheet(item: $dataRestore) { draft in
            if let store = hub.makeNativeAppStore(for: space) {
                NativeAppDataRestoreSheet(backup: draft.backup, store: store, space: space) { Task { await reload() } }
            }
        }
        .confirmationDialog(L.string("apps.drafts.discard"), isPresented: Binding(
            get: { discardingDraft != nil }, set: { if !$0 { discardingDraft = nil } }
        ), titleVisibility: .visible) {
            Button(L.string("apps.drafts.discard"), role: .destructive) {
                guard let id = discardingDraft else { return }
                discardingDraft = nil
                Task {
                    do {
                        guard let store = hub.makeNativeAppDraftStore(for: space) else { throw NativeAppError(.unavailable) }
                        try await store.discard(id: id); await reload()
                    }
                    catch { self.error = L.errorDescription(error) }
                }
            }
            Button(L.string("common.cancel"), role: .cancel) { discardingDraft = nil }
        } message: { Text(L.string("apps.drafts.discard.description")) }
        .alert(L.string(mutation?.kind == .remove ? "apps.remove" : "apps.restore"), isPresented: Binding(
            get: { mutation != nil }, set: { if !$0 { mutation = nil } }
        ), presenting: mutation) { operation in
            Button(L.string("common.cancel"), role: .cancel) { mutation = nil }
            if operation.kind == .remove, operation.snapshot.isInstalled {
                Button(L.string("apps.remove.keep")) { mutate(operation, keepData: true) }
            }
            Button(L.string(operation.kind == .remove ? "apps.remove.all" : "apps.restore"), role: .destructive) {
                mutate(operation, keepData: false)
            }
        } message: { operation in
            Text(L.string(operation.kind == .remove ? "apps.remove.message" : "apps.restore.message"))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L.string("nav.apps")).font(.headline)
                Text(L.string(space.nameKey)).font(.caption).foregroundStyle(space.tint)
                Spacer()
                if loading || busy { ProgressView().controlSize(.small) }
                Menu(L.string("apps.import"), systemImage: "square.and.arrow.down") {
                    Button(L.string("apps.import")) { importApp() }
                    Button(L.string("apps.data.import")) { importBackup() }
                    Divider()
                    Button(L.string("scenario.app.quote")) { previewEstimateTemplate(quote: true) }
                    Button(L.string("scenario.app.hours")) { previewEstimateTemplate(quote: false) }
                    Divider()
                    Button(L.string("apps.template.calculator")) { previewCalculatorTemplate() }
                    Button(L.string("apps.template.slidingPuzzle")) { previewSlidingPuzzleTemplate() }
                    Button(L.string("apps.template.python")) { previewPythonTemplate() }
                    Button(L.string("apps.template.database")) { previewDatabaseTemplate() }
                }
                Button(L.string("apps.generate"), systemImage: "sparkles") {
                    startDesignConversation()
                }.buttonStyle(.borderedProminent)
            }.padding(16)
            Divider()
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(12) }
            if !invalidIDs.isEmpty {
                Text(L.format("apps.catalog.invalid", invalidIDs.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8)
                Button(L.string("apps.folder")) {
                    if let store = hub.makeNativeAppStore(for: space) { NSWorkspace.shared.open(store.directoryURL) }
                }.padding(.bottom, 8)
            }
            pendingDraftsSection
            retainedAppsSection
            if apps.isEmpty, !loading {
                ContentUnavailableView {
                    Label(L.string("apps.empty"), systemImage: "square.grid.3x3")
                } description: {
                    Text(L.string("apps.empty.description"))
                } actions: {
                    HStack {
                        Button(L.string("apps.template.knowledge")) { previewTemplate(knowledge: true) }
                        Button(L.string("apps.template.note")) { previewTemplate(knowledge: false) }
                        Button(L.string("apps.template.calculator")) { previewCalculatorTemplate() }
                        Button(L.string("apps.template.slidingPuzzle")) { previewSlidingPuzzleTemplate() }
                        Button(L.string("apps.template.python")) { previewPythonTemplate() }
                    }
                }.frame(maxHeight: .infinity)
            } else if visibleApps.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 180), spacing: 28)], spacing: 28) {
                        ForEach(visibleApps) { app in appTile(app) }
                    }.padding(32)
                }
            }
            HStack {
                Text(L.string("apps.backup.note")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.help(L.string("apps.refresh"))
            }.padding(12)
        }
    }

    @ViewBuilder
    private var pendingDraftsSection: some View {
        if !pendingDrafts.isEmpty || !invalidDraftIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.string("apps.drafts.title")).font(.headline)
                Text(L.string("apps.drafts.description")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(pendingDrafts) { pending in pendingDraftRow(pending) }
                        ForEach(invalidDraftIDs, id: \.self) { id in
                            HStack {
                                Text(L.string("apps.drafts.invalid")).foregroundStyle(.orange)
                                Spacer()
                                Button(L.string("apps.drafts.discard"), role: .destructive) { discardingDraft = id }
                            }
                        }
                    }
                }.frame(maxHeight: 210)
            }.padding(16)
            Divider()
        }
    }

    private func pendingDraftRow(_ pending: NativeAppPendingDraft) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(pending.definition.text(pending.definition.manifest.nameKey,
                    language: LanguageManager.shared.activeLanguageCode)).font(.callout.weight(.medium))
                Text(AppDate.string(from: pending.createdAt)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L.string("apps.drafts.preview")) {
                draft = NativeAppDraft(definition: pending.definition, pendingID: pending.id)
            }
            if let sessionID = pending.sourceSessionID {
                Button(L.string("apps.drafts.source")) { ProductRoute.open(space: space, page: "chat", sessionID: sessionID) }
            }
            Button(L.string("apps.drafts.discard"), role: .destructive) { discardingDraft = pending.id }
        }
    }

    @ViewBuilder
    private var retainedAppsSection: some View {
        if !retainedApps.isEmpty {
            DisclosureGroup(L.format("apps.retained", retainedApps.count)) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(retainedApps) { app in
                            HStack {
                                Text(app.name(language: LanguageManager.shared.activeLanguageCode))
                                Spacer()
                                Button(L.string("apps.reinstall")) { load(app.id) { draft = NativeAppDraft(definition: $0.definition) } }
                                Button(L.string("apps.data.export")) { exportBackup(app.id) }
                                Button(L.string("apps.remove.all"), role: .destructive) {
                                    load(app.id) { mutation = CatalogMutation(snapshot: $0, kind: .remove) }
                                }
                            }
                        }
                    }.padding(8)
                }.frame(maxHeight: 150)
            }.padding(.horizontal, 16)
        }
    }

    private func appTile(_ app: NativeAppSummary) -> some View {
        let language = LanguageManager.shared.activeLanguageCode
        let tint = iconTint(app.iconColor)
        return Button { load(app.id) { snapshot in try NativeAppWindowCoordinator.shared.open(snapshot: snapshot, space: space, hub: hub) } } label: {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 20).fill(tint.gradient).frame(width: 76, height: 76)
                    .overlay(Image(systemName: NSImage(systemSymbolName: app.icon, accessibilityDescription: nil) != nil ? app.icon : "app")
                        .font(.system(size: 34, weight: .medium)).foregroundStyle(.white))
                    .shadow(color: tint.opacity(0.18), radius: 6, y: 3)
                    .overlay(alignment: .bottomTrailing) {
                        if app.iconColorNeedsReset {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(L.string("apps.icon.color.reset_needed"))
                        }
                    }
                Text(app.name(language: language)).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, minHeight: 118).contentShape(Rectangle())
        }.buttonStyle(.plain).help(app.summary(language: language))
            .accessibilityLabel(app.name(language: language))
            .contextMenu {
                Button(L.string("apps.open")) { load(app.id) { try NativeAppWindowCoordinator.shared.open(snapshot: $0, space: space, hub: hub) } }
                Button(L.string("apps.preview")) { load(app.id) { draft = NativeAppDraft(definition: $0.definition) } }
                Button(L.string("apps.update")) { startDesignConversation(updating: app.id) }
                Menu(L.string("apps.icon.color"), systemImage: "paintpalette") {
                    ForEach(NativeAppIconColor.allCases, id: \.self) { color in
                        Button { setIconColor(color, app: app) } label: {
                            Label(L.string("apps.icon.color." + color.rawValue),
                                  systemImage: app.iconColor == color ? "checkmark.circle.fill" : "circle.fill")
                                .foregroundStyle(iconTint(color))
                        }
                    }
                }
                if ["quick-note", "knowledge-browser"].contains(app.id), app.version < 2 {
                    Button(L.string("apps.template.update")) { previewTemplate(knowledge: app.id == "knowledge-browser") }
                }
                Button(L.string("apps.export")) { load(app.id) { export($0.definition) } }
                Button(L.string("apps.data.export")) { exportBackup(app.id) }
                Button(L.string("apps.data.recovery")) { recovery(app.id) }
                Button(L.string("apps.restore")) { load(app.id) {
                    guard $0.hasPrevious else { throw NativeAppError(.missing) }
                    mutation = CatalogMutation(snapshot: $0, kind: .restore)
                } }
                Divider()
                Button(L.string("apps.remove"), role: .destructive) { load(app.id) { mutation = CatalogMutation(snapshot: $0, kind: .remove) } }
            }
    }

    private func iconTint(_ color: NativeAppIconColor) -> Color {
        switch color {
        case .space: space.tint
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .rose: .pink
        case .purple: .purple
        case .gray: .gray
        }
    }

    private func setIconColor(_ color: NativeAppIconColor, app: NativeAppSummary) {
        guard let store = hub.makeNativeAppStore(for: space), !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await store.setIconColor(color, id: app.id); await reload() }
            catch { if hub.spaceStore.current == space { self.error = L.errorDescription(error) } }
        }
    }

    private func startDesignConversation(updating id: String? = nil) {
        let prompt = id.map { L.format("apps.update.prompt", $0) } ?? L.string("apps.create.prompt")
        ProductRoute.open(space: space, page: "chat", draft: prompt)
    }

    private func reload() async {
        guard let store = hub.makeNativeAppStore(for: space) else { error = L.string("apps.error.unavailable"); return }
        loading = true
        defer { loading = false }
        do {
            let catalog = try await store.catalog()
            guard let drafts = hub.makeNativeAppDraftStore(for: space) else { throw NativeAppError(.unavailable) }
            let saved = try await drafts.catalog()
            guard !Task.isCancelled, hub.spaceStore.current == space else { return }
            apps = catalog.apps; retainedApps = catalog.retainedApps; invalidIDs = catalog.invalidIDs; error = nil
            pendingDrafts = saved.drafts; invalidDraftIDs = saved.invalidIDs
        } catch { if !Task.isCancelled { self.error = L.errorDescription(error) } }
    }

    private func load(_ id: String, perform: @escaping @MainActor (NativeAppSnapshot) throws -> Void) {
        guard let store = hub.makeNativeAppStore(for: space), !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let snapshot = try await store.loadIncludingRetained(id: id)
                guard hub.spaceStore.current == space else { return }
                try perform(snapshot)
            } catch { self.error = L.errorDescription(error) }
        }
    }

    private func importApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let definition = try await NativeAppStore.importDefinition(from: url)
                guard hub.spaceStore.current == space else { return }
                draft = NativeAppDraft(definition: definition)
            } catch { self.error = L.errorDescription(error) }
        }
    }

    private func export(_ definition: NativeAppDefinition) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = definition.id + ".zhiapp.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try await Task.detached { try definition.encoded().write(to: url, options: .atomic) }.value }
            catch { self.error = L.errorDescription(error) }
        }
    }

    private func exportBackup(_ id: String) {
        guard let store = hub.makeNativeAppStore(for: space), !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = id + ".zhiapp.backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard await NativeAppWindowCoordinator.shared.flush(space: space, id: id) else { throw NativeAppError(.storage) }
                let backup = try await store.backup(id: id, space: space)
                try await Task.detached { try backup.encoded().write(to: url, options: .atomic) }.value
            } catch { self.error = L.errorDescription(error) }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let backup = try await NativeAppBackup.importSelectedFile(url)
                guard backup.space == space else { throw NativeAppError(.spaceMismatch) }
                guard hub.spaceStore.current == space else { return }
                dataRestore = NativeAppRestoreDraft(backup: backup)
            } catch { self.error = L.errorDescription(error) }
        }
    }

    private func recovery(_ id: String) {
        guard let store = hub.makeNativeAppStore(for: space), !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let backup = try await store.recoveryBackup(id: id, space: space)
                guard hub.spaceStore.current == space else { return }
                dataRestore = NativeAppRestoreDraft(backup: backup)
            } catch let issue as NativeAppError where issue.code == .missing {
                do {
                    let url = try await store.rawRecoveryDirectory(id: id)
                    guard hub.spaceStore.current == space else { return }
                    NSWorkspace.shared.open(url)
                } catch { self.error = L.errorDescription(error) }
            } catch { self.error = L.errorDescription(error) }
        }
    }

    private func previewCalculatorTemplate() {
        do { draft = NativeAppDraft(definition: try NativeAppTemplates.calculator()) }
        catch { self.error = L.errorDescription(error) }
    }

    private func previewSlidingPuzzleTemplate() {
        do { draft = NativeAppDraft(definition: try NativeAppTemplates.slidingPuzzle()) }
        catch { self.error = L.errorDescription(error) }
    }

    private func previewEstimateTemplate(quote: Bool) {
        do { draft = NativeAppDraft(definition: try quote ? NativeAppTemplates.quoteEstimate() : NativeAppTemplates.workHours()) }
        catch { self.error = L.errorDescription(error) }
    }

    private func previewPythonTemplate() {
        do { draft = NativeAppDraft(definition: try NativeAppTemplates.textStatistics()) }
        catch { self.error = L.errorDescription(error) }
    }

    private func previewDatabaseTemplate() {
        do { draft = NativeAppDraft(definition: try NativeAppTemplates.databaseMetadata()) }
        catch { self.error = L.errorDescription(error) }
    }

    private func previewTemplate(knowledge: Bool) {
        do { draft = NativeAppDraft(definition: try knowledge ? NativeAppTemplates.knowledge() : NativeAppTemplates.note()) }
        catch { self.error = L.errorDescription(error) }
    }

    private func consumeDraft() {
        guard draft == nil, dataRestore == nil, hub.spaceStore.current == space else { return }
        if let id = draftCenter.request(for: space), let saved = pendingDrafts.first(where: { $0.id == id }) {
            draftCenter.consumeRequest(space: space)
            draft = NativeAppDraft(definition: saved.definition, pendingID: saved.id)
        }
    }

    private func mutate(_ operation: CatalogMutation, keepData: Bool) {
        guard let store = hub.makeNativeAppStore(for: space), !busy else { return }
        busy = true; mutation = nil
        Task {
            defer { busy = false }
            do {
                switch operation.kind {
                case .remove:
                    try await NativeAppWindowCoordinator.shared.pauseForDataChange(space: space, id: operation.snapshot.definition.id)
                    try await store.remove(id: operation.snapshot.definition.id, revision: operation.snapshot.revision, keepData: keepData)
                    NativeAppWindowCoordinator.shared.discard(space: space, id: operation.snapshot.definition.id)
                case .restore:
                    try await store.restore(id: operation.snapshot.definition.id, replacing: operation.snapshot.revision)
                }
                await reload()
            } catch {
                NativeAppWindowCoordinator.shared.resume(space: space, id: operation.snapshot.definition.id)
                self.error = L.errorDescription(error)
            }
        }
    }
}

struct NativeAppDraft: Identifiable {
    let id = UUID()
    let definition: NativeAppDefinition
    var pendingID: UUID? = nil
}

@MainActor
@Observable
final class NativeAppDraftCenter {
    static let shared = NativeAppDraftCenter()
    private var requests: [AppSpace: UUID] = [:]
    private(set) var version = 0
    func requestPreview(id: UUID, space: AppSpace) { requests[space] = id; version += 1 }
    func request(for space: AppSpace) -> UUID? { requests[space] }
    func consumeRequest(space: AppSpace) { requests[space] = nil }
}

private struct NativeAppInstallSheet: View {
    let definition: NativeAppDefinition
    let space: AppSpace
    let store: NativeAppStore?
    let onInstall: (NativeAppSnapshot, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: NativeAppInstallation

    init(definition: NativeAppDefinition, space: AppSpace, store: NativeAppStore?,
         onInstall: @escaping (NativeAppSnapshot, Bool) -> Void) {
        self.definition = definition; self.space = space; self.store = store; self.onInstall = onInstall
        _model = State(initialValue: NativeAppInstallation(definition: definition, store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.text(definition.manifest.nameKey, language: LanguageManager.shared.activeLanguageCode)).font(.title2.bold())
                    Text(definition.text(definition.manifest.summaryKey, language: LanguageManager.shared.activeLanguageCode)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(L.string(space.nameKey)).foregroundStyle(space.tint)
            }
            Text(L.string("apps.preview.description")).font(.caption).foregroundStyle(.secondary)
            if let capabilities = definition.capabilities, !capabilities.isEmpty {
                DisclosureGroup(L.string("apps.capability.requested")) {
                    ForEach(capabilities.keys.sorted(), id: \.self) { key in
                        if let descriptor = NativeAppCapabilityCatalog.descriptor(capabilities[key]!) {
                            Text(L.string(descriptor.localizationKey)).font(.callout)
                        }
                    }
                    Text(L.string("apps.capability.installNote")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.current?.isInstalled == false { Text(L.string("apps.reinstall.description")).font(.callout).foregroundStyle(.orange) }
            NativeAppPreview(definition: definition, space: space)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            DisclosureGroup(L.string("apps.definition")) {
                ScrollView { Text(String(decoding: (try? definition.encoded()) ?? Data(), as: UTF8.self))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 120)
            }
            if let current = model.current, !model.unchanged {
                Text(L.format("apps.update.versions", current.definition.manifest.version, definition.manifest.version))
                    .font(.callout).foregroundStyle(.orange)
                Text(L.string("apps.update.windows")).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L.string("apps.update.changes")) {
                    ScrollView {
                        if let diff = model.diff { DiffTextView(diff: diff) }
                        else { Text(model.oldDefinitionJSON ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    }.frame(height: 140)
                }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.saving)
                if !model.unchanged {
                    Button(L.string(model.current == nil ? "apps.install" : "apps.update.install")) { install(open: false) }
                        .disabled(!model.ready || model.saving || model.error != nil)
                }
                Button(L.string(model.unchanged ? "apps.open" : (model.current == nil ? "apps.install.open" : "apps.update.install.open"))) {
                    install(open: true)
                }.buttonStyle(.borderedProminent).disabled(!model.ready || model.saving || model.error != nil)
            }
        }.padding(20).frame(width: 820, height: 700)
        .interactiveDismissDisabled(model.saving)
        .task { await model.load() }
    }

    private func install(open: Bool) {
        Task {
            do {
                let installed = try await model.confirmInstallation()
                onInstall(installed, open); dismiss()
            } catch { /* The installation model retains the actionable error. */ }
        }
    }
}
