import AppKit
import AVKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Independent agent model routing")
struct AgentModelRoutingTests {
    @Test("Legacy JSON and database migration retain agents and isolate provider selections")
    func migrationAndIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("work.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareSpace(queue)
        let agent = Agent(name: "Legacy specialist", modelName: "legacy-model")
        try await AgentService(databaseQueue: queue).save(agent)
        try await queue.write { db in
            try db.execute(sql: "ALTER TABLE agents DROP COLUMN providerID")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2_agent_model_provider'")
        }
        try DatabaseBootstrap.prepareSpace(queue)
        let service = AgentService(databaseQueue: queue)
        var restored = try #require(try await service.getAll().first)
        #expect(restored.name == agent.name && restored.providerID == nil && restored.modelName == "legacy-model")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        json.removeValue(forKey: "providerID")
        #expect(try JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: json)).providerID == nil)
        restored.providerID = UUID(); restored.modelName = "specialist-model"
        try await service.save(restored)
        let reopened = try DatabaseQueue(path: path)
        try DatabaseBootstrap.prepareSpace(reopened)
        #expect(try await AgentService(databaseQueue: reopened).getAll().first == restored)
        let personal = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(personal)
        try await AgentService(databaseQueue: personal).save(agent)
        #expect(try await AgentService(databaseQueue: personal).getAll().first?.providerID == nil)
        #expect(try await service.getAll().first?.providerID == restored.providerID)
    }

    @Test("Inheritance, independent protocol and invalid providers never silently reroute")
    func resolverBoundaries() throws {
        let inherited = CloudProvider(config: .init(name: "Main", endpoint: "http://localhost/main", model: "main"), apiKey: "synthetic-main")
        let selected = LLMProviderConfig(name: "Specialist", endpoint: "https://api.anthropic.com/v1/messages", model: "specialist")
        let resolver = AgentProviderResolver(configurations: [selected]) { config, recorder in
            CloudProvider(config: config, apiKey: "synthetic-specialist", usageRecorder: recorder)
        }
        #expect(try resolver.resolve(Agent(name: "Inherited"), inheriting: inherited) === inherited)
        let agent = Agent(name: "Pinned", providerID: selected.id)
        let provider = try resolver.resolve(agent, inheriting: inherited)
        #expect(provider.providerID == selected.id && provider.isAnthropic && provider.model == selected.model)
        var disabled = selected; disabled.isEnabled = false
        #expect(throws: AgentModelError.self) { try AgentProviderResolver(configurations: [disabled]).resolve(agent, inheriting: inherited) }
        #expect(throws: AgentModelError.self) { try AgentProviderResolver(configurations: []).resolve(agent, inheriting: inherited) }
        #expect(throws: AgentModelError.self) { try AgentProviderResolver.resolve(agent, inheriting: inherited, using: nil) }
        var unsafe = selected; unsafe.endpoint = "http://example.invalid/v1/messages"
        #expect(throws: (any Error).self) { try AgentProviderResolver(configurations: [unsafe]).resolve(agent, inheriting: inherited) }
    }

    @Test("Ordinary delegation and team workers send the chosen model and record usage in the parent space")
    func bothExecutionPaths() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let other = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(other)
        let usage = UsageService(databaseQueue: queue)
        let recorder = ProviderUsageRecorder(service: usage, source: "agent-routing-test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentRoutingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let inherited = CloudProvider(config: .init(name: "Main", endpoint: "http://localhost/main", model: "main-model"),
            apiKey: "synthetic-main", session: session, usageRecorder: recorder)
        let selected = LLMProviderConfig(name: "Specialist", endpoint: "http://localhost/specialist", model: "provider-default")
        let resolver = AgentProviderResolver(configurations: [selected]) { config, recorder in
            CloudProvider(config: config, apiKey: "synthetic-specialist", session: session, usageRecorder: recorder)
        }
        let agent = Agent(name: "Researcher", modelName: "explicit-specialist", providerID: selected.id)
        let tools = DispatcherToolFactory.buildTools(provider: inherited, agents: [agent], memoryService: nil, agentProviderResolver: resolver)
        let tool = try #require(tools.first(where: { $0.definition.name == agent.toolName }))
        #expect(try await tool.execute(argumentsJSON: #"{"message":"Read synthetic context"}"#).contains("specialist reply"))
        var teamAgent = agent; teamAgent.modelName = ""
        let subtask = TeamSubtask(title: "Inspect", objective: "Use synthetic context", assignee: agent.name)
        let worker = try await DispatcherTeamWorkerFactory(provider: inherited, agents: [teamAgent], agentProviderResolver: resolver)
            .makeWorker(taskID: UUID(), plan: TeamPlan(goal: "Synthetic routing", subtasks: [subtask]), subtask: subtask, inputs: [], budget: .default)
        let result = try await worker.run()
        #expect(result.outcome == .succeeded)
        let receipts = try await usage.getRecords()
        #expect(receipts.count == 2)
        #expect(receipts.allSatisfy { $0.providerID == selected.id.uuidString && $0.status == "succeeded" })
        #expect(Set(receipts.map(\.requestedModel)) == ["explicit-specialist", "provider-default"])
        #expect(try await UsageService(databaseQueue: other).getStats().totalRequests == 0)
    }
}

private final class AgentRoutingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.path == "/specialist")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-specialist")
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let tools = body["tools"] as? [[String: Any]] ?? []
        let isTeam = tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "team_submit_result" }
        let hasResult = messages.contains { $0["role"] as? String == "tool" }
        let delta: [String: Any]
        if isTeam && !hasResult {
            delta = ["tool_calls": [["index": 0, "id": "result", "function": ["name": "team_submit_result", "arguments": #"{"outcome":"succeeded","summary":"Checked","artifacts":[],"evidence":[],"open_questions":[]}"#]]]]
        } else { delta = ["content": "specialist reply"] }
        let payload: [String: Any] = ["choices": [["delta": delta, "finish_reason": isTeam && !hasResult ? "tool_calls" : "stop"]], "usage": ["prompt_tokens": 10, "completion_tokens": 5]]
        let bytes = "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(bytes.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Conversation media and menu commands", .serialized)
@MainActor
struct ConversationMediaMenuTests {
    @Test("Video and audio links become media blocks while code, prose and images retain their semantics")
    func mediaParsing() throws {
        for source in ["[Demo](clip.MP4?download=1)", "![Speech](speech.m4a)", "> [Video](movie.mov)", "- [Audio](sound.wav)"] {
            let document = MarkdownParser.parse(source)
            let parts = MarkdownSegment.segments(from: document.blocks)
            #expect(parts.contains { if case .media = $0 { true } else { false } })
            #expect(MarkdownResourcePlan.keys(in: document.blocks).isEmpty)
        }
        for source in ["```\n[Video](clip.mp4)\n```", "Download [video](clip.mp4) here", "![Picture](photo.png)"] {
            #expect(!MarkdownSegment.segments(from: MarkdownParser.parse(source).blocks).contains { if case .media = $0 { true } else { false } })
        }
        #expect(ChatAttachment(name: "Movie.MOV", path: "/tmp/123", isImage: false).mediaKind == .video)
        #expect(ChatAttachment(name: "sound", path: "/tmp/voice.mp3", isImage: false).mediaKind == .audio)
    }

    @Test("Media references obey the conversation roots, forbidden space and symlink boundaries")
    func mediaScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let work = root.appendingPathComponent("work"), personal = root.appendingPathComponent("personal")
        for url in [work, personal] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        for url in [work, personal] { try Data([1, 2, 3]).write(to: url.appendingPathComponent("video.mp4")) }
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("escape"), withDestinationURL: personal)
        let context = MarkdownSourceContext(spaceID: "work", baseURL: work, allowedRoots: [work], forbiddenRoots: [personal])
        let loader = ConversationMediaLoader()
        let loaded = try await loader.load("video.mp4", context: context)
        #expect(loaded.path == work.appendingPathComponent("video.mp4").resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: loaded) == Data([1, 2, 3]))
        for source in ["../personal/video.mp4", "escape/video.mp4", personal.appendingPathComponent("video.mp4").absoluteString,
                       "http://example.invalid/video.mp4", "https://user:password@example.invalid/video.mp4"] {
            await #expect(throws: (any Error).self) { try await loader.load(source, context: context) }
        }
        let workspace = ChatWorkspace(name: "Work", path: work.path, space: .work)
        let strict = MarkdownSourceContext.conversation(space: .work, workspace: workspace)
        #expect(strict.allowedRoots == workspace.folderURLs)
    }

    @Test("Remote media copies are bounded and removed with their owning loader")
    func boundedRemoteMedia() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MediaDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let context = MarkdownSourceContext()
        var loader: ConversationMediaLoader? = ConversationMediaLoader()
        let url = try await loader!.load("https://example.invalid/clip.mp4", context: context, session: session)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
        loader = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: (any Error).self) {
            try await ConversationMediaLoader().load("https://example.invalid/oversized.mp4", context: context, session: session)
        }
    }

    @Test("Playback rejects remote URLs and cancellation cannot revive a detached player")
    func playbackLifetime() async throws {
        let playback = ConversationMediaPlayback()
        await playback.load(URL(string: "https://example.invalid/video.mp4")!)
        #expect(playback.failed && playback.player == nil && !playback.isLoading)
        let task = Task { await playback.load(URL(fileURLWithPath: "/nonexistent/clip.mp4")) }
        task.cancel(); playback.stop()
        await task.value
        #expect(playback.player == nil && !playback.isLoading)
    }

    @Test("A generated local video loads in the native player and releases its item when stopped")
    func nativeVideoPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        CVPixelBufferGetBaseAddress(pixels)?.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for tick in 0..<2 {
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(tick), timescale: 1)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        let playback = ConversationMediaPlayback()
        await playback.load(url)
        let player = try #require(playback.player)
        #expect(!playback.failed && !playback.isLoading && player.currentItem != nil)
        #expect(player.currentItem?.asset.referenceRestrictions == .forbidAll)
        playback.pause(); #expect(player.rate == 0)
        playback.stop(); #expect(player.currentItem == nil && playback.player == nil)
    }

    @Test("Preview hosting windows remain resizable in both directions")
    func resizablePreview() async throws {
        _ = NSApplication.shared
        let attachment = ChatAttachment(name: "Synthetic image", path: "/nonexistent/preview.png", isImage: true)
        let resource = MarkdownRenderedResource(image: NSImage(size: NSSize(width: 32, height: 32)))
        let previews = [AnyView(ImageViewerSheet(attachment: attachment)),
            AnyView(MarkdownResourcePreview(resource: resource, name: "Markdown image")),
            AnyView(ConversationMediaPreview(name: "Video", playback: ConversationMediaPlayback()))]
        for preview in previews {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = NSHostingView(rootView: preview)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(window.styleMask.contains(.resizable))
            window.setContentSize(NSSize(width: 1050, height: 720))
            #expect(window.contentLayoutRect.width >= 1000)
            window.setContentSize(NSSize(width: 520, height: 360))
            #expect(window.contentLayoutRect.width < 600)
        }
    }

    @Test("Commands survive window recreation once and cannot be delivered into another space")
    func pendingCommands() throws {
        let navigation = AppNavigation()
        let inbox = MenuCommandInbox()
        let token = NotificationCenter.default.addObserver(forName: AppNavigation.CommandRequest.notification, object: nil, queue: nil) { notification in
            if let value = notification.object as? AppNavigation.CommandRequest {
                MainActor.assumeIsolated { inbox.received.append(value) }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        navigation.perform(.newChat, space: .work)
        #expect(inbox.received.isEmpty)
        navigation.deliverCommandIfNeeded(space: .work)
        #expect(inbox.received.count == 1 && inbox.received[0].command == .newChat)
        navigation.deliverCommandIfNeeded(space: .work)
        #expect(inbox.received.count == 1)
        navigation.perform(.artifactLibrary, space: .work)
        navigation.deliverCommandIfNeeded(space: .personal)
        #expect(inbox.received.count == 1)
        navigation.registerSpaceProvider { .personal }
        navigation.perform(.search, space: .personal)
        navigation.consume(try #require(inbox.received.last))
        navigation.deliverCommandIfNeeded(space: .personal)
        #expect(inbox.received.count == 2)
        #expect(Set(HubNavSection.allCases.flatMap(\.items)) == Set(HubNavItem.allCases.filter(\.isVisibleInSidebar)))
    }
}

@MainActor private final class MenuCommandInbox {
    var received: [AppNavigation.CommandRequest] = []
}

private final class MediaDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let oversized = request.url?.lastPathComponent == "oversized.mp4"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp4", "Content-Length": oversized ? "999999999" : "4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3, 4])); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
