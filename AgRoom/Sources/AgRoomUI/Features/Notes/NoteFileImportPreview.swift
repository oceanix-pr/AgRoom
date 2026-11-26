import SwiftUI
import AgRoomCore

struct NoteFileImportPreview: View {
    @Bindable var model: NotesModel
    let package: NoteFilePackage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string("notes.import.preview")).font(.title2)
            Text(package.note.title).font(.headline)
            Text(package.note.createdAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            Text(L.format("notes.import.count", package.media.count, package.note.todos.count))
            Text(ByteCountFormatter.string(fromByteCount: Int64(package.media.reduce(0) { $0 + $1.bytes }), countStyle: .file)).font(.caption)
            ScrollView { Text(package.note.markdown).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }
            Text(L.format("notes.import.progress", model.importCompleted, model.importRemaining.count)).font(.caption)
            if !model.importFailures.isEmpty {
                DisclosureGroup(L.format("notes.import.failures", model.importFailures.count)) { ScrollView { Text(model.importFailures.joined(separator: "\n")).textSelection(.enabled) }.frame(maxHeight: 120) }
            }
            if model.busy { ProgressView(); Button(L.string("notes.cancel")) { model.cancel() } }
            HStack {
                Button(L.string("notes.close")) { model.closeFileImport(); dismiss() }.disabled(model.busy).keyboardShortcut(.cancelAction)
                Spacer()
                if !model.importRemaining.isEmpty {
                    Button(L.string("notes.import.skip")) { model.skipFileImport() }.disabled(model.busy)
                    Button(L.string("notes.import.all")) { model.confirmFileImport(all: true) }.disabled(model.busy)
                }
                Button(L.string("notes.import.confirm")) { model.confirmFileImport(all: false) }.disabled(model.busy).buttonStyle(.borderedProminent)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }.padding(24).frame(width: 700,height: 640).interactiveDismissDisabled(model.busy)
    }
}
