import SwiftUI
import AgRoomCore

struct NotesWorkflowPreview: View {
    @Bindable var model: NotesModel
    let plan: NoteWorkflowPlan
    @Environment(\.dismiss) private var dismiss
    private var plans: [NoteWorkflowPlan] { model.pendingBatchPlans.isEmpty ? [model.pendingWorkflow ?? plan] : model.pendingBatchPlans }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.string("notes.pipeline.preview")).font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(plans) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.note.title).font(.headline)
                            ForEach(item.steps, id: \.self) { step in Label(L.string("notes.step." + step.rawValue), systemImage: "checkmark.circle") }
                            ForEach(item.skipped, id: \.self) { step in Text(L.format("notes.pipeline.skipped", L.string("notes.step." + step.rawValue))).foregroundStyle(.secondary) }
                            if item.steps.contains(.transcription), !item.note.transcript.isEmpty { Text(L.string("notes.pipeline.overwrite")).foregroundStyle(.orange) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L.string("notes.pipeline.scope")).font(.callout).foregroundStyle(.secondary)
            Toggle(L.string("notes.pipeline.background"), isOn: $model.allowBackground)
            Text(L.string("notes.pipeline.reminders.manual")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L.string("notes.cancel")) { model.pendingWorkflow = nil; model.pendingBatchPlans = []; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.string("notes.pipeline.start")) { model.confirmWorkflow(); dismiss() }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.padding(24).frame(width: 620, height: 580)
    }
}
