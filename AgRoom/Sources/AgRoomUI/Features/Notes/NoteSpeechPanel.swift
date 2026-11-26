import SwiftUI
import AVKit
import UniformTypeIdentifiers
import AgRoomCore

struct NoteSpeechPanel: View {
    @Bindable var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = "text"
    @State private var format = "m4a"
    @State private var working = false
    @State private var task: Task<Void,Never>?
    @State private var player: AVPlayer?
    @State private var temporary: URL?
    @State private var failure: String?
    @State private var generation = UUID()
    private var text: String { NoteSpeechText.prepare(source == "summary" ? model.draft?.summaries.last?.text ?? "" : source == "transcript" ? model.draft?.transcript ?? "" : model.draft?.text ?? "") }
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text(L.string("notes.speech.export")).font(.title2)
            Picker(L.string("notes.speech.source"),selection: $source) {
                Text(L.string("notes.text")).tag("text")
                Text(L.string("notes.transcript")).tag("transcript")
                Text(L.string("notes.summary.heading")).tag("summary")
            }.pickerStyle(.segmented)
            Picker(L.string("notes.speech.voice"),selection: $model.speechVoiceID) {
                Text(L.string("notes.speech.default")).tag("")
                ForEach(AVSpeechSynthesisVoice.speechVoices(),id: \.identifier) { Text($0.name + " · " + $0.language).tag($0.identifier) }
            }
            Slider(value: $model.speechRate,in: 0.25...0.65) { Text(L.string("notes.speech.rate")) }
            Picker(L.string("notes.speech.format"),selection: $format) { Text("M4A").tag("m4a"); Text("WAV").tag("wav") }.pickerStyle(.segmented)
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }.frame(minHeight: 180)
            if let player { VideoPlayer(player: player).frame(height: 64) }
            if working { HStack { ProgressView().controlSize(.small); Text(L.string("notes.processing")); Button(L.string("notes.cancel")) { task?.cancel() } } }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button(L.string("notes.close")) { stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.string("notes.speech.preview")) { generate(preview: true) }.disabled(working || text.isEmpty)
                Spacer()
                Button(L.string("notes.speech.export")) { generate(preview: false) }.disabled(working || text.isEmpty).buttonStyle(.borderedProminent)
            }
            Text(L.string("notes.speech.local.hint")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 680,height: 660)
            .onDisappear { stop() }
            .onChange(of: source) { stop() }
            .onChange(of: format) { stop() }
            .onChange(of: model.speechVoiceID) { stop(); Task { _ = await model.saveLocalPreferences() } }
            .onChange(of: model.speechRate) { stop(); Task { _ = await model.saveLocalPreferences() } }
    }
    private func generate(preview: Bool) {
        let input = preview ? String(text.prefix(600)) : text
        let destination: URL?
        if preview { destination = nil }
        else {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "note-speech." + format
            guard panel.runModal() == .OK else { return }; destination = panel.url
        }
        stop(); failure = nil; working = true
        let request = UUID(); generation = request
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporary = root
        let voice = model.speechVoiceID, rate = model.speechRate, locale = model.locale
        let outputFormat = preview ? "m4a" : format
        task = Task {
            defer { if generation == request { working = false; task = nil } }
            do {
                try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
                let output = root.appendingPathComponent("speech." + outputFormat)
                try await NoteSpeechExport().write(text: input,locale: locale,voiceID: voice.isEmpty ? nil : voice,rate: rate,to: output)
                try Task.checkCancellation()
                if let destination {
                    let staging = destination.deletingLastPathComponent().appendingPathComponent(".speech-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try await NoteFileTransfer.copy(output,to: staging)
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt: staging) }
                    else { try FileManager.default.moveItem(at: staging,to: destination) }
                    try? FileManager.default.removeItem(at: root); temporary = nil
                } else { player = AVPlayer(url: output); player?.play() }
            } catch is CancellationError { try? FileManager.default.removeItem(at: root) }
            catch { if generation == request { failure = L.actionableError(error,fallbackKey: "notes.error") }; try? FileManager.default.removeItem(at: root) }
        }
    }
    private func stop() {
        player?.pause(); player = nil
        let pending = task; pending?.cancel()
        generation = UUID(); task = nil; working = false
        if let root = temporary { Task { await pending?.value; try? FileManager.default.removeItem(at: root) } }
        temporary = nil
    }
}
