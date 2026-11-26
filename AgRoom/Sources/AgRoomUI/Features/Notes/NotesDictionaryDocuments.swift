import SwiftUI
import AgRoomCore

struct NotesDictionaryDocuments: View {
    @Bindable var model: NotesModel
    @State private var deleting: NoteDictionaryDocument?
    var body: some View {
        DisclosureGroup(L.string("notes.dictionary.documents")) {
            ForEach(model.processingPreferences.dictionaryDocuments ?? []) { document in
                VStack(alignment: .leading) {
                    HStack {
                        TextField(L.string("notes.dictionary.name"),text: binding(document,\.name))
                        Button(role: .destructive) { deleting = document } label: { Image(systemName: "trash") }.help(L.string("notes.delete"))
                    }
                    TextEditor(text: binding(document,\.text)).font(.body.monospaced()).frame(minHeight: 100,maxHeight: 180)
                }.padding(.vertical,6)
            }
            Button(L.string("notes.dictionary.new")) {
                if model.processingPreferences.dictionaryDocuments == nil { model.processingPreferences.dictionaryDocuments = [] }
                model.processingPreferences.dictionaryDocuments?.append(.init(name: L.string("notes.dictionary.new")))
            }.disabled((model.processingPreferences.dictionaryDocuments?.count ?? 0) >= 100)
        }
        .confirmationDialog(L.string("notes.dictionary.delete.confirm"),isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } }),titleVisibility: .visible) {
            Button(L.string("notes.delete"),role: .destructive) { if let deleting { model.processingPreferences.dictionaryDocuments?.removeAll { $0.id == deleting.id } }; deleting = nil }
        }
    }
    private func binding(_ document: NoteDictionaryDocument,_ path: WritableKeyPath<NoteDictionaryDocument,String>) -> Binding<String> {
        Binding(get: { model.processingPreferences.dictionaryDocuments?.first { $0.id == document.id }?[keyPath: path] ?? "" },set: { value in
            if let index = model.processingPreferences.dictionaryDocuments?.firstIndex(where: { $0.id == document.id }) { model.processingPreferences.dictionaryDocuments?[index][keyPath: path] = value }
        })
    }
}
