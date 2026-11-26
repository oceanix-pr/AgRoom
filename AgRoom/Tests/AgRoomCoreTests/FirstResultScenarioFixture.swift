import Foundation
@testable import AgRoomCore

/// A model protocol fixture that must consume actual read-tool receipts before
/// requesting a report. It never opens a network connection or reads sources itself.
enum FirstResultScenarioProvider {
    static func make(scenario: String, destination: URL? = nil, mailID: UUID? = nil) -> CloudProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FirstResultScenarioProtocol.self]
        config.httpAdditionalHeaders = ["X-Scenario":scenario, "X-Destination":destination?.path ?? "", "X-Mail-ID":mailID?.uuidString ?? ""]
        return CloudProvider(config: .init(name: "Disposable scenario", endpoint: "https://first-scenario.invalid/v1", model: "fixture"),
            apiKey: "synthetic", session: URLSession(configuration: config))
    }
}

private final class FirstResultScenarioProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "first-scenario.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
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
            let object = try JSONSerialization.jsonObject(with: data) as? [String:Any] ?? [:]
            let streaming = object["stream"] as? Bool == true
            let body: String
            if !streaming {
                body = #"{"choices":[{"message":{"role":"assistant","content":"connected"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#
            } else {
                let messages = object["messages"] as? [[String:Any]] ?? []
                let results = messages.filter { $0["role"] as? String == "tool" }
                let scenario = request.value(forHTTPHeaderField: "X-Scenario") ?? ""
                func has(_ id: String) -> Bool { results.contains { $0["tool_call_id"] as? String == id } }
                var calls: [(String,String,[String:Any])] = []
                if !has("source-read-0"), scenario == "mail" {
                    if !has("source-list") { calls = [("source-list","mail_list",["limit":10])] }
                    else { calls = [("source-read-0","mail_read",["messageId":request.value(forHTTPHeaderField: "X-Mail-ID") ?? ""])] }
                } else if !has("source-read-0") {
                    let user = messages.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
                    let paths = user.components(separatedBy: .newlines).compactMap { line -> String? in
                        guard line.hasPrefix("- /"), let end = line.range(of: " (file)") else { return nil }
                        return String(line.dropFirst(2).prefix(upTo: end.lowerBound))
                    }
                    guard paths.count >= (scenario == "compare" ? 2 : 1) else { throw URLError(.cannotParseResponse) }
                    calls = paths.prefix(scenario == "compare" ? 2 : 1).enumerated().map { ("source-read-\($0.offset)", "files_read", ["path":$0.element]) }
                } else if !has("report-write") {
                    let evidence = results.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
                    guard evidence.contains("SYNTHETIC EVIDENCE") else { throw URLError(.cannotParseResponse) }
                    let report = "# \(scenario.capitalized) report\n\n## Sources and evidence\n\n\(evidence)\n\n## Findings\n" +
                        (scenario == "compare" ? "The supplied dates conflict: Wednesday and Friday. Confirm the launch date.\n" :
                         scenario == "mail" ? "Local cached INBOX only, at most 10 messages. Review the requested decision; no message was sent, marked or deleted.\n" : "Review the evidence and confirm the unresolved launch date.\n")
                    calls = [("report-write","files_write",["path":request.value(forHTTPHeaderField: "X-Destination") ?? "","content":report])]
                }
                let delta: [String:Any]
                let reason: String
                if calls.isEmpty {
                    let write = results.first { $0["tool_call_id"] as? String == "report-write" }?["content"] as? String ?? ""
                    delta = ["content":write.contains("Written ") ? "Report saved from actual read receipts. Review the retained report and its sources." : "The report write did not complete. Review the rejected operation before continuing."]
                    reason = "stop"
                }
                else {
                    delta = ["tool_calls":try calls.enumerated().map { index,call in
                        ["index":index,"id":call.0,"type":"function","function":["name":call.1,"arguments":String(decoding: try JSONSerialization.data(withJSONObject: call.2), as: UTF8.self)]] as [String:Any]
                    }]; reason = "tool_calls"
                }
                let event: [String:Any] = ["choices":[["index":0,"delta":delta,"finish_reason":reason]],"usage":["prompt_tokens":40,"completion_tokens":20]]
                body = "data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type":streaming ? "text/event-stream" : "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
