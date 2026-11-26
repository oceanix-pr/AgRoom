import Foundation
import GRDB
import Synchronization
import Testing
@testable import AgRoomCore

@Suite("Long-lived, space-bound job receipts")
struct ProductJobHistoryTests: Sendable {
    private func queue() throws -> DatabaseQueue {
        let value = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(value); return value
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestFailure.timeout
    }
    private enum TestFailure: Error { case timeout }
    private func cacheURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json") }

    @Test("Jobs beyond the indicator window remain searchable and paged without duplicate live receipts")
    func retainedBeyondCache() async throws {
        let db = try queue(), file = cacheURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ProductJobRunStore(databaseQueue: db, space: .work)
        let center = JobCenter(historyFileURL: file)
        var ids = Set<UUID>()
        var first: UUID?
        for index in 0..<45 {
            let id = center.submit(name: "Export \(index)", kind: "test", space: .work, origin: "settings", historyStore: store) { $0.reportResult("Result \(index)") }
            if first == nil { first = id }; ids.insert(id)
            try await wait { center.snapshot().first { $0.id == id }?.state == .succeeded }
        }
        #expect(center.history().count == JobCenter.maxHistory)
        let oldID = try #require(first)
        #expect(try await store.run(id: oldID)?.resultText == "Result 0")
        #expect(!JobCenter(historyFileURL: file).history().contains { $0.id == oldID })
        let timeline = ProductTaskCenterStore(databaseQueue: db, space: .work)
        var seen = Set<UUID>(), cursor: ProductTaskCenterItem?
        repeat {
            let page = try await timeline.page(source: .job, before: cursor, limit: 7, jobs: center.snapshot(space: .work))
            for item in page.items { #expect(seen.insert(item.sourceID).inserted) }
            cursor = page.items.last
            if !page.hasMore { break }
        } while cursor != nil
        #expect(seen == ids)
        let search = try await timeline.page(source: .job, search: "Export 0")
        #expect(search.items.count == 1 && search.items.first?.origin == "settings")
    }

    @Test("The first durable completion archives legacy cache entries before indicator rotation can discard them")
    func migrateBeforeRotation() async throws {
        let db = try queue(), file = cacheURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ProductJobRunStore(databaseQueue: db, space: .work), center = JobCenter(historyFileURL: file)
        var legacyIDs = Set<UUID>()
        for index in 0..<JobCenter.maxHistory {
            let id = center.submit(name: "Legacy \(index)", kind: "test", space: .work) { _ in }
            legacyIDs.insert(id)
            try await wait { center.snapshot().first { $0.id == id }?.state == .succeeded }
        }
        let id = center.submit(name: "First durable", kind: "test", space: .work, historyStore: store) { _ in }
        try await wait { center.snapshot().first { $0.id == id }?.state == .succeeded }
        let page = try await ProductTaskCenterStore(databaseQueue: db, space: .work).page(source: .job, limit: 100)
        #expect(Set(page.items.map(\.sourceID)) == legacyIDs.union([id]))
    }

    @Test("Backup preparation includes labelled legacy receipts even if the task center has never opened")
    func legacyIncludedInFirstBackup() async throws {
        let db = try queue(), target = try queue(), file = cacheURL()
        let root = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductJobRunStore(databaseQueue: db, space: .work), center = JobCenter(historyFileURL: file)
        let id = center.submit(name: "Old export", kind: "legacy", space: .work) { $0.reportResult("Legacy result") }
        let privateID = center.submit(name: "Personal", kind: "legacy", space: .personal) { _ in }
        try await wait { [id, privateID].allSatisfy { id in center.snapshot().contains { $0.id == id && $0.state.isFinished } } }
        let backup = BackupService(sessionService: SessionService(databaseQueue: db), memoryService: MemoryService(databaseQueue: db),
            skillStore: SkillStore(directoryURL: root.appendingPathComponent("source-skills")), spaceName: "work",
            prepareExport: { try await center.archiveHistory(to: store) })
        let zip = root.appendingPathComponent("backup.zip")
        _ = try await backup.export(to: zip)
        let restore = BackupService(sessionService: SessionService(databaseQueue: target), memoryService: MemoryService(databaseQueue: target),
            skillStore: SkillStore(directoryURL: root.appendingPathComponent("target-skills")), spaceName: "work")
        _ = try await restore.restore(from: zip)
        let restored = ProductJobRunStore(databaseQueue: target, space: .work)
        #expect(try await restored.run(id: id)?.resultText == "Legacy result")
        #expect(try await restored.run(id: privateID) == nil)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_prepare BEFORE INSERT ON product_job_runs BEGIN SELECT RAISE(FAIL,'injected'); END") }
        let rejected = root.appendingPathComponent("rejected.zip")
        await #expect(throws: (any Error).self) { _ = try await backup.export(to: rejected) }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
    }

    @Test("A terminal archive write failure retains the real result, releases the slot, and retries only persistence")
    func failedArchiveAndRetry() async throws {
        let db = try queue(), file = cacheURL(), executions = Mutex(0)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ProductJobRunStore(databaseQueue: db, space: .work), center = JobCenter(historyFileURL: file)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_job_finish BEFORE UPDATE ON product_job_runs BEGIN SELECT RAISE(FAIL,'injected'); END") }
        let id = center.submit(name: "Report", kind: "test", space: .work, historyStore: store) { context in
            executions.withLock { $0 += 1 }; context.reportResult("Actual report")
        }
        try await wait { center.snapshot().first { $0.id == id }?.state == .awaitingSave }
        let page = try await ProductTaskCenterStore(databaseQueue: db, space: .work).page(jobs: center.snapshot(space: .work))
        #expect(page.items.count == 1 && page.items.first?.status == .recoveryRequired)
        #expect(center.snapshot().first?.resultText == "Actual report")
        let other = center.submit(name: "Another", kind: "test") { _ in }
        try await wait { center.snapshot().first { $0.id == other }?.state == .succeeded }
        try await db.write { try $0.execute(sql: "DROP TRIGGER fail_job_finish") }
        #expect(await center.retryHistoryPersistence(id: id))
        #expect(executions.withLock { $0 } == 1)
        #expect(try await store.run(id: id)?.resultText == "Actual report")
        #expect(try await store.run(id: id)?.state == .succeeded)
    }

    @Test("Failed start persistence prevents execution; interrupted records never acquire an automatic replay")
    func failedStartAndInterruptedHistory() async throws {
        let db = try queue(), file = cacheURL(), executions = Mutex(0)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = ProductJobRunStore(databaseQueue: db, space: .personal), center = JobCenter(historyFileURL: file)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_job_start BEFORE INSERT ON product_job_runs BEGIN SELECT RAISE(FAIL,'injected'); END") }
        let id = center.submit(name: "No execution", kind: "test", space: .personal, historyStore: store) { _ in executions.withLock { $0 += 1 } }
        try await wait { center.snapshot().first { $0.id == id }?.state == .awaitingSave }
        #expect(executions.withLock { $0 } == 0)
        try await db.write { try $0.execute(sql: "DROP TRIGGER fail_job_start") }
        #expect(await center.retryHistoryPersistence(id: id))
        #expect(executions.withLock { $0 } == 0)
        var abandoned = BackgroundJob(name: "Interrupted", kind: "test", space: .personal)
        abandoned.state = .running
        try await store.recordStarted(abandoned)
        let history = try await ProductTaskCenterStore(databaseQueue: db, space: .personal).page(source: .job)
        #expect(history.items.contains { $0.sourceID == abandoned.id && $0.status == .recoveryRequired })
        let snapshot = try #require(try await store.run(id: abandoned.id))
        #expect(snapshot.state == .interrupted && snapshot.finishedAt == nil)
    }

    @Test("Interrupted jobs can be reviewed without changing their results or touching live jobs and other spaces")
    func acknowledgeInterruptedHistory() async throws {
        let db = try queue(), otherDB = try queue()
        let store = ProductJobRunStore(databaseQueue: db, space: .work)
        let otherStore = ProductJobRunStore(databaseQueue: otherDB, space: .personal)
        let center = ProductTaskCenterStore(databaseQueue: db, space: .work)
        var old = BackgroundJob(name: "Interrupted index", kind: "knowledge-index-work", space: .work, origin: "knowledge")
        old.state = .running
        try await store.recordStarted(old)
        let oldID = old.id
        try await db.write {
            try $0.execute(sql: "UPDATE product_job_runs SET hostID='previous-process' WHERE id=?", arguments: [oldID.uuidString])
        }
        var other = BackgroundJob(id: oldID, name: "Personal index", kind: "knowledge-index-personal", space: .personal)
        other.state = .interrupted
        try otherStore.saveCompleted([other])
        var cached = BackgroundJob(name: "Restored interruption", kind: "test", space: .work)
        cached.state = .interrupted
        cached.resultText = "Retained result"
        try store.saveCompleted([cached])
        var active = BackgroundJob(name: "Live index", kind: "knowledge-index-work", space: .work)
        active.state = .running
        try await store.recordStarted(active)
        let activeID = active.id
        await #expect(throws: ProductTaskHistoryError.self) { _ = try await store.acknowledgeInterruption(id: activeID) }

        try await db.write {
            try $0.execute(sql: "CREATE TRIGGER reject_review BEFORE UPDATE ON product_job_runs BEGIN SELECT RAISE(FAIL,'fixture'); END")
        }
        await #expect(throws: (any Error).self) { _ = try await store.acknowledgeInterruption(id: oldID) }
        #expect(try await store.run(id: oldID)?.state == .interrupted)
        try await db.write { try $0.execute(sql: "DROP TRIGGER reject_review") }

        let acknowledged = try await store.acknowledgeInterruption(id: oldID)
        #expect(acknowledged.state == .interruptionAcknowledged && acknowledged.finishedAt == nil)
        #expect(try await store.acknowledgeInterruption(id: oldID) == acknowledged)
        _ = try await store.acknowledgeInterruption(id: cached.id)
        try store.saveCompleted([cached])
        let snapshots = [cached, active, other]
        #expect(try await center.page(group: .attention, jobs: snapshots).items.isEmpty)
        let finished = try await center.page(group: .finished, jobs: snapshots).items
        #expect(Set(finished.map(\.sourceID)) == [oldID, cached.id])
        #expect(finished.allSatisfy { $0.sourceStatus == BackgroundJob.State.interruptionAcknowledged.rawValue })
        #expect(try await store.run(id: cached.id)?.resultText == "Retained result")
        #expect(try await otherStore.run(id: oldID)?.state == .interrupted)
        #expect(try await center.clearFinished(jobs: snapshots) == 2)
        #expect(try await center.page(jobs: snapshots).items.map(\.sourceID) == [activeID])
        #expect(try await store.run(id: oldID)?.state == .interruptionAcknowledged)
    }

    @Test("Scoped migration and explicit clearing never read the other space or remove active work")
    func legacyAndClearIsolation() async throws {
        let personalDB = try queue(), workDB = try queue(), file = cacheURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let personalStore = ProductJobRunStore(databaseQueue: personalDB, space: .personal)
        let workStore = ProductJobRunStore(databaseQueue: workDB, space: .work)
        let center = JobCenter(historyFileURL: file)
        let global = center.submit(name: "Unassigned old receipt", kind: "legacy") { _ in }
        let personal = center.submit(name: "Personal", kind: "legacy", space: .personal) { _ in }
        let work = center.submit(name: "Work", kind: "legacy", space: .work) { _ in }
        try await wait { [global, personal, work].allSatisfy { id in center.snapshot().contains { $0.id == id && $0.state.isFinished } } }
        try await center.archiveHistory(to: personalStore); try await center.archiveHistory(to: workStore)
        #expect(try await personalStore.run(id: personal) != nil)
        #expect(try await personalStore.run(id: work) == nil)
        #expect(try await workStore.run(id: personal) == nil)
        #expect(try await personalStore.run(id: global) == nil)
        let entered = Mutex(false), release = Mutex(false)
        let active = center.submit(name: "Active", kind: "test", space: .personal, historyStore: personalStore) { _ in
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await wait { entered.withLock { $0 } }
        var old = BackgroundJob(name: "Previous process", kind: "test", space: .personal)
        old.state = .running
        try await personalStore.recordStarted(old)
        let oldID = old.id
        try await personalDB.write { try $0.execute(sql: "UPDATE product_job_runs SET hostID='previous-process' WHERE id=?", arguments: [oldID.uuidString]) }
        #expect(await center.clearFinished(space: .personal, historyStore: personalStore))
        try await center.archiveHistory(to: personalStore)
        #expect(try await personalStore.run(id: personal) == nil)
        #expect(try await personalStore.run(id: old.id) == nil)
        #expect(try await personalStore.run(id: active) != nil)
        #expect(try await workStore.run(id: work) != nil)
        release.withLock { $0 = true }
        try await wait { center.snapshot().first { $0.id == active }?.state == .succeeded }
        #expect(try await personalStore.run(id: active)?.state == .succeeded)
    }

    @Test("Ordinary schedule insertion retains old receipts and explicit pruning cannot remove active occurrences")
    func scheduleLongHistory() async throws {
        let db = try queue(), store = ScheduledRunStore(databaseQueue: db), taskID = UUID()
        let active = ScheduledRun(taskID: taskID, taskName: "Active", trigger: .scheduled, scheduledFor: Date(timeIntervalSince1970: 1), status: .running)
        #expect(try await store.insert(active))
        for index in 0..<120 {
            let run = ScheduledRun(taskID: taskID, taskName: "Schedule", trigger: .scheduled,
                scheduledFor: Date(timeIntervalSince1970: Double(index + 2)), status: .succeeded)
            #expect(try await store.insert(run))
        }
        #expect(try await store.runs(taskID: taskID, limit: 200).count == 121)
        try await store.prune(taskID: taskID, keep: 3)
        #expect(try await store.runs(taskID: taskID, limit: 200).count == 4)
        #expect(try await store.activeRun(taskID: taskID)?.id == active.id)
        #expect(try await store.insert(active) == false)
    }
}
