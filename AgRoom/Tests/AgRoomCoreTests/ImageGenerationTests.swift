import Foundation
import CoreGraphics
import ImageIO
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Image model requests and conversation results")
struct ImageGenerationTests {
    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let result = NSMutableData()
        let target = try #require(CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(target))
        return result as Data
    }

    private func answer(_ data: Data) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "data": [["b64_json": data.base64EncodedString()]],
            "usage": ["input_tokens": 50, "output_tokens": 100]
        ]), as: UTF8.self)
    }

    private func provider(endpoint: String = "https://relay.invalid/prefix/v1/chat/completions?tenant=fixture",
                          replies: [CompatibilityProtocol.Reply]) -> (CloudProvider, String) {
        let id = UUID().uuidString
        CompatibilityProtocol.register(id, replies: replies)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CompatibilityProtocol.self]
        session.httpAdditionalHeaders = ["X-AgRoom-Test-Fixture": id]
        return (CloudProvider(config: .init(name: "Image fixture", endpoint: endpoint, model: "gpt-image-2.6-sunburst"),
            apiKey: "fixture-key", session: URLSession(configuration: session)), id)
    }

    @Test("Images use a same-origin image route with no text generation parameters", arguments: [
        "https://relay.invalid/prefix/v1/chat/completions?tenant=fixture",
        "https://relay.invalid/prefix/v1/responses?tenant=fixture",
        "https://relay.invalid/prefix/v1/images/generations?tenant=fixture"
    ])
    func imageRoute(_ endpoint: String) async throws {
        let data = try png()
        let (p, id) = provider(endpoint: endpoint, replies: [.init(body: try answer(data))])
        defer { CompatibilityProtocol.remove(id) }
        let reply = try await p.generateImages(prompt: "台湾花莲的风景")
        #expect(reply.generatedImages.first?.data == data)
        #expect(reply.promptTokens == 50 && reply.completionTokens == 100)
        let request = try #require(CompatibilityProtocol.requests(id).first)
        #expect(request.url.host == "relay.invalid" && request.url.path == "/prefix/v1/images/generations")
        #expect(request.url.query == "tenant=fixture")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["prompt"] as? String == "台湾花莲的风景")
        #expect(body["model"] as? String == "gpt-image-2.6-sunburst")
        #expect(Set(body.keys) == ["model", "prompt", "n", "output_format"])
    }

    @Test("Explicit reference images use multipart edits and stay on the same gateway")
    func edits() throws {
        let (p, id) = provider(replies: [])
        defer { CompatibilityProtocol.remove(id) }
        let request = try p.buildImageRequest(prompt: "Change the sky", images: [.init(data: try png(), mimeType: "image/png")], config: .default)
        #expect(request.url?.path == "/prefix/v1/images/edits")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"image[]\"") && body.contains("Change the sky"))
        #expect(!body.contains("max_tokens") && !body.contains("tools"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    }

    @Test("Text generation and internal title requests cannot accidentally generate images")
    func textEntryDenied() async throws {
        let (p, id) = provider(replies: [])
        defer { CompatibilityProtocol.remove(id) }
        await #expect(throws: ImageGenerationError.self) { try await p.generate(prompt: "title") }
        await #expect(throws: ImageGenerationError.self) { try await p.stream(prompt: "title") }
        await #expect(throws: ImageGenerationError.self) { try await p.chat(messages: [], tools: [], config: .default) }
        await #expect(throws: ImageGenerationError.self) {
            try await p.chatStream(messages: [], tools: [], config: .default, onDelta: { _ in })
        }
        #expect(CompatibilityProtocol.requests(id).isEmpty)
    }

    @Test("A direct image turn drops unrelated context, settles usage, and cannot be handed off")
    func imageTurn() async throws {
        let (p, id) = provider(replies: [.init(body: try answer(png()))])
        defer { CompatibilityProtocol.remove(id) }
        let budget = ExecutionBudgetLedger(maxTokens: 10_000, maxToolCalls: 10)
        let engine = DispatcherEngine(provider: p, tools: [], systemPrompt: String(repeating: "private system context ", count: 1000),
            budgetLedger: budget, contextTokenBudget: 64, allowsImageGeneration: true)
        let history = [EngineMessage(role: .user, text: "private old question")]
        #expect(engine.preparedHistory(history, userMessage: "draw").isEmpty)
        let outcome = try await engine.run(userMessage: "draw\n\n[Attached files]\n/local/private/path", history: history,
            imagePrompt: "draw")
        guard case .finished(_, _, _, let tokens, let input, let output, _) = outcome else { Issue.record("Image turn did not finish"); return }
        #expect(tokens == 150 && input == 50 && output == 100)
        let spent = await budget.spent, reserved = await budget.reserved
        #expect(spent == 150 && reserved == 0)
        #expect(engine.generatedImages.count == 1)
        #expect(engine.requestReport.toolNames.isEmpty && engine.requestReport.systemCharacters == 0)
        let request = try #require(CompatibilityProtocol.requests(id).first)
        let raw = String(decoding: request.body, as: UTF8.self)
        #expect(!raw.contains("private") && !raw.contains("Attached files"))
        #expect(engine.claimHandoffSnapshot() == nil)
        #expect(!engine.isAtRecoverableBoundary)
        await #expect(throws: ImageGenerationError.self) { try await engine.run(fromSnapshot: engine.takeSnapshot()) }
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("Only explicit HTTP rejection can retry an image request", arguments: [true, false])
    func retryBoundary(_ capacityRejection: Bool) async throws {
        let first = capacityRejection
            ? CompatibilityProtocol.Reply(status: 503, body: #"{"error":{"message":"No available capacity was found for the model"}}"#)
            : .init(body: "", failure: .networkConnectionLost)
        let (p, id) = provider(replies: [first, .init(body: try answer(png()))])
        defer { CompatibilityProtocol.remove(id) }
        let engine = DispatcherEngine(provider: p, tools: [], systemPrompt: "", allowsImageGeneration: true)
        if capacityRejection { _ = try await engine.run(userMessage: "draw", history: []) }
        else { await #expect(throws: URLError.self) { try await engine.run(userMessage: "draw", history: []) } }
        #expect(CompatibilityProtocol.requests(id).count == (capacityRejection ? 2 : 1))
    }

    @Test("Malformed images and external URLs are rejected without another generation or fetch", arguments: [
        #"{"data":[{"b64_json":"bm90LWFuLWltYWdl"}]}"#,
        #"{"data":[{"url":"https://other.invalid/private.png"}]}"#,
        #"{"data":[]}"#
    ])
    func invalidResult(_ body: String) async throws {
        let (p, id) = provider(replies: [.init(body: body), .init(body: try answer(png()))])
        defer { CompatibilityProtocol.remove(id) }
        let engine = DispatcherEngine(provider: p, tools: [], systemPrompt: "", allowsImageGeneration: true)
        await #expect(throws: ImageGenerationError.self) { try await engine.run(userMessage: "draw", history: []) }
        #expect(CompatibilityProtocol.requests(id).count == 1)
    }

    @Test("Image generation needs a foreground opt-in and respects task budgets")
    func guardedExecution() async throws {
        let (p, id) = provider(replies: [])
        defer { CompatibilityProtocol.remove(id) }
        let background = DispatcherEngine(provider: p, tools: [], systemPrompt: "")
        await #expect(throws: ImageGenerationError.self) { try await background.run(userMessage: "draw", history: []) }
        let constrained = DispatcherEngine(provider: p, tools: [], systemPrompt: "",
            budgetLedger: ExecutionBudgetLedger(maxTokens: 10, maxToolCalls: 10), allowsImageGeneration: true)
        await #expect(throws: BudgetError.self) { try await constrained.run(userMessage: "draw", history: []) }
        #expect(CompatibilityProtocol.requests(id).isEmpty)
    }

    @Test("Generated attachments reject directory links into another space")
    func storageBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generated-images-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let personal = root.appendingPathComponent("personal/attachments"), work = root.appendingPathComponent("work/attachments")
        let images = [EngineImage(data: try png(), mimeType: "image/png")]
        let saved = try AttachmentService.storeGeneratedImages(images, directory: personal)
        try FileManager.default.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: personal)
        #expect(throws: ImageGenerationError.self) { try AttachmentService.storeGeneratedImages(images, directory: work) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: personal.path).count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: saved[0].path)) == images[0].data)
    }

    @MainActor
    @Test("Image replies persist, switch versions, and survive backup after the original files are removed")
    func conversationResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-conversation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let service = SessionService(databaseQueue: queue)
        var session = ChatSession(title: "Synthetic image request")
        session.messages = [.init(role: .user, content: "Hualien landscape"), .init(role: .error, content: "Original failure")]
        let answerID = session.messages[1].id
        try await service.save(session)
        let data = try png()
        let (p, id) = provider(replies: [.init(body: try answer(data)), .init(body: try answer(data))])
        defer { CompatibilityProtocol.remove(id) }
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        let model = ChatViewModel(hub: Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue)),
            space: .work, workspaceRegistry: registry, observeHostServices: false,
            handoffStore: DaemonHandoffStore(baseDirectory: root.appendingPathComponent("handoffs")), draftDefaults: nil,
            makeEngine: { _ in DispatcherEngine(provider: p, tools: [], systemPrompt: "", allowsImageGeneration: true) },
            saveGeneratedImages: { images, owner in
                #expect(owner == .work)
                return try AttachmentService.storeGeneratedImages(images, directory: root.appendingPathComponent("source/work/attachments"))
            })
        await model.load()
        model.activeSessionId = session.id
        await model.retryLoadActiveMessages()
        let loadingDeadline = ContinuousClock.now + .seconds(10)
        while (model.session(id: session.id)?.isMessagesLoaded != true || model.session(id: session.id)?.messages.count != 2), ContinuousClock.now < loadingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.session(id: session.id)?.isMessagesLoaded == true)
        try #require(model.session(id: session.id)?.messages.count == 2)
        try #require(model.activeSessionId == session.id)
        var paths: [String] = []
        for _ in 0..<2 {
            model.retryAnswer(messageId: answerID)
            try #require(model.isAnyRunning, "Retry did not start: \(model.errorMessage ?? "no error")")
            let deadline = ContinuousClock.now + .seconds(10)
            while model.isAnyRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(!model.isAnyRunning && !model.isActiveSessionPersistFailed)
            let saved = try #require(try await service.fetch(id: session.id)?.messages.last)
            try #require(saved.role == .assistant && saved.runStatus == .succeeded, "Synthetic image run failed: \(saved.content)")
            #expect(saved.inputTokens == 50 && saved.outputTokens == 100)
            paths.append(try #require(saved.attachments?.first?.path))
        }
        #expect(Set(paths).count == 2)
        model.switchVariation(messageId: answerID, to: 1)
        #expect(model.sessions.first?.messages.last?.attachments?.first?.path == paths[0])
        model.switchVariation(messageId: answerID, to: 2)
        #expect(model.sessions.first?.messages.last?.attachments?.first?.path == paths[1])
        let sourceSession = try #require(model.session(id: session.id))
        // Version switching schedules UI persistence. Back up a durable copy in
        // its own store so the fixture does not race those pending UI writes.
        let backupQueue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(backupQueue)
        let backupSessions = SessionService(databaseQueue: backupQueue)
        try await backupSessions.save(sourceSession)
        let sourceBackup = BackupService(sessionService: backupSessions, memoryService: MemoryService(databaseQueue: backupQueue),
            skillStore: SkillStore(directoryURL: root.appendingPathComponent("source-skills")),
            spaceName: "work", workspacesProvider: { [] })
        let archive = root.appendingPathComponent("images.zip")
        #expect(try await sourceBackup.export(to: archive).attachments == 2)
        let restoredQueue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restoredQueue)
        let restoredSessions = SessionService(databaseQueue: restoredQueue)
        let destination = root.appendingPathComponent("restored/work/attachments")
        let targetBackup = BackupService(sessionService: restoredSessions, memoryService: MemoryService(databaseQueue: restoredQueue),
            skillStore: SkillStore(directoryURL: root.appendingPathComponent("target-skills")),
            spaceName: "work", workspacesProvider: { [] }, attachmentsDirectory: destination,
            audioDirectory: root.appendingPathComponent("audio"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("source"))
        _ = try await targetBackup.restore(from: archive)
        let restored = try #require(try await restoredSessions.getAll().first?.messages.last)
        #expect(Set(restored.allAttachments.map(\.path)).count == 2)
        for attachment in restored.allAttachments {
            #expect(attachment.path.hasPrefix(destination.path + "/"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: attachment.path)) == data)
        }
        #expect(CompatibilityProtocol.requests(id).count == 2)
    }

    @Test("Image endpoint receipts retain reported input modalities and image output for costs")
    func imageUsageBreakdown() async throws {
        let db = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(db)
        let service = UsageService(databaseQueue: db), id = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [["b64_json": try png().base64EncodedString()]],
            "usage": ["input_tokens": 50, "input_tokens_details": ["text_tokens": 20, "image_tokens": 30], "output_tokens": 100]
        ])
        CompatibilityProtocol.register(id, replies: [.init(body: String(decoding: body, as: UTF8.self))])
        defer { CompatibilityProtocol.remove(id) }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CompatibilityProtocol.self]
        session.httpAdditionalHeaders = ["X-AgRoom-Test-Fixture": id]
        let provider = CloudProvider(config: .init(name: "fixture", endpoint: "https://api.openai.com/v1", model: "gpt-image-2.6-sunburst"),
            apiKey: "fixture", session: URLSession(configuration: session), usageRecorder: ProviderUsageRecorder(service: service, source: "chat"))
        let reply = try await provider.generateImages(prompt: "fixture")
        #expect(reply.usage.inputText == 20 && reply.usage.inputImage == 30 && reply.usage.outputImage == 100)
        let receipts = try await service.exportRecords()
        #expect(receipts.count == 1 && receipts.first?.usage.hasCompleteImageTokenCounts == true)
        #expect(receipts.first?.usage.inputText == 20 && receipts.first?.usage.outputImage == 100)
    }

    @MainActor
    @Test("Capacity, invalid image and image-only model failures have three-language guidance")
    func localizedErrors() {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        var messages = Set<String>()
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            let error = LLMError.networkError(statusCode: 503, message: "No available capacity was found for the model")
            let message = L.errorDescription(error)
            messages.insert(message)
            #expect(message.contains("503"))
            #expect(L.actionableError(error, fallbackKey: "error.database") == message)
            #expect(!L.errorDescription(ImageGenerationError.invalidImage).hasPrefix("error."))
            #expect(!L.errorDescription(ImageGenerationError.textModelRequired).hasPrefix("error."))
        }
        #expect(messages.count == 3)
    }
}
