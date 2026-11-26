import Foundation

private enum ResponseTextItem: Hashable {
    case id(String)
    case index(Int)
}

extension CloudProvider {
    func buildResponsesRequest(messages: [EngineMessage], tools: [ToolDefinition], config: LLMConfig,
                               stream: Bool, omitTemperature: Bool = false) throws -> URLRequest {
        let endpoint = requestEndpoint(for: config)
        try EndpointSafety.validate(endpoint)
        guard let url = URL(string: endpoint) else { throw LLMError.configurationError(reason: "Invalid Responses endpoint") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": requestModel(config), "max_output_tokens": config.maxTokens,
            "input": try responsesInput(messages, explicitCacheBoundaries: usesExplicitCacheBoundaries(config)), "stream": stream, "store": false,
            "include": ["reasoning.encrypted_content"]
        ]
        if let level = openAIReasoningLevel(config) { body["reasoning"] = ["effort": level] }
        if let threshold = nativeCompactionThreshold(config) {
            body["context_management"] = [["type": "compaction", "compact_threshold": threshold]]
        }
        if shouldSendTemperature(config, omit: omitTemperature) { body["temperature"] = config.temperature }
        if !tools.isEmpty {
            if config.requestToolChoiceNone == true { body["tool_choice"] = "none" }
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["type": "function", "name": tool.name, "description": tool.description,
                 "parameters": try validatedToolSchema(tool),
                 // Responses defaults to strict schema normalization. Keep the existing
                 // optional/default argument semantics and all original constraints.
                 "strict": false]
            }
        }
        applyPromptCaching(to: &body, config: config)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func responsesInput(_ messages: [EngineMessage], explicitCacheBoundaries: Bool = false) throws -> [[String: Any]] {
        var input: [[String: Any]] = []
        var boundaries = 0
        for message in messages {
            switch message.role {
            case .system:
                if explicitCacheBoundaries, boundaries < 2, !message.text.isEmpty {
                    input.append(["role": "developer", "content": [["type": "input_text", "text": message.text,
                        "prompt_cache_breakpoint": ["mode": "explicit"]]]])
                    boundaries += 1
                } else { input.append(["role": "system", "content": message.text]) }
            case .user:
                var content: [[String: Any]] = [["type": "input_text", "text": message.text]]
                for image in message.images {
                    content.append(["type": "input_image", "image_url": "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"])
                }
                input.append(["role": "user", "content": content])
            case .assistant:
                if let raw = message.continuation?.responsesItemsJSON {
                    try LLMResponseLimits.check(raw, limit: LLMResponseLimits.responseBytes)
                    guard let items = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
                        throw LLMError.responseParsingFailed(reason: "Invalid saved Responses output")
                    }
                    // Replay opaque reasoning, assistant phase and calls in their original order.
                    // Do not duplicate the text/toolCalls represented by these items.
                    input.append(contentsOf: items)
                } else {
                    if !message.text.isEmpty { input.append(["role": "assistant", "content": message.text]) }
                    for call in message.toolCalls {
                        input.append(["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.argumentsJSON])
                    }
                }
            case .toolResult:
                guard let id = message.toolCallId, !id.isEmpty else { throw LLMError.toolCallFinishMismatch }
                input.append(["type": "function_call_output", "call_id": id, "output": message.text])
            }
        }
        return input
    }

    func parseResponsesReply(_ json: [String: Any]) throws -> ChatReply {
        let status = json["status"] as? String
        if status == "failed" || json["error"] is [String: Any] {
            let error = json["error"] as? [String: Any]
            throw LLMError.networkError(statusCode: -1, message: String((error?["message"] as? String ?? "Responses generation failed").prefix(4096)))
        }
        guard status == "completed" || status == "incomplete",
              let output = json["output"] as? [[String: Any]] else {
            throw LLMError.responseParsingFailed(reason: "Responses output is missing or not terminal")
        }
        let truncated = status == "incomplete"
        let incompleteReason = (json["incomplete_details"] as? [String: Any])?["reason"] as? String
        guard !truncated || incompleteReason == "max_output_tokens" else {
            throw LLMError.responseParsingFailed(reason: "Responses generation did not complete")
        }
        var text = "", reasoning = "", commentary = ""
        var calls: [ToolCallRaw] = []
        var ids = Set<String>()
        for item in output {
            switch item["type"] as? String {
            case "compaction":
                guard let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty else {
                    throw LLMError.responseParsingFailed(reason: "Compaction output is missing its opaque state")
                }
                try LLMResponseLimits.check(encrypted, limit: LLMResponseLimits.responseBytes)
            case "message":
                guard let content = item["content"] as? [[String: Any]] else { throw LLMError.responseParsingFailed(reason: "Invalid Responses message") }
                let value = Self.responsesMessageText(content)
                if item["phase"] as? String == "commentary" { commentary += value }
                else { text += value }
                try LLMResponseLimits.check(text)
                try LLMResponseLimits.check(commentary)
            case "reasoning":
                for part in item["summary"] as? [[String: Any]] ?? [] {
                    if let value = part["text"] as? String { reasoning += value }
                    try LLMResponseLimits.check(reasoning)
                }
            case "function_call":
                // Neither a partial call nor an incomplete response may execute tools.
                guard !truncated, item["status"] as? String != "incomplete",
                      item["status"] as? String != "in_progress",
                      let id = item["call_id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                      let name = item["name"] as? String, !name.isEmpty,
                      let arguments = item["arguments"] as? String else { throw LLMError.toolCallFinishMismatch }
                try LLMResponseLimits.check(arguments, limit: LLMResponseLimits.argumentBytes)
                guard (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any] else {
                    throw LLMError.responseParsingFailed(reason: "Incomplete or invalid Responses tool arguments")
                }
                calls.append(.init(id: id, name: name, argumentsJSON: arguments))
                guard calls.count <= LLMResponseLimits.toolCalls else { throw LLMError.responseTooLarge }
            default:
                // Only function tools were advertised. Never reinterpret other call types.
                throw LLMError.responseParsingFailed(reason: "Unsupported Responses output item")
            }
        }
        guard !text.isEmpty || commentary.isEmpty || !calls.isEmpty else { throw LLMError.reasoningOnlyResponse }
        let data = try JSONSerialization.data(withJSONObject: output)
        guard data.count <= LLMResponseLimits.responseBytes else { throw LLMError.responseTooLarge }
        var usage = ProviderTokenUsage.decode(json["usage"] as? [String: Any], anthropic: false)
        usage.reportedModel = json["model"] as? String
        let reply = ChatReply(text: text, toolCalls: calls, promptTokens: usage.input, completionTokens: usage.output,
            finishReason: truncated ? "length" : (calls.isEmpty ? "stop" : "tool_calls"), reasoning: reasoning.isEmpty ? nil : reasoning,
            usage: usage, continuation: .init(responsesItemsJSON: String(decoding: data, as: UTF8.self)),
            commentary: commentary.isEmpty ? nil : commentary)
        try LLMResponseLimits.validate(reply)
        return reply
    }

    private static func responsesMessageText(_ content: [[String: Any]]) -> String {
        content.compactMap { part -> String? in
            switch part["type"] as? String {
            case "output_text": part["text"] as? String
            case "refusal": part["refusal"] as? String
            default: nil
            }
        }.joined()
    }

    func parseResponsesStream(_ bytes: URLSession.AsyncBytes, requiresExplicitPhase: Bool, onDelta: @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)?, monitor: StreamActivityMonitor,
        usageProgress: ProviderUsageProgress, generation: StreamGenerationTracker?) async throws -> ChatReply {
        var payload = "", eventType = "", visible = "", reasoning = ""
        var arguments: [String: String] = [:]
        var commentary = "", allDeltas = ""
        var itemText: [ResponseTextItem: String] = [:]
        var hasUnidentifiedText = false
        var phasesByID: [String: String] = [:], phasesByIndex: [Int: String] = [:]
        var deferText = false

        func consume() throws -> ChatReply? {
            try Task.checkCancellation()
            guard !payload.isEmpty else { return nil }
            defer { payload = ""; eventType = "" }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                throw LLMError.responseParsingFailed(reason: "Invalid Responses stream event")
            }
            let type = json["type"] as? String ?? eventType
            if let response = json["response"] as? [String: Any] { usageProgress.observe(response, anthropic: false) }
            switch type {
            case "response.output_item.added":
                if let item = json["item"] as? [String: Any], item["type"] as? String == "message" {
                    let phase = item["phase"] as? String ?? (requiresExplicitPhase ? nil : "final_answer")
                    if let id = item["id"] as? String { phasesByID[id] = phase }
                    if let index = json["output_index"] as? Int { phasesByIndex[index] = phase }
                    guard max(phasesByID.count, phasesByIndex.count) <= 512 else { throw LLMError.responseTooLarge }
                }
            case "response.output_text.delta", "response.refusal.delta":
                if let delta = json["delta"] as? String {
                    allDeltas += delta
                    try LLMResponseLimits.check(allDeltas)
                    let id = json["item_id"] as? String, index = json["output_index"] as? Int
                    if let key = id.map(ResponseTextItem.id) ?? index.map(ResponseTextItem.index) {
                        itemText[key, default: ""] += delta
                        guard itemText.count <= 512 else { throw LLMError.responseTooLarge }
                    } else { hasUnidentifiedText = true }
                    let phase = id.flatMap { phasesByID[$0] } ?? index.flatMap { phasesByIndex[$0] }
                    // Some compatible servers omit item.added. The terminal object gives
                    // those deltas a reliable phase before any progress leaks into the answer.
                    if phase == nil { deferText = true }
                    if !deferText {
                        generation?.observe(delta)
                        if phase == "commentary" { commentary += delta; onReasoningDelta?(delta) }
                        else { visible += delta; onDelta(delta) }
                    }
                }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = json["delta"] as? String {
                    reasoning += delta; try LLMResponseLimits.check(reasoning)
                    generation?.observe(delta); onReasoningDelta?(delta)
                }
            case "response.function_call_arguments.delta":
                guard let delta = json["delta"] as? String,
                      let id = json["item_id"] as? String else { throw LLMError.toolCallFinishMismatch }
                arguments[id, default: ""] += delta
                guard arguments.count <= LLMResponseLimits.toolCalls else { throw LLMError.responseTooLarge }
                try LLMResponseLimits.check(arguments[id] ?? "", limit: LLMResponseLimits.argumentBytes)
                generation?.observe(delta)
            case "response.completed", "response.incomplete":
                guard let response = json["response"] as? [String: Any] else { throw LLMError.toolCallFinishMismatch }
                let reply = try parseResponsesReply(response)
                try Task.checkCancellation()
                // The terminal object is canonical and includes complete, ordered output.
                // EOF, item.done or a final argument fragment alone is never completion.
                let output = response["output"] as? [[String: Any]] ?? []
                var wireText = ""
                for (index, item) in output.enumerated() where item["type"] as? String == "message" {
                    let value = Self.responsesMessageText(item["content"] as? [[String: Any]] ?? [])
                    let id = item["id"] as? String
                    let declaredPhase = id.flatMap { phasesByID[$0] } ?? phasesByIndex[index]
                    let keys: [ResponseTextItem] = [.index(index)] + (id.map { [.id($0)] } ?? [])
                    guard declaredPhase == nil || declaredPhase == (item["phase"] as? String ?? "final_answer"),
                          keys.allSatisfy({ key in
                              guard let delta = itemText.removeValue(forKey: key) else { return true }
                              return value.utf8.starts(with: delta.utf8)
                          }) else { throw LLMError.responseParsingFailed(reason: "Responses output item changed at completion") }
                    if hasUnidentifiedText { wireText += value }
                }
                let progress = reply.commentary ?? ""
                guard itemText.isEmpty, !hasUnidentifiedText || wireText.utf8.starts(with: allDeltas.utf8), reply.text.utf8.starts(with: visible.utf8),
                      progress.utf8.starts(with: commentary.utf8) else { throw LLMError.responseParsingFailed(reason: "Responses text changed at completion") }
                let progressTail = String(decoding: progress.utf8.dropFirst(commentary.utf8.count), as: UTF8.self)
                if !progressTail.isEmpty { generation?.observe(progressTail); onReasoningDelta?(progressTail) }
                let tail = String(decoding: reply.text.utf8.dropFirst(visible.utf8.count), as: UTF8.self)
                if !tail.isEmpty { generation?.observe(tail); onDelta(tail) }
                if let summary = reply.reasoning, summary.hasPrefix(reasoning) {
                    let tail = String(summary.dropFirst(reasoning.count))
                    if !tail.isEmpty { generation?.observe(tail); onReasoningDelta?(tail) }
                }
                return reply
            case "response.failed", "error":
                let error = json["error"] as? [String: Any]
                throw LLMError.networkError(statusCode: -1, message: String((error?["message"] as? String ?? json["message"] as? String ?? "Responses stream failed").prefix(4096)))
            default: break
            }
            return nil
        }

        for try await line in BoundedLLMLines(bytes: bytes) {
            try Task.checkCancellation()
            monitor.touch()
            if line.isEmpty {
                if let reply = try consume() { return reply }
            } else if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                if !payload.isEmpty { payload += "\n" }
                payload += value
                try LLMResponseLimits.check(payload, limit: LLMResponseLimits.eventBytes)
            }
        }
        try Task.checkCancellation()
        if let reply = try consume() { return reply }
        throw LLMError.streamIncomplete(partialCharacters: visible.count)
    }
}
