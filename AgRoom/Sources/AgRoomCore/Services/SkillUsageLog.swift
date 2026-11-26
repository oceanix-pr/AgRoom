import Foundation
import Darwin

// MARK: - Skill Usage Log

/// 技能使用记录条目：skill_load / skill_run_script 的每次调用结果。
/// 用于 AI 重写时回注真实使用反馈（"越用越深"闭环的数据源）
public struct SkillUsageEntry: Codable, Sendable, Equatable {
    /// 技能名（文件夹名）
    public let skill: String
    /// 工具名：skill_load / skill_run_script
    public let tool: String
    /// ISO8601 时间戳
    public let time: Date
    /// 成功与否（skill_load 成功；脚本 exitCode == 0 且未超时）
    public let success: Bool
    /// 详情：脚本路径 / 失败摘要（截断保护）
    public let detail: String
}

/// 技能使用摘要（运营视角）：常用度（加载次数）+ 健康度（失败率），
/// 决定「哪些技能值得迭代」
public struct SkillUsageSummary: Sendable, Equatable {
    /// 成功加载次数（skill_load 成功）
    public let loads: Int
    /// 脚本运行次数（skill_run_script，含成败）
    public let runs: Int
    /// 失败事件数（加载失败 + 脚本失败）
    public let failures: Int
    /// 最近一次使用（任意事件）
    public let lastUsed: Date

    /// 全部事件数（失败率的分母）
    public var total: Int { loads + runs + failures }
    /// 失败率（0...1；无事件时 nil）
    public var failureRate: Double? {
        guard total > 0 else { return nil }
        return Double(failures) / Double(total)
    }

    struct Accumulator {
        var loads = 0
        var runs = 0
        var failures = 0
        var lastUsed = Date.distantPast

        func summary() -> SkillUsageSummary {
            SkillUsageSummary(loads: loads, runs: runs, failures: failures, lastUsed: lastUsed)
        }
    }
}

/// 技能使用日志：按空间存 JSON 文件（`<space>/skill-usage.json`），
/// 追加写 + 环形截断（最近 500 条）。
///
/// 进程内由串行 I/O 队列排序，进程间由文件租约协调；每次追加读取最新文件，
/// 独立服务实例不会用旧快照覆盖其他实例。提交闭包持有服务直到原子替换结束。
public final class SkillUsageLog: @unchecked Sendable {

    static let maxEntries = 500
    static let detailLimit = 400

    let fileURL: URL

    private static let ioQueue = DispatchQueue(label: "agroom.skill-usage-log.io", qos: .utility)

    public init(spaceDirectoryURL: URL) {
        self.fileURL = spaceDirectoryURL.appendingPathComponent("skill-usage.json")
    }

    /// 便捷构造：从技能库目录（<space>/skills/）推出空间目录
    public convenience init(skillsDirectoryURL: URL) {
        self.init(spaceDirectoryURL: skillsDirectoryURL.deletingLastPathComponent())
    }

    /// 记录一次使用（失败记录最有价值，不抛错：记录失败不应影响工具主流程，
    /// 但写入失败必须记日志，否则"技能统计消失"无从排查）
    public func record(_ entry: SkillUsageEntry) {
        let bounded = SkillUsageEntry(skill: entry.skill, tool: entry.tool, time: entry.time,
            success: entry.success, detail: String(entry.detail.prefix(Self.detailLimit)))
        Self.ioQueue.async { [self] in
            let fd = Darwin.open(fileURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { HubLogger.shared.warning("Skill usage lock unavailable"); return }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { return }
            defer { flock(fd, LOCK_UN) }
            var entries = Self.readEntries(from: fileURL)
            entries.append(bounded)
            do {
                try JSONEncoder().encode(Array(entries.suffix(Self.maxEntries))).write(to: fileURL, options: .atomic)
            } catch { HubLogger.shared.warning("Skill usage log write failed") }
        }
    }

    func flushPendingWrites() { Self.ioQueue.sync {} }

    /// 查询某技能的使用记录（新→旧）
    public func entries(for skill: String) -> [SkillUsageEntry] {
        snapshot()
            .filter { $0.skill == skill }
            .sorted { $0.time > $1.time }
    }

    /// 全库使用统计（技能页排序/展示用）：技能名 → 使用摘要（次数/失败率/最近使用）
    public func usageStats() -> [String: SkillUsageSummary] {
        let all = snapshot()
        var summaries: [String: SkillUsageSummary.Accumulator] = [:]
        for entry in all {
            var acc = summaries[entry.skill] ?? .init()
            if entry.tool == "skill_load" {
                if entry.success { acc.loads += 1 }
            } else if entry.tool == "skill_run_script" {
                acc.runs += 1
            }
            if !entry.success { acc.failures += 1 }
            if acc.lastUsed < entry.time { acc.lastUsed = entry.time }
            summaries[entry.skill] = acc
        }
        return summaries.mapValues { $0.summary() }
    }

    /// 生成"使用反馈摘要"（注入 AI 重写上下文）：统计 + 最近失败详情
    public func feedbackSummary(for skill: String, recent: Int = 10) -> String? {
        let all = entries(for: skill)
        guard !all.isEmpty else { return nil }
        let loads = all.filter { $0.tool == "skill_load" }
        let runs = all.filter { $0.tool == "skill_run_script" }
        let failures = all.filter { !$0.success }
        var lines: [String] = []
        lines.append("Usage stats: \(all.count) total events; \(loads.count) skill_load, \(runs.count) script runs, \(failures.count) failures.")
        if !failures.isEmpty {
            lines.append("Recent failure details (most relevant for improvement):")
            for failure in failures.prefix(recent) {
                lines.append("- [\(failure.tool)] \(failure.detail.isEmpty ? "(no detail)" : failure.detail)")
            }
        }
        if failures.isEmpty {
            lines.append("No failures recorded. Recent usage has been smooth.")
        }
        return lines.joined(separator: "\n")
    }

    /// 内存快照（短临界区，不做 I/O）
    private func snapshot() -> [SkillUsageEntry] {
        Self.ioQueue.sync { Self.readEntries(from: fileURL) }
    }

    /// 一次性载入：文件不存在返回空；损坏时记警告后从空开始
    /// （静默吞掉会让历史统计无声归零）
    private static func readEntries(from fileURL: URL) -> [SkillUsageEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            return Array(try JSONDecoder().decode([SkillUsageEntry].self, from: data).suffix(Self.maxEntries))
        } catch {
            HubLogger.shared.warning("Skill usage log unreadable, starting fresh: \(HubLogger.safeErrorSummary(error))")
            return []
        }
    }
}
