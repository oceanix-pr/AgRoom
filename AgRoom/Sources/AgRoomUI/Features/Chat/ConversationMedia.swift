import SwiftUI
import AVKit
import Observation
import AgRoomCore

struct MarkdownMediaReference {
    let source: String
    let name: String

    init?(_ nodes: [MarkdownInline]) {
        guard nodes.count == 1 else { return nil }
        let destination: String?
        let children: [MarkdownInline]
        switch nodes[0].content {
        case .link(let target, _, let content), .image(let target, _, let content):
            destination = target; children = content
        default: return nil
        }
        guard let destination, [.video, .audio].contains(ChatMediaKind.detect(destination)) else { return nil }
        source = destination; name = children.map(\.plainText).joined()
    }
}

/// Native playback belongs to the visible message, never a cross-space singleton.
@MainActor @Observable
final class ConversationMediaPlayback {
    private(set) var player: AVPlayer?
    private(set) var isLoading = false
    private(set) var failed = false
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?

    func load(_ url: URL) async {
        stop()
        let request = UUID(); requestID = request
        isLoading = true; failed = false
        defer { if requestID == request { isLoading = false } }
        do {
            guard url.isFileURL else { throw MarkdownResourceError.denied }
            let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
            let playable = try await TaskDeadline.run(until: Date().addingTimeInterval(15)) {
                try await withTaskCancellationHandler {
                    try await asset.load(.isPlayable)
                } onCancel: { asset.cancelLoading() }
            }
            guard playable else { throw MarkdownResourceError.invalid }
            try Task.checkCancellation()
            guard requestID == request else { return }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            self.player = player
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == request, failed else { return }
                    self.failed = true; self.player?.pause()
                }
            }
            player.play()
        } catch {
            if requestID == request, !Task.isCancelled { failed = true }
        }
    }

    func pause() { player?.pause() }

    func stop() {
        requestID = nil
        statusObserver?.invalidate(); statusObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        isLoading = false
    }
}

struct ConversationPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var isVideo = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = isVideo
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

/// A single controller is shared by inline and expanded playback. Opening a preview
/// does not start a second audio stream; closing it always pauses playback.
struct ConversationMediaCard: View {
    let name: String
    let kind: ChatMediaKind
    let loadURL: @Sendable () async throws -> URL
    @State private var playback = ConversationMediaPlayback()
    @State private var loadTask: Task<Void, Never>?
    @State private var resolvedURL: URL?
    @State private var loading = false
    @State private var failed = false
    @State private var showingPreview = false

    init(attachment: ChatAttachment) {
        name = attachment.name; kind = attachment.mediaKind
        let url = URL(fileURLWithPath: attachment.path)
        loadURL = { url }
    }

    init(name: String, kind: ChatMediaKind, loadURL: @escaping @Sendable () async throws -> URL) {
        self.name = name; self.kind = kind; self.loadURL = loadURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(name, systemImage: kind == .video ? "video" : "waveform")
                    .font(MeetTypography.secondary).lineLimit(1).help(name)
                Spacer(minLength: 8)
                if kind == .video {
                    Button { showingPreview = true } label: {
                        Label(L.string("md.resource.expand"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }.disabled(playback.player == nil || playback.failed)
                }
            }
            if let player = playback.player, !playback.failed {
                ConversationPlayerView(player: player, isVideo: kind == .video)
                    .frame(height: kind == .video ? 210 : 64)
            } else {
                Button(action: start) {
                    Label(L.string(failed || playback.failed ? "chat.media.retry" : "chat.media.play"), systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: kind == .video ? 120 : 44)
                }.disabled(loading || playback.isLoading)
                if failed || playback.failed {
                    Text(L.string("chat.media.failed")).font(MeetTypography.secondary).foregroundStyle(.secondary)
                }
            }
            if loading || playback.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(10).frame(maxWidth: 440)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showingPreview, onDismiss: { playback.pause() }) {
            ConversationMediaPreview(name: name, playback: playback)
        }
        .onDisappear {
            showingPreview = false
            loadTask?.cancel(); loadTask = nil
            playback.stop(); loading = false
        }
    }

    private func start() {
        loadTask?.cancel()
        loading = true; failed = false
        loadTask = Task { @MainActor in
            defer { if !Task.isCancelled { loading = false } }
            do {
                let url: URL
                if let resolvedURL { url = resolvedURL }
                else { url = try await loadURL() }
                try Task.checkCancellation()
                resolvedURL = url
                await playback.load(url)
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

struct ConversationMediaPreview: View {
    let name: String
    let playback: ConversationMediaPlayback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if let player = playback.player {
                ConversationPlayerView(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Color.clear }
        }
        .frame(minWidth: 480, idealWidth: 960, maxWidth: .infinity, minHeight: 320, idealHeight: 640, maxHeight: .infinity)
        .background(SheetResizeEnabler())
        .onDisappear { playback.pause() }
    }
}

/// Remote media is fetched only after Play, without cookies or credentials. The
/// player receives a bounded local copy so redirects cannot bypass URL validation.
actor ConversationMediaLoader {
    static let maximumBytes = 128 * 1_024 * 1_024
    private var temporaryURL: URL?
    private var temporarySource: String?
    private var temporaryContext: MarkdownSourceContext?

    deinit { if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }

    func load(_ source: String, context: MarkdownSourceContext, session testingSession: URLSession? = nil) async throws -> URL {
        try Task.checkCancellation()
        let url = try context.resolveImage(source)
        if url.isFileURL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw MarkdownResourceError.invalid }
            return url
        }
        if let temporaryURL, temporarySource == source, temporaryContext == context { return temporaryURL }
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL); self.temporaryURL = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 60
        let session = testingSession ?? URLSession(configuration: configuration, delegate: MarkdownImageSessionDelegate(), delegateQueue: nil)
        defer { if testingSession == nil { session.invalidateAndCancel() } }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MarkdownResourceError.failed }
        guard response.expectedContentLength <= Self.maximumBytes else { throw MarkdownResourceError.tooLarge }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw MarkdownResourceError.failed }
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: target) } }
        let file = try FileHandle(forWritingTo: target)
        defer { try? file.close() }
        var buffer = Data(); var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= Self.maximumBytes else { throw MarkdownResourceError.tooLarge }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try Task.checkCancellation(); try file.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation(); try file.write(contentsOf: buffer)
        temporaryURL = target; temporarySource = source; temporaryContext = context; committed = true
        return target
    }
}

struct MarkdownMediaBlock: View {
    let source: String
    let name: String
    let context: MarkdownSourceContext
    @State private var loader = ConversationMediaLoader()

    var body: some View {
        ConversationMediaCard(name: name.isEmpty ? (URL(string: source)?.lastPathComponent ?? source) : name,
            kind: ChatMediaKind.detect(source), loadURL: { try await loader.load(source, context: context) })
    }
}
