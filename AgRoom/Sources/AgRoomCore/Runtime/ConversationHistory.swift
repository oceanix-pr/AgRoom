import CryptoKit
import Foundation

/// One completed turn in its original provider format. Stored with the selected answer
/// in the space database. Earlier turns and system instructions are not duplicated here.
public struct ProviderTurnHistory: Codable, Equatable, Sendable {
    struct Origin: Codable, Equatable, Sendable {
        let space: AppSpace
        let sessionID: UUID
        let providerID: UUID
        let endpointDigest: String
        let model: String
        let scopeDigest: String
    }

    /// Exclude transient run IDs and issuance times. Reopening the same conversation
    /// with different directory or project access invalidates its provider history.
    struct Access: Encodable {
        let resources: RunResourceContext?
        let mode: PermissionMode?
        let workspace: UUID?
        let path: String?
        let directory: TaskDirectoryIdentity?
        let reads: [String]
        let writes: [String]
        let writeIdentities: [String: TaskDirectoryIdentity]
        let artifacts: [String]
        let capabilities: [String]
        let constraints: [String]

        init(resources: RunResourceContext?, context: ExecutionContext) {
            let scope = context.taskScope
            self.resources = resources
            mode = scope?.permissionMode ?? context.permissionPolicy?.mode
            workspace = scope?.workspaceID
            path = scope?.workspacePath
            directory = scope?.workspaceIdentity
            reads = scope?.readRoots.sorted() ?? []
            writes = scope?.writeRoots.sorted() ?? []
            writeIdentities = scope?.writeRootIdentities ?? [:]
            artifacts = scope?.artifactRoots.sorted() ?? []
            capabilities = scope?.capabilities.map(\.rawValue).sorted() ?? []
            constraints = scope?.constraints.map(\.rawValue).sorted() ?? []
        }
    }

    let origin: Origin
    let messages: [EngineMessageSnapshot]
    /// Opaque output can depend on every earlier item and the advertised tools.
    let prefixDigest: String?
    private var displayDigest: String?
    static let byteLimit = 1024 * 1024

    public func bound(to displayedText: String) -> Self? {
        guard messages.last?.text == displayedText else { return nil }
        var result = self
        result.displayDigest = ResponsesContextWindow.digest(displayedText)
        return result
    }

    func matchesDisplay(_ text: String) -> Bool { displayDigest == ResponsesContextWindow.digest(text) }

    static func digest<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash each message once while reconstructing several signed turns. A NUL byte
    /// separates JSON values (the encoder escapes NUL characters inside strings).
    struct Prefix {
        private var hash = SHA256()
        private var valid = true
        private let encoder = JSONEncoder()

        init(_ messages: [EngineMessage], _ tools: [ToolDefinition]) {
            encoder.outputFormatting = [.sortedKeys]
            add(tools)
            append(messages)
        }

        mutating func append(_ messages: [EngineMessage]) {
            for message in messages { add(EngineMessageSnapshot(message: message)) }
        }

        var digest: String? {
            valid ? hash.finalize().map { String(format: "%02x", $0) }.joined() : nil
        }

        private mutating func add<T: Encodable>(_ value: T) {
            guard valid, let bytes = try? encoder.encode(value) else { valid = false; return }
            hash.update(data: bytes)
            hash.update(data: Data([0]))
        }
    }

    init?(origin: Origin, request: [EngineMessage], pinnedUserDigest: String?, tools: [ToolDefinition], reply: ChatReply) {
        guard !reply.isTruncated, !reply.textUsedReasoningBackfill, !reply.text.isEmpty,
              reply.toolCalls.isEmpty, reply.generatedImages.isEmpty, let pinnedUserDigest,
              let start = request.lastIndex(where: { $0.role == .user && ResponsesContextWindow.digest($0.text) == pinnedUserDigest })
        else { return nil }
        var turn = Array(request[start...])
        turn.append(.init(role: .assistant, text: reply.text, continuation: reply.continuation))
        guard turn.count <= 512, turn.allSatisfy({ $0.images.isEmpty }),
              turn.contains(where: { !$0.toolCalls.isEmpty || $0.continuation?.reasoningContent != nil ||
                  $0.continuation?.alternateReasoning != nil || $0.continuation?.responsesItemsJSON != nil ||
                  $0.continuation?.anthropicBlocksJSON != nil }),
              TokenEstimator.estimate(messages: turn) <= Self.byteLimit else { return nil }
        let snapshots = turn.map(EngineMessageSnapshot.init(message:))
        guard Self.complete(snapshots), let encoded = try? JSONEncoder().encode(snapshots),
              encoded.count <= Self.byteLimit else { return nil }
        self.origin = origin
        self.messages = snapshots
        if turn.contains(where: { $0.continuation?.responsesItemsJSON != nil || $0.continuation?.containsThinkingBlocks == true }) {
            guard let digest = Prefix(Array(request[..<start]), tools).digest else { return nil }
            prefixDigest = digest
        } else { prefixDigest = nil }
    }

    /// A historical invocation is data. Only a complete assistant/result batch can be
    /// disclosed to a model, and none of these items are submitted to the tool executor.
    static func complete(_ messages: [EngineMessageSnapshot]) -> Bool {
        guard messages.first?.role == .user, messages.last?.role == .assistant,
              messages.last?.toolCalls.isEmpty == true else { return false }
        var seen = Set<String>(), pending = Set<String>()
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .system: return false
            case .user: guard index == 0 else { return false }
            case .assistant:
                guard pending.isEmpty else { return false }
                for call in message.toolCalls {
                    guard !call.id.isEmpty, !call.name.isEmpty, seen.insert(call.id).inserted else { return false }
                    pending.insert(call.id)
                }
            case .toolResult:
                guard let id = message.toolCallId, pending.remove(id) != nil,
                      message.text != EngineRunSnapshot.suspensionPlaceholder else { return false }
            }
        }
        return pending.isEmpty
    }
}

enum ConversationHistory {
    private struct Turn {
        var visible: [EngineMessage]
        var replay: [EngineMessage]?
        var prefixDigest: String?
    }

    static func resolve(_ visible: [EngineMessage], origin: ProviderTurnHistory.Origin?,
                        rules: [EngineMessage], tools: [ToolDefinition], tokenBudget: Int,
                        requiresAssistantReasoning: Bool) -> [EngineMessage] {
        var groups: [Turn] = []
        for (index, original) in visible.enumerated() {
            var message = original
            guard message.role == .assistant else {
                groups.append(Turn(visible: [message]))
                continue
            }
            let history = message.historyTurn
            message.historyTurn = nil
            let canUseEvidence = origin != nil && history?.origin.space == origin?.space
                && history?.origin.sessionID == origin?.sessionID
                && history?.origin.scopeDigest == origin?.scopeDigest
            let evidence = canUseEvidence ? message.historyEvidence : nil
            if requiresAssistantReasoning || evidence != nil {
                // Missing reasoning cannot be reconstructed. Quote visible facts as prior
                // conversation data; do not invent an assistant message or a tool receipt.
                let prior = message.text + (evidence.map { "\nCompleted tool results:\n" + $0 } ?? "")
                let id = message.chatMessageID
                message = .init(role: .user, text: "[Earlier assistant answer, quoted as data]\n" + DispatcherEngine.wrap(prior))
                message.chatMessageID = id
            }
            guard index > 0, visible[index - 1].role == .user,
                  let last = groups.indices.last, groups[last].visible.count == 1,
                  let user = groups[last].visible.first, user.role == .user,
                  user.chatMessageID != nil else {
                groups.append(Turn(visible: [message]))
                continue
            }
            groups[last].visible.append(message)
            guard let history, history.origin == origin, history.messages.first?.text == DispatcherEngine.wrap(user.text),
                  ProviderTurnHistory.complete(history.messages),
                  !requiresAssistantReasoning || history.messages.allSatisfy({ $0.role != .assistant || $0.continuation?.reasoningContent != nil }) else { continue }
            groups[last].prefixDigest = history.prefixDigest
            groups[last].replay = history.messages.enumerated().map { index, saved in
                var value = saved.toEngineMessage
                value.chatMessageID = index == 0 ? user.chatMessageID : message.chatMessageID
                return value
            }
        }
        // Spend the historical budget on complete recent turns. Never cut between a
        // function call and its results, or truncate an encrypted/signed item.
        var remaining = tokenBudget
        var selected: [Turn] = []
        for var turn in groups.reversed() {
            let fallbackCost = TokenEstimator.estimate(messages: turn.visible)
            if let replay = turn.replay {
                let cost = max(fallbackCost, TokenEstimator.estimate(messages: replay))
                if cost <= remaining { remaining -= cost; selected.append(turn); continue }
                turn.replay = nil
            }
            guard fallbackCost <= remaining else { break }
            remaining -= fallbackCost
            selected.append(turn)
        }
        var resolved: [EngineMessage] = []
        var prefix = selected.contains(where: { $0.replay != nil && $0.prefixDigest != nil }) ? ProviderTurnHistory.Prefix(rules, tools) : nil
        for turn in selected.reversed() {
            let matches = turn.prefixDigest == nil || turn.prefixDigest == prefix?.digest
            let items = matches ? (turn.replay ?? turn.visible) : turn.visible
            resolved += items
            prefix?.append(items)
        }
        return resolved
    }
}
