import AgRoomCore
import Darwin
import ImageIO
import SwiftUI

/// One serial decoder bounds concurrent ImageIO allocations. Identical queued requests reuse the first result.
actor AttachmentThumbnailLoader {
    static let shared = AttachmentThumbnailLoader()
    private let cache = NSCache<NSString, CGImage>()
    private(set) var decodeCount = 0

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 256
    }

    struct Request: Hashable, Sendable {
        let space: AppSpace
        let path: String
        let pixels: Int
    }

    private func version(of request: Request) -> String? {
        var info = stat()
        guard stat(request.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return "\(request.space.rawValue):\(request.pixels):\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    func image(for request: Request) -> CGImage? {
        guard !Task.isCancelled, (1...1024).contains(request.pixels), let key = version(of: request) else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: request.pixels
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: request.path) as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled, version(of: request) == key else { return nil }
        decodeCount += 1
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Arm before decoding so an atomic replacement during the read also wakes the visible bubble.
    struct Watch: Sendable {
        let events: AsyncStream<Void>
        let cancel: @Sendable () -> Void
    }

    func watch(_ path: String) -> Watch {
        var fd = open(path, O_EVTONLY | O_CLOEXEC)
        if fd < 0 { fd = open(URL(fileURLWithPath: path).deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC) }
        guard fd >= 0 else { return Watch(events: AsyncStream { $0.finish() }, cancel: {}) }
        let descriptor = fd
        let (events, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .revoke, .write, .attrib], queue: .global(qos: .utility))
        source.setEventHandler {
            continuation.yield()
            continuation.finish()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return Watch(events: events, cancel: { source.cancel(); continuation.finish() })
    }
}

struct AttachmentThumbnail: View {
    let space: AppSpace
    let path: String
    let side: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var loaded: (AttachmentThumbnailLoader.Request, CGImage)?
    private var request: AttachmentThumbnailLoader.Request {
        .init(space: space, path: path, pixels: min(1024, max(1, Int((side * scale).rounded(.up)))))
    }

    var body: some View {
        Group {
            if let loaded, loaded.0 == request {
                Image(decorative: loaded.1, scale: scale).resizable().scaledToFill()
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .task(id: request) { [request] in
            let loader = AttachmentThumbnailLoader.shared
            while !Task.isCancelled {
                let changes = await loader.watch(request.path)
                defer { changes.cancel() }
                let image = await loader.image(for: request)
                guard !Task.isCancelled else { return }
                loaded = image.map { (request, $0) }
                var events = changes.events.makeAsyncIterator()
                guard await events.next() != nil else { return }
            }
        }
    }
}
