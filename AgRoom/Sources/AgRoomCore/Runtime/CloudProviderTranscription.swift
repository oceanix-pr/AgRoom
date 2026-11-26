import Foundation
import CryptoKit

extension CloudProvider {
    /// A non-secret checkpoint identity, invalidated by service configuration changes.
    public var transcriptionIdentity: String { NoteMediaTranscriber.sourceHash(Data((providerID.uuidString + "\n" + endpoint).utf8)) }
    public func transcribeAudio(_ audio: Data, modelName: String, language: String) async throws -> TranscriptionResult {
        guard !isAnthropic, !modelName.isEmpty, modelName.count <= 200, !modelName.contains(where: { $0.isNewline }),
              !audio.isEmpty, audio.count <= 25 * 1024 * 1024 else { throw LLMError.configurationError(reason: "Unsupported audio transcription configuration") }
        try EndpointSafety.validate(endpoint)
        guard var components = URLComponents(string: endpoint), components.user == nil, components.password == nil else { throw LLMError.providerUnavailable }
        var path = components.path
        for suffix in ["/chat/completions", "/responses", "/completions"] where path.hasSuffix(suffix) { path.removeLast(suffix.count); break }
        guard path.hasSuffix("/v1") || path.isEmpty || components.path.hasSuffix("/chat/completions") || components.path.hasSuffix("/responses") else { throw LLMError.configurationError(reason: "Audio transcription requires an OpenAI-compatible service") }
        components.path = path + "/audio/transcriptions"
        guard let url = components.url else { throw LLMError.providerUnavailable }
        let boundary = "agroom-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", modelName)
        field("response_format", modelName == "whisper-1" ? "verbose_json" : "json")
        let shortLanguage = language.split(separator: "-").first.map(String.init) ?? ""
        if (2...3).contains(shortLanguage.count), shortLanguage.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) { field("language", shortLanguage) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 180
        request.httpBody = body; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let frozen = request
        return try await withUsage(model: modelName) {
            try Task.checkCancellation()
            let (data, response) = try await boundedData(for: frozen)
            guard let response = response as? HTTPURLResponse else { throw LLMError.providerUnavailable }
            guard (200..<300).contains(response.statusCode) else { throw LLMError.networkError(statusCode: response.statusCode, message: "Audio transcription failed") }
            struct Output: Decodable {
                struct Segment: Decodable { let start: Double; let end: Double?; let text: String }
                let text: String
                let segments: [Segment]?
            }
            let value = try JSONDecoder().decode(Output.self, from: data)
            guard value.text.utf8.count <= NoteStore.maximumContentBytes,
                  value.segments?.allSatisfy({ segment in
                      segment.start.isFinite && segment.start >= 0 &&
                      (segment.end.map { $0.isFinite && $0 >= segment.start } ?? true)
                  }) != false else { throw LLMError.responseTooLarge }
            let segments = value.segments?.map { TranscriptSegment(text: $0.text, timestamp: $0.start, endTimestamp: $0.end) } ?? [TranscriptSegment(text: value.text, timestamp: 0)]
            return (TranscriptionResult(text: value.text, segments: segments), nil, nil)
        }
    }
}
