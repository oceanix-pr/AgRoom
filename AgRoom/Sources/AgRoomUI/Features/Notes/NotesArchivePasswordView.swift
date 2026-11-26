import SwiftUI

struct NotesArchivePasswordView: View {
    @Bindable var model: NotesModel
    let importing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.string(importing ? "notes.protected.import" : "notes.protected.export")).font(.title2)
            Text(L.string("notes.protected.hint")).foregroundStyle(.secondary)
            SecureField(L.string("notes.protected.password"), text: $password)
            if !importing { SecureField(L.string("notes.protected.confirm"), text: $confirm) }
            HStack {
                Button(L.string("notes.cancel")) { dismiss() }
                Spacer()
                Button(L.string("notes.protected.continue")) {
                    let value = password; password = ""; confirm = ""; dismiss()
                    model.protectedArchive(password: value, importing: importing)
                }.disabled(password.count < 12 || (!importing && password != confirm))
            }
        }.padding(24).frame(width: 500)
    }
}
