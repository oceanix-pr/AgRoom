import Foundation
import Observation
import SwiftUI
import AgRoomCore

@MainActor @Observable
final class MailComposePresetManager: Identifiable {
    let id = UUID()
    private let hub: Hub
    private let space: AppSpace
    private(set) var presets = MailComposePresets()
    private(set) var accounts: [MailAccount] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var selectedID: UUID?
    private(set) var editingNew = false
    var kind = MailComposePreset.Kind.signature
    var name = ""
    var text = ""
    var pendingDelete: MailComposePreset?
    var importAccount: MailAccount?
    private let initialImportAccountID: UUID?
    private(set) var importedFor: MailAccount?
    var useImportedAsDefault = false
    private var closed = false
    private var generation = UUID()
    var canEdit: Bool { editingNew || selectedID != nil }
    var dirty: Bool {
        if editingNew { return true }
        guard let old = presets.items.first(where: { $0.id == selectedID }) else { return false }
        return old.name != name || old.body != text || old.kind != kind
    }
    init(hub: Hub, space: AppSpace, importAccountID: UUID? = nil) {
        self.hub = hub; self.space = space; initialImportAccountID = importAccountID
    }

    func load(openImport: Bool = false) async {
        guard !busy, !closed, !dirty else { return }
        busy = true; error = nil
        let token = generation
        defer { if generation == token { busy = false } }
        do {
            guard let mail = hub.makeMailService(for: space), let owners = hub.makeMailAccountService(for: space) else { throw MailComposePresetError.changed }
            let value = try await mail.composePresets(), accounts = try await owners.getAll().filter { !$0.isLocalArchive }
            guard !closed, generation == token, !Task.isCancelled else { return }
            presets = value; self.accounts = accounts; resetEditor()
            if openImport { importAccount = accounts.first { $0.id == initialImportAccountID && $0.isEnabled } }
        } catch { if generation == token { self.error = MailErrorText.message(for: error) } }
    }

    func select(_ id: UUID) {
        guard !busy, !dirty, !closed, let item = presets.items.first(where: { $0.id == id }) else { return }
        selectedID = item.id; editingNew = false; name = item.name; text = item.body; kind = item.kind
    }
    func new(_ value: MailComposePreset.Kind) {
        guard !busy, !dirty, !closed else { return }
        resetEditor(); editingNew = true; kind = value
    }
    func resetEditor() {
        selectedID = nil; editingNew = false; name = ""; text = ""; kind = .signature
        importedFor = nil; useImportedAsDefault = false
    }

    func makeSyncService() -> MailSyncService? { hub.makeMailSyncService(for: space) }

    func editImportedSignature(_ body: String, account: MailAccount) {
        guard !busy, !closed, !dirty, importAccount?.id == account.id, !body.isEmpty else { return }
        new(.signature)
        name = L.format("mail.signature.accountName", account.displayName.isEmpty ? account.emailAddress : account.displayName)
        text = body; importedFor = account
        useImportedAsDefault = presets.defaultSignature(accountID: account.id) == nil
        importAccount = nil
    }

    func saveEditor() async {
        guard !busy, !closed, canEdit else { return }
        let item = MailComposePreset(id: selectedID ?? UUID(), kind: kind, name: name.trimmingCharacters(in: .whitespacesAndNewlines), body: text)
        var next = presets
        if let index = next.items.firstIndex(where: { $0.id == item.id }) { next.items[index] = item }
        else { next.items.append(item) }
        if item.kind != .signature { next.defaultSignatures = next.defaultSignatures.filter { $0.value != item.id } }
        if item.kind == .signature, let importedFor, useImportedAsDefault { next.defaultSignatures[importedFor.id.uuidString] = item.id }
        if await commit(next) { resetEditor(); select(item.id) }
    }
    func delete(_ item: MailComposePreset) async {
        guard !busy, !closed, !dirty else { return }
        var next = presets; next.items.removeAll { $0.id == item.id }
        next.defaultSignatures = next.defaultSignatures.filter { $0.value != item.id }
        if await commit(next) { resetEditor() }
    }
    func setDefault(_ signature: UUID?, account: UUID) async {
        guard !busy, !closed, !dirty else { return }
        var next = presets; next.defaultSignatures[account.uuidString] = signature
        _ = await commit(next)
    }
    private func commit(_ next: MailComposePresets) async -> Bool {
        busy = true; error = nil
        let token = generation
        defer { if generation == token { busy = false } }
        do {
            guard let mail = hub.makeMailService(for: space) else { throw MailComposePresetError.changed }
            let value = try await mail.saveComposePresets(next, replacing: presets)
            guard !closed, generation == token else { return false }
            presets = value; return true
        } catch { if generation == token { self.error = MailErrorText.message(for: error) }; return false }
    }
    func close() { closed = true; generation = UUID(); pendingDelete = nil; importAccount = nil }
}

struct MailComposePresetManagerView: View {
    @State var model: MailComposePresetManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.presets.title")).font(.headline)
            HStack {
                Button(L.string("mail.presets.newSignature")) { model.new(.signature) }
                Menu(L.string("mail.signature.import")) {
                    ForEach(model.accounts.filter(\.isEnabled)) { account in
                        Button(account.emailAddress) { model.importAccount = account }
                    }
                }.fixedSize().disabled(!model.accounts.contains(where: \.isEnabled))
                Button(L.string("mail.presets.newReply")) { model.new(.reply) }
                Button(L.string("common.refresh")) { Task { await model.load() } }
            }.disabled(model.busy || model.dirty)
            HSplitView {
                List {
                    ForEach(MailComposePreset.Kind.allCases, id: \.self) { kind in
                        Section(L.string("mail.presets.kind." + kind.rawValue)) {
                            ForEach(model.presets.items.filter { $0.kind == kind }) { item in
                                Button(item.name) { model.select(item.id) }.disabled(model.busy || model.dirty)
                            }
                        }
                    }
                }.frame(minWidth: 160, maxWidth: 210)
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L.string("mail.presets.kind"), selection: $model.kind) {
                        ForEach(MailComposePreset.Kind.allCases, id: \.self) { Text(L.string("mail.presets.kind." + $0.rawValue)).tag($0) }
                    }
                    TextField(L.string("mail.presets.name"), text: $model.name)
                    TextEditor(text: $model.text).font(.body).accessibilityLabel(L.string("mail.presets.text"))
                    if model.kind == .signature, let account = model.importedFor {
                        Toggle(L.format("mail.signature.useDefault", account.emailAddress), isOn: $model.useImportedAsDefault)
                    }
                    HStack {
                        Button(L.string("common.save")) { Task { await model.saveEditor() } }.disabled(!model.dirty)
                        Button(L.string("common.cancel")) { model.resetEditor() }
                        Spacer()
                        if let selected = model.presets.items.first(where: { $0.id == model.selectedID }) {
                            Button(L.string("common.delete"), role: .destructive) { model.pendingDelete = selected }.disabled(model.dirty)
                        }
                    }
                }.padding(8).disabled(model.busy || !model.canEdit)
            }.frame(minHeight: 260)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.accounts) { account in
                        Picker(account.displayName.isEmpty ? account.emailAddress : account.displayName,
                            selection: Binding<UUID?>(get: { model.presets.defaultSignatures[account.id.uuidString] },
                                set: { value in Task { await model.setDefault(value, account: account.id) } })) {
                            Text(L.string("mail.presets.none")).tag(nil as UUID?)
                            ForEach(model.presets.items.filter { $0.kind == .signature }) { Text($0.name).tag($0.id as UUID?) }
                        }
                    }
                }
            }.frame(maxHeight: 100).disabled(model.busy || model.dirty)
            Text(L.string("mail.presets.manageHint")).font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L.string("common.close")) { model.close(); dismiss() }.disabled(model.busy || model.dirty).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 700, height: 620)
            .task { await model.load(openImport: true) }.onDisappear { model.close() }
            .sheet(item: $model.importAccount) { account in
                MailSignatureImportView(account: account, makeService: model.makeSyncService) { text in
                    model.editImportedSignature(text, account: account)
                }
            }
            .alert(L.string("mail.presets.delete"), isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }), presenting: model.pendingDelete) { item in
                Button(L.string("common.delete"), role: .destructive) { model.pendingDelete = nil; Task { await model.delete(item) } }
                Button(L.string("common.cancel"), role: .cancel) { model.pendingDelete = nil }
            } message: { item in Text(L.format("mail.presets.deleteHint", item.name)) }
    }
}
