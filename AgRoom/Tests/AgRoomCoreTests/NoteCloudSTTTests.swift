import Foundation
import Testing
@testable import AgRoomCore

struct NoteCloudSTTTests {
    @Test func existingProviderCredentialsAndEndpointAreReused() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoteAudioProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let config = LLMProviderConfig(name: "Synthetic", endpoint: "https://notes.invalid/v1/chat/completions", model: "text-model")
        let provider = CloudProvider(config: config, apiKey: "synthetic-key", session: session)
        let result = try await provider.transcribeAudio(Data("synthetic-audio".utf8), modelName: "whisper-1", language: "en-US")
        #expect(result.text == "Synthetic transcript")
        #expect(result.segments.first?.timestamp == 1.5)
        #expect(result.segments.first?.endTimestamp == 3.25)
        let changed = CloudProvider(config: LLMProviderConfig(name: "Other", endpoint: "https://other.invalid/v1", model: "text-model"), apiKey: "synthetic-key", session: session)
        #expect(provider.transcriptionIdentity != changed.transcriptionIdentity)
    }
}
private final class NoteAudioProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.path == "/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"Synthetic transcript","segments":[{"start":1.5,"end":3.25,"text":"Synthetic transcript"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
