import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Legacy Daemon migration preflight")
struct DaemonLegacyMigrationPreflightTests {
    private struct Fixture {
        let parent: URL
        let daemon: URL
        let workQueue: DatabaseQueue
        let personalQueue: DatabaseQueue
        let work: SessionService
        let personal: SessionService
    }

    private struct LegacyOwner: Encodable {
        let version = 1
        let id: UUID
        let space: AppSpace
        let sessionId: UUID
        let assistantMessageId: UUID
        let taskRunID: UUID? = nil
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-preflight-qc-" + UUID().uuidString, isDirectory: true)
        let daemon = parent.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        let workQueue = try DatabaseQueue()
        let personalQueue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(workQueue)
        try DatabaseBootstrap.prepareSpace(personalQueue)
        return Fixture(parent: parent, daemon: daemon, workQueue: workQueue,
            personalQueue: personalQueue, work: SessionService(databaseQueue: workQueue),
            personal: SessionService(databaseQueue: personalQueue))
    }

    private func record(id: UUID = UUID(), space: AppSpace = .work,
                        sessionID: UUID = UUID(), messageID: UUID = UUID(),
                        state: DaemonRunState = .completed) -> DaemonRunRecord {
        let snapshot = EngineRunSnapshot(messages: [], thoughts: [], trace: [], stepsUsed: 0,
            totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0,
            callFingerprintCounts: [:], consecutiveFailedRounds: 0,
            restrictedToolNames: nil, activeSkillWorkspace: nil,
            loopNoticeInjected: false, preApprovedTools: [])
        let settings = DaemonRunSettings(maxTokens: 128, temperature: 0,
            reasoningEffortRaw: nil, maxSteps: 1, replyLanguageInstruction: "English",
            personaInstruction: "SYNTHETIC_PRIVATE_BODY_MARKER", workspacePath: "")
        return DaemonRunRecord(id: id, space: space, sessionId: sessionID,
            assistantMessageId: messageID, state: state,
            snapshot: snapshot, settings: settings)
    }

    private func writeLegacy(_ record: DaemonRunRecord, to daemon: URL) throws -> (body: URL, owner: URL) {
        let body = daemon.appendingPathComponent("run-\(record.id.uuidString).json")
        let owner = daemon.appendingPathComponent("owner-\(record.id.uuidString).json")
        try JSONEncoder().encode(record).write(to: body)
        try JSONEncoder().encode(LegacyOwner(id: record.id, space: record.space,
            sessionId: record.sessionId, assistantMessageId: record.assistantMessageId)).write(to: owner)
        return (body, owner)
    }

    private func saveMessage(_ service: SessionService, sessionID: UUID, messageID: UUID,
                             role: ChatMessage.Role = .assistant,
                             status: TaskRunStatus = .succeeded,
                             content: String = "SYNTHETIC_PRIVATE_MESSAGE_MARKER") async throws {
        var session = ChatSession(id: sessionID, title: "Synthetic migration preflight")
        session.messages = [ChatMessage(id: messageID, role: role, content: content,
            runStatus: status)]
        try await service.save(session)
    }

    private func input(_ record: DaemonRunRecord, target: LegacyDaemonRecordProbeResult,
                       targetExpectation: LegacyDaemonRecordExpectation? = nil,
                       origin: DaemonRecordOrigin = .legacyRoot) -> DaemonLegacyMigrationPlanner.Input {
        let expected = LegacyDaemonRecordExpectation(record: record)
        return .init(located: LocatedDaemonRecord(record: record, origin: origin),
            target: .init(space: record.space, expectation: targetExpectation ?? expected, result: target))
    }

    @Test("Same UUIDs in two physical databases remain independent; other-space exact never substitutes for target")
    func dualSpaceSameUUIDAndNoFallback() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let id = UUID(), sessionID = UUID(), messageID = UUID()
        let workRecord = record(id: id, sessionID: sessionID, messageID: messageID)
        let paths = try writeLegacy(workRecord, to: fixture.daemon)
        let originalBody = try Data(contentsOf: paths.body)
        let originalOwner = try Data(contentsOf: paths.owner)
        try await saveMessage(fixture.work, sessionID: sessionID, messageID: messageID,
            content: "WORK_PRIVATE_MESSAGE_MARKER")
        try await saveMessage(fixture.personal, sessionID: sessionID, messageID: messageID,
            content: "PERSONAL_PRIVATE_MESSAGE_MARKER")
        let expected = LegacyDaemonRecordExpectation(record: workRecord)
        let workProbe = await fixture.work.probeLegacyDaemonRecord(expected)
        let personalProbe = await fixture.personal.probeLegacyDaemonRecord(expected)
        #expect(workProbe == .exact)
        #expect(personalProbe == .exact)
        let report = DaemonLegacyInventory.inspect(root: fixture.daemon)
        #expect(report.summary.isComplete && !report.summary.hasUnknownEvidence)
        let decision = try #require(DaemonLegacyMigrationPlanner.assess(report: report,
            inputs: [input(workRecord, target: workProbe)]).first)
        #expect(decision.disposition == .preflightCandidate(.completedReview))
        let description = String(describing: decision)
        #expect(!description.contains("PRIVATE_MESSAGE_MARKER"))
        #expect(!description.contains("PRIVATE_BODY_MARKER"))
        #expect(!description.contains(fixture.parent.path))
        #expect(try Data(contentsOf: paths.body) == originalBody)
        #expect(try Data(contentsOf: paths.owner) == originalOwner)
        #expect(try await fixture.work.fetch(id: sessionID)?.messages.first?.content == "WORK_PRIVATE_MESSAGE_MARKER")
        #expect(try await fixture.personal.fetch(id: sessionID)?.messages.first?.content == "PERSONAL_PRIVATE_MESSAGE_MARKER")

        let missingTarget = record(sessionID: UUID(), messageID: UUID())
        _ = try writeLegacy(missingTarget, to: fixture.daemon)
        try await saveMessage(fixture.personal, sessionID: missingTarget.sessionId,
            messageID: missingTarget.assistantMessageId)
        let targetResult = await fixture.work.probeLegacyDaemonRecord(.init(record: missingTarget))
        let otherResult = await fixture.personal.probeLegacyDaemonRecord(.init(record: missingTarget))
        #expect(targetResult == .missing && otherResult == .exact)
        let missingDecision = try #require(DaemonLegacyMigrationPlanner.assess(
            report: DaemonLegacyInventory.inspect(root: fixture.daemon),
            inputs: [input(missingTarget, target: targetResult)]).first)
        #expect(missingDecision.disposition == .deferred(.targetNotExact))
    }

    @Test("The single-space database probe rejects missing, mismatched, restored and damaged conversations")
    func databaseProbeRejectsUntrustedMatches() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let absent = record()
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: absent)) == .missing)

        let missingMessage = record()
        try await saveMessage(fixture.work, sessionID: missingMessage.sessionId, messageID: UUID())
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: missingMessage)) == .missing)

        let wrongRole = record()
        try await saveMessage(fixture.work, sessionID: wrongRole.sessionId,
            messageID: wrongRole.assistantMessageId, role: .user)
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: wrongRole)) == .conflict)

        let duplicate = record()
        var duplicateSession = ChatSession(id: duplicate.sessionId, title: "Duplicate assistant ID")
        duplicateSession.messages = [
            ChatMessage(id: duplicate.assistantMessageId, role: .assistant,
                content: "SYNTHETIC_FIRST_COPY", runStatus: .succeeded),
            ChatMessage(id: duplicate.assistantMessageId, role: .assistant,
                content: "SYNTHETIC_SECOND_COPY", runStatus: .succeeded)
        ]
        try await fixture.work.save(duplicateSession)
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: duplicate)) == .conflict)

        let pending = record()
        try await saveMessage(fixture.work, sessionID: pending.sessionId,
            messageID: pending.assistantMessageId)
        let pendingID = pending.sessionId.uuidString
        try await fixture.workQueue.write { db in
            try db.execute(sql: "UPDATE chat_sessions SET pendingConfirmationJSON='{}' WHERE id=?",
                arguments: [pendingID])
        }
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: pending)) == .conflict)

        let wrongRun = record()
        var runSession = ChatSession(id: wrongRun.sessionId, title: "Wrong run")
        runSession.messages = [ChatMessage(id: wrongRun.assistantMessageId,
            role: .assistant, content: "SYNTHETIC_WRONG_RUN_MARKER",
            runStatus: .succeeded, taskRun: ProductTaskIdentity())]
        try await fixture.work.save(runSession)
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: wrongRun)) == .conflict)

        let restored = record()
        try await saveMessage(fixture.work, sessionID: restored.sessionId,
            messageID: restored.assistantMessageId)
        try await fixture.work.invalidateRestoredSnapshots(ids: [restored.sessionId])
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: restored)) == .conflict)

        let damaged = record()
        try await saveMessage(fixture.work, sessionID: damaged.sessionId,
            messageID: damaged.assistantMessageId)
        let damagedID = damaged.sessionId.uuidString
        try await fixture.workQueue.write { db in
            try db.execute(sql: "UPDATE chat_messages SET payload='broken' WHERE sessionId=?",
                arguments: [damagedID])
        }
        #expect(await fixture.work.probeLegacyDaemonRecord(.init(record: damaged)) == .unavailable)

        let unprepared = SessionService(databaseQueue: try DatabaseQueue())
        #expect(await unprepared.probeLegacyDaemonRecord(.init(record: absent)) == .unavailable)
    }

    @Test("Only a matching inventory body and bound probe can suggest terminal review or retained recovery")
    func plannerBindsBodyVersionAndProbeIdentity() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let completed = record()
        try writeLegacy(completed, to: fixture.daemon)
        try await saveMessage(fixture.work, sessionID: completed.sessionId,
            messageID: completed.assistantMessageId)
        let recovery = record(state: .recoveryRequired(reason: "synthetic unknown result"))
        try writeLegacy(recovery, to: fixture.daemon)
        try await saveMessage(fixture.work, sessionID: recovery.sessionId,
            messageID: recovery.assistantMessageId, status: .recoveryRequired)
        let actuallyRunning = record(state: .running)
        _ = try writeLegacy(actuallyRunning, to: fixture.daemon)
        let report = DaemonLegacyInventory.inspect(root: fixture.daemon)
        let completedProbe = await fixture.work.probeLegacyDaemonRecord(.init(record: completed))
        let recoveryProbe = await fixture.work.probeLegacyDaemonRecord(.init(record: recovery))
        #expect(completedProbe == .exact && recoveryProbe == .exact)
        let decisions = DaemonLegacyMigrationPlanner.assess(report: report, inputs: [
            input(completed, target: completedProbe), input(recovery, target: recoveryProbe)
        ])
        #expect(decisions.first(where: { $0.recordID == completed.id })?.disposition ==
            .preflightCandidate(.completedReview))
        #expect(decisions.first(where: { $0.recordID == recovery.id })?.disposition ==
            .preflightCandidate(.recoveryRetention))

        var forgedState = completed
        forgedState.state = .running
        let stale = DaemonLegacyMigrationPlanner.assess(report: report,
            inputs: [input(forgedState, target: .exact)]).first
        #expect(stale?.disposition == .deferred(.bodyVersionMismatch))
        var forgedToken = completed
        forgedToken.restorationToken = "SYNTHETIC_DIFFERENT_RESTORE_TOKEN"
        let wrongToken = DaemonLegacyMigrationPlanner.assess(report: report,
            inputs: [input(forgedToken, target: .exact)]).first
        #expect(wrongToken?.disposition == .deferred(.bodyVersionMismatch))
        var forgedCompletion = actuallyRunning
        forgedCompletion.state = .completed
        let falseCleanup = DaemonLegacyMigrationPlanner.assess(report: report,
            inputs: [input(forgedCompletion, target: .exact)]).first
        #expect(falseCleanup?.disposition == .deferred(.bodyVersionMismatch))

        let wrongExpectations = [
            LegacyDaemonRecordExpectation(sessionID: UUID(),
                assistantMessageID: completed.assistantMessageId, taskRunID: nil,
                restorationToken: nil, state: .completed),
            LegacyDaemonRecordExpectation(sessionID: completed.sessionId,
                assistantMessageID: UUID(), taskRunID: nil,
                restorationToken: nil, state: .completed),
            LegacyDaemonRecordExpectation(sessionID: completed.sessionId,
                assistantMessageID: completed.assistantMessageId, taskRunID: UUID(),
                restorationToken: nil, state: .completed),
            LegacyDaemonRecordExpectation(sessionID: completed.sessionId,
                assistantMessageID: completed.assistantMessageId, taskRunID: nil,
                restorationToken: "SYNTHETIC_OTHER_GENERATION", state: .completed),
            LegacyDaemonRecordExpectation(sessionID: completed.sessionId,
                assistantMessageID: completed.assistantMessageId, taskRunID: nil,
                restorationToken: nil, state: .recoveryRequired)
        ]
        for expectation in wrongExpectations {
            let mismatched = DaemonLegacyMigrationPlanner.assess(report: report,
                inputs: [input(completed, target: .exact, targetExpectation: expectation)]).first
            #expect(mismatched?.disposition == .deferred(.probeExpectationMismatch))
        }
        let wrongSpace = DaemonLegacyMigrationPlanner.Input(
            located: .init(record: completed, origin: .legacyRoot),
            target: .init(space: .personal, expectation: .init(record: completed), result: .exact))
        #expect(DaemonLegacyMigrationPlanner.assess(report: report,
            inputs: [wrongSpace]).first?.disposition == .deferred(.probeSpaceMismatch))
    }

    @Test("Active runs, incomplete inventory and unrelated legacy evidence cannot become migration candidates")
    func plannerDefersUnsafeLegacyShapes() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let active = record(state: .running)
        try writeLegacy(active, to: fixture.daemon)
        let clean = DaemonLegacyInventory.inspect(root: fixture.daemon)
        #expect(DaemonLegacyMigrationPlanner.assess(report: clean,
            inputs: [input(active, target: .exact)]).first?.disposition == .deferred(.unsupportedState))
        let incomplete = DaemonLegacyInventory.inspect(root: fixture.daemon,
            limits: .init(maxEntries: 1))
        #expect(!incomplete.summary.isComplete)
        #expect(DaemonLegacyMigrationPlanner.assess(report: incomplete,
            inputs: [input(active, target: .exact)]).first?.disposition == .deferred(.inventoryIncomplete))
        try Data("SYNTHETIC_PRIVATE_OLD_LOG".utf8).write(to:
            fixture.daemon.appendingPathComponent("daemon.log"))
        let withLog = DaemonLegacyInventory.inspect(root: fixture.daemon)
        #expect(withLog.summary.hasUnknownEvidence)
        #expect(DaemonLegacyMigrationPlanner.assess(report: withLog,
            inputs: [input(active, target: .exact)]).first?.disposition == .deferred(.globalUnknownEvidence))
        #expect(!String(describing: DaemonLegacyMigrationPlanner.assess(report: withLog,
            inputs: [input(active, target: .exact)])).contains("SYNTHETIC_PRIVATE_OLD_LOG"))

        try FileManager.default.removeItem(at: fixture.daemon.appendingPathComponent("daemon.log"))
        let handoff = DaemonHandoff(space: .personal, sessionId: UUID(),
            assistantMessageId: UUID(), snapshot: active.snapshot, settings: active.settings)
        let handoffURL = fixture.daemon.appendingPathComponent("handoff-\(handoff.id.uuidString).json")
        try JSONEncoder().encode(handoff).write(to: handoffURL)
        let withHandoff = DaemonLegacyInventory.inspect(root: fixture.daemon)
        #expect(withHandoff.summary.hasUnknownEvidence)
        #expect(DaemonLegacyMigrationPlanner.assess(report: withHandoff,
            inputs: [input(active, target: .exact)]).first?.disposition == .deferred(.globalUnknownEvidence))

        try FileManager.default.removeItem(at: handoffURL)
        let orphanID = UUID()
        let orphanJournal = fixture.daemon.appendingPathComponent(
            "run-\(orphanID.uuidString)/operations.json")
        try FileManager.default.createDirectory(at: orphanJournal.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{unpaired journal".utf8).write(to: orphanJournal)
        let withOrphan = DaemonLegacyInventory.inspect(root: fixture.daemon)
        #expect(withOrphan.summary.hasUnknownEvidence)
        #expect(DaemonLegacyMigrationPlanner.assess(report: withOrphan,
            inputs: [input(active, target: .exact)]).first?.disposition == .deferred(.globalUnknownEvidence))
    }
}
