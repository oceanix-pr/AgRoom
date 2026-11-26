import Foundation

// MARK: - Skill Validation

/// 技能保存验证的状态。语法检查只编译/解析，不执行脚本顶层逻辑；
/// 冒烟测试是独立的执行步骤，必须单独经过 `.codeExecution` 权限判定。
public enum SkillValidationOutcome: String, Codable, Sendable, Equatable {
    case unverified
    case syntaxPassed
    case runtimePassed
    case failed
    case timedOut
    case runtimeUnavailable

    public var isPassing: Bool {
        self == .syntaxPassed || self == .runtimePassed
    }

    public var isExecuted: Bool {
        self == .runtimePassed
    }
}

public struct SkillScriptValidation: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let outcome: SkillValidationOutcome
    public let message: String
    public let checkedAt: Date

    public var id: String { path }

    public init(
        path: String,
        outcome: SkillValidationOutcome,
        message: String = "",
        checkedAt: Date = Date()
    ) {
        self.path = path
        self.outcome = outcome
        self.message = message
        self.checkedAt = checkedAt
    }
}

public struct SkillValidationRecord: Codable, Sendable, Equatable {
    public let outcome: SkillValidationOutcome
    /// 脚本级结果；references 或其他静态问题也可放这里。
    public let scripts: [SkillScriptValidation]
    /// 运行验证是否真的执行过。超时/运行时不可用时必须为 false。
    public let executed: Bool
    public let checkedAt: Date
    public let detail: String

    public init(
        outcome: SkillValidationOutcome,
        scripts: [SkillScriptValidation] = [],
        executed: Bool = false,
        checkedAt: Date = Date(),
        detail: String = ""
    ) {
        self.outcome = outcome
        self.scripts = scripts
        self.executed = executed
        self.checkedAt = checkedAt
        self.detail = detail
    }

    public static let unverified = SkillValidationRecord(outcome: .unverified)

    public var isPassing: Bool { outcome.isPassing }
    public var wasExecuted: Bool { executed && outcome.isExecuted }
}

/// 保存入口与 UI 复用的验证服务。语法检查与运行验证分为两个方法，
/// 调用方必须为运行验证单独做 `.codeExecution` 权限判定。
public actor SkillValidationService {
    public static let validationFileName = ".agroom-validation.json"

    private let store: SkillStore
    private let executor: PythonExecutor

    public init(store: SkillStore, executor: PythonExecutor) {
        self.store = store
        self.executor = executor
    }

    /// 只编译/解析，不执行生成脚本的顶层逻辑。
    public func syntaxCheck(name: String) async -> SkillValidationRecord {
        let scripts = (try? store.files(for: name))?
            .filter { $0.hasSuffix(".py") } ?? []
        guard !scripts.isEmpty else {
            let record = SkillValidationRecord(
                outcome: .unverified,
                detail: "This skill contains no Python scripts."
            )
            persist(record, for: name)
            return record
        }
        guard executor.runtimeStatus.pythonPath != nil else {
            let record = SkillValidationRecord(
                outcome: .runtimeUnavailable,
                scripts: scripts.map {
                    SkillScriptValidation(path: $0, outcome: .runtimeUnavailable, message: "Python runtime is unavailable")
                },
                detail: "Syntax check could not run because no Python runtime is available."
            )
            persist(record, for: name)
            return record
        }

        var results: [SkillScriptValidation] = []
        for path in scripts {
            guard let code = try? store.readFile(name: name, relativePath: path) else {
                results.append(SkillScriptValidation(path: path, outcome: .failed, message: "Script could not be read."))
                continue
            }
            do {
                if let result = try await executor.compileCheck(code: code) {
                    results.append(SkillScriptValidation(
                        path: path,
                        outcome: result.succeeded ? .syntaxPassed : .failed,
                        message: result.succeeded ? "Syntax OK (not executed)." : result.displayOutput
                    ))
                } else {
                    results.append(SkillScriptValidation(
                        path: path, outcome: .runtimeUnavailable,
                        message: "Python runtime became unavailable."
                    ))
                }
            } catch {
                results.append(SkillScriptValidation(
                    path: path, outcome: .failed, message: error.localizedDescription
                ))
            }
        }
        let record = Self.combine(
            results,
            executed: false,
            detail: "Syntax checked only; scripts were not executed."
        )
        persist(record, for: name)
        return record
    }

    /// 独立的冒烟执行步骤。调用方必须先通过 `.codeExecution` 权限判定；
    /// 超时返回 `.timedOut`，绝不会显示为通过。
    ///
    /// 运行验证使用**真实技能入口与真实工作目录**（技能根目录），并经过与运行期一致的
    /// 统一启动器——这样多文件技能（`from processor import run`）与相对资源才能被真实覆盖，
    /// 把脚本复制到临时目录执行会丢失目录结构、给出错误的通过结论。
    public func smokeTest(name: String, relativePath: String, timeout: TimeInterval = 15) async -> SkillValidationRecord {
        let entryURL: URL
        let skillRoot: URL
        do {
            entryURL = try store.scriptURL(name: name, relativePath: relativePath)
            skillRoot = try store.folderURL(for: name)
        } catch {
            let record = SkillValidationRecord(
                outcome: .failed,
                scripts: [SkillScriptValidation(path: relativePath, outcome: .failed, message: "Script could not be resolved.")],
                detail: "Smoke test did not run."
            )
            persist(record, for: name)
            return record
        }
        guard executor.runtimeStatus.pythonPath != nil else {
            let record = SkillValidationRecord(
                outcome: .runtimeUnavailable,
                scripts: [SkillScriptValidation(path: relativePath, outcome: .runtimeUnavailable, message: "Python runtime is unavailable")],
                detail: "Smoke test did not run because no Python runtime is available."
            )
            persist(record, for: name)
            return record
        }
        do {
            let result = try await executor.executeSkillScript(
                entryURL: entryURL, skillRoot: skillRoot, timeout: timeout
            )
            let (outcome, executed, detail) = Self.classify(result)
            let record = SkillValidationRecord(
                outcome: outcome,
                scripts: [SkillScriptValidation(
                    path: relativePath,
                    outcome: outcome,
                    message: result.displayOutput
                )],
                executed: executed,
                detail: detail
            )
            persist(record, for: name)
            return record
        } catch is CancellationError {
            let record = SkillValidationRecord(
                outcome: .unverified,
                scripts: [SkillScriptValidation(path: relativePath, outcome: .unverified, message: "Cancelled.")],
                executed: false,
                detail: "Smoke test was cancelled before completing."
            )
            persist(record, for: name)
            return record
        } catch {
            let record = SkillValidationRecord(
                outcome: .failed,
                scripts: [SkillScriptValidation(path: relativePath, outcome: .failed, message: error.localizedDescription)],
                executed: true,
                detail: "Smoke test failed to execute."
            )
            persist(record, for: name)
            return record
        }
    }

    /// 运行验证结果判据：
    /// - 超时 → `.timedOut`（绝不显示为通过）
    /// - 退出 0 → `.runtimePassed`
    /// - 缺参数（argparse usage / 缺少必需参数）→ `.unverified`，明确标注未完成运行验证，
    ///   不能用语法通过代替
    /// - 其余非零 → `.failed`
    static func classify(
        _ result: PythonExecutionResult
    ) -> (outcome: SkillValidationOutcome, executed: Bool, detail: String) {
        if result.timedOut {
            return (.timedOut, false, "Smoke test timed out and did not complete.")
        }
        if result.succeeded {
            return (.runtimePassed, true, "Smoke test executed the real entry with no arguments.")
        }
        let output = result.displayOutput.lowercased()
        let needsArguments = output.contains("usage:")
            || output.contains("the following arguments are required")
        if result.exitCode == 2, needsArguments {
            return (
                .unverified, false,
                "Runtime verification needs arguments that were not provided, so it did not run; "
                    + "this is not a syntax pass."
            )
        }
        return (.failed, true, "Smoke test executed the real entry and it failed.")
    }

    public func currentRecord(name: String) -> SkillValidationRecord {
        store.validationRecord(name: name)
    }

    /// 由保存入口写入静态检查结果（例如新技能只有 references 或没有运行时）。
    public func recordStatic(_ record: SkillValidationRecord, for name: String) {
        store.saveValidationRecord(record, name: name)
    }

    private func persist(_ record: SkillValidationRecord, for name: String) {
        store.saveValidationRecord(record, name: name)
    }

    private static func combine(
        _ scripts: [SkillScriptValidation],
        executed: Bool,
        detail: String
    ) -> SkillValidationRecord {
        let outcome: SkillValidationOutcome
        if scripts.isEmpty {
            outcome = .unverified
        } else if scripts.contains(where: { $0.outcome == .failed }) {
            outcome = .failed
        } else if scripts.contains(where: { $0.outcome == .timedOut }) {
            outcome = .timedOut
        } else if scripts.contains(where: { $0.outcome == .runtimeUnavailable }) {
            outcome = .runtimeUnavailable
        } else if scripts.contains(where: { $0.outcome == .syntaxPassed }) {
            outcome = executed ? .runtimePassed : .syntaxPassed
        } else {
            outcome = .unverified
        }
        return SkillValidationRecord(
            outcome: outcome,
            scripts: scripts,
            executed: executed,
            detail: detail
        )
    }
}
