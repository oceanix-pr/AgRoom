import AppKit
import SwiftUI
import AgRoomCore

/// A resumable first task: choose an outcome, verify the configured model, select sources,
/// then run through the same chat, approval and artifact flow as every subsequent task.
struct OnboardingView: View {
    let hub: Hub
    let onFinish: (FirstTaskRequest?) -> Void
    var onConfigureMail: (() -> Void)?
    @State private var setup: FirstTaskSetupModel
    @State private var showingProvider = false
    @State private var sourcePanel: NSOpenPanel?

    init(hub: Hub, onFinish: @escaping (FirstTaskRequest?) -> Void, onConfigureMail: (() -> Void)? = nil) {
        self.hub = hub
        self.onFinish = onFinish
        self.onConfigureMail = onConfigureMail
        self._setup = State(initialValue: FirstTaskSetupModel(hub: hub, space: hub.spaceStore.current))
    }

    init(hub: Hub, setup: FirstTaskSetupModel, onFinish: @escaping (FirstTaskRequest?) -> Void) {
        self.hub = hub
        self.onFinish = onFinish
        self._setup = State(initialValue: setup)
    }

    var body: some View {
        @Bindable var setup = setup
        VStack(alignment: .leading, spacing: 16) {
            Text(L.string("product.setup.title")).font(.title.bold())
            Text(L.string("product.setup.description")).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.string("product.setup.task")).font(.headline)
                            Picker(L.string("product.setup.task"), selection: $setup.template) {
                                ForEach(["organize", "compare", "mail"], id: \.self) { value in
                                    Text(L.string("product.template.\(value).title")).tag(value)
                                }
                            }.pickerStyle(.segmented).labelsHidden()
                            Text(L.string("product.template.\(setup.template).description")).font(.callout)
                            Label(L.string("product.setup.output"), systemImage: "doc.badge.checkmark").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L.string("product.setup.model"), systemImage: setup.connected ? "checkmark.circle.fill" : "cpu").font(.headline)
                            if !setup.providers.isEmpty {
                                Picker(L.string("settings.providers"), selection: $setup.selectedProvider) {
                                    ForEach(setup.providers) { value in Text(value.chatDisplayName).tag(Optional(value.id)) }
                                }
                            } else if !setup.loadingProviders { Text(L.string("settings.providers.empty")).font(.callout) }
                            HStack {
                                Button(L.string("settings.provider.add")) { showingProvider = true }
                                Button(L.string("common.refresh")) { setup.configurationChanged() }.disabled(setup.loadingProviders || !setup.isLoaded)
                                Button(L.string("product.setup.test")) { setup.testConnection() }.disabled(setup.provider == nil || setup.testing || setup.loadingProviders || !setup.isLoaded)
                                if setup.testing || setup.loadingProviders { ProgressView().controlSize(.small) }
                                if setup.connected { Text(L.string("settings.provider.test_ok")).foregroundStyle(.green).font(.caption) }
                            }
                            Text(L.string("product.setup.test.help")).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.string("product.setup.sources")).font(.headline)
                            if setup.template == "mail" {
                                Text(L.string("product.setup.mail.help")).font(.callout)
                                if setup.loadingMail { ProgressView().controlSize(.small) }
                                else if let sources = setup.mailSources, sources.enabledAccounts > 0, sources.syncedMessages > 0 {
                                    Text(L.format("product.setup.mail.ready", sources.enabledAccounts, sources.syncedMessages)).font(.caption).foregroundStyle(.secondary)
                                } else { Text(L.string("product.setup.mail.required")).font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    Button(L.string("common.refresh")) { Task { await setup.refreshMailSources() } }.disabled(setup.loadingMail)
                                    Button(L.string("product.setup.mail.configure")) {
                                        Task { if await setup.saveForNavigation() { onConfigureMail?() } }
                                    }.disabled(!setup.isLoaded || setup.starting)
                                }
                            } else {
                                Toggle(L.string("product.setup.sample"), isOn: $setup.useSample)
                                if !setup.useSample {
                                    Button(L.string("chat.attach.add")) { selectFiles() }.disabled(sourcePanel != nil)
                                    ForEach(Array(setup.sourceNames.enumerated()), id: \.offset) { index, name in
                                        HStack {
                                            Text(name).font(.caption)
                                                .help(setup.files.indices.contains(index) ? setup.files[index].path : name)
                                            Spacer()
                                            Button { setup.removeFile(at: index) } label: { Image(systemName: "xmark.circle") }
                                                .buttonStyle(.plain).accessibilityLabel(L.string("product.setup.sources.remove"))
                                        }
                                    }
                                    if setup.needsSourceReselection { Text(L.string("product.setup.sources.reselect")).font(.caption).foregroundStyle(.orange) }
                                    else if !setup.sourcesReady { Text(L.string("product.setup.sources.required")).font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Text(L.string("onboarding.privacy")).font(.caption).foregroundStyle(.secondary)
                    Text(L.string("product.setup.approvals")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let errorText = setup.errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L.string("onboarding.skip")) { onFinish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.string("product.setup.begin")) {
                    Task { if let request = await setup.request() { onFinish(request) } }
                }.buttonStyle(.borderedProminent).disabled(!setup.canStart)
            }
        }.padding(24).frame(width: 700, height: 690)
        .task { await setup.load() }
        .task(id: setup.isLoaded ? setup.template : "") {
            if setup.template == "mail" { await setup.refreshMailSources() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderConfigService.configurationDidChange)) { _ in
            setup.configurationChanged()
        }
        .sheet(isPresented: $showingProvider) {
            ProviderFormSheet(hub: hub, provider: nil) {
                showingProvider = false
                setup.configurationChanged()
            }
        }
        .onDisappear {
            setup.cancel()
            if let panel = sourcePanel, panel.isVisible { panel.cancel(nil) }
            sourcePanel = nil
        }
    }

    private func selectFiles() {
        guard sourcePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        sourcePanel = panel
        panel.begin { response in
            guard sourcePanel === panel else { return }
            if response == .OK { setup.selectFiles(panel.urls) }
            sourcePanel = nil
        }
    }
}
