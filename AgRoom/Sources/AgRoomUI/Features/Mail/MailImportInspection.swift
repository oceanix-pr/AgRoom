import Foundation
import Observation
import SwiftUI
import AgRoomCore

struct MailImportInspectionSource: Sendable { let data: Data; let caption: String }

@MainActor @Observable
final class MailImportInspectionModel: Identifiable {
    let id = UUID()
    private let readSource: @MainActor () async throws -> MailImportInspectionSource
    private let revealSource: (@MainActor () async throws -> Void)?
    private var task: Task<Void, Never>?
    private var revealTask: Task<Void, Error>?
    private var generation = UUID()
    private(set) var content: MailImportInspection?
    private(set) var caption = ""
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isRevealing = false
    var canReveal: Bool { revealSource != nil && content != nil }

    init(readSource: @escaping @MainActor () async throws -> MailImportInspectionSource,
         revealSource: (@MainActor () async throws -> Void)? = nil) {
        self.readSource = readSource; self.revealSource = revealSource
    }

    func load() async {
        guard !isLoading else { return }
        cancel(); isLoading = true; error = nil
        let token = generation
        let work = Task {
            defer { if generation == token { isLoading = false; task = nil } }
            do {
                let source = try await readSource()
                try Task.checkCancellation()
                let parse = Task.detached { try autoreleasepool { try MailImportReader.inspect(source.data) } }
                let loaded = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                content = loaded; caption = source.caption
            } catch is CancellationError { }
            catch { if generation == token { self.error = MailErrorText.message(for: error) } }
        }
        task = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    func reveal() async {
        guard canReveal, !isRevealing, let revealSource else { return }
        let token = generation
        isRevealing = true
        let work = Task { try Task.checkCancellation(); try await revealSource() }
        revealTask = work
        defer { if generation == token { isRevealing = false; revealTask = nil } }
        do { try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch is CancellationError { }
        catch { if generation == token { self.error = MailErrorText.message(for: error) } }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        revealTask?.cancel(); revealTask = nil
        content = nil; isLoading = false; isRevealing = false
    }
}

struct MailImportInspectionView: View {
    @State var model: MailImportInspectionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.string("mail.import.inspect.title")).font(.headline)
            Text(L.string("mail.import.inspect.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.caption.isEmpty { Text(model.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.caption).textSelection(.enabled) }
            if let content = model.content {
                Text(content.envelope.subject.isEmpty ? L.string("mail.noSubject") : content.envelope.subject).font(.title3.weight(.semibold)).lineLimit(3).help(content.envelope.subject).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow { Text(L.string("mail.compose.from")).foregroundStyle(.secondary); Text(addresses([content.envelope.from])) }
                    GridRow { Text(L.string("mail.compose.to")).foregroundStyle(.secondary); Text(addresses(content.envelope.to)) }
                    if !content.envelope.cc.isEmpty { GridRow { Text(L.string("mail.compose.cc")).foregroundStyle(.secondary); Text(addresses(content.envelope.cc)) } }
                    if let date = content.envelope.date { GridRow { Text(L.string("mail.filter.date")).foregroundStyle(.secondary); Text(AppDate.string(from: date)) } }
                }.font(.caption).textSelection(.enabled)
                if !content.body.attachments.isEmpty {
                    DisclosureGroup(L.format("mail.attachments.count", content.body.attachments.count)) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(content.body.attachments.enumerated()), id: \.offset) { _, part in
                                    HStack {
                                        Image(systemName: "paperclip")
                                        Text(part.filename.isEmpty ? part.mimeType : part.filename).textSelection(.enabled)
                                        Spacer()
                                        if part.sizeBytes > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(part.sizeBytes), countStyle: .file)).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }.frame(maxHeight: 100)
                    }.font(.caption)
                }
                MailHTMLView(html: content.body.htmlBody, text: content.body.textBody)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.1)))
            } else if model.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Spacer() }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if model.canReveal { Button(L.string("mail.import.revealMessage")) { Task { await model.reveal() } }.disabled(model.isRevealing) }
                Spacer()
                if model.error != nil { Button(L.string("common.retry")) { Task { await model.load() } } }
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 720, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }

    private func addresses(_ values: [MailAddress]) -> String {
        values.map { $0.name.isEmpty ? $0.address : $0.name + " <" + $0.address + ">" }.joined(separator: ", ")
    }
}
