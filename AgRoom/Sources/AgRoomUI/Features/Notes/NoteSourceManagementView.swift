import SwiftUI
import AgRoomCore

struct NoteSourceCleanupPreview: View {
    @Bindable var model: NotesModel
    let plan: NoteSourceCleanupPlan
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text(L.string("notes.sources.cleanup")).font(.title2)
            Text(L.string("notes.sources.cleanup.hint"))
            Text(ByteCountFormatter.string(fromByteCount: Int64(plan.bytes),countStyle: .file)).font(.headline)
            List(plan.items,id: \.note.id) { item in
                VStack(alignment: .leading) {
                    Text(item.note.title).font(.headline)
                    ForEach(item.media) { file in Text(file.name).font(.caption).foregroundStyle(.secondary) }
                    if item.media.isEmpty { Text(L.string("notes.sources.none")).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button(L.string("notes.cancel")) { model.pendingCleanup = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.string("notes.sources.cleanup.confirm"),role: .destructive) { model.confirmCleanup(); dismiss() }.disabled(plan.bytes == 0)
            }
        }.padding(24).frame(width: 660,height: 560)
    }
}

struct NoteRecordingMergePreview: View {
    @Bindable var model: NotesModel
    let plan: NoteRecordingMergePlan
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text(L.string("notes.recordings.merge")).font(.title2)
            Text(L.string("notes.recordings.merge.hint"))
            Text(Duration.seconds(plan.duration).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
            List(plan.items,id: \.note.id) { item in
                HStack { Text(item.note.title); Spacer(); Text(item.note.createdAt,style: .date); Text(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) }
            }
            if let target = plan.items.last { Text(L.format("notes.recordings.merge.target",target.note.title)).font(.callout) }
            HStack {
                Button(L.string("notes.cancel")) { model.pendingMerge = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.string("notes.recordings.merge.confirm")) { model.confirmMerge(); dismiss() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 700,height: 520)
    }
}
