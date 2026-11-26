import Foundation
import AVFoundation

public enum NoteWaveform {
    public static func peaks(_ url: URL, buckets: Int = 320) async throws -> [Float] {
        let task = Task.detached { () throws -> [Float] in
            let asset = AVURLAsset(url: url), duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 28_800, (16...1024).contains(buckets), let track = try await asset.loadTracks(withMediaType: .audio).first else { throw NoteStoreError.invalidContent }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track,outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:8000, AVNumberOfChannelsKey:1, AVLinearPCMIsFloatKey:true, AVLinearPCMBitDepthKey:32, AVLinearPCMIsNonInterleaved:false])
            reader.add(output); guard reader.startReading() else { throw NoteStoreError.invalidContent }
            defer { reader.cancelReading() }
            var peaks = [Float](repeating: 0,count: buckets), frame = 0
            let perBucket = max(1,Int(ceil(duration * 8000 / Double(buckets))))
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { throw NoteStoreError.invalidContent }
                let size = CMBlockBufferGetDataLength(block)
                guard size % 4 == 0, size <= 16 * 1024 * 1024 else { throw NoteStoreError.tooLarge }
                var values = [Float](repeating: 0,count: size / 4)
                let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: size,destination: $0.baseAddress!) }
                guard status == noErr else { throw NoteStoreError.invalidContent }
                for value in values { let index = min(buckets - 1,frame / perBucket); if value.isFinite { peaks[index] = max(peaks[index],min(abs(value),1)) }; frame += 1 }
            }
            guard reader.status == .completed else { throw NoteStoreError.invalidContent }
            return peaks
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
