import Foundation
import AgRoomScriptIPC

/// 固定探针，不执行模型提供的命令。最小探针不带会话目录或 Python 环境。
struct SandboxDiagnoseTool: DispatcherTool {
    let space: AppSpace
    let workspaceRoot: String?
    var runner: (@Sendable (_ shell: Bool) throws -> ScriptAppSandbox)? = nil

    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    var permissionClass: PermissionClass { .readOnly }
    var definition: ToolDefinition {
        ToolDefinition(name: "sandbox_diagnose", description:
            "Diagnose signed offline Shell and Python runner authorization using fixed probes. Default checks use only a fresh private temporary directory, without conversation workspace, database or Python environment. Set check_workspace=true to compare with a probe of the bound workspace. Reports stage/error codes only, never bookmarks or directory contents. This does not validate Python packages or enable builds/child processes. Use once after an isolation failure instead of repeating unchanged commands or assuming private data.",
            parametersSchemaJSON: #"{"type":"object","properties":{"check_workspace":{"type":"boolean","description":"Also test access to this conversation's bound workspace, default false."}},"additionalProperties":false}"#)
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        guard args.keys.allSatisfy({ $0 == "check_workspace" }),
              args["check_workspace"] == nil || args["check_workspace"] is Bool else {
            throw ToolExecutionFailure(message: "sandbox_diagnose accepts only check_workspace (boolean).")
        }
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("agroom-diagnose-\(space.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: run) }
        var checks: [[String: String]] = []
        for shell in [true, false] {
            try Task.checkCancellation()
            let role = shell ? "shell" : "python"
            let helper: ScriptAppSandbox
            do { helper = try runner?(shell) ?? ScriptAppSandbox.bundled(space: space) }
            catch { checks.append(report(error, role: role, check: "minimal")); continue }
            checks.append(try await probe(helper, role: role, workspace: nil, run: run))
            if args["check_workspace"] as? Bool == true {
                guard let path = workspaceRoot, let workspace = FileAreaService.expandHome(path) else {
                    checks.append(["role": role, "check": "workspace", "status": "unavailable", "code": "workspaceNotBound"])
                    continue
                }
                checks.append(try await probe(helper, role: role, workspace: workspace, run: run))
            }
        }
        let result: [String: Any] = ["protocol_version": ScriptRunnerRequest.currentVersion, "checks": checks,
            "child_processes_supported": false, "sandbox_builds_supported": false,
            "guidance": "A failed scope check does not establish private data. Compare minimal/workspace stages. Files can be read with files_read pagination and edited with files_edit. Builds require an explicitly approved host build; never automatically switch a failed sandbox command to host mode."]
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }

    private func probe(_ helper: ScriptAppSandbox, role: String, workspace: URL?, run: URL) async throws -> [String: String] {
        do {
            var denied = ScriptSandbox.privateRoots(space: space)
            if let workspace {
                denied += ScriptSandbox.legacyRunRoots(in: [workspace])
            }
            let plan = ScriptExecutionPlan(executable: URL(fileURLWithPath: workspace == nil ? "/bin/echo" : "/bin/ls"),
                arguments: workspace.map { ["-A", "-1", $0.path] } ?? ["agroom-sandbox-ok"], directory: run,
                environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], timeout: 5,
                sandbox: ScriptSandbox(readRoots: [run] + (workspace.map { [$0] } ?? []), writeRoots: [], deniedRoots: denied))
            let result = await ChildProcessRunner.run(try await helper.request(plan: plan, label: "sandbox_diagnose", outputLimit: 1024))
            if result.outcome.isCancelled { throw CancellationError() }
            if result.succeeded, workspace != nil || result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "agroom-sandbox-ok" {
                return ["role": role, "check": workspace == nil ? "minimal" : "workspace", "status": "passed"]
            }
            return ["role": role, "check": workspace == nil ? "minimal" : "workspace", "status": "failed",
                "code": workspace == nil ? "fixedProbeFailed" : "workspaceProbeFailed", "stage": "execution",
                "outcome": result.timedOut ? "timedOut" : String(result.exitCode)]
        } catch is CancellationError { throw CancellationError() }
        catch { return report(error, role: role, check: workspace == nil ? "minimal" : "workspace") }
    }

    private func report(_ error: Error, role: String, check: String) -> [String: String] {
        var result = ["role": role, "check": check, "status": "failed", "code": "diagnosticUnavailable"]
        if let failure = error as? ScriptIsolationError {
            result["code"] = failure.code
            if case .diagnostic(let detail) = failure {
                result["stage"] = detail.stage.rawValue
                if let index = detail.scopeIndex { result["scope_index"] = String(index) }
            }
        }
        return result
    }
}
