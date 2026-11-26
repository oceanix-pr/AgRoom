import Foundation
import AVFoundation

public struct NoteAudioPart: Sendable {
    public let url: URL
    public let offset: TimeInterval
    public let source: String
    public init(url: URL, offset: TimeInterval, source: String) { self.url = url; self.offset = offset; self.source = source }
}

public enum NoteAudioAssembler {
    public static func assemble(_ parts: [NoteAudioPart], to output: URL) async throws {
        guard !parts.isEmpty, parts.count <= 2000 else { throw NoteStoreError.invalidContent }
        let composition = AVMutableComposition()
        var tracks: [String: AVMutableCompositionTrack] = [:]
        for part in parts.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            guard part.offset.isFinite, part.offset >= 0, part.offset <= 28_800 else { throw NoteStoreError.invalidContent }
            let asset = AVURLAsset(url: part.url)
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 28_800,
                  let source = try await asset.loadTracks(withMediaType: .audio).first else { throw NoteStoreError.invalidContent }
            let track: AVMutableCompositionTrack
            if let existing = tracks[part.source] { track = existing }
            else {
                guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NoteStoreError.invalidContent }
                tracks[part.source] = added; track = added
            }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: CMTime(seconds: part.offset, preferredTimescale: 600))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.values.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(1 / Float(tracks.count), at: .zero)
            return parameters
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw NoteStoreError.invalidContent }
        exporter.audioMix = mix
        let handle = NoteAudioAssemblyHandle(exporter)
        try await TaskDeadline.run(until: Date().addingTimeInterval(300)) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await handle.exporter.export(to: output, as: .m4a)
            } onCancel: { handle.exporter.cancelExport() }
        }
    }
}
private final class NoteAudioAssemblyHandle: @unchecked Sendable {
    let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
}
