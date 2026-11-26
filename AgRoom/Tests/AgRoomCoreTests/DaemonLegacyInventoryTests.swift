import Foundation
import Darwin
import Testing
@testable import AgRoomCore

@Suite("Legacy daemon inventory")
struct DaemonLegacyInventoryTests {
    private struct LegacyOwner: Encodable {
        let version = 1
        let id: UUID
        let space: AppSpace
        let sessionId: UUID
        let assistantMessageId: UUID
        let taskRunID: UUID? = nil
    }

    private func temporaryRoot() throws -> (parent: URL, daemon: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-inventory-qc-" + UUID().uuidString, isDirectory: true)
        let daemon = parent.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        return (parent, daemon)
    }

    private func record(id: UUID, space: AppSpace, sessionID: UUID, messageID: UUID) -> DaemonRunRecord {
        let snapshot = EngineRunSnapshot(messages: [], thoughts: [], trace: [], stepsUsed: 0,
            totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0,
            callFingerprintCounts: [:], consecutiveFailedRounds: 0,
            restrictedToolNames: nil, activeSkillWorkspace: nil,
            loopNoticeInjected: false, preApprovedTools: [])
        let settings = DaemonRunSettings(maxTokens: 128, temperature: 0,
            reasoningEffortRaw: nil, maxSteps: 1, replyLanguageInstruction: "English",
            personaInstruction: "SYNTHETIC_PRIVATE_BODY_MARKER", workspacePath: "")
        return DaemonRunRecord(id: id, space: space, sessionId: sessionID,
            assistantMessageId: messageID, snapshot: snapshot, settings: settings)
    }

    @Test("The shared root inventory covers orphan journals, abandoned evidence and logs without following links or space directories")
    func recursiveEvidenceAndNoTraversal() throws {
        let fixture = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let runID = UUID()
        let journal = fixture.daemon.appendingPathComponent("run-\(runID.uuidString)/operations.json")
        try fileManager.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"synthetic\":true}".utf8).write(to: journal)
        let abandoned = fixture.daemon.appendingPathComponent("quarantine/abandoned/1-run-\(runID.uuidString).json")
        try fileManager.createDirectory(at: abandoned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{damaged legacy bytes".utf8).write(to: abandoned)
        let log = fixture.daemon.appendingPathComponent("daemon.log")
        try Data("SYNTHETIC_PRIVATE_LOG_MARKER".utf8).write(to: log)
        try Data("temporary copy".utf8).write(to: fixture.daemon.appendingPathComponent(".pending-synthetic"))
        try Data("unknown format".utf8).write(to: fixture.daemon.appendingPathComponent("mystery.bin"))

        // Personal and work are fixed boundaries. An equal UUID in both
        // partitions must not be treated as one legacy-root evidence group.
        for space in ["personal", "work"] {
            let directory = fixture.daemon.appendingPathComponent(space, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("SPACE_PRIVATE_\(space)".utf8).write(to:
                directory.appendingPathComponent("run-\(runID.uuidString).json"))
        }
        let outside = fixture.parent.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("SYMLINK_TARGET_MUST_NOT_BE_READ".utf8).write(to:
            outside.appendingPathComponent("secret.txt"))
        try fileManager.createSymbolicLink(at: fixture.daemon.appendingPathComponent("escape"),
            withDestinationURL: outside)

        let report = DaemonLegacyInventory.inspect(root: fixture.daemon)
        func kind(_ path: String) -> String? {
            report.entries.first(where: { $0.relativePath == path }).map { String(describing: $0.kind) }
        }
        #expect(kind("run-\(runID.uuidString)/operations.json") == "journalFile")
        #expect(kind("quarantine/abandoned/1-run-\(runID.uuidString).json") == "abandonedEvidence")
        #expect(kind("daemon.log") == "legacyLog")
        #expect(kind("escape") == "symbolicLink")
        #expect(kind("personal") == "spaceBoundary")
        #expect(kind("work") == "spaceBoundary")
        #expect(report.entries.contains { $0.relativePath == "mystery.bin" })
        #expect(report.entries.contains { $0.relativePath == ".pending-synthetic" })
        #expect(!report.entries.contains { $0.relativePath.contains("secret.txt") ||
            $0.relativePath.contains("SPACE_PRIVATE_") })
        #expect(report.summary.hasLegacyContent)
        #expect(report.summary.hasUnknownEvidence)
        #expect(report.entries.first(where: { $0.relativePath == "daemon.log" })?.sha256?.isEmpty == false)
        #expect(!String(describing: report).contains("SYNTHETIC_PRIVATE_LOG_MARKER"))
        #expect(!String(describing: report).contains("SYMLINK_TARGET_MUST_NOT_BE_READ"))
    }

    @Test("Only matching legacy body and owner establish a space; conflicts retain an unknown group")
    func ownerAndBodyMustCorroborate() throws {
        let fixture = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let goodID = UUID(), goodSession = UUID(), goodMessage = UUID()
        let good = record(id: goodID, space: .personal, sessionID: goodSession, messageID: goodMessage)
        try JSONEncoder().encode(good).write(to: fixture.daemon
            .appendingPathComponent("run-\(goodID.uuidString).json"))
        try JSONEncoder().encode(LegacyOwner(id: goodID, space: .personal,
            sessionId: goodSession, assistantMessageId: goodMessage)).write(to: fixture.daemon
            .appendingPathComponent("owner-\(goodID.uuidString).json"))

        let conflictID = UUID(), bodySession = UUID(), bodyMessage = UUID()
        let conflict = record(id: conflictID, space: .work, sessionID: bodySession, messageID: bodyMessage)
        try JSONEncoder().encode(conflict).write(to: fixture.daemon
            .appendingPathComponent("run-\(conflictID.uuidString).json"))
        try JSONEncoder().encode(LegacyOwner(id: conflictID, space: .personal,
            sessionId: UUID(), assistantMessageId: UUID())).write(to: fixture.daemon
            .appendingPathComponent("owner-\(conflictID.uuidString).json"))

        let report = DaemonLegacyInventory.inspect(root: fixture.daemon)
        let goodGroup = try #require(report.groups.first { $0.id == goodID })
        if case .fileCorroborated(let space, let sessionID, let messageID, _) = goodGroup.ownership {
            #expect(space == .personal)
            #expect(sessionID == goodSession)
            #expect(messageID == goodMessage)
        } else { Issue.record("Matching owner and body should establish personal ownership") }
        let conflictGroup = try #require(report.groups.first { $0.id == conflictID })
        if case .unknown = conflictGroup.ownership {
            #expect(report.summary.hasUnknownEvidence)
        } else { Issue.record("Conflicting owner and body must never establish ownership") }
        #expect(!String(describing: report).contains("SYNTHETIC_PRIVATE_BODY_MARKER"))
    }

    @Test("A journal bound to another space or run invalidates otherwise matching legacy owner and body")
    func journalBindingMustMatchGroup() throws {
        let fixture = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        var mismatchedIDs: [UUID] = []
        for wrongSpace in [true, false] {
            let id = UUID(), sessionID = UUID(), messageID = UUID()
            mismatchedIDs.append(id)
            let body = record(id: id, space: .personal, sessionID: sessionID, messageID: messageID)
            try JSONEncoder().encode(body).write(to: fixture.daemon
                .appendingPathComponent("run-\(id.uuidString).json"))
            try JSONEncoder().encode(LegacyOwner(id: id, space: .personal,
                sessionId: sessionID, assistantMessageId: messageID)).write(to: fixture.daemon
                .appendingPathComponent("owner-\(id.uuidString).json"))
            let journalDirectory = fixture.daemon.appendingPathComponent("run-\(id.uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            let binding = OperationJournal.Binding(runID: wrongSpace ? id : UUID(),
                space: wrongSpace ? .work : .personal)
            let journal = OperationJournal(directory: journalDirectory, binding: binding)
            let identity = OperationJournal.CallIdentity(binding: binding, modelStep: 1,
                toolName: "files_write", argumentsJSON: "{\"synthetic\":true}")
            #expect(journal.recordIntent(operationID: "synthetic-write", identity: identity))
        }
        let report = DaemonLegacyInventory.inspect(root: fixture.daemon)
        for id in mismatchedIDs {
            let group = try #require(report.groups.first { $0.id == id })
            if case .unknown = group.ownership { }
            else { Issue.record("A foreign journal binding must prevent file corroboration") }
            #expect(group.entries.contains { $0.kind == .journalFile })
        }
        #expect(report.summary.hasUnknownEvidence)
    }

    @Test("An invalid inventory root cannot be treated as an empty, complete migration")
    func nonDirectoryRootFailsClosed() throws {
        let fixture = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let ordinaryFile = fixture.parent.appendingPathComponent("not-a-directory")
        try Data("synthetic bytes".utf8).write(to: ordinaryFile)
        let report = DaemonLegacyInventory.inspect(root: ordinaryFile)
        #expect(!report.summary.isComplete)
    }

    @Test("Budget exhaustion, hard links and unsupported file types retain original evidence without trusting it")
    func unsafeFileShapesFailClosed() throws {
        let fixture = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let largeURL = fixture.daemon.appendingPathComponent("daemon.log")
        let original = Data("SYNTHETIC_PRIVATE_BUDGET_MARKER".utf8)
        try original.write(to: largeURL)
        let budget = DaemonLegacyInventory.inspect(root: fixture.daemon,
            limits: .init(maxFileBytes: 4))
        let overBudget = try #require(budget.entries.first { $0.relativePath == "daemon.log" })
        #expect(overBudget.status == .overBudget)
        #expect(overBudget.sha256 == nil)
        #expect(!budget.summary.isComplete)
        #expect(budget.summary.hasUnknownEvidence)
        #expect(try Data(contentsOf: largeURL) == original)

        let duplicateURL = fixture.daemon.appendingPathComponent("daemon-copy.log")
        try FileManager.default.linkItem(at: largeURL, to: duplicateURL)
        let fifoURL = fixture.daemon.appendingPathComponent("legacy-pipe")
        let created = fifoURL.path.withCString { Darwin.mkfifo($0, 0o600) }
        #expect(created == 0)
        let report = DaemonLegacyInventory.inspect(root: fixture.daemon)
        #expect(report.entries.first(where: { $0.relativePath == "daemon.log" })?.status == .hardLinked)
        #expect(report.entries.first(where: { $0.relativePath == "daemon-copy.log" })?.status == .hardLinked)
        #expect(report.entries.first(where: { $0.relativePath == "legacy-pipe" })?.status == .unsupportedType)
        #expect(report.summary.hasUnknownEvidence)
        #expect(try Data(contentsOf: largeURL) == original)
    }
}
