import Foundation

// MARK: - Skill Dependency Declaration

/// 技能依赖声明（技能包内 `scripts/requirements.txt`）的解析与执行前检查。
///
/// 约束：只接受「分发名 + 受限版本说明符」的纯文本行；pip 选项、外部 URL、
/// 本地路径、PEP 508 直接引用与环境标记一律拒绝——不能把任意参数原样交给安装器。
/// 缺失依赖只上报，不隐式安装：安装必须走 `python_package_manage` 的既有确认策略。
public enum SkillRequirements {

    public struct Requirement: Equatable, Sendable {
        public let name: String
        /// 版本说明符（如 `==2.2.0`、`>=1.0,<2.0`；空串表示不限定）
        public let specifier: String
        public let raw: String
    }

    /// 单行白名单：`name` / `name[extra]` + 可选的一组比较子句
    static let linePattern =
        #"^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9_,.-]+\])?((===|==|~=|!=|<=|>=|<|>)[A-Za-z0-9.*+!_-]+(,(===|==|~=|!=|<=|>=|<|>)[A-Za-z0-9.*+!_-]+)*)?$"#

    /// 解析声明文本：返回通过校验的依赖与被拒绝的行（拒绝的行不静默跳过）
    public static func parse(_ text: String) -> (requirements: [Requirement], rejected: [String]) {
        var requirements: [Requirement] = []
        var rejected: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.range(of: linePattern, options: .regularExpression) != nil else {
                rejected.append(line)
                continue
            }
            let name = line.prefix { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
                    || character == "." || character == "[" || character == "]"
            }
            let specifier = String(line.dropFirst(name.count))
            requirements.append(Requirement(
                name: distributionName(String(name)),
                specifier: specifier,
                raw: line
            ))
        }
        return (requirements, rejected)
    }

    /// `pandas[extra]` → `pandas`
    static func distributionName(_ spec: String) -> String {
        spec.prefix { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }.description
    }

    /// 缺失依赖条目
    public struct Missing: Equatable, Sendable {
        public let name: String
        public let specifier: String
        /// nil = 环境中未安装
        public let installedVersion: String?
    }

    /// 在统一环境中检查声明的依赖：返回未安装或版本不满足的条目（空数组 = 全部可用）
    public static func missing(
        requirements: [Requirement],
        executor: PythonExecutor
    ) async -> [Missing] {
        guard !requirements.isEmpty else { return [] }
        let names = requirements.map(\.name)
        guard let installed = await installedVersions(names: names, executor: executor) else {
            // 探测失败（运行时不可用）：不误报缺失，交给脚本自身报错
            return []
        }
        return requirements.compactMap { requirement in
            guard let version = installed[requirement.name] else {
                return Missing(name: requirement.name, specifier: requirement.specifier, installedVersion: nil)
            }
            guard versionSatisfies(version: version, specifier: requirement.specifier) else {
                return Missing(
                    name: requirement.name, specifier: requirement.specifier, installedVersion: version
                )
            }
            return nil
        }
    }

    /// 一次性查询多个分发名的已安装版本；运行时不可用返回 nil
    static func installedVersions(
        names: [String],
        executor: PythonExecutor
    ) async -> [String: String]? {
        // 分发名已被声明解析限制在 [A-Za-z0-9._-]，可直接作为 Python 列表字面量嵌入
        guard let data = try? JSONSerialization.data(withJSONObject: names),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        let code = """
        import importlib.metadata as md
        import json

        result = {}
        for name in \(literal):
            try:
                result[name] = md.version(name)
            except md.PackageNotFoundError:
                result[name] = None
        print(json.dumps(result))
        """
        guard let result = try? await executor.execute(code: code, timeout: 30), result.succeeded else {
            return nil
        }
        // 取最后一行 JSON（脚本自身可能先输出别的内容）
        guard let line = result.stdout
            .split(separator: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
              let jsonData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        var versions: [String: String] = [:]
        for (key, value) in object {
            // 未安装为 JSON null：忽略该键，调用方按「未安装」处理
            if let version = value as? String { versions[key] = version }
        }
        return versions
    }

    /// 版本说明符判断（数值点分比较，逗号分隔为全部满足）。
    /// 无法判定时保守返回 true：宁可让脚本自行报错，也不误判为缺失而阻断执行。
    static func versionSatisfies(version: String, specifier: String) -> Bool {
        let trimmed = specifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        for clause in trimmed.split(separator: ",") {
            let text = clause.trimmingCharacters(in: .whitespaces)
            if !clauseSatisfied(version: version, clause: text) { return false }
        }
        return true
    }

    private static func clauseSatisfied(version: String, clause: String) -> Bool {
        let operators = ["===", "==", "~=", "!=", "<=", ">=", "<", ">"]
        guard let op = operators.first(where: { clause.hasPrefix($0) }) else { return true }
        let target = String(clause.dropFirst(op.count)).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return true }
        switch op {
        case "===":
            return version == target
        case "==":
            // 允许通配前缀（如 2.*）
            if target.hasSuffix(".*") {
                return version.hasPrefix(String(target.dropLast(2)))
            }
            return compare(version, target) == .orderedSame
        case "!=":
            return compare(version, target) != .orderedSame
        case "~=":
            // 兼容发布语义的近似：至少不低于目标（更细的边界由脚本自身保证）
            return compare(version, target) != .orderedAscending
        case ">=":
            return compare(version, target) != .orderedAscending
        case "<=":
            return compare(version, target) != .orderedDescending
        case ">":
            return compare(version, target) == .orderedDescending
        case "<":
            return compare(version, target) == .orderedAscending
        default:
            return true
        }
    }

    /// 点分数值比较；出现非数值段时回退字符串比较
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? String(left[index]) : "0"
            let rightPart = index < right.count ? String(right[index]) : "0"
            if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
                if leftNumber != rightNumber {
                    return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
                }
                continue
            }
            let result = leftPart.compare(rightPart, options: .numeric)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}
