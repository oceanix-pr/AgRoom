import Foundation
import Synchronization
import Testing
@testable import AgRoomCore

@Suite("Durable background job completion")
struct JobLifecycleTests: Sendable {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Background job did not reach the expected state")
    }
    private func write(_ entries: [BackgroundJob], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    @Test("Completion survives toolbar eviction and reports failed persistence exactly once")
    func trackedOutcomes() async throws {
        let center = JobCenter.ephemeral()
        let submission = center.submitTracked(name: "Target", kind: "note", space: .personal, origin: "notes", historyStore: nil) { _ in }
        try await wait { center.history().contains { $0.id == submission.id } }
        for _ in 0..<25 { center.submit(name: "Later", kind: "test", space: .personal) { _ in } }
        try await wait { !center.snapshot().contains { $0.id == submission.id || $0.isActive } }
        var stream = submission.completion.makeAsyncIterator()
        let finished = try #require(await stream.next())
        #expect(finished.job.space == .personal && finished.job.id == submission.id && finished.job.state == .succeeded && finished.historySaved)
        #expect(await stream.next() == nil)

        let fail = Mutex(true), count = Mutex(0)
        let unavailable = JobCenter(historyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            historyWriter: { _, _ in if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) } })
        let retry = unavailable.submitTracked(name: "Receipt", kind: "test", space: .work, origin: "notes", historyStore: nil) { _ in
            count.withLock { $0 += 1 }
        }
        var delayed = retry.completion.makeAsyncIterator()
        let pending = try #require(await delayed.next())
        #expect(!pending.historySaved && pending.job.state == .succeeded)
        #expect(unavailable.snapshot().first?.state == .awaitingSave)
        fail.withLock { $0 = false }
        #expect(await unavailable.retryHistoryPersistence(id: retry.id))
        #expect(await delayed.next() == nil && count.withLock { $0 } == 1)
    }

    @Test("Polling, new subscriptions and completion callbacks cannot see success while disk is blocked")
    func diskBeforeVisibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let entered = Mutex(false), writes = Mutex(0), callbacks = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let center = JobCenter(historyFileURL: file, historyWriter: { entries, url in
            let number = writes.withLock { $0 += 1; return $0 }
            if number == 1 {
                entered.withLock { $0 = true }
                guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
            }
            try write(entries, url)
        })
        center.onCompletion = { _ in callbacks.withLock { $0 += 1 } }
        let id = center.submit(name: "First", kind: "test") { $0.reportResult("done") }
        try await wait { entered.withLock { $0 } }
        #expect(center.snapshot().first { $0.id == id }?.state.isFinished == false)
        #expect(center.history().isEmpty)
        #expect(callbacks.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        var subscriber = center.stream().makeAsyncIterator()
        let first = await subscriber.next()
        #expect(first?.first { $0.id == id }?.state.isFinished == false)
        let other = center.submit(name: "Other", kind: "test") { $0.reportResult("other") }
        release.signal()
        try await wait { center.snapshot().first { $0.id == other }?.state.isFinished == true }
        let history = try JSONDecoder().decode([BackgroundJob].self, from: Data(contentsOf: file))
        #expect(Set(history.map(\.id)) == [id, other])
        try await wait { callbacks.withLock { $0 } == 2 }
    }

    @Test("A failed history write stays unfinished; retry saves the receipt without executing the job again")
    func retryOnlyPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let fail = Mutex(true), executions = Mutex(0)
        let center = JobCenter(historyFileURL: file, historyWriter: { entries, url in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            try write(entries, url)
        })
        let id = center.submit(name: "Export", kind: "test") { context in
            executions.withLock { $0 += 1 }
            context.reportResult("Generated result")
        }
        try await wait { center.snapshot().first?.state == .awaitingSave }
        #expect(center.history().isEmpty)
        #expect(center.snapshot().first?.resultText == "Generated result")
        #expect(center.snapshot().first?.state.isFinished == false)
        fail.withLock { $0 = false }
        #expect(await center.retryHistoryPersistence(id: id))
        #expect(executions.withLock { $0 } == 1)
        #expect(center.snapshot().first?.state == .succeeded)
        #expect(JobCenter(historyFileURL: file).history().first?.id == id)
    }

    @Test("Storage failure in one space does not block completion or clearing in the other")
    func scopedFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let center = JobCenter(historyFileURL: file, historyWriter: { entries, url in
            if url.deletingLastPathComponent().lastPathComponent == "personal" { throw CocoaError(.fileWriteNoPermission) }
            try write(entries, url)
        })
        let personal = center.submit(name: "Personal", kind: "test", space: .personal) { _ in }
        let work = center.submit(name: "Work", kind: "test", space: .work) { _ in }
        try await wait { center.snapshot().first { $0.id == personal }?.state == .awaitingSave }
        try await wait { center.snapshot().first { $0.id == work }?.state == .succeeded }
        let contents = try String(contentsOf: root.appendingPathComponent("work/history.json"), encoding: .utf8)
        #expect(contents.contains("Work") && !contents.contains("Personal"))
        #expect(await center.clearFinished(space: .work))
        #expect(center.snapshot().contains { $0.id == personal && $0.state == .awaitingSave })
        #expect(!center.snapshot().contains { $0.id == work })
    }
    @Test("History retention and later completion preserve the other space's full receipt window")
    func retentionIsPerSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("history.json")
        for space in AppSpace.allCases {
            let entries = (0..<JobCenter.maxHistory).map { index -> BackgroundJob in
                var job = BackgroundJob(name: "History \(index)", kind: "test", space: space)
                job.state = .succeeded; job.finishedAt = Date(timeIntervalSince1970: Double(index))
                return job
            }
            try write(entries, root.appendingPathComponent(space.rawValue + "/history.json"))
        }
        let center = JobCenter(historyFileURL: base)
        #expect(center.history().filter { $0.space == .personal }.count == JobCenter.maxHistory)
        #expect(center.history().filter { $0.space == .work }.count == JobCenter.maxHistory)
        let id = center.submit(name: "New work", kind: "test", space: .work) { _ in }
        try await wait { center.snapshot().first { $0.id == id }?.state == .succeeded }
        let restored = JobCenter(historyFileURL: base)
        #expect(restored.history().filter { $0.space == .personal }.count == JobCenter.maxHistory)
        #expect(restored.history().filter { $0.space == .work }.count == JobCenter.maxHistory)
        #expect(await center.clearFinished())
        #expect(JobCenter(historyFileURL: base).history().isEmpty)
    }

}
