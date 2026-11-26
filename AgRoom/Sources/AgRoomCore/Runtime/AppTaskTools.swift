import Foundation

// MARK: - App Task Tool Factory
//
// B 档「长任务与导入导出」工具：备份导出/恢复、Python 运行时与包管理、技能导入导出。
//
// 为什么这些工具直接在前台对话轮次内执行，而不提交到 JobCenter：
// JobCenter 面向「发起后用户会切走、完成时需要拉回来」的任务，其作业名要求
// `L.string` 本地化文案（见 BackupService 尾部 AutoBackupPolicy 注释），而 Core
// 不依赖 UI、拿不到本地化资源；把跨模块本地化硬塞进 Core 会破坏模块边界。
// 这些操作本身都是有界的（本地打包/解包为秒级，pip 走 PythonExecutor 自带超时），
// 运行状态由对话本身承载：轨迹可见、停止可取消；退出移交时按副作用分类处理。
//
// 安全约束：
// - 备份/导入来源路径必须落在受管文件区内（FileAreaService.resolveManaged）；
//   导出目标写死在标准备份目录，不接受模型给的任意路径。
// - 技能导出目标目录由引擎的 FileAreaPolicy 写范围守卫约束（见 writeTargets）。
// - pip 包名做白名单校验，拒绝以 `-` 开头等可注入 pip 选项的取值。
public enum AppTaskToolFactory {

    /// 工具返回文本中 pip / 命令输出的截断上限
    static let maxOutputLength = 6_000

    public static func build(
        space: AppSpace,
        backupService: BackupService?,
        fileAreaService: FileAreaService?,
        pythonExecutor: PythonExecutor?,
        skillStore: SkillStore?
    ) -> [any DispatcherTool] {
        var tools: [any DispatcherTool] = []
        if let backupService {
            tools.append(BackupExportTool(service: backupService, space: space))
            if let fileAreaService {
                tools.append(BackupInspectTool(service: backupService, fileAreaService: fileAreaService))
                tools.append(BackupRestoreTool(
                    service: backupService, fileAreaService: fileAreaService, space: space
                ))
            }
        }
        if let pythonExecutor {
            tools.append(PythonEnvStatusTool(executor: pythonExecutor))
            tools.append(PythonPackagesTool(executor: pythonExecutor))
            tools.append(PythonPackageManageTool(executor: pythonExecutor))
        }
        if let skillStore {
            if let fileAreaService {
                tools.append(SkillImportTool(store: skillStore, fileAreaService: fileAreaService))
                tools.append(SkillExportTool(store: skillStore, fileAreaService: fileAreaService))
            }
        }
        return tools
    }

    /// 输出截断：保留头部并明确标注被截断，避免模型以为看全了
    static func truncated(_ text: String) -> String {
        guard text.count > maxOutputLength else { return text }
        return String(text.prefix(maxOutputLength))
            + "\n… [output truncated at \(maxOutputLength) characters]"
    }

    /// pip 包名白名单：拒绝空值与以 `-` 开头的取值，
    /// 防止模型用 `--index-url=…` 这类参数改变 pip 行为
    static func validatePackageName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LLMError.configurationError(reason: "package name cannot be empty")
        }
        guard name.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._+!<>=~*\[\],-]*$"#,
            options: .regularExpression
        ) != nil else {
            throw LLMError.configurationError(
                reason: "'\(name)' is not a valid package name. Pass a plain distribution name "
                    + "with an optional version specifier (e.g. 'pandas' or 'pandas==2.2.0'); "
                    + "pip options are not accepted."
            )
        }
        return name
    }

    /// 从包规格（`pandas` / `pandas==2.2.0` / `pandas[extra]>=2`）取出分发名，
    /// 供 pip show 之类的按名查询使用
    static func distributionName(_ spec: String) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.prefix { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }
        return String(name)
    }
}

// MARK: - Backup Tools

/// 备份导出：当前空间（会话 + 记忆 + 技能）打包到标准备份目录
struct BackupExportTool: DispatcherTool {
    let service: BackupService
    let space: AppSpace

    var definition: ToolDefinition {
        ToolDefinition(
            name: "backup_export",
            description: "Export the current space into a zip archive in the standard backups folder "
                + "(~/Documents/AgRoomBackups). Covers conversations, memories, skills and versions, agents, knowledge, mail, "
                + "schedules, connection definitions, mini-app data, user SQLite databases and managed project files. External "
                + "registered folders are excluded by default and listed in coverage; use Settings to explicitly include them. API keys never enter the package. Use when the user "
                + "asks for a backup or before risky changes.",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }
    var requiresConfirmation: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        guard let directory = AutoBackupPolicy.destinationDirectory() else {
            throw LLMError.configurationError(reason: "Could not resolve the backups folder in Documents")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LLMError.configurationError(
                reason: "Could not create the backups folder at \(directory.path): \(error.localizedDescription)"
            )
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let url = directory.appendingPathComponent(
            "AgRoom-\(space.rawValue)-\(formatter.string(from: Date())).zip"
        )

        let summary = try await service.export(to: url)
        return "Exported \(summary.sessions) sessions, \(summary.memories) memories, "
            + "\(summary.skills) skills, \(summary.attachments) attachments and "
            + "\(summary.workspaces) workspaces to \(summary.url.path)\nCoverage: "
            + summary.coverage.map { "\($0.kind): \($0.records) records, \($0.files) files" }.joined(separator: "; ")
    }
}

struct BackupInspectTool: DispatcherTool {
    let service: BackupService
    let fileAreaService: FileAreaService
    var definition: ToolDefinition {
        ToolDefinition(name: "backup_inspect", description: "Read and verify a space backup without restoring anything. Returns the package fingerprint, coverage, omissions, conflicts and warnings. Explain these to the user before requesting backup_restore confirmation.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#)
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }
    func execute(argumentsJSON: String) async throws -> String {
        let url = try BackupToolInput.resolve(argumentsJSON, using: fileAreaService)
        let plan = try await service.inspect(from: url)
        return "Package fingerprint: \(plan.packageFingerprint)\nSource space: \(plan.manifest.space); cross-space: \(plan.spaceMismatch). "
            + "Corrupt sections: \(plan.corruptSections.joined(separator: ", ")). Conflicting skills: \(plan.conflictingSkills.count); apps: \(plan.conflictingApps.count).\n"
            + plan.coverage.map { "\($0.kind): \($0.records) records, \($0.files) files" }.joined(separator: "\n")
            + "\nWarnings: " + plan.warnings.map(\.rawValue).joined(separator: ", ")
            + "\nOmitted paths: " + plan.omittedPaths.prefix(50).joined(separator: "; ")
            + "\nRestore merges same-ID business data, preserves delivered-mail receipts, pauses background schedules and restored connections, restores project files into new managed folders, and keeps a local undo point. Keys and OS permissions are excluded."
    }
}

private enum BackupToolInput {
    static func resolve(_ argumentsJSON: String, using fileArea: FileAreaService) throws -> URL {
        let path = ToolArguments.string(ToolArguments.parse(argumentsJSON), "path").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.lowercased().hasSuffix(".zip") else { throw BackupError.preflightFailed("Supply the path of a backup .zip") }
        let url = try fileArea.resolveManaged(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw BackupError.preflightFailed("Backup archive was not found") }
        return url
    }
}

/// 备份恢复：把备份包合并进当前空间（同名条目按 id 覆盖，同名技能覆盖前自动快照）→ 硬确认
struct BackupRestoreTool: DispatcherTool {
    let service: BackupService
    let fileAreaService: FileAreaService
    let space: AppSpace

    var definition: ToolDefinition {
        ToolDefinition(
            name: "backup_restore",
            description: "Restore a backup zip into the current space. The package is merged in: sessions and "
                + "memories with an existing id are overwritten, and same-named skills are overwritten after an "
                + "automatic version snapshot. Chat attachments and workspace mappings are rebuilt for this "
                + "machine. The package is verified first (manifest and per-section checksums); "
                + "if verification fails or writing fails part-way, nothing is left half-restored. The zip must "
                + "be inspected with backup_inspect first. Pass its exact package_fingerprint so confirmation is bound to that inspected package. The zip must live inside the managed file area (~/Documents/AgRoom); ask the user to place it there if it "
                + "is elsewhere.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path of the backup .zip inside the managed file area"},"package_fingerprint":{"type":"string","description":"Exact SHA-256 returned by backup_inspect","pattern":"^[0-9a-f]{64}$"}},"required":["path","package_fingerprint"]}"#
        )
    }
    var requiresConfirmation: Bool { true }
    /// 覆盖当前空间数据：无视本轮「始终允许」，每次都必须用户明确批准
    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .irreversible }

    func execute(argumentsJSON: String) async throws -> String {
        let raw = ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw LLMError.configurationError(reason: "backup_restore requires a 'path' argument")
        }
        guard raw.lowercased().hasSuffix(".zip") else {
            throw LLMError.configurationError(reason: "backup_restore expects a .zip archive, got '\(raw)'")
        }
        // 路径必须落在受管根内（拒绝任意绝对路径与路径穿越）
        let url: URL
        do {
            url = try fileAreaService.resolveManaged(raw)
        } catch {
            throw LLMError.configurationError(
                reason: "'\(raw)' is outside the managed file area. Move the backup into "
                    + "~/Documents/AgRoom (the user can do this from the Files page) and retry."
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LLMError.configurationError(reason: "No backup archive found at \(url.path)")
        }

        let fingerprint = ToolArguments.string(ToolArguments.parse(argumentsJSON), "package_fingerprint")
        guard fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw BackupError.preflightFailed("Inspect this archive with backup_inspect and use its package_fingerprint before requesting restore approval")
        }

        // 先预检：校验和/格式/同名冲突都在这步判定，不通过时一个字节都不会写
        let plan = try await service.inspect(from: url)
        guard plan.corruptSections.isEmpty else {
            throw LLMError.configurationError(
                reason: "The package failed verification (nothing was restored): "
                    + plan.corruptSections.joined(separator: ", ")
            )
        }

        // 跨空间恢复需要用户明确同意：工具无法替用户表达意愿，故拒绝并说明怎么做
        if plan.spaceMismatch {
            throw LLMError.configurationError(
                reason: "This package was exported from the '\(plan.manifest.space)' space but the current space "
                    + "is '\(space.rawValue)'. Ask the user to confirm restoring across spaces in Settings."
            )
        }

        let summary = try await service.restore(from: url, expectedFingerprint: fingerprint)
        var text = "Restored from \(url.lastPathComponent): \(summary.sessions) sessions, "
            + "\(summary.memories) memories, \(summary.skills) skills, "
            + "\(summary.attachments) attachments and \(summary.workspaces) workspaces."
        text += "\nVerification: \(summary.verificationSucceeded). Restore point: \(summary.restorePointID?.uuidString ?? "pending").\n"
            + summary.coverage.map { "\($0.kind): \($0.records) records, \($0.files) files" }.joined(separator: "; ")
        if !plan.conflictingSkills.isEmpty {
            text += " Overwrote \(plan.conflictingSkills.count) existing skill(s) (previous versions snapshotted)."
        }
        if plan.integrityUnverified {
            // 老包没有段清单：如实说明这次恢复无法做完整性校验
            text += " Note: this package predates integrity manifests, so its contents could not be verified."
        }
        return text
    }
}

// MARK: - Python Tools

/// Python 运行时状态：报告执行器实际采用的环境（只读）。
/// 直接读取执行器解析出的环境，不再另行探测——避免状态与实际执行口径不一致。
struct PythonEnvStatusTool: DispatcherTool {
    let executor: PythonExecutor

    var definition: ToolDefinition {
        ToolDefinition(
            name: "python_env_status",
            description: "Report the Python environment the app will actually use: interpreter path, whether it is "
                + "the space's virtual environment, and the dedicated runtime under Documents/AgRoom. "
                + "System Python and external environments are never selected. If the runtime is missing, ask the user "
                + "to download it in Python settings. Use before reporting Python availability or requesting packages.",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }

    func execute(argumentsJSON: String) async throws -> String {
        let manager = PythonRuntimeManager.shared
        let status = executor.runtimeStatus
        let origin: String
        switch status {
        case .managed: origin = "managed runtime (installed by this app)"
        case .notInstalled: origin = "none"
        }
        var lines = [
            "Base Python runtime: \(origin)",
            "Base interpreter: \(status.pythonPath ?? "not available")",
            "Managed root: \(manager.environmentRoot.path)",
            "System and external Python environments: disabled"
        ]
        // 报告执行器实际采用的解释器（安装与执行指向同一个）
        if let environment = await executor.currentEnvironment() {
            lines.append("Execution interpreter: \(environment.interpreter)")
            lines.append(
                "Environment: "
                    + (environment.isVirtual ? "space virtual environment" : "base interpreter (no virtual environment)")
            )
            if let space = environment.space {
                lines.append("Space: \(space.rawValue)")
            }
        } else if status.pythonPath != nil {
            lines.append("Environment: not prepared; this query did not create it or execute Python.")
            lines.append("Open Python settings and prepare the current space environment on the host before running Python or changing packages.")
        }
        if status.pythonPath == nil {
            lines.append(
                PythonEnvironmentError.noRuntime.localizedDescription
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// 已安装包列表：pip list（只读）
struct PythonPackagesTool: DispatcherTool {
    let executor: PythonExecutor

    var definition: ToolDefinition {
        ToolDefinition(
            name: "python_packages",
            description: "List the Python packages installed in the runtime the app uses. "
                + "Use before python_package_manage to see what is already available.",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }
    var requiresConfirmation: Bool { false }
    var sideEffectClass: ToolSideEffectClass { .readOnly }

    func execute(argumentsJSON: String) async throws -> String {
        let result: PythonExecutionResult
        do {
            result = try await executor.runPip(arguments: ["list", "--format=columns"], timeout: 60)
        } catch {
            throw LLMError.configurationError(
                reason: "Could not run pip (no usable Python runtime, or it failed to start): "
                    + error.localizedDescription
            )
        }
        guard result.succeeded else {
            return "pip list failed (exit \(result.exitCode)).\n"
                + AppTaskToolFactory.truncated(result.displayOutput)
        }
        return "Installed packages:\n" + AppTaskToolFactory.truncated(result.displayOutput)
    }
}

/// 包安装 / 卸载（写操作，需确认）
struct PythonPackageManageTool: DispatcherTool {
    let executor: PythonExecutor

    var definition: ToolDefinition {
        ToolDefinition(
            name: "python_package_manage",
            description: "Install or uninstall a Python package in the runtime the app uses. "
                + "Installation contacts the PyPI index to fetch verified wheels, including dependencies, then modifies the space environment offline. Uninstall is offline. The command output is returned "
                + "so you can report what actually happened.",
            parametersSchemaJSON: #"{"type":"object","properties":{"package":{"type":"string","description":"Distribution name with an optional version specifier, e.g. 'pandas' or 'pandas==2.2.0'"},"uninstall":{"type":"boolean","description":"True to uninstall instead of install (default false)"}},"required":["package"]}"#
        )
    }
    var requiresConfirmation: Bool { true }

    func requiresHardConfirmation(argumentsJSON: String) -> Bool { true }
    func hardConfirmationReason(argumentsJSON: String) -> ConfirmationRequirement.HardReason { .irreversible }

    func executionAuthorizationKey(argumentsJSON: String) -> String? {
        guard let environment = executor.environmentIdentity else { return nil }
        return Self.authorizationKey(environment: environment, arguments: argumentsJSON)
    }

    private static func authorizationKey(environment: String, arguments: String) -> String {
        "package/v2#" + MCPJSON.digest(environment + "\n" + arguments)
    }

    func execute(argumentsJSON: String) async throws -> String {
        try await execute(argumentsJSON: argumentsJSON, authorizationKey: executionAuthorizationKey(argumentsJSON: argumentsJSON))
    }

    func execute(argumentsJSON: String, authorizationKey: String?) async throws -> String {
        guard let environment = executor.environmentIdentity,
              Self.authorizationKey(environment: environment, arguments: argumentsJSON) == authorizationKey else {
            throw ToolExecutionFailure(message: "Prepare the space environment in Python settings and request a fresh package approval.")
        }
        let args = ToolArguments.parse(argumentsJSON)
        let package = try AppTaskToolFactory.validatePackageName(
            ToolArguments.string(args, "package")
        )
        let uninstall = (args["uninstall"] as? Bool) ?? false

        let result: PythonExecutionResult
        do {
            result = try await executor.runPip(
                arguments: uninstall ? ["uninstall", "-y", package] : ["install", package],
                expectedEnvironmentIdentity: environment
            )
        } catch {
            throw LLMError.configurationError(
                reason: "Could not run pip (no usable Python runtime, or it failed to start): "
                    + error.localizedDescription
            )
        }
        let verb = uninstall ? "uninstall" : "install"
        var header = result.succeeded
            ? "pip \(verb) \(package) finished."
            : "pip \(verb) \(package) failed (exit \(result.exitCode))."
        var output = header + "\n" + AppTaskToolFactory.truncated(result.displayOutput)
        if !result.succeeded {
            throw ToolExecutionFailure(message: output)
        }
        // 安装后复验：用目标环境的解释器确认包确实可见（安装与执行必须是同一环境）
        if !uninstall {
            header += "\n" + (await Self.verifyInstalled(
                package: package, executor: executor
            ))
        }
        output = header + "\n" + AppTaskToolFactory.truncated(result.displayOutput)
        return output
    }

    /// 复验安装结果：pip show 走目标环境解释器，返回如实的可见性结论
    private static func verifyInstalled(package: String, executor: PythonExecutor) async -> String {
        let distribution = AppTaskToolFactory.distributionName(package)
        guard !distribution.isEmpty else { return "Visibility check skipped (no distribution name)." }
        do {
            let result = try await executor.runPip(arguments: ["show", distribution], timeout: 60)
            if result.succeeded {
                return "Verified: '\(distribution)' is visible in the execution environment."
            }
            return "Warning: pip reported success but '\(distribution)' is not visible in the execution "
                + "environment (exit \(result.exitCode)). The code run by this app may not be able to import it."
        } catch {
            return "Visibility check could not run: \(error.localizedDescription)"
        }
    }
}

// MARK: - Skill Transfer Tools

/// 技能导入：从受管文件区内的 zip 或目录导入技能包
struct SkillImportTool: DispatcherTool {
    let store: SkillStore
    let fileAreaService: FileAreaService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "skill_import_zip",
            description: "Import a skill into the current space from a .zip package or a folder that contains "
                + "SKILL.md, located inside the managed file area (~/Documents/AgRoom). Same-named skills are "
                + "overwritten after an automatic version snapshot. Ask the user to put the package in the file "
                + "area if it is elsewhere.",
            parametersSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Absolute path of the .zip file or skill folder inside the managed file area"}},"required":["path"]}"#
        )
    }
    var requiresConfirmation: Bool { true }

    func execute(argumentsJSON: String) async throws -> String {
        let raw = ToolArguments.string(ToolArguments.parse(argumentsJSON), "path")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw LLMError.configurationError(reason: "skill_import_zip requires a 'path' argument")
        }
        let url: URL
        do {
            url = try fileAreaService.resolveManaged(raw)
        } catch {
            throw LLMError.configurationError(
                reason: "'\(raw)' is outside the managed file area. Move the package into "
                    + "~/Documents/AgRoom (the user can do this from the Files page) and retry."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LLMError.configurationError(reason: "No file or folder found at \(url.path)")
        }
        let isZip = !isDirectory.boolValue && url.pathExtension.lowercased() == "zip"
        guard isDirectory.boolValue || isZip else {
            throw LLMError.configurationError(
                reason: "'\(raw)' is neither a folder nor a .zip archive"
            )
        }

        // 先预检：把将要导入的技能与覆盖风险一并返回，避免用户确认时看不到实际影响
        var preview = "Importing from \(url.lastPathComponent)."
        if isZip, let inspected = try? store.inspectZip(from: url) {
            preview = "Package contains skill '\(inspected.name)' "
                + "(\(inspected.fileCount) file(s)): \(inspected.description)"
            if inspected.overwritesExisting {
                preview += " It overwrites an existing skill of the same name; the previous version is "
                    + "snapshotted to versions/ and can be rolled back."
            }
        }

        let importedName: String
        do {
            importedName = isZip
                ? try store.importZip(from: url)
                : try store.importFolder(from: url)
        } catch {
            throw LLMError.configurationError(
                reason: "Import failed: \(error.localizedDescription). A skill package must contain a SKILL.md "
                    + "with valid frontmatter, either at the archive root or in a single top-level folder."
            )
        }
        return "\(preview) Imported as skill '\(importedName)'."
    }
}

/// 技能导出：把技能目录打包为 zip，写入当前写范围内的目录
struct SkillExportTool: DispatcherTool {
    let store: SkillStore
    let fileAreaService: FileAreaService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "skill_export_zip",
            description: "Export a skill (SKILL.md, scripts and resource files) as a .zip into a folder inside "
                + "the current write scope. Use when the user wants to share or archive a skill.",
            parametersSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"Skill name (folder name, slug form)"},"destination_dir":{"type":"string","description":"Absolute path of an existing folder inside the current write scope"}},"required":["name","destination_dir"]}"#
        )
    }
    var requiresConfirmation: Bool { true }
    /// 导出目标受 FileAreaPolicy 写范围约束，按工作区文件变更处理。
    var permissionClass: PermissionClass { .workspaceMutation }
    func writeTargets(argumentsJSON: String) -> [String] {
        [ToolArguments.string(ToolArguments.parse(argumentsJSON), "destination_dir")].filter { !$0.isEmpty }
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = ToolArguments.parse(argumentsJSON)
        let name = ToolArguments.string(args, "name")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw LLMError.configurationError(reason: "skill_export_zip requires a non-empty 'name'")
        }
        let rawDir = ToolArguments.string(args, "destination_dir")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDir.isEmpty else {
            throw LLMError.configurationError(reason: "skill_export_zip requires a 'destination_dir'")
        }
        // 引擎的 FileAreaPolicy 已按写范围拦截越界目标；此处再校验受管根，避免绕过引擎直接调用
        let directory: URL
        do {
            directory = try fileAreaService.resolveManaged(rawDir)
        } catch {
            throw LLMError.configurationError(reason: "'\(rawDir)' is outside the managed file area")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LLMError.configurationError(reason: "No folder found at \(directory.path)")
        }

        let destination = directory.appendingPathComponent("\(name).zip")
        do {
            try store.exportZip(name: name, to: destination)
        } catch {
            throw LLMError.configurationError(
                reason: "Could not export skill '\(name)': \(error.localizedDescription). "
                    + "Check the skill name with skill_search if unsure."
            )
        }
        return "Exported skill '\(name)' to \(destination.path)"
    }
}
