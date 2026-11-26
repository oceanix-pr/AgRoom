import Foundation
import Testing
@testable import AgRoomCore

@Suite("Generated content stays out of diagnostics")
struct PrivateLogRegressionTests {
    @Test("failed skill and agent repairs do not log model output")
    func failedGenerationLogsOnlyDiagnostics() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvalidGenerationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = CloudProvider(config: .init(name: "Fixture", endpoint: "https://privacy-log.invalid/v1",
            model: "fixture"), apiKey: "synthetic", session: session)
        let existingIDs = Set(HubLogger.shared.entries.map(\.id))

        do {
            _ = try await SkillGenerator(provider: provider).generateInteractive(requirement: "synthetic",
                priorAnswer: nil)
            Issue.record("Invalid skill output should fail after one repair")
        } catch {
            #expect(error as? SkillGenerator.GeneratorError == .invalidJSON)
        }
        do {
            _ = try await AgentGenerator(provider: provider).generate(requirement: "synthetic")
            Issue.record("Invalid agent output should fail after one repair")
        } catch {
            #expect(error as? AgentGenerator.GeneratorError == .invalidJSON)
        }

        let entries = HubLogger.shared.entries.filter { !existingIDs.contains($0.id) }
        #expect(entries.contains { $0.message.contains("Skill generation decode failed: stage=initial") })
        #expect(entries.contains { $0.message.contains("Skill generation decode failed: stage=repair") })
        #expect(entries.contains { $0.message.contains("Agent generation decode failed: stage=initial") })
        #expect(entries.contains { $0.message.contains("Agent generation decode failed: stage=repair") })
        #expect(entries.allSatisfy { !$0.message.contains(InvalidGenerationProtocol.privateOutput) })
    }
}

private final class InvalidGenerationProtocol: URLProtocol, @unchecked Sendable {
    static let privateOutput = "PRIVATE_MODEL_OUTPUT_4A6B5B7E"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "privacy-log.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"\(Self.privateOutput)\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
