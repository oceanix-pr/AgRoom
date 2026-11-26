import Foundation
import ImageIO

/// Image-only models never enter text generation, title generation or tool planning.
public enum ImageGenerationError: Error, Sendable {
    case textModelRequired
    case unsupportedEndpoint
    case invalidImage
    case saveFailed
    case cannotResume
    case modelUnavailable
}

extension CloudProvider {
    public func isImageGenerationModel(for config: LLMConfig = .default) -> Bool {
        Self.isImageGenerationModel(requestModel(config))
    }

    public static func isImageGenerationModel(_ model: String) -> Bool {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return name.hasPrefix("gpt-image-") || name == "chatgpt-image-latest"
    }

    /// Retains the configured origin, gateway prefix and query. No credentials or
    /// request data are moved to a different service based on a model's name.
    func imageEndpoint(editing: Bool) throws -> URL {
        try EndpointSafety.validate(endpoint)
        guard !isAnthropic, var parts = URLComponents(string: endpoint) else {
            throw ImageGenerationError.unsupportedEndpoint
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let suffixes = ["/chat/completions", "/responses", "/images/generations", "/images/edits"]
        if let suffix = suffixes.first(where: { path.lowercased().hasSuffix($0) }) {
            path.removeLast(suffix.count)
        } else if !path.isEmpty, !path.lowercased().hasSuffix("/v1") {
            throw ImageGenerationError.unsupportedEndpoint
        }
        parts.path = path + (editing ? "/images/edits" : "/images/generations")
        guard let url = parts.url else { throw ImageGenerationError.unsupportedEndpoint }
        try EndpointSafety.validate(url.absoluteString)
        return url
    }

    func buildImageRequest(prompt: String, images: [EngineImage], config: LLMConfig) throws -> URLRequest {
        guard isImageGenerationModel(for: config) else { throw ImageGenerationError.textModelRequired }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 128 * 1024, images.count <= 16,
              images.allSatisfy({ ["image/png", "image/jpeg", "image/webp"].contains($0.mimeType)
                  && !$0.data.isEmpty && $0.data.count <= 5 * 1024 * 1024 }),
              images.reduce(0, { $0 + $1.data.count }) <= 20 * 1024 * 1024 else {
            throw ImageGenerationError.invalidImage
        }
        var request = URLRequest(url: try imageEndpoint(editing: !images.isEmpty))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let fields = ["model": requestModel(config), "prompt": prompt, "n": "1", "output_format": "png"]
        if images.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = fields
            body["n"] = 1
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            let boundary = "AgRoom-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func append(_ value: String) { body.append(Data(value.utf8)) }
            for key in fields.keys.sorted() {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
            }
            for (index, image) in images.enumerated() {
                let ext = image.mimeType == "image/jpeg" ? "jpg" : image.mimeType == "image/webp" ? "webp" : "png"
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"input-\(index).\(ext)\"\r\nContent-Type: \(image.mimeType)\r\n\r\n")
                body.append(image.data)
                append("\r\n")
            }
            append("--\(boundary)--\r\n")
            request.httpBody = body
        }
        return request
    }

    /// A single user-initiated Images request. HTTP rejection retries belong to
    /// the engine; ambiguous disconnects must not silently generate another image.
    public func generateImages(prompt: String, images: [EngineImage] = [], config: LLMConfig = .default) async throws -> ChatReply {
        let request = try buildImageRequest(prompt: prompt, images: images, config: config)
        let ticket = try await ProviderConcurrencyGate.shared.acquire(endpoint)
        defer { Task { await ProviderConcurrencyGate.shared.release(ticket) } }
        let progress = ProviderUsageProgress()
        return try await withUsage(model: requestModel(config), progress: progress) {
            let (data, response) = try await boundedData(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMError.networkError(statusCode: -1, message: "Invalid image response")
            }
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 401 { throw LLMError.invalidAPIKey }
                let body = String(decoding: data.prefix(4096), as: UTF8.self)
                throw LLMError.networkError(statusCode: http.statusCode, message: body)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LLMError.responseParsingFailed(reason: "Invalid image response")
            }
            var usage = ProviderTokenUsage.decode(json["usage"] as? [String: Any], anthropic: false)
            progress.observe(json, anthropic: false)
            // /images output tokens are image tokens by protocol. Do not infer
            // the input split when a gateway omitted input_tokens_details.
            if usage.outputImage == nil { usage.outputImage = usage.output }
            progress.merge(usage, anthropic: false)
            progress.update(input: usage.input, output: usage.output)
            // Request exactly one image and accept inline bytes only. Do not fetch
            // arbitrary provider URLs or forward the API key to an image host.
            guard let items = json["data"] as? [[String: Any]], items.count == 1,
                  let encoded = items[0]["b64_json"] as? String,
                  let bytes = Data(base64Encoded: encoded) else {
                throw ImageGenerationError.invalidImage
            }
            try Self.validateGeneratedPNG(bytes)
            return (ChatReply(text: "", toolCalls: [], promptTokens: usage.input,
                completionTokens: usage.output, usage: usage,
                generatedImages: [.init(data: bytes, mimeType: "image/png")]), usage.input, usage.output)
        }
    }

    static func validateGeneratedPNG(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 12 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else { throw ImageGenerationError.invalidImage }
    }
}
