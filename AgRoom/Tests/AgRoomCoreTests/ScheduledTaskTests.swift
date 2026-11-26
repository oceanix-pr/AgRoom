import Testing
import Foundation
import GRDB
@testable import AgRoomCore

@Suite("ScheduledTasks")
struct ScheduledTaskTests {

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: String = "UTC"
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func components(
        of date: Date,
        timeZone: String
    ) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    private func task(
        schedule: ScheduledTaskSchedule,
        nextFireAt: Date?,
        enabled: Bool = true,
        profileVersion: String = ScheduledCapabilityProfile.readOnlyV1
    ) -> ScheduledTask {
        ScheduledTask(
            name: "每日摘要",
            enabled: enabled,
            prompt: "总结昨天的内容",
            schedule: schedule,
            profileVersion: profileVersion,
            nextFireAt: nextFireAt
        )
    }

    // MARK: - Calculator

    @Test("每天：按任务时区计算下一次触发")
    func dailyNextFireUsesTaskTimeZone() throws {
        let schedule = ScheduledTaskSchedule(
            rule: .daily(hour: 9, minute: 0),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let next = try #require(ScheduleCalculator.nextFireDate(
            for: schedule,
            after: date(2026, 10, 20, 10, 0, timeZone: "Asia/Shanghai")
        ))
        let c = components(of: next, timeZone: "Asia/Shanghai")
        #expect(c.year == 2026)
        #expect(c.month == 10)
        #expect(c.day == 21)
        #expect(c.hour == 9)
        #expect(c.minute == 0)
    }

    @Test("每周：ISO 1 = 周一，跨周取最近一天")
    func weeklyNextFireUsesISOWeekdays() throws {
        // 2026-10-25 是周日。
        let schedule = ScheduledTaskSchedule(
            rule: .weekly(weekdays: [1, 3], hour: 8, minute: 30),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let next = try #require(ScheduleCalculator.nextFireDate(
            for: schedule,
            after: date(2026, 10, 25, 12, 0, timeZone: "Asia/Shanghai")
        ))
        let c = components(of: next, timeZone: "Asia/Shanghai")
        #expect(c.year == 2026)
        #expect(c.month == 10)
        #expect(c.day == 26) // 周一
        #expect(c.weekday == 2)
        #expect(c.hour == 8)
        #expect(c.minute == 30)
    }

    @Test("间隔：从锚点推进，不因上次完成时间漂移")
    func intervalNextFireIsAnchored() throws {
        let anchor = date(2026, 10, 20, 0, 0)
        let schedule = ScheduledTaskSchedule(
            rule: .interval(minutes: 60, anchor: anchor)
        )
        let next = try #require(ScheduleCalculator.nextFireDate(
            for: schedule,
            after: date(2026, 10, 20, 1, 0)
        ))
        #expect(next == date(2026, 10, 20, 2, 0))
    }

    @Test("一次任务过期后不再触发")
    func onceTaskExpires() {
        let schedule = ScheduledTaskSchedule(
            rule: .once(date(2026, 10, 20, 9, 0)),
            timeZoneIdentifier: "UTC"
        )
        #expect(ScheduleCalculator.nextFireDate(
            for: schedule,
            after: date(2026, 10, 20, 9, 0)
        ) == nil)
    }

    @Test("夏令时：不存在的本地时间顺延到之后第一个有效时刻")
    func dstSpringForward() throws {
        let schedule = ScheduledTaskSchedule(
            rule: .daily(hour: 2, minute: 30),
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let next = try #require(ScheduleCalculator.nextFireDate(
            for: schedule,
            after: date(2024, 3, 10, 1, 0, timeZone: "America/Los_Angeles")
        ))
        let c = components(of: next, timeZone: "America/Los_Angeles")
        #expect(c.year == 2024)
        #expect(c.month == 3)
        #expect(c.day == 10)
        #expect(c.hour == 3)
        #expect(c.minute == 0)
    }

    @Test("夏令时：重复的本地时间只取较早一次")
    func dstFallBack() throws {
        let schedule = ScheduledTaskSchedule(
            rule: .daily(hour: 1, minute: 30),
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let next = try #require(ScheduleCalculator.nextFireDate(
            for: schedule,
            after: date(2024, 11, 2, 2, 0, timeZone: "America/Los_Angeles")
        ))
        let c = components(of: next, timeZone: "America/Los_Angeles")
        #expect(c.year == 2024)
        #expect(c.month == 11)
        #expect(c.day == 3)
        #expect(c.hour == 1)
        #expect(c.minute == 30)
        let nextAfterFirst = try #require(ScheduleCalculator.nextFireDate(
            for: schedule,
            after: next
        ))
        let after = components(of: nextAfterFirst, timeZone: "America/Los_Angeles")
        #expect(after.day == 4)
    }

    @Test("到期判定：未到期 / 宽限内补跑 / 超出宽限标记错过 / 重叠跳过")
    func dueDecisionBoundaries() {
        let now = date(2026, 10, 20, 10, 0)
        let schedule = ScheduledTaskSchedule(rule: .daily(hour: 9, minute: 0))
        let due = task(schedule: schedule, nextFireAt: date(2026, 10, 20, 9, 0))
        #expect(ScheduleCalculator.dueDecision(task: due, now: now, isActive: false)
            == .run(scheduledFor: date(2026, 10, 20, 9, 0), trigger: .scheduled))
        #expect(ScheduleCalculator.dueDecision(task: due, now: now, isActive: true)
            == .skipOverlap(scheduledFor: date(2026, 10, 20, 9, 0)))

        let late = task(schedule: schedule, nextFireAt: date(2026, 10, 20, 7, 0))
        #expect(ScheduleCalculator.dueDecision(task: late, now: now, isActive: false)
            == .missed(scheduledFor: date(2026, 10, 20, 7, 0)))

        let future = task(schedule: schedule, nextFireAt: date(2026, 10, 20, 11, 0))
        #expect(ScheduleCalculator.dueDecision(task: future, now: now, isActive: false) == .notDue)

        let disabled = task(schedule: schedule, nextFireAt: date(2026, 10, 20, 9, 0), enabled: false)
        #expect(ScheduleCalculator.dueDecision(task: disabled, now: now, isActive: false) == .notDue)

        let unsupported = task(
            schedule: schedule,
            nextFireAt: date(2026, 10, 20, 9, 0),
            profileVersion: "unknown.v9"
        )
        #expect(ScheduleCalculator.dueDecision(task: unsupported, now: now, isActive: false) == .notDue)
    }

    @Test("校验：空名称/空指令/非法时间/非法星期/过短间隔/未知能力档")
    func validation() {
        let schedule = ScheduledTaskSchedule(rule: .daily(hour: 9, minute: 0))
        var candidate = task(schedule: schedule, nextFireAt: nil)
        candidate.name = " "
        #expect(candidate.validate() == .emptyName)

        candidate.name = "有效名称"
        candidate.prompt = "\n"
        #expect(candidate.validate() == .emptyPrompt)

        candidate.prompt = "指令"
        candidate.profileVersion = "unknown"
        #expect(candidate.validate() == .unsupportedProfile)

        candidate.profileVersion = ScheduledCapabilityProfile.readOnlyV1
        candidate.schedule = ScheduledTaskSchedule(rule: .daily(hour: 24, minute: 0))
        #expect(candidate.validate() == .invalidTime)

        candidate.schedule = ScheduledTaskSchedule(rule: .weekly(weekdays: [0], hour: 9, minute: 0))
        #expect(candidate.validate() == .invalidWeekdays)

        candidate.schedule = ScheduledTaskSchedule(
            rule: .interval(minutes: 1, anchor: Date())
        )
        #expect(candidate.validate() == .intervalTooShort)

        candidate.schedule = ScheduledTaskSchedule(
            rule: .once(Date(timeIntervalSinceNow: -60))
        )
        #expect(candidate.validate() == .onceInPast)
    }

    @Test("规则 JSON 往返稳定，包含时区")
    func scheduleRoundTrips() throws {
        let schedule = ScheduledTaskSchedule(
            rule: .weekly(weekdays: [1, 5], hour: 18, minute: 45),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(ScheduledTaskSchedule.self, from: data)
        #expect(decoded == schedule)
        #expect(decoded.timeZoneIdentifier == "Europe/Berlin")
    }

    @Test("能力档白名单不包含 Shell/写入/邮件发送/团队/提问/任意 SQL")
    func capabilityAllowlistIsReadOnly() {
        let allowed = ScheduledCapabilityProfile.allowedToolNames
        for forbidden in [
            "shell_run", "python_execute", "files_write", "files_delete", "files_rename",
            "mail_send", "mail_delete", "mail_mark", "reminders_create", "reminders_complete",
            "team_run", "ask_user", "notify_user", "sql_query", "skill_run_script",
            "skill_create", "browser_open", "browser_click", "backup_restore",
        ] {
            #expect(!allowed.contains(forbidden), "\(forbidden) 不应进入定时只读能力档")
        }
        #expect(allowed.contains("knowledge_search"))
        #expect(allowed.contains("files_read"))
        #expect(allowed.contains("web_fetch"))
    }
}

// MARK: - Store

@Suite("ScheduledTaskStore")
struct ScheduledTaskStoreTests {

    private func makeStores() throws -> (ScheduledTaskStore, ScheduledRunStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("space.sqlite").path)
        try DatabaseBootstrap.prepareSpace(queue)
        return (ScheduledTaskStore(databaseQueue: queue), ScheduledRunStore(databaseQueue: queue))
    }

    private func makeTask(
        name: String = "每日摘要",
        enabled: Bool = true,
        nextFireAt: Date? = Date().addingTimeInterval(60)
    ) -> ScheduledTask {
        ScheduledTask(
            name: name,
            enabled: enabled,
            prompt: "总结昨天的内容",
            schedule: ScheduledTaskSchedule(rule: .daily(hour: 9, minute: 0)),
            nextFireAt: nextFireAt
        )
    }

    @Test("任务定义保存、查询、筛选与删除")
    func taskCRUD() async throws {
        let (tasks, _) = try makeStores()
        let enabled = makeTask(name: "启用的任务")
        let disabled = makeTask(name: "停用的任务", enabled: false)
        try await tasks.save(enabled)
        try await tasks.save(disabled)

        let all = try await tasks.all()
        #expect(all.count == 2)
        let onlyEnabled = try await tasks.enabled()
        #expect(onlyEnabled.map(\.id) == [enabled.id])
        let fetched = try await tasks.task(id: enabled.id)
        #expect(fetched?.name == "启用的任务")
        #expect(fetched?.schedule == enabled.schedule)

        try await tasks.delete(id: enabled.id)
        #expect(try await tasks.task(id: enabled.id) == nil)
        #expect(try await tasks.all().count == 1)
    }

    @Test("触发游标更新不覆盖任务正文与规则")
    func updateFireStatePreservesDefinition() async throws {
        let (tasks, _) = try makeStores()
        var task = makeTask()
        try await tasks.save(task)
        let next = Date().addingTimeInterval(3_600)
        try await tasks.updateFireState(
            id: task.id,
            nextFireAt: next,
            lastRunAt: Date(),
            lastRunStatus: .succeeded
        )
        let fetched = try #require(try await tasks.task(id: task.id))
        #expect(abs((fetched.nextFireAt ?? .distantPast).timeIntervalSince(next)) < 0.01)
        #expect(fetched.lastRunStatus == .succeeded)
        #expect(fetched.prompt == task.prompt)
        #expect(fetched.schedule == task.schedule)
    }

    @Test("运行记录：计划时刻唯一，手动运行可多次")
    func runOccurrenceIsUnique() async throws {
        let (_, runs) = try makeStores()
        let taskID = UUID()
        let scheduledFor = Date()
        let first = ScheduledRun(
            taskID: taskID,
            taskName: "任务",
            trigger: .scheduled,
            scheduledFor: scheduledFor
        )
        #expect(try await runs.insert(first))
        #expect(try await runs.insert(first) == false)

        let manualA = ScheduledRun(taskID: taskID, taskName: "任务", trigger: .manual, scheduledFor: nil)
        let manualB = ScheduledRun(taskID: taskID, taskName: "任务", trigger: .manual, scheduledFor: nil)
        #expect(try await runs.insert(manualA))
        #expect(try await runs.insert(manualB))
        #expect(try await runs.runs(taskID: taskID).count == 3)
    }

    @Test("运行状态更新、活动运行查询与启动对账")
    func runLifecycleAndInterruption() async throws {
        let (_, runs) = try makeStores()
        let taskID = UUID()
        var run = ScheduledRun(
            taskID: taskID,
            taskName: "任务",
            trigger: .scheduled,
            scheduledFor: Date(),
            status: .pending
        )
        #expect(try await runs.insert(run))
        #expect(try await runs.activeRun(taskID: taskID)?.status == .pending)

        run.status = .running
        run.startedAt = Date()
        try await runs.update(run)
        #expect(try await runs.activeRun(taskID: taskID)?.status == .running)

        run.status = .succeeded
        run.finishedAt = Date()
        try await runs.update(run)
        #expect(try await runs.activeRun(taskID: taskID) == nil)
        #expect(try await runs.latestRun(taskID: taskID)?.status == .succeeded)

        let other = ScheduledRun(
            taskID: UUID(),
            taskName: "另一个任务",
            trigger: .manual,
            scheduledFor: nil,
            status: .running
        )
        #expect(try await runs.insert(other))
        #expect(try await runs.markInterrupted() == 1)
    }

    @Test("运行记录按任务保留上限裁剪")
    func runPruning() async throws {
        let (_, runs) = try makeStores()
        let taskID = UUID()
        for index in 0..<8 {
            let run = ScheduledRun(
                taskID: taskID,
                taskName: "任务",
                trigger: .scheduled,
                scheduledFor: Date().addingTimeInterval(TimeInterval(index)),
                status: .succeeded
            )
            #expect(try await runs.insert(run))
        }
        try await runs.prune(taskID: taskID, keep: 3)
        #expect(try await runs.runs(taskID: taskID, limit: 10).count == 3)
    }

    @Test("编辑任务保留最近运行状态，不被旧快照覆盖")
    func updatePreservesLastRun() async throws {
        let (tasks, _) = try makeStores()
        var task = makeTask()
        try await tasks.save(task)
        let finishedAt = Date()
        try await tasks.updateLastRun(id: task.id, lastRunAt: finishedAt, lastRunStatus: .succeeded)

        task.name = "改名"
        task.prompt = "新指令"
        task.updatedAt = Date()
        try await tasks.update(task)
        let fetched = try #require(try await tasks.task(id: task.id))
        #expect(fetched.name == "改名")
        #expect(fetched.prompt == "新指令")
        #expect(fetched.lastRunStatus == .succeeded)
        #expect(abs((fetched.lastRunAt ?? .distantPast).timeIntervalSince(finishedAt)) < 0.01)
    }

    @Test("任务删除后迟到编辑不会把它复活")
    func updateDoesNotResurrectDeletedTask() async throws {
        let (tasks, _) = try makeStores()
        var task = makeTask()
        try await tasks.save(task)
        try await tasks.delete(id: task.id)

        task.name = "迟到编辑"
        task.updatedAt = Date()
        try await tasks.update(task)
        #expect(try await tasks.all().isEmpty)
    }

    @Test("两个空间的定时定义互不串写")
    func spaceIsolation() async throws {
        let (personal, _) = try makeStores()
        let (work, _) = try makeStores()
        let task = makeTask(name: "生活任务")
        try await personal.save(task)

        #expect(try await personal.all().count == 1)
        #expect(try await work.all().isEmpty)
    }
}

// MARK: - Tool Policy

private struct NamedTool: DispatcherTool, Sendable {
    let definition: ToolDefinition
    let requiresConfirmation = false

    func execute(argumentsJSON: String) async throws -> String { "" }
}

@Suite("ScheduledToolPolicy")
struct ScheduledToolPolicyTests {
    @Test("只读白名单只保留允许工具，并继续应用排除名单")
    func allowlistFiltersToolSurface() {
        let names = ["get_current_time", "files_read", "shell_run", "files_write", "team_run"]
        let tools: [any DispatcherTool] = names.map { name in
            NamedTool(definition: ToolDefinition(
                name: name,
                description: "",
                parametersSchemaJSON: #"{"type":"object","properties":{}}"#
            ))
        }
        let filtered = EngineAssembly.filterTools(
            tools,
            allowedToolNames: ScheduledCapabilityProfile.allowedToolNames,
            excludedToolNames: []
        )
        #expect(filtered.map { $0.definition.name }.sorted() == ["files_read", "get_current_time"])
        #expect(!filtered.contains { $0.definition.name == "shell_run" })

        let excluded = EngineAssembly.filterTools(
            tools,
            allowedToolNames: nil,
            excludedToolNames: ["shell_run"]
        )
        #expect(excluded.count == 4)
        #expect(!excluded.contains { $0.definition.name == "shell_run" })
    }
}

@Suite("ScheduledFileScope")
struct ScheduledFileScopeTests {
    @Test("定时文件读取只允许当前空间的受管根与登记工作区")
    func fileScopeIsSpaceScoped() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = FileAreaService(baseDirectory: base)
        try service.ensureRoots()

        let work = ScheduledFileReadScope(service: service, space: .work)
        _ = try work.resolve(service.filesRoot.path)
        _ = try work.resolve(service.workspaceRoot.path)
        _ = try work.resolve(service.defaultChatRoot(for: .work).path)
        #expect(throws: (any Error).self) {
            _ = try work.resolve(service.privateRoot.path)
        }
        #expect(throws: (any Error).self) {
            _ = try work.resolve(service.defaultChatRoot(for: .personal).path)
        }

        let personal = ScheduledFileReadScope(service: service, space: .personal)
        _ = try personal.resolve(service.privateRoot.path)
        #expect(throws: (any Error).self) {
            _ = try personal.resolve(service.workspaceRoot.path)
        }
    }
}
