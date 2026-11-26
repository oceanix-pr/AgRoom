import SwiftUI
import AVKit
import AgRoomCore

struct NoteMediaPlayer: View {
    let player: AVPlayer
    @Bindable var model: NotesModel
    @State private var peaks: [Float] = []
    @State private var duration = 0.0
    @State private var loading = true
    @State private var failed = false
    var body: some View {
        VStack(spacing: 8) {
            VideoPlayer(player: player).frame(height: 180)
            if loading { ProgressView().controlSize(.small) }
            else if failed { Text(L.string("notes.waveform.failed")).font(.caption).foregroundStyle(.secondary) }
            else {
                GeometryReader { geo in
                    Canvas { context, size in
                        let width = size.width / Double(max(1,peaks.count))
                        for (index, peak) in peaks.enumerated() {
                            let height = max(1,Double(peak) * size.height)
                            context.fill(Path(CGRect(x: Double(index) * width,y: (size.height - height) / 2,width: max(1,width - 1),height: height)),with: .color(Double(index) / Double(peaks.count) * duration <= model.playbackTime ? .accentColor : .secondary.opacity(0.4)))
                        }
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in model.seek(min(1,max(0,value.location.x / max(1,geo.size.width))) * duration) })
                }.frame(height: 48).accessibilityLabel(L.string("notes.waveform"))
            }
            if duration > 0 {
                Slider(value: Binding(get: { min(duration,max(0,model.playbackTime)) },set: model.seek),in: 0...duration).accessibilityLabel(L.string("notes.transcript.seek"))
                HStack { Text(Duration.seconds(model.playbackTime).formatted(.time(pattern: .hourMinuteSecond))); Spacer(); Text(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond))) }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }.task(id: ObjectIdentifier(player)) {
            loading = true; failed = false
            do {
                guard let asset = player.currentItem?.asset as? AVURLAsset else { throw NoteStoreError.missing }
                duration = try await asset.load(.duration).seconds
                peaks = try await NoteWaveform.peaks(asset.url)
            } catch { if !Task.isCancelled { failed = true } }
            loading = false
        }
    }
}
