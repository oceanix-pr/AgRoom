import SwiftUI
import AgRoomCore

struct NoteTranscriptView: View {
    @Bindable var model: NotesModel
    @State private var query = ""
    @State private var replacement = ""
    @State private var editing = false
    @State private var selectedMatch = 0
    private var segments: [NoteSegment] { model.draft?.segments ?? [] }
    private var matches: [UUID] { segments.filter { !query.isEmpty && $0.text.localizedCaseInsensitiveContains(query) }.map(\.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L.string("notes.transcript.find"), text: $query)
                Button { selectedMatch -= 1 } label: { Image(systemName: "chevron.up") }.disabled(matches.isEmpty).help(L.string("notes.transcript.previous"))
                Button { selectedMatch += 1 } label: { Image(systemName: "chevron.down") }.disabled(matches.isEmpty).help(L.string("notes.transcript.next"))
                Text("\(matches.count)").foregroundStyle(.secondary)
                Toggle(L.string("notes.transcript.edit"), isOn: $editing).toggleStyle(.button)
            }
            if editing && !segments.isEmpty {
                HStack {
                    TextField(L.string("notes.transcript.replacement"), text: $replacement)
                    Button(L.string("notes.transcript.replace")) { replace(all: false) }.disabled(matches.isEmpty)
                    Button(L.string("notes.transcript.replaceAll")) { replace(all: true) }.disabled(matches.isEmpty)
                }
            }
            if segments.isEmpty {
                TextEditor(text: Binding(get: { model.draft?.transcript ?? "" }, set: { model.draft?.transcript = $0 })).readingBodyFont().frame(minHeight: 220)
            } else {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            segmentRow(segment, index: index).id(segment.id)
                        }
                    }
                    .onChange(of: selectedMatch) {
                        guard !matches.isEmpty else { return }
                        let index = ((selectedMatch % matches.count) + matches.count) % matches.count
                        proxy.scrollTo(matches[index], anchor: .center)
                    }
                    .onChange(of: query) { selectedMatch = 0; if let id = matches.first { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }
    private func segmentRow(_ segment: NoteSegment, index: Int) -> some View {
        let end = segment.endTimestamp ?? (index + 1 < segments.count ? segments[index + 1].timestamp : segment.timestamp + 3)
        let playing = model.player != nil && model.playbackTime >= segment.timestamp && model.playbackTime < end
        return HStack(alignment: .top, spacing: 12) {
            Button { model.playSegment(segment.timestamp) } label: {
                Text(Duration.seconds(segment.timestamp).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
            }.buttonStyle(.borderless).help(L.string("notes.transcript.seek"))
            VStack(alignment: .leading, spacing: 6) {
                if editing {
                    TextField(L.string("notes.speaker"), text: Binding(get: { model.draft?.segments.first { $0.id == segment.id }?.speaker ?? "" }, set: { value in
                        guard let old = model.draft?.segments.first(where: { $0.id == segment.id })?.speaker else { return }
                        if let indices = model.draft?.segments.indices { for i in indices where model.draft?.segments[i].speaker == old { model.draft?.segments[i].speaker = value } }
                    })).font(.caption).frame(maxWidth: 180)
                    TextField(L.string("notes.transcript"), text: Binding(get: { model.draft?.segments.first { $0.id == segment.id }?.text ?? "" }, set: { value in
                        if let i = model.draft?.segments.firstIndex(where: { $0.id == segment.id }) { model.draft?.segments[i].text = value; synchronize() }
                    }), axis: .vertical).readingBodyFont()
                } else {
                    if !segment.speaker.isEmpty { Text(segment.speaker).font(.caption).foregroundStyle(.secondary) }
                    Text(highlighted(segment.text)).readingBodyFont().textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(10).background(playing ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
    private func synchronize() { model.draft?.transcript = model.draft?.segments.map(\.text).joined(separator: "\n") ?? "" }
    private func replace(all: Bool) {
        guard !query.isEmpty, !matches.isEmpty else { return }
        let targets = all ? matches : [matches[((selectedMatch % matches.count) + matches.count) % matches.count]]
        guard let indices = model.draft?.segments.indices else { return }
        for index in indices where targets.contains(model.draft!.segments[index].id) {
            model.draft?.segments[index].text = model.draft!.segments[index].text.replacingOccurrences(of: query, with: replacement, options: .caseInsensitive)
        }
        synchronize()
    }
    private func highlighted(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        guard !query.isEmpty else { return value }
        var start = value.startIndex
        while start < value.endIndex, let range = value[start...].range(of: query, options: .caseInsensitive) {
            value[range].backgroundColor = .yellow.opacity(0.4); start = range.upperBound
        }
        return value
    }
}
