import Foundation

public struct NativeAppScriptError: Error, Sendable {
    public enum Code: String, Sendable {
        case noRuntime, missingDependencies, dependencyCheckFailed, queryTooLarge, invalidResult, executionFailed
        case installationChanged, isolationUnavailable, environmentUnavailable
        case inputTruncated, inputUnavailable, invalidSyntax
        case reviewRejected, reviewChanged, authorizationStorageUnavailable
    }
    public let code: Code
    public let details: String
    public init(_ code: Code, details: String = "") { self.code = code; self.details = details }
    public var localizationKey: String { "apps.script.error." + code.rawValue }
}

public struct NativeAppScriptArtifact: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let data: Data
    public var sha256: String { NativeAppDisk.digest(data) }
}

public struct NativeAppScriptResult: Sendable {
    public let values: [String: NativeAppValue]
    public let artifacts: [NativeAppScriptArtifact]
    public let diagnostics: String
}

/// Typed result channel: UI never parses the dispatcher's human-readable trace.
public actor NativeAppScriptReceipt {
    private var outcome: Result<NativeAppScriptResult, NativeAppScriptError>?
    func complete(_ value: Result<NativeAppScriptResult, NativeAppScriptError>) { outcome = value }
    public func result() throws -> NativeAppScriptResult {
        guard let outcome else { throw NativeAppScriptError(.executionFailed) }
        return try outcome.get()
    }
}

public struct NativeAppScriptCommand: Sendable {
    public let engine: DispatcherEngine
    public let call: ToolCallRaw
    public let receipt: NativeAppScriptReceipt
    public let source: String
    public let inputsJSON: String
    public let presentation: ToolApprovalPresentation
    public let authorizationState: NativeAppScriptAuthorizationState
    public let reviewReason: NativeAppScriptReviewReason?
    public let versionCommand: NativeAppScriptVersionCommand?
    public let definitionJSON: String
    public var codeReviewed: Bool { authorizationState.isAuthorized }
}

/// Host-only, captured command. Never registered in an LLM tool surface.
public struct NativeAppScriptVersionCommand: Sendable {
    public let engine: DispatcherEngine
    public let call: ToolCallRaw
}

/// One window's service, permanently bound to a single installation and space.
public actor NativeAppScriptService {
    public nonisolated let workspace: NativeAppWorkspace
    private let executor: PythonExecutor
    private let reviewer: NativeAppScriptReviewer?
    private let reviews: NativeAppScriptReviewStore
    private var manualReview: (identity: NativeAppScriptReviewIdentity, reason: NativeAppScriptReviewReason)?
    private var rejectedIdentity: NativeAppScriptReviewIdentity?
    private var authorizationGeneration = UUID()

    public init(workspace: NativeAppWorkspace, reviewer: NativeAppScriptReviewer? = nil) {
        self.workspace = workspace
        self.reviewer = reviewer
        reviews = NativeAppScriptReviewStore(workspace: workspace)
        executor = PythonExecutor(space: workspace.space,
            workspaceName: workspace.appID + "-" + workspace.identity.uuidString.lowercased(),
            runRoot: workspace.root.deletingLastPathComponent().appendingPathComponent("app-runs", isDirectory: true))
    }

    /// Internal backend injection for synthetic / signed-runner regression tests only.
    init(workspace: NativeAppWorkspace, executor: PythonExecutor, reviewer: NativeAppScriptReviewer? = nil,
         signingKey: (@Sendable () throws -> Data)? = nil) {
        self.workspace = workspace; self.executor = executor
        self.reviewer = reviewer; reviews = NativeAppScriptReviewStore(workspace: workspace, signingKey: signingKey)
    }

    public func authorizationGrantedAt(definition: NativeAppDefinition) async throws -> Date? {
        guard let environment = executor.environmentIdentity else { return nil }
        let identity = try await reviews.identity(definition: definition, environment: environment)
        guard let receipt = try await reviews.receipt(identity), receipt.state.isAuthorized else { return nil }
        return receipt.grant?.grantedAt
    }

    public func authorizationState(definition: NativeAppDefinition) async throws -> NativeAppScriptAuthorizationState {
        guard executor.hasVerifiedSandboxBackend, let environment = executor.environmentIdentity else { return .unavailable }
        let identity = try await reviews.identity(definition: definition, environment: environment)
        if let receipt = try await reviews.receipt(identity) { return receipt.state }
        if rejectedIdentity == identity { return .rejected }
        return .required
    }

    public func isCodeReviewed(definition: NativeAppDefinition) async throws -> Bool {
        try await authorizationState(definition: definition).isAuthorized
    }

    /// Explicit retry only; clicking Run again must not repeat a failed model request.
    public func reviewCode(definition: NativeAppDefinition) async throws {
        manualReview = nil; rejectedIdentity = nil
        _ = try await reviewIfNeeded(definition, environment: executor.environmentIdentity, retryRevoked: true)
    }

    private func reviewIfNeeded(_ definition: NativeAppDefinition, environment: String?, retryRevoked: Bool = false) async throws -> NativeAppScriptReviewReceipt? {
        guard executor.hasVerifiedSandboxBackend, let environment else { return nil }
        let identity = try await reviews.identity(definition: definition, environment: environment)
        do {
            if let receipt = try await reviews.receipt(identity) {
                if receipt.state.isAuthorized { return receipt }
                if !retryRevoked { manualReview = (identity, .revoked); return nil }
            }
        } catch { manualReview = (identity, .storageUnavailable); return nil }
        let revision = try await reviews.revision()
        if rejectedIdentity == identity { throw NativeAppScriptError(.reviewRejected) }
        if manualReview?.identity == identity { return nil }
        guard let reviewer else { manualReview = (identity, .unavailable); return nil }
        let generation = authorizationGeneration
        let decision: NativeAppScriptReviewDecision
        do { decision = try await reviewer(.init(definition: definition, digest: try identity.digest)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard generation == authorizationGeneration else { throw NativeAppScriptError(.reviewChanged) }
            HubLogger.shared.info("App code review unavailable; manual confirmation required.")
            manualReview = (identity, .unavailable)
            return nil
        }
        try Task.checkCancellation()
        guard generation == authorizationGeneration, executor.environmentIdentity == environment,
              try await reviews.identity(definition: definition, environment: environment) == identity else {
            throw NativeAppScriptError(.reviewChanged)
        }
        switch decision {
        case .rejected:
            rejectedIdentity = identity
            throw NativeAppScriptError(.reviewRejected)
        case .manual, .invalidResponse, .unavailable:
            let reason: NativeAppScriptReviewReason = decision == .manual ? .manual : (decision == .unavailable ? .unavailable : .invalidResponse)
            manualReview = (identity, reason)
            return nil
        case .approved:
            do { return try await reviews.approve(identity, definition: definition, expectedRevision: revision) }
            catch is CancellationError { throw CancellationError() }
            catch let error as NativeAppError where error.code == .conflict { throw error }
            catch {
                HubLogger.shared.warning("App code review receipt could not be saved; manual confirmation required.")
                manualReview = (identity, .storageUnavailable)
                return nil
            }
        }
    }

    fileprivate func authorize(_ identity: NativeAppScriptReviewIdentity, definition: NativeAppDefinition,
                               generation: UUID, expectedRevision: String) async throws -> NativeAppScriptReviewReceipt {
        try Task.checkCancellation()
        guard generation == authorizationGeneration, executor.hasVerifiedSandboxBackend,
              executor.environmentIdentity == identity.environment, rejectedIdentity != identity,
              try await reviews.identity(definition: definition, environment: identity.environment) == identity else {
            throw NativeAppScriptError(.reviewChanged)
        }
        do {
            let receipt = try await reviews.approve(identity, definition: definition, source: .user, expectedRevision: expectedRevision)
            manualReview = nil
            return receipt
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeAppError where error.code == .conflict { throw error }
        catch { throw NativeAppScriptError(.authorizationStorageUnavailable) }
    }

    public func makeRevokeCommand(definition: NativeAppDefinition) async throws -> NativeAppScriptVersionCommand {
        guard let environment = executor.environmentIdentity else { throw NativeAppScriptError(.environmentUnavailable) }
        let identity = try await reviews.identity(definition: definition, environment: environment)
        let arguments = String(decoding: try identity.encoded(), as: UTF8.self)
        let revision = try await reviews.revision()
        let tool = NativeAppAuthorizationRevokeTool(arguments: arguments) { [self] in
            try await revoke(identity, definition: definition, expectedRevision: revision)
        }
        return versionCommand(tool: tool, arguments: arguments)
    }

    private func revoke(_ identity: NativeAppScriptReviewIdentity, definition: NativeAppDefinition, expectedRevision: String) async throws {
        try Task.checkCancellation()
        authorizationGeneration = UUID()
        try await reviews.revoke(identity, definition: definition, expectedRevision: expectedRevision)
        manualReview = (identity, .revoked)
    }

    private func versionCommand(tool: any DispatcherTool, arguments: String) -> NativeAppScriptVersionCommand {
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil)
        let context = ExecutionContext(space: workspace.space, permissionPolicy: policy, deadline: Date().addingTimeInterval(300))
        return .init(engine: DispatcherEngine(tools: [tool], systemPrompt: "", permissionPolicy: policy, executionContext: context),
                     call: ToolCallRaw(id: UUID().uuidString, name: tool.definition.name, argumentsJSON: arguments))
    }

    /// AST parsing only: no venv creation, dependency installation, imports or top-level execution.
    public static func validateSyntax(_ definition: NativeAppDefinition, space: AppSpace) async throws {
        guard let scripts = definition.scripts, !scripts.isEmpty else { return }
        let executor = PythonExecutor(space: space, workspaceName: "app-syntax")
        for (key, script) in scripts.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            if let result = try await executor.compileCheck(code: script.source), !result.succeeded {
                throw NativeAppScriptError(.invalidSyntax, details: key + "\n" + result.displayOutput)
            }
        }
    }

    public func prepare(definition: NativeAppDefinition, actionID: String, inputs: [String: NativeAppValue],
                        records: [String: NativeAppScriptRecordQuery], files: [String: UUID],
                        datasets: [String: HostDataTable] = [:]) async throws -> NativeAppScriptCommand {
        try definition.validate()
        try await workspace.validateScriptInstallation(definition)
        guard let action = definition.actions[actionID], action.type == .runPython,
              let scriptID = action.script, let script = definition.scripts?[scriptID],
              Set(inputs.keys) == Set(script.inputTypes.keys),
              inputs.allSatisfy({ script.inputTypes[$0.key] == $0.value.valueType && $0.value.isBounded }),
              Set(records.keys) == Set((action.recordInputs ?? [:]).keys),
              Set(files.keys) == Set((action.fileInputs ?? [:]).keys),
              Set(datasets.keys) == Set((action.dataInputs ?? [:]).keys) else { throw NativeAppError(.invalidDefinition) }
        for dataset in datasets.values {
            try dataset.validate()
            guard !dataset.hasMore && dataset.isComplete else { throw NativeAppScriptError(.inputTruncated) }
        }
        for (key, query) in records {
            guard let declared = action.recordInputs?[key], let source = definition.dataSources[declared.source],
                  query.collection == (source.collection ?? declared.source), query.limit == declared.limit else {
                throw NativeAppError(.invalidDefinition)
            }
        }
        guard executor.runtimeStatus.pythonPath != nil else { throw NativeAppScriptError(.noRuntime) }
        var snapshot = try await workspace.scriptInputs(values: inputs, records: records, files: files)
        if !datasets.isEmpty {
            let old = try JSONDecoder().decode(NativeAppScriptInputs.Payload.self, from: snapshot.payload)
            let payload = NativeAppScriptInputs.Payload(inputs: old.inputs, records: old.records, files: old.files, data: datasets)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(payload)
            guard bytes.count <= 5 * 1024 * 1024 else { throw NativeAppError(.tooLarge) }
            snapshot = NativeAppScriptInputs(payload: bytes, files: snapshot.files)
        }
        try await workspace.validateScriptInstallation(definition)
        let environment = executor.environmentIdentity
        let reviewReceipt = try await reviewIfNeeded(definition, environment: environment)
        try Task.checkCancellation()
        let invocation = Invocation(runID: UUID(), appID: workspace.appID, installationID: workspace.identity,
            definitionSHA256: NativeAppDisk.digest(try definition.encoded()), script: scriptID, inputsSHA256: snapshot.digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let arguments = String(decoding: try encoder.encode(invocation), as: UTF8.self)
        let receipt = NativeAppScriptReceipt()
        let tool = NativeAppScriptTool(service: self, executor: executor, appDefinition: definition, script: script,
            snapshot: snapshot, expectedArguments: arguments, receipt: receipt, environment: environment, reviewReceipt: reviewReceipt, grantIdentity: nil, grantGeneration: authorizationGeneration, grantRevision: nil)
        let policy = PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil)
        let context = ExecutionContext(space: workspace.space, permissionPolicy: policy, deadline: Date().addingTimeInterval(300))
        let presentation = tool.approvalPresentation(argumentsJSON: arguments)!
        var grantCommand: NativeAppScriptVersionCommand?
        if reviewReceipt == nil, executor.hasVerifiedSandboxBackend, let environment {
            let identity = try await reviews.identity(definition: definition, environment: environment)
            let grantTool = NativeAppScriptTool(service: self, executor: executor, appDefinition: definition, script: script,
                snapshot: snapshot, expectedArguments: arguments, receipt: receipt, environment: environment,
                reviewReceipt: nil, grantIdentity: identity, grantGeneration: authorizationGeneration, grantRevision: try await reviews.revision())
            grantCommand = versionCommand(tool: grantTool, arguments: arguments)
        }
        return NativeAppScriptCommand(
            engine: DispatcherEngine(tools: [tool], systemPrompt: "", permissionPolicy: policy, executionContext: context),
            call: ToolCallRaw(id: invocation.runID.uuidString, name: "nativeapp_python_run", argumentsJSON: arguments),
            receipt: receipt, source: script.source, inputsJSON: String(decoding: snapshot.payload, as: UTF8.self),
            presentation: presentation, authorizationState: reviewReceipt?.state ?? .required,
            reviewReason: reviewReceipt == nil ? (manualReview?.reason ?? .environmentUnavailable) : nil,
            versionCommand: grantCommand, definitionJSON: String(decoding: try definition.encoded(), as: UTF8.self))
    }

    private struct Invocation: Encodable {
        let runID: UUID
        let appID: String
        let installationID: UUID
        let definitionSHA256: String
        let script: String
        let inputsSHA256: String
    }

    fileprivate func run(definition: NativeAppDefinition, script: NativeAppDefinition.Script,
                         snapshot: NativeAppScriptInputs, environment: String?,
                         reviewReceipt: NativeAppScriptReviewReceipt?) async throws -> NativeAppScriptResult {
        try Task.checkCancellation()
        try await workspace.validateScriptInstallation(definition)
        guard executor.environmentIdentity == environment else { throw NativeAppError(.conflict) }
        try await validateReview(reviewReceipt, definition: definition)
        let requirements = SkillRequirements.parse((script.requirements ?? []).joined(separator: "\n")).requirements
        if !requirements.isEmpty {
            guard let installed = await SkillRequirements.installedVersions(names: requirements.map(\.name), executor: executor) else {
                throw NativeAppScriptError(.dependencyCheckFailed)
            }
            let missing = requirements.filter { requirement in
                guard let version = installed[requirement.name] else { return true }
                return !SkillRequirements.versionSatisfies(version: version, specifier: requirement.specifier)
            }
            guard missing.isEmpty else {
                throw NativeAppScriptError(.missingDependencies, details: missing.map(\.raw).joined(separator: "\n"))
            }
        }
        try Task.checkCancellation()
        try await workspace.validateScriptInstallation(definition)
        try await validateReview(reviewReceipt, definition: definition)
        let execution = try await executor.executeAppScript(source: script.source, payload: snapshot.payload, files: snapshot.files,
            timeout: TimeInterval(script.timeoutSeconds ?? 30), expectedEnvironmentIdentity: environment)
        defer {
            if !execution.indeterminate, let output = execution.outputDirectory {
                do { try FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
                catch { HubLogger.shared.warning("App script temporary run cleanup failed.") }
            }
        }
        guard execution.succeeded else { throw NativeAppScriptError(.executionFailed, details: execution.displayOutput) }
        try Task.checkCancellation()
        try await workspace.validateScriptInstallation(definition)
        try await validateReview(reviewReceipt, definition: definition)
        return try Self.collect(execution, script: script)
    }

    private func validateReview(_ expected: NativeAppScriptReviewReceipt?, definition: NativeAppDefinition) async throws {
        guard let expected else { return } // A manually approved invocation grants only this execution.
        guard executor.hasVerifiedSandboxBackend, executor.environmentIdentity == expected.identity.environment,
              try await reviews.identity(definition: definition, environment: expected.identity.environment) == expected.identity,
              try await reviews.receipt(expected.identity) == expected else { throw NativeAppScriptError(.reviewChanged) }
    }

    static func collect(_ execution: PythonExecutionResult, script: NativeAppDefinition.Script) throws -> NativeAppScriptResult {
        guard execution.succeeded, let output = execution.outputDirectory else { throw NativeAppScriptError(.executionFailed) }
        do {
            let directory = try AppDirectory(url: output, create: false)
            let values = try JSONDecoder().decode([String: NativeAppValue].self,
                from: directory.read("result.json", limit: 128 * 1024))
            guard Set(values.keys) == Set(script.outputTypes.keys),
                  values.allSatisfy({ script.outputTypes[$0.key] == $0.value.valueType && $0.value.isBounded }) else {
                throw NativeAppScriptError(.invalidResult)
            }
            let artifactsDirectory = try directory.child("artifacts", create: false)
            let names = try artifactsDirectory.names().sorted()
            guard names.count <= 16 else { throw NativeAppScriptError(.invalidResult) }
            var total = 0
            var artifacts: [NativeAppScriptArtifact] = []
            for name in names {
                try Task.checkCancellation()
                guard NativeAppDisk.validFileName(name) else { throw NativeAppScriptError(.invalidResult) }
                let bytes = try artifactsDirectory.read(name, limit: NativeAppWorkspace.maximumFileBytes)
                total += bytes.count
                guard total <= 32 * 1024 * 1024 else { throw NativeAppScriptError(.invalidResult) }
                artifacts.append(.init(id: UUID(), name: name, data: bytes))
            }
            return NativeAppScriptResult(values: values, artifacts: artifacts, diagnostics: execution.displayOutput)
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeAppScriptError { throw error }
        catch { throw NativeAppScriptError(.invalidResult, details: execution.displayOutput) }
    }
}

private struct NativeAppScriptTool: DispatcherTool {
    let service: NativeAppScriptService
    let executor: PythonExecutor
    let appDefinition: NativeAppDefinition
    let script: NativeAppDefinition.Script
    let snapshot: NativeAppScriptInputs
    let expectedArguments: String
    let receipt: NativeAppScriptReceipt
    let environment: String?
    let reviewReceipt: NativeAppScriptReviewReceipt?
    let grantIdentity: NativeAppScriptReviewIdentity?
    let grantGeneration: UUID
    let grantRevision: String?
    var requiresConfirmation: Bool { true }
    var permissionClass: PermissionClass { .confinedCodeExecution }
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { reviewReceipt == nil }
    func isCoveredByPersistentRule(argumentsJSON: String) -> Bool {
        argumentsJSON == expectedArguments && reviewReceipt != nil
    }
    var definition: ToolDefinition {
        ToolDefinition(name: grantIdentity == nil ? "nativeapp_python_run" : "nativeapp_python_authorize_and_run", description: "Run one captured offline app function.", parametersSchemaJSON: #"{"type":"object"}"#)
    }
    func executionAuthorizationKey(argumentsJSON: String) -> String? {
        guard argumentsJSON == expectedArguments else { return nil }
        guard executor.environmentIdentity == environment else { return nil }
        return "nativeapp_python#" + NativeAppDisk.digest(Data((expectedArguments + "\n" + (environment ?? "")).utf8))
    }
    func approvalPresentation(argumentsJSON: String) -> ToolApprovalPresentation? {
        let base = PythonExecuteTool(executor: executor).approvalPresentation(argumentsJSON: "{}")!
        return ToolApprovalPresentation(executionKind: .offlinePython, resourceAccess: .init(
            readable: base.resourceAccess.readable + [ToolApprovalPresentation.ScopeToken.runTemporary],
            writable: base.resourceAccess.writable, outputs: base.resourceAccess.outputs, temporary: base.resourceAccess.temporary,
            executorContainer: base.resourceAccess.executorContainer, systemBaseline: true, verified: true),
            network: .init(allowed: false), childProcesses: .init(allowed: false), reasonCode: "offline_python",
            constraintSources: ["space", "executor"],
            executionDetails: [expectedArguments, "timeout=\(script.timeoutSeconds ?? 30)s", "environment=\(executor.environmentIdentity ?? "")"])
    }
    func execute(argumentsJSON: String) async throws -> String {
        try await execute(argumentsJSON: argumentsJSON, authorizationKey: executionAuthorizationKey(argumentsJSON: argumentsJSON))
    }
    func execute(argumentsJSON: String, authorizationKey: String?) async throws -> String {
        guard let authorizationKey, executionAuthorizationKey(argumentsJSON: argumentsJSON) == authorizationKey else {
            throw NativeAppError(.conflict)
        }
        do {
            var authorization = reviewReceipt
            if let grantIdentity, let grantRevision {
                authorization = try await service.authorize(grantIdentity, definition: appDefinition, generation: grantGeneration, expectedRevision: grantRevision)
            }
            let result = try await service.run(definition: appDefinition, script: script, snapshot: snapshot,
                environment: environment, reviewReceipt: authorization)
            await receipt.complete(.success(result))
            return "App function completed. Structured outputs were validated; artifacts await explicit saving."
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure: NativeAppScriptError
            if let typed = error as? NativeAppScriptError { failure = typed }
            else if error is ScriptIsolationError { failure = .init(.isolationUnavailable) }
            else if error is PythonEnvironmentError { failure = .init(.environmentUnavailable) }
            else if let app = error as? NativeAppError, app.code == .conflict { failure = .init(.installationChanged) }
            else { failure = .init(.executionFailed) }
            await receipt.complete(.failure(failure))
            throw ToolExecutionFailure(message: failure.localizationKey)
        }
    }
}

/// A fresh hard-confirmed command, separate from ordinary script execution.
private struct NativeAppAuthorizationRevokeTool: DispatcherTool {
    let arguments: String
    let operation: @Sendable () async throws -> Void
    var requiresConfirmation: Bool { true }
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    var definition: ToolDefinition {
        .init(name: "nativeapp_python_revoke", description: "Revoke this installed app's code authorization.", parametersSchemaJSON: #"{"type":"object"}"#)
    }
    func execute(argumentsJSON: String) async throws -> String {
        guard argumentsJSON == arguments else { throw NativeAppError(.conflict) }
        try Task.checkCancellation()
        try await operation()
        return "App code authorization revoked."
    }
}
