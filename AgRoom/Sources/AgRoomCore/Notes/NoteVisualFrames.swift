import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public struct NoteVisualFrame: Sendable {
    public let seconds: Double
    public let jpeg: Data
    public init(seconds: Double, jpeg: Data) { self.seconds = seconds; self.jpeg = jpeg }
}
public enum NoteVisualFrames {
    public static func thumbnail(_ data: Data) throws -> Data {
        guard data.count <= NoteStore.maximumMediaBytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw NoteStoreError.invalidContent }
        return try jpeg(image)
    }
    public static func extract(from url: URL) async throws -> [NoteVisualFrame] {
        try await NoteKeyframeExtractor.extractKeyframes(from: url).map { .init(seconds: $0.time, jpeg: $0.jpegData) }
    }
    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw NoteStoreError.invalidContent }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 2 * 1024 * 1024 else { throw NoteStoreError.tooLarge }
        return data as Data
    }
}
