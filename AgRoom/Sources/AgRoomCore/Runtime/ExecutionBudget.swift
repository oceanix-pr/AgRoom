import Foundation

public struct ExecutionBudgetCheckpoint: Codable, Sendable, Equatable {
    /// nil 表示仅记录累计用量。旧检查点中保存的数值继续作为上限。
    public let maxTokens: Int?
    public let maxToolCalls: Int
    public let spentTokens: Int
    public let toolCalls: Int
    public var deadline: Date? = nil
}

extension ExecutionBudgetCheckpoint {
    private enum CodingKeys: String, CodingKey { case maxTokens, maxToolCalls, spentTokens, toolCalls, deadline }

    // 仅计量的运行显式编码为 null。上限字段缺失表示检查点损坏，恢复时应报告错误。
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(maxTokens, forKey: .maxTokens)
        try fields.encode(maxToolCalls, forKey: .maxToolCalls)
        try fields.encode(spentTokens, forKey: .spentTokens)
        try fields.encode(toolCalls, forKey: .toolCalls)
        try fields.encodeIfPresent(deadline, forKey: .deadline)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maxTokens: fields.decode(Int?.self, forKey: .maxTokens),
                      maxToolCalls: fields.decode(Int.self, forKey: .maxToolCalls),
                      spentTokens: fields.decode(Int.self, forKey: .spentTokens),
                      toolCalls: fields.decode(Int.self, forKey: .toolCalls),
                      deadline: fields.decodeIfPresent(Date.self, forKey: .deadline))
    }
}

private final class BudgetCheckpointState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ExecutionBudgetCheckpoint
    init(_ value: ExecutionBudgetCheckpoint) { self.value = value }
    func read() -> ExecutionBudgetCheckpoint { lock.withLock { value } }
    func update(_ value: ExecutionBudgetCheckpoint) { lock.withLock { self.value = value } }
}

// MARK: - Execution Budget

/// 一次模型请求的预算预留。必须显式结算；未结算的预留会占用额度，
/// 防止并发请求反复花费同一份预算。
public struct BudgetReservation: Sendable, Hashable {
    public let id: UUID
    public let tokens: Int
    public let purpose: BudgetPurpose
}

public enum BudgetPurpose: String, Codable, Sendable, Equatable {
    case main
    case worker
    case verifier
    /// 自动审核模型的独立用途；与主任务共享任务账本，但另有调用/token 上限。
    case reviewer
}

public enum BudgetError: LocalizedError, Sendable, Equatable {
    case tokensExhausted
    case toolCallsExhausted
    case deadlineExceeded
    case invalidReservation

    public var errorDescription: String? {
        switch self {
        case .tokensExhausted:
            return "The task token budget is exhausted; no further model request can be reserved."
        case .toolCallsExhausted:
            return "The task tool-call budget is exhausted."
        case .deadlineExceeded:
            return "The task deadline has passed."
        case .invalidReservation:
            return "The budget reservation is unknown or was already settled."
        }
    }
}

/// 任务级预算账本：主协调、Worker、传统子代理、验证者与重试共享同一份额度。
/// 模型输出上限和实际 usage 都计入；Provider 未返回 usage 时按预留量保守结算。
public actor ExecutionBudgetLedger {
    public nonisolated let maxTokens: Int?
    public nonisolated let maxToolCalls: Int
    public nonisolated let deadline: Date?
    private let parent: ExecutionBudgetLedger?
    private nonisolated let checkpointState: BudgetCheckpointState
    public nonisolated var checkpoint: ExecutionBudgetCheckpoint { checkpointState.read() }

    private var spentTokens = 0
    private var reservedTokens = 0
    private var toolCalls = 0
    private var verificationReserve = 0
    private var active: [UUID: BudgetReservation] = [:]
    private var parentReservations: [UUID: BudgetReservation] = [:]
    private var unknownUsageRequests = 0

    public init(
        maxTokens: Int?,
        maxToolCalls: Int,
        deadline: Date? = nil,
        verificationReserve: Int = 0,
        restoring: ExecutionBudgetCheckpoint? = nil,
        parent: ExecutionBudgetLedger? = nil
    ) {
        self.parent = parent
        let limit = [maxTokens, restoring?.maxTokens, parent?.maxTokens].compactMap { $0 }.min()
        self.maxTokens = limit.map { max(1, $0) }
        self.maxToolCalls = max(1, min(maxToolCalls, parent?.maxToolCalls ?? maxToolCalls))
        self.deadline = [restoring?.deadline, deadline, parent?.deadline].compactMap { $0 }.min()
        self.verificationReserve = min(max(0, verificationReserve), (self.maxTokens ?? 0) / 2)
        self.spentTokens = max(0, restoring?.spentTokens ?? 0)
        self.toolCalls = max(0, restoring?.toolCalls ?? 0)
        self.checkpointState = BudgetCheckpointState(ExecutionBudgetCheckpoint(
            maxTokens: self.maxTokens, maxToolCalls: self.maxToolCalls,
            spentTokens: self.spentTokens, toolCalls: self.toolCalls, deadline: self.deadline))
    }

    private func updateCheckpoint() {
        // 移交时未结算请求按预留量保守计入；不能通过退出/接管重置审核额度。
        checkpointState.update(ExecutionBudgetCheckpoint(maxTokens: maxTokens, maxToolCalls: maxToolCalls,
            spentTokens: spentTokens + reservedTokens, toolCalls: toolCalls, deadline: deadline))
    }

    public var spent: Int { spentTokens }
    public var reserved: Int { reservedTokens }
    public var remaining: Int? {
        maxTokens.map { max(0, $0 - reservedTokens - spentTokens) }
    }
    public var remainingForVerification: Int? {
        maxTokens.map { max(0, $0 - verificationReserve - spentTokens) }
    }
    public var toolCallCount: Int { toolCalls }
    public var unknownUsageCount: Int { unknownUsageRequests }

    /// 预留输入估算 + 输出上限。验证阶段可使用专份额度；普通阶段不能吃掉它。
    public func reserve(
        inputEstimate: Int,
        outputCap: Int,
        purpose: BudgetPurpose,
        allowSmallerOutput: Bool = false
    ) async throws -> BudgetReservation {
        try Task.checkCancellation()
        try checkDeadline()
        let requested = max(1, inputEstimate + max(1, outputCap))
        let available = purpose == .verifier ? remaining
            : remainingForVerification.map { max(0, $0 - reservedTokens) }
        var tokens = requested
        if let available, requested > available {
            guard allowSmallerOutput, available > inputEstimate else {
                HubLogger.shared.warning("Model budget reservation rejected: input=\(inputEstimate) outputCap=\(outputCap) available=\(available) spent=\(spentTokens) reserved=\(reservedTokens)")
                throw BudgetError.tokensExhausted
            }
            tokens = available
        }
        var reservation = BudgetReservation(id: UUID(), tokens: tokens, purpose: purpose)
        active[reservation.id] = reservation
        reservedTokens += tokens
        updateCheckpoint()
        if let parent {
            do {
                // 先占本地额度再跨 actor，防止重入并发花费同一份子预算。
                // 子验证者只使用子级专份，不能侵占父级验证者的专份。
                let inherited = try await parent.reserve(inputEstimate: inputEstimate, outputCap: tokens - inputEstimate,
                    purpose: .worker, allowSmallerOutput: allowSmallerOutput)
                parentReservations[reservation.id] = inherited
                if inherited.tokens < tokens {
                    reservedTokens -= tokens - inherited.tokens
                    reservation = BudgetReservation(id: reservation.id, tokens: inherited.tokens, purpose: purpose)
                    active[reservation.id] = reservation
                    updateCheckpoint()
                }
                try Task.checkCancellation()
                try checkDeadline()
            } catch {
                await cancel(reservation)
                throw error
            }
        }
        return reservation
    }

    /// 按实际 usage 结算；nil 表示 Provider 未返回 usage，按预留量保守计入。
    public func settle(
        _ reservation: BudgetReservation,
        inputTokens: Int?,
        outputTokens: Int?
    ) async {
        guard let stored = active.removeValue(forKey: reservation.id) else { return }
        let inherited = parentReservations.removeValue(forKey: reservation.id)
        reservedTokens = max(0, reservedTokens - stored.tokens)
        let actual: Int
        if let inputTokens, let outputTokens {
            actual = max(0, inputTokens) + max(0, outputTokens)
        } else {
            actual = stored.tokens
            unknownUsageRequests += 1
        }
        spentTokens += max(0, actual)
        updateCheckpoint()
        if let parent, let inherited {
            await parent.settle(inherited, inputTokens: inputTokens, outputTokens: outputTokens)
        }
    }

    /// 请求失败/取消时释放预留；不把未发生的调用算成消耗。
    public func cancel(_ reservation: BudgetReservation) async {
        guard let stored = active.removeValue(forKey: reservation.id) else { return }
        let inherited = parentReservations.removeValue(forKey: reservation.id)
        reservedTokens = max(0, reservedTokens - stored.tokens)
        updateCheckpoint()
        if let parent, let inherited { await parent.cancel(inherited) }
    }

    public func recordToolCall() async throws {
        try Task.checkCancellation()
        try checkDeadline()
        guard toolCalls < maxToolCalls else { throw BudgetError.toolCallsExhausted }
        toolCalls += 1
        updateCheckpoint()
        do {
            try await parent?.recordToolCall()
        } catch {
            toolCalls -= 1
            updateCheckpoint()
            throw error
        }
    }

    /// 验证阶段开始时释放专份额度，让验证者可以使用剩余总量。
    public func releaseVerificationReserve() {
        verificationReserve = 0
    }

    public func checkDeadline() throws {
        if let deadline, Date() >= deadline { throw BudgetError.deadlineExceeded }
    }
}
