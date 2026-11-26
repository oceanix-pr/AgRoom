import Foundation
import AgRoomCore
import IOKit.pwr_mgt
import Darwin

// MARK: - AgRoom Daemon

/// AgRoom 守护进程：App 退出时接管仍在流式运行的对话轮，
/// 从引擎快照续跑工具循环，把结果写回会话库（SQLite，WAL 跨进程并发安全）。
///
/// 生命周期：启动抢占单例锁 → 无移交任务立即退出；有任务则持有
/// 「阻止系统空闲休眠」断言逐个执行 → 全部完成后释放锁并退出（无常驻义务）。
/// 明确排除：不接管 JobCenter 中未运行的后台作业
@main
struct AgRoomDaemonMain {

    private struct RunKey: Hashable {
        let space: AppSpace
        let id: UUID
    }

    private static let relayReadyPrefix = "AGROOM_DAEMON_READY_V2 "

    private static func relayNonce(arguments: [String]) -> String? {
        guard arguments.contains("--wait-for-lock"),
              let index = arguments.firstIndex(of: "--ready-token"),
              arguments.indices.contains(index + 1),
              UUID(uuidString: arguments[index + 1]) != nil else { return nil }
        return arguments[index + 1]
    }

    /// A relay reports that it has opened the persistent lock inode and is
    /// about to wait for the previous Daemon. The App may then finish exiting.
    private static func reportRelayReady(nonce: String) -> Bool {
        let line = Array((relayReadyPrefix + nonce + "\n").utf8)
        return line.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return false }
            return Darwin.write(STDOUT_FILENO, start, bytes.count) == bytes.count
        }
    }

    @MainActor
    static func main() async {
        // 守护进程可能先于 App 启动（上次退出时拉起）：路径迁移必须早于移交目录读取
        let store = DaemonHandoffStore.standard

        let arguments = Array(CommandLine.arguments.dropFirst())
        let waiting = arguments.contains("--wait-for-lock")
        let nonce = relayNonce(arguments: arguments)
        guard !waiting || nonce != nil else {
            HubLogger.shared.error("AgRoomDaemon: invalid relay request")
            exit(2)
        }

        // The relay waits on the same inode as an older Daemon. After taking
        // the lock it scans both space directories and the legacy root afresh.
        let ready: (@Sendable () -> Bool)?
        if let nonce {
            ready = { Self.reportRelayReady(nonce: nonce) }
        } else {
            ready = nil
        }
        guard store.acquireDaemonLock(waiting: waiting, onReady: ready) else {
            HubLogger.shared.error("AgRoomDaemon: could not acquire daemon lock")
            exit(1)
        }
        defer { store.releaseDaemonLock() }

        guard store.hasActionableRecords || NoteBackgroundHandoff.hasRequests else {
            // 没有待接管任务：守护进程自动关闭（自然返回，让 defer 释放锁）
            return
        }

        // 防系统空闲休眠：任务执行期间不让电脑睡（合盖/手动休眠仍会暂停，唤醒后继续）
        var assertionID = IOPMAssertionID(0)
        let assertionHeld = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AgRoom daemon is finishing background chat tasks" as CFString,
            &assertionID
        ) == kIOReturnSuccess

        // 处理期间 App 可能再次退出并写入新任务。持续领取本进程尚未尝试的任务；
        // 写回失败而保留的任务本轮不反复重试，交给下次启动恢复。
        // 终态记录（completed / recoveryRequired）不参与领取，避免无谓重启循环。
        var attempted = Set<RunKey>()
        while true {
            let records = store.actionableLocatedRecords.filter {
                !attempted.contains(RunKey(space: $0.record.space, id: $0.record.id))
            }
            guard !records.isEmpty else { break }
            HubLogger.shared.info("AgRoomDaemon: processing \(records.count) run record(s)")
            for located in records {
                attempted.insert(RunKey(space: located.record.space, id: located.record.id))
                await process(located, store: store)
            }
        }

        // Note jobs have their own fixed-space queue and expiring database leases.
        // They only resume requests explicitly published by the App exit handoff.
        if NoteBackgroundHandoff.hasRequests {
            let hub = Hub()
            for space in AppSpace.allCases { await NoteBackgroundHandoff.drain(hub: hub, space: space) }
        }
        if assertionHeld { IOPMAssertionRelease(assertionID) }
        HubLogger.shared.info("AgRoomDaemon: all tasks finished, exiting")
    }

    // MARK: - Single Run

    /// 执行单个托管任务：状态机推进（pending → running → committing → completed）→
    /// 挂载能力集与副作用日志 → 快照续跑 → 结果写回会话库 → 删除记录
    @MainActor
    private static func process(_ located: LocatedDaemonRecord, store: DaemonHandoffStore) async {
        var recovered = located.record
        let origin = located.origin
        let record: DaemonRunRecord
        // 空间库挂载：SpaceStore.current 与本任务无关，queue(for:) 显式取任务归属空间
        let spaceStore = SpaceStore()
        guard let queue = await spaceStore.prepare(recovered.space) else {
            HubLogger.shared.error("AgRoomDaemon: space database unavailable; record retained")
            return
        }
        let sessionService = SessionService(databaseQueue: queue, expectedRestoreVersion:
            SessionRestoreVersion(id: recovered.sessionId, token: recovered.restorationToken))
        do { try await sessionService.checkRestorationVersion() }
        catch {
            store.updateState(id: recovered.id, origin: origin,
                to: .recoveryRequired(reason: "conversation was restored; old run cannot write back"))
            HubLogger.shared.error("AgRoomDaemon: restored conversation; old run retained for recovery")
            return
        }
        let stableRunID = recovered.settings.taskAuthorization?.runID ?? recovered.id
        let binding = OperationJournal.Binding(runID: stableRunID, space: recovered.space)
        let journal = OperationJournal(
            directory: store.runDirectory(id: recovered.id, origin: origin), binding: binding
        )
        if recovered.state == .running,
           let paired = recovered.snapshot.reconcilingFinishedChild(journal: journal, binding: binding, sessionID: recovered.sessionId) {
            recovered.snapshot = paired
            recovered.updatedAt = Date()
            guard store.writeRecord(recovered, origin: origin) else {
                HubLogger.shared.error("AgRoomDaemon: paired child receipt could not be checkpointed")
                return
            }
        }
        record = recovered

        // 日志损坏 / 不可读：无法判定是否有未决副作用，绝不能按「空日志」继续自动执行
        if journal.requiresManualRecovery {
            store.updateState(id: record.id, origin: origin, to: .recoveryRequired(
                reason: "side-effect journal could not be read; manual recovery required"
            ))
            HubLogger.shared.error("AgRoomDaemon: side-effect journal unreadable; manual recovery required")
            return
        }

        // 恢复规则：有 intent 无 receipt 的副作用结果不确定 → 绝不重放，转人工恢复
        let unresolved = journal.unresolvedOperationIDs()
        if !unresolved.isEmpty {
            store.updateState(id: record.id, origin: origin, to: .recoveryRequired(
                reason: "\(unresolved.count) side-effect operation(s) have no recorded receipt"
            ))
            HubLogger.shared.error("AgRoomDaemon: unresolved side effects; manual recovery required")
            return
        }

        // 回执可能已落盘，但工具批完成快照尚未写回；消息仍有未配对的工具调用。
        // 即使日志无未决 intent，也不能让模型据此生成另一批并自动续跑。
        if record.snapshot.journalUnavailable || record.snapshot.requiresManualToolRecovery {
            store.updateState(id: record.id, origin: origin, to: .recoveryRequired(
                reason: "side-effect journal or tool batch checkpoint is incomplete; manual recovery required"
            ))
            HubLogger.shared.error("AgRoomDaemon: incomplete side-effect checkpoint; not auto-resuming")
            return
        }

        // 已进入 committing 的崩溃残留：待提交结果已经保存，直接提交，不重新请求模型
        if case .committing = record.state, let text = record.pendingFinalText {
            let snapshot = record.snapshot
            do {
                let terminal = try await writeBack(
                    .finished(
                        text: text,
                        thoughts: snapshot.thoughts,
                        trace: snapshot.trace,
                        tokens: snapshot.totalTokens,
                        inputTokens: snapshot.totalInputTokens,
                        outputTokens: snapshot.totalOutputTokens,
                        // 完成评估随快照持久化；旧记录缺该字段时按「未评估」兼容
                        completion: snapshot.completion ?? .unassessed
                    ),
                    finalSnapshot: snapshot,
                    record: record,
                    sessionService: sessionService
                )
                guard store.updateState(id: record.id, origin: origin, to: terminal) != nil else {
                    throw DaemonStateWriteFailure(detail: "terminal state could not be persisted")
                }
                store.removeRecord(id: record.id, origin: origin)
                HubLogger.shared.info("AgRoomDaemon: committed from checkpoint (\(describe(terminal)))")
            } catch {
                // 提交失败：保留记录，下次启动继续提交
                HubLogger.shared.error(
                    "AgRoomDaemon: commit from checkpoint failed; record retained: "
                        + HubLogger.safeErrorSummary(error))
            }
            return
        }

        guard store.updateState(id: record.id, origin: origin, to: .running) != nil else {
            HubLogger.shared.error("AgRoomDaemon: state write failed; record retained")
            return
        }
        var progress: ProgressWriter?
        var executingEngine: DispatcherEngine?
        // 检查点：模型回复后的稳定工具调用 ID 与工具批结果随运行持久化，
        // 崩溃恢复时从最近检查点续跑，不会重新生成已执行调用的 ID。
        // 传入的副本状态为 running，避免检查点写回把已推进的状态覆盖回 pending
        var runningRecord = record
        runningRecord.state = .running
        let checkpoints = CheckpointWriter(record: runningRecord, origin: origin, store: store)

        do {
            let engine = try await EngineAssembly.build(
                spaceStore: spaceStore,
                space: record.space,
                settings: record.settings,
                hostCapabilities: .headless,
                // 后台不复用 Shell 授权池；仅范围内的静态只读沙箱命令可免确认。
                shellApprovalPolicy: .scopedBackground,
                // 与宿主能力描述共用排除集合；旧移交记录也不能恢复前台工具。
                excludedToolNames: DaemonCapabilitySet.unsupportedToolNames,
                // 仅主动移交且范围校验成功的任务可继承确定性低风险自动批准。
                allowsWorkspaceAutoApproval: record.settings.taskAuthorization != nil,
                // 无头进程没有任务板审批人：团队写必须关闭，否则 Worker 会无限等待审批。
                allowsTeamWrites: false,
                sessionID: record.sessionId,
                runID: stableRunID,
                workspaceID: record.settings.resourceContext?.workspaceID ?? record.settings.taskAuthorization?.workspaceID,
                taskRequest: record.snapshot.messages.last(where: { $0.role == .user && $0.text.contains("<<<内容开始>>>") })?.text,
                restoredIntentToolNames: record.snapshot.contextReport?.toolDisclosure == "intentDeferred"
                    ? record.snapshot.deferredToolFace.map { Set($0.map(\.name)) } : nil,
                restoredCodingTaskActive: record.snapshot.codingTaskActive == true
            )
            // 副作用执行日志：非幂等写工具执行前后落 intent/receipt，崩溃后凭回执去重
            executingEngine = engine
            engine.operationJournal = journal
            engine.onCheckpoint = { [weak engine] snapshot in
                checkpoints.apply(snapshot, budget: engine?.budgetCheckpoint)
            }
            // 部分进度落库：App 重启可看到后台进度（2s 节流）
            let writer = ProgressWriter(
                sessionService: sessionService,
                sessionId: record.sessionId,
                messageId: record.assistantMessageId,
                taskRunID: record.settings.taskAuthorization?.runID
            )
            progress = writer
            engine.onDelta = { delta in writer.append(delta) }

            var resumeSnapshot = record.snapshot
            if resumeSnapshot.reasoningTokenUsage == nil,
               let message = try await sessionService.latestMessage(id: record.sessionId),
               message.id == record.assistantMessageId,
               let previous = message.thoughts,
               !previous.isEmpty {
                // 旧快照只保存叙述，推理文本在消息中；升级时一并保留。
                resumeSnapshot.thoughts = [previous] + resumeSnapshot.thoughts.filter { !previous.contains($0) }
            }
            var outcome = try await engine.run(fromSnapshot: resumeSnapshot)
            let reviewLog = spaceStore.currentDirectoryURL.map {
                AutoReviewAuditLog(spaceDirectoryURL: $0.appendingPathComponent(record.space.rawValue))
            }
            while case .needsConfirmation = outcome {
                try Task.checkCancellation()
                guard !checkpoints.writeFailed else {
                    throw DaemonStateWriteFailure(detail: "tool-batch checkpoint could not be persisted")
                }
                guard record.settings.autoReviewEnabled else {
                    if let request = engine.pendingAutoReviewRequest() {
                        let reason = AutoReviewService.manualReason(for: request)
                        let evaluation = AutoReviewEvaluation(request: request, decision: .manual(reason: reason))
                        reviewLog?.record(AutoReviewAuditEntry(request: request, decision: evaluation.decision))
                        outcome = evaluation.annotating(outcome)
                    }
                    break
                }
                guard let evaluation = await engine.reviewPending(environment: AutoReviewEnvironment(
                    space: record.space, workspacePath: record.settings.workspacePath
                )) else { break }
                reviewLog?.record(AutoReviewAuditEntry(request: evaluation.request, decision: evaluation.decision))
                switch evaluation.decision {
                case .approve:
                    outcome = try await engine.resume(.autoApproved(callId: evaluation.request.callId,
                        generation: evaluation.request.authorizationGeneration, digest: evaluation.request.callDigest))
                case .reject(let reason):
                    outcome = try await engine.resume(.autoRejected(callId: evaluation.request.callId, reason: reason))
                case .manual:
                    outcome = evaluation.annotating(outcome)
                }
                if case .manual = evaluation.decision { break }
            }
            if checkpoints.writeFailed {
                // 检查点写不进去：恢复依据不可靠，中止推进并保留记录等人工处置
                throw DaemonStateWriteFailure(detail: "tool-batch checkpoint could not be persisted")
            }
            let finalSnapshot = engine.takeSnapshot()
            let liveUserAction: Bool
            switch outcome {
            case .needsConfirmation:
                // Ordinary approval has not executed yet. A nested suspension
                // already has a placeholder and cannot be serialized as approval.
                liveUserAction = finalSnapshot.suspendedToolCallIds.isEmpty
                    && !finalSnapshot.hasSuspensionPlaceholder
            case .waitingForInput:
                liveUserAction = finalSnapshot.isLiveTopLevelQuestion
            case .finished:
                liveUserAction = false
            }
            if DaemonJournalRecoveryGate.requiresManualRecovery(
                journal: journal,
                engineJournalUnavailable: engine.isJournalUnavailable,
                snapshot: finalSnapshot,
                allowLiveUserAction: liveUserAction
            ) {
                guard store.updateState(id: record.id, origin: origin, to: .recoveryRequired(
                    reason: "side-effect outcome or checkpoint is uncertain; manual recovery required"
                )) != nil else {
                    throw DaemonStateWriteFailure(detail: "manual recovery state could not be persisted")
                }
                HubLogger.shared.error("AgRoomDaemon: uncertain side-effect outcome; record retained")
                return
            }
            // 进入 committing 前先保存待提交结果：崩溃后可直接提交，不重跑模型
            if case let .finished(text, _, _, _, _, _, _) = outcome {
                checkpoints.setPendingFinalText(text, snapshot: finalSnapshot, budget: engine.budgetCheckpoint)
            } else {
                checkpoints.apply(finalSnapshot, budget: engine.budgetCheckpoint)
            }
            if checkpoints.writeFailed {
                throw DaemonStateWriteFailure(detail: "pending commit could not be persisted")
            }
            guard store.updateState(id: record.id, origin: origin, to: .committing) != nil else {
                throw DaemonStateWriteFailure(detail: "committing state could not be persisted")
            }
            try await writer.finish()
            let terminal = try await writeBack(
                outcome,
                finalSnapshot: finalSnapshot,
                record: checkpoints.current,
                sessionService: sessionService
            )
            guard store.updateState(id: record.id, origin: origin, to: terminal) != nil else {
                throw DaemonStateWriteFailure(detail: "terminal state could not be persisted")
            }
            // 终态与挂起态都已完整写入会话库后，才确认并删除记录
            // （挂起态由 App 从会话库恢复，不依赖该记录）
            store.removeRecord(id: record.id, origin: origin)
            HubLogger.shared.info("AgRoomDaemon: run completed (\(describe(terminal)))")
        } catch is DaemonStateWriteFailure {
            // 状态落盘失败：不写错误回执也不删记录——唯一凭证必须保留给下次恢复
            if let progress { try? await progress.finish() }
            HubLogger.shared.error("AgRoomDaemon: state checkpoint write failed; record retained")
        } catch {
            let latestSnapshot = executingEngine?.takeSnapshot() ?? record.snapshot
            if DaemonJournalRecoveryGate.requiresManualRecovery(
                journal: journal,
                engineJournalUnavailable: executingEngine?.isJournalUnavailable ?? false,
                snapshot: latestSnapshot
            ) {
                _ = store.updateState(id: record.id, origin: origin, to: .recoveryRequired(
                    reason: "side-effect outcome or checkpoint is uncertain; manual recovery required"
                ))
                HubLogger.shared.error("AgRoomDaemon: execution failed with uncertain side effects; record retained")
                return
            }
            do {
                if let progress {
                    try await progress.finish()
                }
                try await errorWriteBack(sessionService, record: record, error: error,
                                         snapshot: executingEngine?.takeSnapshot())
                store.removeRecord(id: record.id, origin: origin)
                HubLogger.shared.error(
                    "AgRoomDaemon: execution failed and error was persisted: "
                        + HubLogger.safeErrorSummary(error))
            } catch {
                // 写回失败时保留记录，下一次启动仍可发现并恢复，不能把唯一凭证删掉。
                HubLogger.shared.error(
                    "AgRoomDaemon: write-back failed; record retained: "
                        + HubLogger.safeErrorSummary(error))
            }
        }
    }

    /// 状态可读名（日志用，不记录提示词/参数/正文）
    private static func describe(_ state: DaemonRunState) -> String {
        switch state {
        case .pending: return "pending"
        case .running: return "running"
        case .awaitingConfirmation: return "awaitingConfirmation"
        case .awaitingInput: return "awaitingInput"
        case .committing: return "committing"
        case .completed: return "completed"
        case .recoveryRequired: return "recoveryRequired"
        }
    }

    // MARK: - Outcome Write-back

    /// 结果写回（与 App 的 handleOutcome 同语义）：
    /// 完成 → 正文/思维链/轨迹/用量；挂起 → 持久化挂起快照列，等 App 重启恢复。
    /// 返回该轮应当落到的持久化终态（completed / awaitingConfirmation / awaitingInput）
    @MainActor
    private static func writeBack(
        _ outcome: DispatcherOutcome,
        finalSnapshot: EngineRunSnapshot,
        record: DaemonRunRecord,
        sessionService: SessionService
    ) async throws -> DaemonRunState {
        switch outcome {
        case let .finished(text, _, trace, tokens, inputTokens, outputTokens, completion):
            try await sessionService.updateMessage(
                sessionId: record.sessionId,
                messageId: record.assistantMessageId,
                expectedTaskRunID: record.settings.taskAuthorization?.runID
            ) { message in
                message.content = text
                message.providerTurn = completion.isIncomplete ? nil : finalSnapshot.completedProviderTurn?.bound(to: text)
                // 引擎正常结束 ≠ 任务完成：产物缺失/脚本失败按未完成落库，界面据此展示阻塞原因
                message.runStatus = completion.isIncomplete ? .incomplete : .succeeded
                message.completion = completion.status == .unassessed ? nil : completion
                if let report = finalSnapshot.contextReport {
                    var merged = report
                    if let source = message.contextReport { merged.mergeHistoryDisplay(from: source) }
                    merged.attachments = message.contextReport?.attachments ?? []
                    merged.attachmentWarnings = message.contextReport?.attachmentWarnings
                    merged.omittedImages = message.contextReport?.omittedImages ?? []
                    message.contextReport = merged
                }
                applyThoughts(finalSnapshot, to: &message)
                message.trace = trace.isEmpty ? nil : trace
                message.tokenCount = tokens
                message.inputTokens = inputTokens
                message.outputTokens = outputTokens
                syncActiveVariation(&message)
            }
            return .completed

        case let .needsConfirmation(toolName, argumentsDisplay, changePreview, requirement):
            try await sessionService.updateMessage(sessionId: record.sessionId, messageId: record.assistantMessageId, expectedTaskRunID: record.settings.taskAuthorization?.runID) { $0.runStatus = .waitingForConfirmation }
            // 挂起：续跑累计的思维链/轨迹写回消息 + 快照列持久化（App 重启重建确认卡续跑）
            try await writeSuspensionState(
                finalSnapshot: finalSnapshot,
                record: record,
                sessionService: sessionService
            )
            try await sessionService.setPending(
                sessionId: record.sessionId,
                confirmation: PendingConfirmationSnapshot(
                    messageId: record.assistantMessageId,
                    toolName: toolName,
                    argumentsDisplay: argumentsDisplay,
                    changePreview: changePreview,
                    requirement: requirement
                ),
                question: nil
            )
            return .awaitingConfirmation

        case .waitingForInput(let form):
            try await sessionService.updateMessage(sessionId: record.sessionId, messageId: record.assistantMessageId, expectedTaskRunID: record.settings.taskAuthorization?.runID) { $0.runStatus = .waitingForInput }
            try await writeSuspensionState(
                finalSnapshot: finalSnapshot,
                record: record,
                sessionService: sessionService
            )
            try await sessionService.setPending(
                sessionId: record.sessionId,
                confirmation: nil,
                question: PendingQuestionSnapshot(
                    messageId: record.assistantMessageId,
                    form: form
                )
            )
            return .awaitingInput
        }
    }

    /// 挂起态消息写回：思维链/轨迹落库（正文已在流式进度中落库，不动）
    @MainActor
    private static func writeSuspensionState(
        finalSnapshot: EngineRunSnapshot,
        record: DaemonRunRecord,
        sessionService: SessionService
    ) async throws {
        let trace = finalSnapshot.trace
        try await sessionService.updateMessage(
            sessionId: record.sessionId,
            messageId: record.assistantMessageId,
            expectedTaskRunID: record.settings.taskAuthorization?.runID
        ) { message in
            applyThoughts(finalSnapshot, to: &message)
            message.trace = trace.isEmpty ? nil : trace
            syncActiveVariation(&message)
        }
    }

    private static func applyThoughts(_ snapshot: EngineRunSnapshot, to message: inout ChatMessage) {
        let transcript = snapshot.thoughts.joined(separator: "\n\n")
        if let usage = snapshot.reasoningTokenUsage {
            message.thoughts = transcript.isEmpty ? nil : transcript
            message.reasoningTokenUsage = usage
        } else if !transcript.isEmpty {
            // 兼容尚未执行新版引擎的旧待提交记录。
            let previous = message.thoughts ?? ""
            message.thoughts = previous.isEmpty ? transcript : previous + "\n\n" + transcript
        }
    }

    /// 失败写回（App 的 replaceAssistantWithError 同语义）：重建为错误消息，
    /// 继承思考过程/轨迹/附件/版本记录
    @MainActor
    private static func errorWriteBack(
        _ sessionService: SessionService,
        record: DaemonRunRecord,
        error: Error,
        snapshot: EngineRunSnapshot? = nil
    ) async throws {
        let errorText = "Background execution failed: \(error.localizedDescription)"
        try await sessionService.updateMessage(
            sessionId: record.sessionId,
            messageId: record.assistantMessageId,
            expectedTaskRunID: record.settings.taskAuthorization?.runID
        ) { message in
            if let snapshot { applyThoughts(snapshot, to: &message) }
            message = message.appendingError(errorText)
        }
    }

    // MARK: - Helpers

    /// 镜像 content/thoughts/trace/tokens 回当前激活版本
    /// （维持「content 镜像 variations[active]」不变量，与 App 的 syncActiveVariationSnapshot 一致）
    private static func syncActiveVariation(_ message: inout ChatMessage) {
        guard var variations = message.variations, !variations.isEmpty,
              message.activeVariationIndex >= 0,
              message.activeVariationIndex < variations.count else { return }
        variations[message.activeVariationIndex].content = message.content
        variations[message.activeVariationIndex].providerTurn = message.providerTurn
        variations[message.activeVariationIndex].thoughts = message.thoughts
        variations[message.activeVariationIndex].reasoningTokenUsage = message.reasoningTokenUsage
        variations[message.activeVariationIndex].trace = message.trace
        variations[message.activeVariationIndex].tokenCount = message.tokenCount
        variations[message.activeVariationIndex].inputTokens = message.inputTokens
        variations[message.activeVariationIndex].outputTokens = message.outputTokens
        variations[message.activeVariationIndex].runStatus = message.runStatus
        variations[message.activeVariationIndex].contextReport = message.contextReport
        variations[message.activeVariationIndex].completion = message.completion
        variations[message.activeVariationIndex].taskRun = message.taskRun
        variations[message.activeVariationIndex].sourceTaskRunID = message.sourceTaskRunID
        message.variations = variations
    }
}

// MARK: - Checkpoint Writer（工具批检查点持久化）

/// 任务检查点写入器：把引擎在工具批边界给出的快照持久化到任务记录。
/// 回调来自引擎运行线程（非 MainActor），独立串行 I/O 队列拥有记录副本；
/// 写失败只置标记，由调用方在运行结束后中止推进（不删记录）。
private final class CheckpointWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agroom.daemon.checkpoints")
    private let store: DaemonHandoffStore
    private let origin: DaemonRecordOrigin
    private var record: DaemonRunRecord
    private var failed = false

    init(record: DaemonRunRecord, origin: DaemonRecordOrigin, store: DaemonHandoffStore) {
        self.record = record
        self.origin = origin
        self.store = store
    }

    /// 记录一次工具批检查点快照
    @discardableResult
    func apply(_ snapshot: EngineRunSnapshot, budget: ExecutionBudgetCheckpoint?) -> Bool {
        queue.sync {
            guard !failed else { return false }
            record.snapshot = snapshot
            record.settings.taskBudget = budget ?? record.settings.taskBudget
            record.updatedAt = Date()
            guard store.writeRecord(record, origin: origin) else { failed = true; return false }
            return true
        }
    }

    /// committing 前保存待提交结果（正文 + 最终快照）
    func setPendingFinalText(_ text: String, snapshot: EngineRunSnapshot, budget: ExecutionBudgetCheckpoint?) {
        queue.sync {
            record.pendingFinalText = text
            record.snapshot = snapshot
            record.settings.taskBudget = budget ?? record.settings.taskBudget
            record.updatedAt = Date()
            if !store.writeRecord(record, origin: origin) { failed = true }
        }
    }

    var current: DaemonRunRecord { queue.sync { record } }
    var writeFailed: Bool { queue.sync { failed } }
}

/// 任务状态 / 记录落盘失败：中止推进但保留记录（唯一恢复凭证）
private struct DaemonStateWriteFailure: Error {
    let detail: String
}

// MARK: - Progress Writer（部分进度落库）

/// 正文增量 2s 节流落库：App 重启时能看到后台运行的实时进度，
/// 守护进程崩溃也只损失数秒内容
@MainActor
private final class ProgressWriter {
    private let sessionService: SessionService
    private let sessionId: UUID
    private let messageId: UUID
    private let taskRunID: UUID?
    private var buffered = ""
    private var lastFlush = Date.distantPast
    private var flushTask: Task<Void, Never>?
    private var writeTask: Task<Void, Error>?

    init(sessionService: SessionService, sessionId: UUID, messageId: UUID, taskRunID: UUID? = nil) {
        self.sessionService = sessionService
        self.sessionId = sessionId
        self.messageId = messageId
        self.taskRunID = taskRunID
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        buffered += delta
        guard Date().timeIntervalSince(lastFlush) >= 2, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flushBuffered()
        }
    }

    private func flushBuffered() {
        guard !buffered.isEmpty else { return }
        let chunk = buffered
        buffered = ""
        lastFlush = Date()
        let previousWrite = writeTask
        writeTask = Task { [sessionService, sessionId, messageId, taskRunID] in
            if let previousWrite {
                try await previousWrite.value
            }
            try await sessionService.updateMessage(
                sessionId: sessionId,
                messageId: messageId,
                expectedTaskRunID: taskRunID,
                isProgressUpdate: true
            ) { message in
                // 追加到已有正文尾部（库中正文即 App 流式 + 守护进程已落库的进度）
                message.content += chunk
            }
        }
    }

    /// 收尾：取消延迟触发，把余量加入串行写链并等待全部写入完成。
    func finish() async throws {
        flushTask?.cancel()
        flushTask = nil
        flushBuffered()
        if let writeTask {
            try await writeTask.value
        }
        writeTask = nil
    }
}
