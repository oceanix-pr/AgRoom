import SwiftUI
import AgRoomCore

struct NoteTodoEditor: View {
    @State var todo: NoteTodo
    let save: (NoteTodo?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    private func optional(_ path: WritableKeyPath<NoteTodo, String?>) -> Binding<String> {
        Binding(get: { todo[keyPath: path] ?? "" }, set: { todo[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    var body: some View {
        VStack {
            Form {
                TextField(L.string("notes.newTodo"), text: $todo.title)
                TextField(L.string("notes.todo.owner"), text: optional(\.owner))
                TextField(L.string("notes.todo.notes"), text: optional(\.notes), axis: .vertical)
                TextField(L.string("notes.todo.link"), text: optional(\.url))
                TextField(L.string("notes.todo.evidence"), text: optional(\.evidenceQuote), axis: .vertical)
                Picker(L.string("notes.todo.priority"), selection: Binding(get: { todo.priority ?? 0 }, set: { todo.priority = $0 })) {
                    ForEach([0,1,5,9], id: \.self) { Text(L.string("notes.todo.priority.\($0)")).tag($0) }
                }
                Toggle(L.string("notes.due"), isOn: Binding(get: { todo.dueDate != nil }, set: { todo.dueDate = $0 ? Date() : nil }))
                if todo.dueDate != nil {
                    DatePicker(L.string("notes.due"), selection: Binding(get: { todo.dueDate ?? Date() }, set: { todo.dueDate = $0 }))
                    Toggle(L.string("notes.todo.alarm"), isOn: Binding(get: { todo.alarmOffsetMinutes != nil }, set: { todo.alarmOffsetMinutes = $0 ? 10 : nil }))
                    if todo.alarmOffsetMinutes != nil {
                        Stepper(String(format: L.string("notes.todo.minutes"), todo.alarmOffsetMinutes ?? 10), value: Binding(get: { todo.alarmOffsetMinutes ?? 10 }, set: { todo.alarmOffsetMinutes = $0 }), in: 0...525600)
                    }
                }
            }
            HStack {
                Button(L.string("notes.delete"), role: .destructive) { deleting = true }
                Spacer(); Button(L.string("notes.cancel")) { dismiss() }
                Button(L.string("notes.save")) { save(todo); dismiss() }.disabled(todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
        .confirmationDialog(L.string("notes.todo.delete"), isPresented: $deleting) { Button(L.string("notes.delete"), role: .destructive) { save(nil); dismiss() } }
    }
}
