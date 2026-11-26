import AppKit
import SwiftUI
import AgRoomCore

struct MailSignatureImportView: View {
    let account: MailAccount
    let makeService: @MainActor () -> MailSyncService?
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [RemoteMailFolder] = []
    @State private var folderPath = ""
    @State private var sources: [MailSignatureSource] = []
    @State private var sourceID: UInt32?
    @State private var preview: MailSignaturePreview?
    @State private var selection = ""
    @State private var busy = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.signature.import")).font(.headline)
            Text(account.emailAddress).foregroundStyle(.secondary)
            Text(L.string("mail.signature.webmailHint")).font(.callout)
            Picker(L.string("mail.signature.folder"), selection: Binding(get: { folderPath }, set: { selectFolder($0) })) {
                ForEach(folders, id: \.path) { folder in Text(folder.name).tag(folder.path) }
            }.disabled(folders.isEmpty)
            Picker(L.string("mail.signature.message"), selection: Binding(get: { sourceID }, set: { selectSource($0) })) {
                Text(L.string("mail.signature.chooseMessage")).tag(nil as UInt32?)
                ForEach(sources) { source in
                    Text([source.date.map { AppDate.string(from: $0) }, source.subject.isEmpty ? L.string("mail.noSubject") : source.subject]
                        .compactMap { $0 }.joined(separator: " · ")).tag(Optional(source.id))
                }
            }.disabled(sources.isEmpty)
            if let preview {
                Text(L.string("mail.signature.selectText")).font(.callout)
                SignatureSelectionView(preview: preview, selection: $selection)
                    .id(sourceID)
                    .accessibilityLabel(L.string("mail.signature.selectText"))
            } else {
                Spacer()
                if !busy, error == nil, folders.isEmpty || sources.isEmpty {
                    Text(L.string(folders.isEmpty ? "mail.signature.noFolder" : "mail.signature.noMessages")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if selection.utf8.count > 32 * 1024 { Text(L.string("mail.presets.error.capacity")).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(L.string("common.refresh"), action: loadFolders)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L.string("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.string("mail.signature.useSelection")) { onImport(selection) }
                    .disabled(busy || selection.isEmpty || selection.utf8.count > 32 * 1024).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 620, height: 470)
        .onAppear(perform: loadFolders).onDisappear { work?.cancel() }
    }

    private func loadFolders() {
        folders = []; folderPath = ""; sources = []; sourceID = nil
        read { service in
            let values = try await service.signatureFolders(account: account).sorted {
                if $0.role != $1.role { return $0.role == .sent }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            try Task.checkCancellation()
            folders = values
            if let first = values.first { folderPath = first.path; try await loadSources(first, service: service) }
        }
    }

    private func selectFolder(_ path: String) {
        guard let folder = folders.first(where: { $0.path == path }) else { return }
        folderPath = path; sources = []; sourceID = nil
        read { service in try await loadSources(folder, service: service) }
    }

    private func loadSources(_ folder: RemoteMailFolder, service: MailSyncService) async throws {
        let result = try await service.signatureSources(account: account, folder: folder)
        try Task.checkCancellation()
        sources = result
    }

    private func selectSource(_ id: UInt32?) {
        sourceID = id
        read { service in
            guard let source = sources.first(where: { $0.id == id }) else { return }
            let value = try await service.signaturePreview(from: source)
            try Task.checkCancellation()
            preview = value
            if let range = value.suggestedRange { selection = (value.text as NSString).substring(with: range) }
        }
    }

    private func read(_ operation: @escaping @MainActor (MailSyncService) async throws -> Void) {
        work?.cancel()
        preview = nil; selection = ""; error = nil; busy = true
        work = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                guard let service = makeService() else { throw MailSearchError.unavailable }
                try await operation(service)
            } catch { if !Task.isCancelled { self.error = MailErrorText.message(for: error) } }
        }
    }
}

private struct SignatureSelectionView: NSViewRepresentable {
    let preview: MailSignaturePreview
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 14); text.textContainerInset = NSSize(width: 8, height: 8)
        text.string = preview.text
        if let range = preview.suggestedRange { text.setSelectedRange(range); text.scrollRangeToVisible(range) }
        text.delegate = context.coordinator
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var selection: String
        init(selection: Binding<String>) { _selection = selection }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            selection = (text.string as NSString).substring(with: text.selectedRange()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
