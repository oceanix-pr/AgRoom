import Foundation

// MARK: - Scheduled Run Result

public struct ScheduledRunResult: Sendable, Equatable {
    public let status: ScheduledRunStatus
    public let outputText: String?
    public let summary: String?
    public let toolNames: [String]
    public let toolCallCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let errorCode: String?
    public let errorText: String?
    public let durationMs: Int
    public let experience: ScheduledRunExperience?

    public init(
        status: ScheduledRunStatus,
        outputText: String? = nil,
        summary: String? = nil,
        toolNames: [String] = [],
        toolCallCount: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        errorCode: String? = nil,
        errorText: String? = nil,
        durationMs: Int = 0,
        experience: ScheduledRunExperience? = nil
    ) {
        self.status = status
        self.outputText = outputText
        self.summary = summary
        self.toolNames = toolNames
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.errorCode = errorCode
        self.errorText = errorText
        self.durationMs = durationMs
        self.experience = experience
    }
}

// MARK: - Scheduled Runner

/// 无人值守的只读运行：复用 `EngineAssembly` / `DispatcherEngine`，但把能力面
/// 收敛到代码内白名单，并且不处理确认/提问——遇到就失败关闭。
public enum ScheduledRunner {

    @MainActor
    public static func run(spaceStore: SpaceStore, space: AppSpace, task: ScheduledTask, scheduledFor: Date?,
                           settings: DaemonRunSettings, runID: UUID) async -> ScheduledRunResult {
        await run(spaceStore: spaceStore, space: space, task: task, scheduledFor: scheduledFor, settings: settings,
            runID: runID, makeEngine: nil)
    }

    @MainActor
    static func run(spaceStore: SpaceStore, space: AppSpace, task: ScheduledTask, scheduledFor: Date?,
                    settings: DaemonRunSettings, runID: UUID,
                    makeEngine: (@MainActor (DaemonRunSettings, ScheduledPromptContext) async throws -> DispatcherEngine)?) async -> ScheduledRunResult {
        let started = Date(), options = task.effectiveOptions
        var engine: DispatcherEngine?
        var partial = ""
        var partialTruncated = false
        var experience = ScheduledRunExperience(budget: options.budget)
        if options.notifyOnlyOnChange { experience.definitionFingerprint = task.comparisonFingerprint }
        func result(_ status: ScheduledRunStatus, output: String? = nil, code: String? = nil, error: String? = nil) -> ScheduledRunResult {
            let trace = engine?.traceEntries ?? []
            var source = output ?? (partial.isEmpty ? nil : partial)
            var collectedTruncated = false
            if status != .succeeded {
                var recovered = source ?? ""
                let receipts = trace.filter(\.succeeded)
                for (index, entry) in receipts.enumerated() {
                    let value = entry.resultFull ?? entry.resultPreview
                    guard !value.isEmpty else { continue }
                    recovered += (recovered.isEmpty ? "" : "\n\n") + entry.toolName + "\n" + value
                    let bounded = Self.boundedOutput(recovered)
                    recovered = bounded.text
                    if bounded.truncated { collectedTruncated = true; break }
                    if recovered.utf8.count == ScheduledCapabilityProfile.outputTextLimit, index < receipts.count - 1 { collectedTruncated = true; break }
                }
                if !recovered.isEmpty { source = recovered }
            }
            let bounded = source.map(Self.boundedOutput)
            experience.outputTruncated = (bounded?.truncated ?? false) || collectedTruncated || (output == nil && partialTruncated)
            experience.usageKnown = engine?.tokenUsageKnown ?? false
            if let spent = engine?.budgetCheckpoint?.spentTokens, spent > 0 || experience.usageKnown { experience.budgetSpentTokens = spent }
            else { experience.budgetSpentTokens = nil }
            experience.providerID = engine?.providerIdentity?.id; experience.model = engine?.providerIdentity?.model
            let usage = engine?.usageSnapshot
            return .init(status: status, outputText: bounded?.text,
                summary: source.map(Self.summary), toolNames: uniqueToolNames(trace.map(\.toolName)), toolCallCount: engine?.budgetCheckpoint?.toolCalls ?? trace.count,
                inputTokens: usage?.inputTokens ?? 0, outputTokens: usage?.outputTokens ?? 0,
                errorCode: code, errorText: error, durationMs: Int(Date().timeIntervalSince(started) * 1000), experience: experience)
        }
        guard let allowed = ScheduledCapabilityProfile.toolNames(for: task.profileVersion) else {
            return result(.failed, code: "unsupported_profile", error: "Unsupported scheduled capability profile.")
        }
        guard options.isValid, task.schedule.validate(now: .distantPast) == nil else {
            return result(.failed, code: "invalid_options", error: "Invalid scheduled budget or comparison settings.")
        }
        guard !Task.isCancelled else { return result(.cancelled, code: "cancelled") }
        var safe = settings
        safe.permissionMode = .readOnly; safe.autoReviewEnabled = false; safe.teamTasksEnabled = false; safe.teamWritesEnabled = false
        safe.maxSteps = min(max(2, safe.maxSteps), ScheduledCapabilityProfile.maxSteps)
        safe.maxTokens = min(max(256, safe.maxTokens), ScheduledCapabilityProfile.maxOutputTokens)
        safe.taskBudget = options.budget.checkpoint(now: started)
        let safeSettings = safe
        let deadline = started.addingTimeInterval(Double(options.budget.seconds))
        let context = ScheduledPromptContext(taskName: task.name, scheduledFor: scheduledFor ?? started,
            timeZoneIdentifier: task.schedule.timeZoneIdentifier,
            comparisonInstructions: options.notifyOnlyOnChange ? options.comparisonInstructions : nil)
        do {
            let built = try await TaskDeadline.run(until: deadline) {
                if let makeEngine { return try await makeEngine(safeSettings, context) }
                return try await EngineAssembly.build(spaceStore: spaceStore, space: space, settings: safeSettings,
                    hostCapabilities: .headless, shellApprovalPolicy: .confirmEveryTime,
                    excludedToolNames: [], allowsWorkspaceAutoApproval: false,
                    allowsTeamWrites: false, allowedToolNames: allowed, scheduledContext: context, sessionID: nil, runID: runID)
            }
            engine = built
            built.onDelta = { delta in
                if partial.utf8.count < ScheduledCapabilityProfile.outputTextLimit {
                    let value = Self.boundedOutput(partial + delta)
                    partial = value.text; partialTruncated = partialTruncated || value.truncated
                } else { partialTruncated = true }
            }
            built.onThought = { _ in partial = ""; partialTruncated = false }
            let outcome = try await TaskDeadline.run(until: deadline) { try await built.run(userMessage: task.prompt, history: []) }
            try Task.checkCancellation()
            switch outcome {
            case let .finished(text, _, _, _, _, _, completion):
                if let blocked = built.budgetFailure { return result(.failed, output: text, code: Self.budgetCode(blocked), error: blocked.localizedDescription) }
                if built.stepLimitReached { return result(.failed, output: text, code: "budget_steps", error: "The read-only profile's step limit was reached.") }
                if completion.isIncomplete {
                    let code = completion.code == .operationNeedsReview ? "recovery_required" : "incomplete"
                    return result(.failed, output: text, code: code, error: Self.incompleteReason(completion))
                }
                if options.notifyOnlyOnChange {
                    do {
                        let observation = try ScheduledComparison.parse(text)
                        experience.comparisonValue = observation.comparison_value
                        return result(.succeeded, output: observation.result)
                    } catch {
                        experience.comparisonState = .unavailable
                        return result(.failed, output: text, code: "comparison_unavailable", error: "The result did not contain a valid observation for change comparison.")
                    }
                }
                return result(.succeeded, output: text)
            case .needsConfirmation:
                return result(.failed, code: "requires_confirmation", error: "Unattended runs never approve tools requiring confirmation.")
            case .waitingForInput:
                return result(.failed, code: "requires_input", error: "Unattended runs cannot wait for user input.")
            }
        } catch is CancellationError {
            await Task.yield()
            return result(.cancelled, code: "cancelled")
        } catch let error as BudgetError {
            await Task.yield()
            return result(.failed, code: Self.budgetCode(error), error: error.localizedDescription)
        } catch let error as LLMError {
            await Task.yield()
            return result(.failed, code: errorCode(for: error), error: error.localizedDescription)
        } catch {
            await Task.yield()
            return result(.failed, code: "run_failed", error: "The scheduled run could not finish. Review its retained result before running again.")
        }
    }

    private static func boundedOutput(_ text: String) -> (text: String, truncated: Bool) {
        let limit = ScheduledCapabilityProfile.outputTextLimit
        guard text.utf8.count > limit else { return (text, false) }
        var data = Data(text.utf8.prefix(limit))
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return (String(decoding: data, as: UTF8.self), true)
    }

    private static func budgetCode(_ error: BudgetError) -> String {
        switch error {
        case .tokensExhausted: "budget_tokens"
        case .toolCallsExhausted: "budget_tools"
        case .deadlineExceeded: "budget_time"
        case .invalidReservation: "run_failed"
        }
    }

    /// 未完成原因的兜底英文说明（稳定 code 已存入 errorCode，界面可按 code 本地化）。
    /// 不写文件正文，只写技能名/相对路径/字段名这类结构化信息。
    private static func incompleteReason(_ completion: TaskCompletionAssessment) -> String {
        let skill = completion.skill ?? "skill"
        let path = completion.path ?? "output"
        switch completion.code {
        case .skillScriptFailed:
            return "The run did not complete: skill '\(skill)' script '\(path)' failed, so the required "
                + "output was not produced."
        case .skillArtifactMissing:
            return "The run did not complete: skill '\(skill)' did not produce '\(path)'."
        case .skillArtifactInvalid:
            return "The run did not complete: skill '\(skill)' produced '\(path)' but it does not match the "
                + "declared contract (\(completion.detail ?? "invalid"))."
        case .codeUnverified, .codeRevisionChanged:
            return "The current source revision has not been verified."
        case .codeVerificationFailed:
            return "The recorded build or tests did not pass."
        case .codeChecksPassed:
            return "The recorded checks passed on their verified input revision."
        case .operationNeedsReview:
            return "Check the last operation and its saved results before continuing."
        case .requestedSourceMissing:
            return "The requested source could not be verified."
        case .sourceActionIncomplete:
            return "An action requiring a verified source did not complete."
        case .mailDeliveryUncertain:
            return "Delivery is uncertain. Check the mail server before sending again."
        case .mailDeliveredCheckCopy:
            return "The mail was delivered. Check the Sent copy and avoid sending again."
        case .mailDraftNotSaved:
            return "There is no verified saved draft for this request."
        case .mailSelectionAmbiguous:
            return "Identify the message by its source link or by its subject and sender."
        case .none:
            return "The run did not complete: a required output is missing."
        }
    }

    private static func uniqueToolNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func summary(from text: String) -> String {
        let singleLine = text
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(200))
    }

    private static func errorCode(for error: LLMError) -> String {
        switch error {
        case .providerUnavailable:
            return "provider_unavailable"
        case .invalidAPIKey:
            return "invalid_api_key"
        case .rateLimited:
            return "rate_limited"
        case .networkError:
            return "network_error"
        case .streamStalled:
            return "stream_stalled"
        case .configurationError:
            return "configuration_error"
        case .invalidToolSchema:
            return "invalid_tool_schema"
        case .unparsedToolCall:
            return "unparsed_tool_call"
        default:
            return "run_failed"
        }
    }
}
