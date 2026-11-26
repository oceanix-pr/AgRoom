import Foundation
import Darwin
import Testing
@testable import AgRoomCore

@Suite("Daemon Store mutation and journal permissions")
struct DaemonStoreMutationLockTests {
    private func fixture() throws -> (parent: URL, store: DaemonHandoffStore) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-store-lock-qc-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return (parent, DaemonHandoffStore(baseDirectory: parent))
    }

    private func runRecord() -> DaemonRunRecord {
        let snapshot = EngineRunSnapshot(messages: [], thoughts: [], trace: [], stepsUsed: 0,
            totalTokens: 0, totalInputTokens: 0, totalOutputTokens: 0,
            callFingerprintCounts: [:], consecutiveFailedRounds: 0,
            restrictedToolNames: nil, activeSkillWorkspace: nil,
            loopNoticeInjected: false, preApprovedTools: [])
        let settings = DaemonRunSettings(maxTokens: 128, temperature: 0,
            reasoningEffortRaw: nil, maxSteps: 1, replyLanguageInstruction: "English",
            personaInstruction: nil, workspacePath: "")
        return DaemonRunRecord(space: .work, sessionId: UUID(), assistantMessageId: UUID(),
            snapshot: snapshot, settings: settings)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    @Test("A read-only journal lookup creates nothing; persisted journal uses private directory and file modes")
    func journalPersistenceIsPrivate() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let id = UUID()
        let runDirectory = fixture.store.runDirectory(id: id, origin: .space(.work))
        #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
        let binding = OperationJournal.Binding(runID: id, space: .work)
        let journal = OperationJournal(directory: runDirectory, binding: binding)
        #expect(journal.unresolvedEntries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: runDirectory.path))

        let identity = OperationJournal.CallIdentity(binding: binding, modelStep: 1,
            toolName: "files_write", argumentsJSON: "{\"synthetic\":true}")
        #expect(journal.recordIntent(operationID: "private-intent", identity: identity))
        let file = runDirectory.appendingPathComponent("operations.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try permissions(at: runDirectory) == 0o700)
        #expect(try permissions(at: file) == 0o600)
        #expect(try permissions(at: runDirectory.deletingLastPathComponent()) == 0o700)
    }

    @Test("A symbolic-link run directory cannot redirect a journal write outside its space")
    func journalRejectsSymbolicLinkDirectory() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let id = UUID()
        let runDirectory = fixture.store.runDirectory(id: id, origin: .space(.work))
        try fileManager.createDirectory(at: runDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let outside = fixture.parent.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        let original = Data("synthetic outside bytes".utf8)
        try original.write(to: sentinel)
        try fileManager.createSymbolicLink(at: runDirectory, withDestinationURL: outside)

        let binding = OperationJournal.Binding(runID: id, space: .work)
        let journal = OperationJournal(directory: runDirectory, binding: binding)
        let identity = OperationJournal.CallIdentity(binding: binding, modelStep: 1,
            toolName: "files_write", argumentsJSON: "{}")
        #expect(!journal.recordIntent(operationID: "must-not-write", identity: identity))
        #expect(!fileManager.fileExists(atPath: outside.appendingPathComponent("operations.json").path))
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test("A symbolic-link journal file is rejected before loading or replacing its external target")
    func journalRejectsSymbolicLinkFile() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let id = UUID()
        let runDirectory = fixture.store.runDirectory(id: id, origin: .space(.work))
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let outside = fixture.parent.appendingPathComponent("outside-journal.json")
        let original = Data("{\"version\":2,\"entries\":{}}".utf8)
        try original.write(to: outside)
        try fileManager.createSymbolicLink(at: runDirectory.appendingPathComponent("operations.json"),
            withDestinationURL: outside)

        let binding = OperationJournal.Binding(runID: id, space: .work)
        let journal = OperationJournal(directory: runDirectory, binding: binding)
        #expect(journal.requiresManualRecovery)
        let identity = OperationJournal.CallIdentity(binding: binding, modelStep: 1,
            toolName: "files_write", argumentsJSON: "{}")
        #expect(!journal.recordIntent(operationID: "must-not-write", identity: identity))
        #expect(try Data(contentsOf: outside) == original)
    }

    @Test("A journal cannot clear personal evidence after its work parent is replaced")
    func journalClearRejectsReplacedIntermediateDirectory() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let id = UUID()
        let workBinding = OperationJournal.Binding(runID: id, space: .work)
        let personalBinding = OperationJournal.Binding(runID: id, space: .personal)
        let workRun = fixture.store.runDirectory(id: id, origin: .space(.work))
        let personalRun = fixture.store.runDirectory(id: id, origin: .space(.personal))
        let workJournal = OperationJournal(directory: workRun, binding: workBinding)
        let personalJournal = OperationJournal(directory: personalRun, binding: personalBinding)
        let workIdentity = OperationJournal.CallIdentity(binding: workBinding, modelStep: 1,
            toolName: "files_write", argumentsJSON: "{\"space\":\"work\"}")
        let personalIdentity = OperationJournal.CallIdentity(binding: personalBinding, modelStep: 1,
            toolName: "files_write", argumentsJSON: "{\"space\":\"personal\"}")
        #expect(workJournal.recordIntent(operationID: "work-intent", identity: workIdentity))
        #expect(personalJournal.recordIntent(operationID: "personal-intent", identity: personalIdentity))
        let workFile = workRun.appendingPathComponent("operations.json")
        let personalFile = personalRun.appendingPathComponent("operations.json")
        let workBytes = try Data(contentsOf: workFile)
        let personalBytes = try Data(contentsOf: personalFile)

        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        let parked = root.appendingPathComponent("parked-work", isDirectory: true)
        let personal = root.appendingPathComponent("personal", isDirectory: true)
        try fileManager.moveItem(at: work, to: parked)
        try fileManager.createSymbolicLink(at: work, withDestinationURL: personal)

        let nextIdentity = OperationJournal.CallIdentity(binding: workBinding, modelStep: 2,
            toolName: "files_write", argumentsJSON: "{\"space\":\"work\"}")
        #expect(!workJournal.recordIntent(operationID: "late-work-intent", identity: nextIdentity))
        workJournal.clear()
        #expect(fileManager.fileExists(atPath: personalFile.path))
        #expect(try Data(contentsOf: personalFile) == personalBytes)
        let parkedWorkFile = parked
            .appendingPathComponent("run-\(id.uuidString)", isDirectory: true)
            .appendingPathComponent("operations.json")
        #expect(try Data(contentsOf: parkedWorkFile) == workBytes)
    }

    @Test("An unusable permanent Store lock fails closed before creating an owner or body")
    func invalidStoreLockRetainsEmptyIdentity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let record = runRecord()
        try FileManager.default.createDirectory(at: fixture.store.storeLockFileURL,
            withIntermediateDirectories: true)
        #expect(!fixture.store.createHandoffRecord(record))
        let work = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: work
            .appendingPathComponent("owner-\(record.id.uuidString).json").path))
        #expect(!FileManager.default.fileExists(atPath: work
            .appendingPathComponent("run-\(record.id.uuidString).json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.store.storeLockFileURL.path))
    }

    @Test("An independently opened Store lock blocks a second instance for a bounded time without a half-created handoff")
    func heldStoreLockBlocksAnotherInstance() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let second = DaemonHandoffStore(baseDirectory: fixture.parent)
        let record = runRecord()
        let descriptor = fixture.store.storeLockFileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            Issue.record("The synthetic Store lock could not be opened")
            return
        }
        var locked = false
        defer {
            if locked { _ = flock(descriptor, LOCK_UN) }
            _ = Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Issue.record("The synthetic Store lock could not be held")
            return
        }
        locked = true
        let started = Date()
        #expect(!second.createHandoffRecord(record))
        #expect(Date().timeIntervalSince(started) < 4)
        let work = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: work
            .appendingPathComponent("owner-\(record.id.uuidString).json").path))
        #expect(!FileManager.default.fileExists(atPath: work
            .appendingPathComponent("run-\(record.id.uuidString).json").path))

        _ = flock(descriptor, LOCK_UN)
        locked = false
        #expect(second.createHandoffRecord(record))
        #expect(second.records(in: .work).contains { $0.record.id == record.id })
    }

    @Test("A work directory symbolic link cannot redirect writes or scoped reads into personal evidence")
    func spaceDirectoryLinkFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let personalDirectory = fixture.store.directory.appendingPathComponent("personal", isDirectory: true)
        try fileManager.createDirectory(at: personalDirectory, withIntermediateDirectories: true)
        let sentinel = personalDirectory.appendingPathComponent("private-sentinel.txt")
        let original = Data("PERSONAL_SYNTHETIC_PRIVATE_BYTES".utf8)
        try original.write(to: sentinel)
        let personalRecord = runRecord()
        let personal = DaemonRunRecord(id: personalRecord.id, space: .personal,
            sessionId: personalRecord.sessionId, assistantMessageId: personalRecord.assistantMessageId,
            snapshot: personalRecord.snapshot, settings: personalRecord.settings)
        #expect(fixture.store.writeRecord(personal))
        let personalRun = personalDirectory.appendingPathComponent("run-\(personal.id.uuidString).json")
        let personalBytes = try Data(contentsOf: personalRun)

        let workDirectory = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        try fileManager.createSymbolicLink(at: workDirectory, withDestinationURL: personalDirectory)
        let work = runRecord()
        #expect(!fixture.store.writeRecord(work))
        #expect(!fixture.store.createHandoffRecord(work))
        #expect(fixture.store.records(in: .work).isEmpty)
        let ownership = fixture.store.ownershipSnapshot()
        #expect(ownership.hasUnattributedQuarantine || ownership.unattributedSpaces.contains(.work))
        #expect(try Data(contentsOf: sentinel) == original)
        #expect(try Data(contentsOf: personalRun) == personalBytes)
        #expect(!fileManager.fileExists(atPath: personalDirectory
            .appendingPathComponent("run-\(work.id.uuidString).json").path))
        #expect(!fileManager.fileExists(atPath: personalDirectory
            .appendingPathComponent("owner-\(work.id.uuidString).json").path))
    }

    @Test("Removing a work record cannot follow a symbolic-link work directory into personal")
    func spaceDirectoryLinkCannotDeletePersonalRecord() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let personalRecord = runRecord()
        let personal = DaemonRunRecord(id: personalRecord.id, space: .personal,
            sessionId: personalRecord.sessionId,
            assistantMessageId: personalRecord.assistantMessageId,
            snapshot: personalRecord.snapshot, settings: personalRecord.settings)
        #expect(fixture.store.writeRecord(personal))
        let personalDirectory = fixture.store.directory.appendingPathComponent("personal", isDirectory: true)
        let body = personalDirectory.appendingPathComponent("run-\(personal.id.uuidString).json")
        let owner = personalDirectory.appendingPathComponent("owner-\(personal.id.uuidString).json")
        let bodyBytes = try Data(contentsOf: body)
        let ownerBytes = try Data(contentsOf: owner)
        let workDirectory = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        try fileManager.createSymbolicLink(at: workDirectory, withDestinationURL: personalDirectory)

        #expect(!fixture.store.removeRecord(id: personal.id, origin: .space(.work)))
        #expect(try Data(contentsOf: body) == bodyBytes)
        #expect(try Data(contentsOf: owner) == ownerBytes)
        // A malformed work path can conservatively hide all actionable records;
        // the personal bytes and paths must still survive the attempted delete.
        #expect(fileManager.fileExists(atPath: body.path))
        #expect(fileManager.fileExists(atPath: owner.path))
    }

    @Test("A work quarantine symbolic link cannot list or abandon personal evidence")
    func quarantineDirectoryLinkFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let personalQuarantine = fixture.store.directory
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("quarantine", isDirectory: true)
        let workDirectory = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        try fileManager.createDirectory(at: personalQuarantine, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let personalFile = personalQuarantine.appendingPathComponent("1-run-\(id.uuidString).json")
        let original = Data("{personal-private-evidence".utf8)
        try original.write(to: personalFile)
        let linkedQuarantine = workDirectory.appendingPathComponent("quarantine", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedQuarantine, withDestinationURL: personalQuarantine)

        #expect(fixture.store.quarantinedEvidence(in: .work).isEmpty)
        #expect(fixture.store.unattributedEvidence(in: .work).isEmpty)
        let ownership = fixture.store.ownershipSnapshot()
        #expect(ownership.hasUnattributedQuarantine || ownership.unattributedSpaces.contains(.work))
        let forgedPath = linkedQuarantine.appendingPathComponent(personalFile.lastPathComponent)
        let forged = DaemonHandoffStore.QuarantinedEvidence(id: forgedPath.path,
            fileURL: forgedPath, origin: .space(.work), recordID: id,
            space: nil, sessionID: nil, assistantMessageID: nil, taskRunID: nil)
        #expect(!fixture.store.abandonUnattributedEvidence(forged, in: .work))
        #expect(try Data(contentsOf: personalFile) == original)
        #expect(!fileManager.fileExists(atPath: personalQuarantine
            .appendingPathComponent("abandoned", isDirectory: true).path))
    }

    @Test("Pinned work reads do not follow a replaced space directory into personal")
    func pinnedWorkReadIgnoresReplacedPath() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        let personal = root.appendingPathComponent("personal", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: personal, withIntermediateDirectories: true)
        let workName = "run-\(UUID().uuidString).json"
        let personalName = "run-\(UUID().uuidString).json"
        let workBytes = Data("{synthetic-work-evidence".utf8)
        let personalBytes = Data("{synthetic-personal-private-evidence".utf8)
        try workBytes.write(to: work.appendingPathComponent(workName))
        let personalFile = personal.appendingPathComponent(personalName)
        try personalBytes.write(to: personalFile)

        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let workFD = openat(rootFD, "work", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0, workFD >= 0 else {
            if workFD >= 0 { close(workFD) }
            if rootFD >= 0 { close(rootFD) }
            Issue.record("Could not pin the synthetic work directory")
            return
        }
        defer { close(workFD); close(rootFD) }
        #expect(DaemonDescriptorMutation.directoryStillMatchesEntry(
            parentFD: rootFD, named: "work", childFD: workFD))

        let parkedWork = root.appendingPathComponent("parked-work", isDirectory: true)
        try fileManager.moveItem(at: work, to: parkedWork)
        try fileManager.createSymbolicLink(at: work, withDestinationURL: personal)

        #expect(!DaemonDescriptorMutation.directoryStillMatchesEntry(
            parentFD: rootFD, named: "work", childFD: workFD))
        let pinnedNames = DaemonDescriptorMutation.names(in: workFD)
        #expect(pinnedNames?.contains(workName) == true)
        #expect(pinnedNames?.contains(personalName) == false)
        #expect(DaemonDescriptorMutation.read(in: workFD, named: workName) == workBytes)
        #expect(DaemonDescriptorMutation.read(in: workFD, named: personalName) == nil)
        #expect(fixture.store.records(in: .work).isEmpty)
        #expect(fixture.store.quarantinedEvidence(in: .work).isEmpty)
        #expect(fixture.store.unattributedEvidence(in: .work).isEmpty)
        #expect(try Data(contentsOf: personalFile) == personalBytes)
    }

    @Test("Pinned work deletion after a directory swap cannot remove personal bytes")
    func pinnedWorkDeleteCannotAffectPersonal() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        let personal = root.appendingPathComponent("personal", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: personal, withIntermediateDirectories: true)
        let id = UUID()
        let name = "run-\(id.uuidString).json"
        let workBytes = Data("synthetic old work bytes".utf8)
        let personalBytes = Data("PERSONAL_SYNTHETIC_PRIVATE_BYTES".utf8)
        try workBytes.write(to: work.appendingPathComponent(name))
        let personalFile = personal.appendingPathComponent(name)
        try personalBytes.write(to: personalFile)
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let workFD = openat(rootFD, "work", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0, workFD >= 0 else {
            if workFD >= 0 { close(workFD) }
            if rootFD >= 0 { close(rootFD) }
            Issue.record("Could not pin the synthetic deletion source")
            return
        }
        defer { close(workFD); close(rootFD) }
        let originalDigest = try #require(DaemonDescriptorMutation.digest(in: workFD, named: name))

        let parkedWork = root.appendingPathComponent("parked-work", isDirectory: true)
        try fileManager.moveItem(at: work, to: parkedWork)
        try fileManager.createSymbolicLink(at: work, withDestinationURL: personal)

        #expect(!DaemonDescriptorMutation.directoryStillMatchesEntry(
            parentFD: rootFD, named: "work", childFD: workFD))
        #expect(DaemonDescriptorMutation.unlinkRegularFile(
            in: workFD, named: name, matching: originalDigest))
        #expect(!fileManager.fileExists(atPath: parkedWork.appendingPathComponent(name).path))
        #expect(fileManager.fileExists(atPath: personalFile.path))
        #expect(try Data(contentsOf: personalFile) == personalBytes)
        #expect(!fixture.store.removeRecord(id: id, origin: .space(.work)))
        #expect(try Data(contentsOf: personalFile) == personalBytes)
    }

    @Test("Pinned quarantine move after a directory swap cannot move personal evidence")
    func pinnedQuarantineMoveCannotAffectPersonal() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        let workQuarantine = work.appendingPathComponent("quarantine", isDirectory: true)
        let workAbandoned = workQuarantine.appendingPathComponent("abandoned", isDirectory: true)
        let personalQuarantine = root
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("quarantine", isDirectory: true)
        try fileManager.createDirectory(at: workAbandoned, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: personalQuarantine, withIntermediateDirectories: true)
        let name = "1-run-\(UUID().uuidString).json"
        let workBytes = Data("{synthetic broken work record".utf8)
        let personalBytes = Data("{PERSONAL_PRIVATE_EVIDENCE".utf8)
        try workBytes.write(to: workQuarantine.appendingPathComponent(name))
        let personalFile = personalQuarantine.appendingPathComponent(name)
        try personalBytes.write(to: personalFile)
        let evidence = try #require(fixture.store.unattributedEvidence(in: .work)
            .first(where: { $0.fileURL.lastPathComponent == name }))

        let workFD = Darwin.open(work.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let quarantineFD = openat(workFD, "quarantine", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let abandonedFD = openat(quarantineFD, "abandoned", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workFD >= 0, quarantineFD >= 0, abandonedFD >= 0 else {
            if abandonedFD >= 0 { close(abandonedFD) }
            if quarantineFD >= 0 { close(quarantineFD) }
            if workFD >= 0 { close(workFD) }
            Issue.record("Could not pin the synthetic quarantine directories")
            return
        }
        defer { close(abandonedFD); close(quarantineFD); close(workFD) }
        let originalDigest = try #require(DaemonDescriptorMutation.digest(in: quarantineFD, named: name))

        let parkedQuarantine = work.appendingPathComponent("parked-quarantine", isDirectory: true)
        try fileManager.moveItem(at: workQuarantine, to: parkedQuarantine)
        try fileManager.createSymbolicLink(at: workQuarantine, withDestinationURL: personalQuarantine)

        #expect(!DaemonDescriptorMutation.directoryStillMatchesEntry(
            parentFD: workFD, named: "quarantine", childFD: quarantineFD))
        #expect(DaemonDescriptorMutation.names(in: quarantineFD)?.contains(name) == true)
        #expect(DaemonDescriptorMutation.read(in: quarantineFD, named: name) == workBytes)
        #expect(fixture.store.unattributedEvidence(in: .work).isEmpty)
        #expect(!fixture.store.abandonUnattributedEvidence(evidence, in: .work))
        #expect(fixture.store.inspectionCopy(of: evidence, in: .work) == nil)
        #expect(DaemonDescriptorMutation.moveRegularFile(from: quarantineFD, named: name,
            to: abandonedFD, named: "archived-\(name)", matching: originalDigest))
        #expect(fileManager.fileExists(atPath: parkedQuarantine
            .appendingPathComponent("abandoned", isDirectory: true)
            .appendingPathComponent("archived-\(name)").path))
        #expect(try Data(contentsOf: personalFile) == personalBytes)
        #expect(!fileManager.fileExists(atPath: personalQuarantine
            .appendingPathComponent("abandoned", isDirectory: true).path))
    }

    @Test("A redirected work path cannot update or create over an equal-ID personal run")
    func redirectedWorkWriteFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let workRecord = runRecord()
        let personal = DaemonRunRecord(id: workRecord.id, space: .personal,
            sessionId: UUID(), assistantMessageId: UUID(),
            snapshot: workRecord.snapshot, settings: workRecord.settings)
        #expect(fixture.store.writeRecord(workRecord))
        #expect(fixture.store.writeRecord(personal))
        let personalBody = fixture.store.recordFileURL(id: personal.id, origin: .space(.personal))
        let originalBody = try Data(contentsOf: personalBody)
        let personalOwner = fixture.store.directory
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("owner-\(personal.id.uuidString).json")
        let originalOwner = try Data(contentsOf: personalOwner)

        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        let parkedWork = root.appendingPathComponent("parked-work", isDirectory: true)
        let personalDirectory = root.appendingPathComponent("personal", isDirectory: true)
        let workFD = Darwin.open(work.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workFD >= 0 else {
            Issue.record("Could not pin the synthetic write directory")
            return
        }
        defer { close(workFD) }
        let createName = "extra-\(UUID().uuidString).json"
        let personalExtra = personalDirectory.appendingPathComponent(createName)
        let personalExtraBytes = Data("PERSONAL_SYNTHETIC_EXTRA".utf8)
        try personalExtraBytes.write(to: personalExtra)
        try fileManager.moveItem(at: work, to: parkedWork)
        try fileManager.createSymbolicLink(at: work, withDestinationURL: personalDirectory)

        let workExtraBytes = Data("synthetic new work evidence".utf8)
        #expect(DaemonDescriptorMutation.createOnly(workExtraBytes,
            in: workFD, named: createName))
        #expect(DaemonDescriptorMutation.replaceAtomically(
            Data("synthetic updated work evidence".utf8), in: workFD,
            named: "run-\(workRecord.id.uuidString).json"))
        #expect(try Data(contentsOf: parkedWork.appendingPathComponent(createName)) == workExtraBytes)
        #expect(try Data(contentsOf: personalExtra) == personalExtraBytes)
        #expect(!fixture.store.writeRecord(workRecord))
        #expect(fixture.store.updateState(id: workRecord.id,
            origin: .space(.work), to: .completed) == nil)
        #expect(!fixture.store.createHandoffRecord(workRecord))
        #expect(!fixture.store.removeRecord(id: workRecord.id, origin: .space(.work)))
        if case .uncertain = fixture.store.recordPresence(id: workRecord.id,
            origin: .space(.work)) {} else {
            Issue.record("A redirected work directory must retain an uncertain execution claim")
        }
        #expect(fixture.store.records(in: .work).isEmpty)
        #expect(try Data(contentsOf: personalBody) == originalBody)
        #expect(try Data(contentsOf: personalOwner) == originalOwner)
        #expect(fileManager.fileExists(atPath: parkedWork
            .appendingPathComponent("run-\(workRecord.id.uuidString).json").path))
    }

    @Test("A replaced legacy root cannot redirect inspection or deletion into personal")
    func replacedLegacyRootFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let root = fixture.store.directory
        let id = UUID()
        let name = "run-\(id.uuidString).json"
        let legacyBytes = Data("{synthetic legacy evidence".utf8)
        let personalBytes = Data("{PERSONAL_PRIVATE_EVIDENCE".utf8)
        try legacyBytes.write(to: root.appendingPathComponent(name))
        let personal = root.appendingPathComponent("personal", isDirectory: true)
        try fileManager.createDirectory(at: personal, withIntermediateDirectories: true)
        let personalFile = personal.appendingPathComponent(name)
        try personalBytes.write(to: personalFile)
        let personalHandoff = personal.appendingPathComponent("handoff-\(id.uuidString).json")
        let handoffBytes = Data("{PERSONAL_PRIVATE_HANDOFF".utf8)
        try handoffBytes.write(to: personalHandoff)
        let evidence = try #require(fixture.store.unattributedLegacyEvidence()
            .first(where: { $0.fileURL.lastPathComponent == name }))
        let parentFD = Darwin.open(fixture.parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let rootFD = openat(parentFD, "daemon", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0, rootFD >= 0 else {
            if rootFD >= 0 { close(rootFD) }
            if parentFD >= 0 { close(parentFD) }
            Issue.record("Could not pin the synthetic legacy root")
            return
        }
        defer { close(rootFD); close(parentFD) }
        let parkedRoot = fixture.parent.appendingPathComponent("parked-daemon", isDirectory: true)
        try fileManager.moveItem(at: root, to: parkedRoot)
        try fileManager.createSymbolicLink(at: root,
            withDestinationURL: parkedRoot.appendingPathComponent("personal", isDirectory: true))

        #expect(!DaemonDescriptorMutation.directoryStillMatchesEntry(
            parentFD: parentFD, named: "daemon", childFD: rootFD))
        #expect(DaemonDescriptorMutation.read(in: rootFD, named: name) == legacyBytes)
        #expect(fixture.store.unattributedLegacyEvidence().isEmpty)
        #expect(fixture.store.inspectionCopy(of: evidence, in: nil) == nil)
        #expect(!fixture.store.removeRecord(id: id, origin: .legacyRoot))
        #expect(!fixture.store.remove(id: id))
        let parkedPersonalFile = parkedRoot.appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent(name)
        let parkedPersonalHandoff = parkedRoot.appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("handoff-\(id.uuidString).json")
        #expect(fileManager.fileExists(atPath: parkedPersonalFile.path))
        #expect(try Data(contentsOf: parkedPersonalFile) == personalBytes)
        #expect(fileManager.fileExists(atPath: parkedPersonalHandoff.path))
        #expect(try Data(contentsOf: parkedPersonalHandoff) == handoffBytes)
        #expect(try Data(contentsOf: parkedRoot.appendingPathComponent(name)) == legacyBytes)
    }

    @Test("A same-name replacement invalidates a previously scanned evidence selection")
    func inspectionRejectsChangedEvidence() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let work = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        let quarantine = work.appendingPathComponent("quarantine", isDirectory: true)
        try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let name = "1-run-\(UUID().uuidString).json"
        let evidenceFile = quarantine.appendingPathComponent(name)
        try Data("{old synthetic evidence".utf8).write(to: evidenceFile)
        let evidence = try #require(fixture.store.unattributedEvidence(in: .work)
            .first(where: { $0.fileURL.lastPathComponent == name }))
        #expect(evidence.sourceDigest != nil)
        let inspectedCopy = try #require(fixture.store.inspectionCopy(of: evidence, in: .work))
        defer { try? fileManager.removeItem(at: inspectedCopy) }
        #expect(try Data(contentsOf: inspectedCopy) == Data("{old synthetic evidence".utf8))
        #expect(try permissions(at: inspectedCopy) == 0o600)
        #expect(try permissions(at: inspectedCopy.deletingLastPathComponent()) == 0o700)
        let replacement = Data("{new synthetic evidence".utf8)
        try replacement.write(to: evidenceFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evidenceFile.path)

        #expect(fixture.store.inspectionCopy(of: evidence, in: .work) == nil)
        #expect(try Data(contentsOf: evidenceFile) == replacement)
    }

    @Test("Journal inspection copies the selected run and rejects redirected work or run directories")
    func journalInspectionRejectsRedirectedSource() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let workRecord = runRecord()
        let personal = DaemonRunRecord(id: workRecord.id, space: .personal,
            sessionId: UUID(), assistantMessageId: UUID(),
            snapshot: workRecord.snapshot, settings: workRecord.settings)
        #expect(fixture.store.writeRecord(workRecord))
        #expect(fixture.store.writeRecord(personal))
        let workLocated = try #require(fixture.store.records(in: .work)
            .first(where: { $0.record.id == workRecord.id }))

        func persistJournal(for record: DaemonRunRecord) -> URL? {
            let runDirectory = fixture.store.runDirectory(id: record.id, origin: .space(record.space))
            let binding = OperationJournal.Binding(runID: record.id, space: record.space)
            let journal = OperationJournal(directory: runDirectory, binding: binding)
            let identity = OperationJournal.CallIdentity(binding: binding, modelStep: 1,
                toolName: "files_write", argumentsJSON: "{\"synthetic\":true}")
            guard journal.recordIntent(operationID: "synthetic-intent", identity: identity) else { return nil }
            return runDirectory.appendingPathComponent("operations.json")
        }
        let workJournal = try #require(persistJournal(for: workRecord))
        let personalJournal = try #require(persistJournal(for: personal))
        let workBytes = try Data(contentsOf: workJournal)
        let personalBytes = try Data(contentsOf: personalJournal)
        let inspected = try #require(fixture.store.inspectionCopy(of: workLocated, in: .work))
        defer { try? fileManager.removeItem(at: inspected) }
        #expect(try Data(contentsOf: inspected) == workBytes)
        #expect(try permissions(at: inspected) == 0o600)
        #expect(try permissions(at: inspected.deletingLastPathComponent()) == 0o700)

        // The same filename is insufficient: the journal must claim this run
        // and this space before any bytes are offered to Finder.
        try personalBytes.write(to: workJournal, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workJournal.path)
        #expect(fixture.store.inspectionCopy(of: workLocated, in: .work) == nil)
        try workBytes.write(to: workJournal, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workJournal.path)

        let workRunDirectory = workJournal.deletingLastPathComponent()
        let parkedRunDirectory = workRunDirectory.deletingLastPathComponent()
            .appendingPathComponent("parked-run-directory", isDirectory: true)
        try fileManager.moveItem(at: workRunDirectory, to: parkedRunDirectory)
        try fileManager.createSymbolicLink(at: workRunDirectory,
            withDestinationURL: personalJournal.deletingLastPathComponent())
        #expect(fixture.store.inspectionCopy(of: workLocated, in: .work) == nil)
        #expect(try Data(contentsOf: personalJournal) == personalBytes)

        try fileManager.removeItem(at: workRunDirectory)
        try fileManager.moveItem(at: parkedRunDirectory, to: workRunDirectory)
        let root = fixture.store.directory
        let work = root.appendingPathComponent("work", isDirectory: true)
        let personalDirectory = root.appendingPathComponent("personal", isDirectory: true)
        let parkedWork = root.appendingPathComponent("parked-work", isDirectory: true)
        try fileManager.moveItem(at: work, to: parkedWork)
        try fileManager.createSymbolicLink(at: work, withDestinationURL: personalDirectory)
        #expect(fixture.store.inspectionCopy(of: workLocated, in: .work) == nil)
        #expect(try Data(contentsOf: personalJournal) == personalBytes)
        #expect(try Data(contentsOf: parkedWork
            .appendingPathComponent("run-\(workRecord.id.uuidString)", isDirectory: true)
            .appendingPathComponent("operations.json")) == workBytes)
    }

    @Test("A linked work evidence file cannot disclose or abandon its personal target")
    func linkedEvidenceFileFailsClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let personalRecord = runRecord()
        let personal = DaemonRunRecord(id: personalRecord.id, space: .personal,
            sessionId: personalRecord.sessionId,
            assistantMessageId: personalRecord.assistantMessageId,
            snapshot: personalRecord.snapshot, settings: personalRecord.settings)
        #expect(fixture.store.writeRecord(personal))
        let personalFile = fixture.store.recordFileURL(id: personal.id, origin: .space(.personal))
        let original = try Data(contentsOf: personalFile)
        let work = fixture.store.directory.appendingPathComponent("work", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let linked = work.appendingPathComponent(personalFile.lastPathComponent)
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: personalFile)
        let fifo = work.appendingPathComponent("owner-\(UUID().uuidString).json")
        #expect(fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) } == 0)

        #expect(fixture.store.records(in: .work).isEmpty)
        let unknown = fixture.store.unattributedEvidence(in: .work)
        #expect(unknown.allSatisfy { $0.space == nil && $0.origin == .space(.work) })
        #expect(fixture.store.ownershipSnapshot().unattributedSpaces.contains(.work))
        if let evidence = unknown.first(where: { $0.fileURL.lastPathComponent == linked.lastPathComponent }) {
            #expect(fixture.store.inspectionCopy(of: evidence, in: .work) == nil)
            #expect(!fixture.store.abandonUnattributedEvidence(evidence, in: .work))
        }
        #expect(fileManager.fileExists(atPath: personalFile.path))
        #expect(try Data(contentsOf: personalFile) == original)
    }

    @Test("An unknown journal child retains the whole run until explicitly cleared")
    func unknownRunChildBlocksRemoval() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let record = runRecord()
        #expect(fixture.store.writeRecord(record))
        let body = fixture.store.recordFileURL(id: record.id, origin: .space(.work))
        let owner = fixture.store.directory
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("owner-\(record.id.uuidString).json")
        let bodyBytes = try Data(contentsOf: body)
        let ownerBytes = try Data(contentsOf: owner)
        let runDirectory = fixture.store.runDirectory(id: record.id, origin: .space(.work))
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let unexpected = runDirectory.appendingPathComponent("unknown-evidence.bin")
        let unexpectedBytes = Data("synthetic unknown evidence".utf8)
        try unexpectedBytes.write(to: unexpected)

        #expect(!fixture.store.removeRecord(id: record.id, origin: .space(.work)))
        #expect(try Data(contentsOf: body) == bodyBytes)
        #expect(try Data(contentsOf: owner) == ownerBytes)
        #expect(try Data(contentsOf: unexpected) == unexpectedBytes)

        try fileManager.removeItem(at: unexpected)
        #expect(fixture.store.removeRecord(id: record.id, origin: .space(.work)))
        #expect(!fileManager.fileExists(atPath: body.path))
        #expect(!fileManager.fileExists(atPath: owner.path))
    }

    @Test("Legitimate space and legacy sources can still be deleted or explicitly abandoned")
    func legitimateSourceOperationsRemainAvailable() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let fileManager = FileManager.default
        let workRecord = runRecord()
        #expect(fixture.store.writeRecord(workRecord))
        #expect(fixture.store.removeRecord(id: workRecord.id, origin: .space(.work)))
        #expect(!fileManager.fileExists(atPath: fixture.store
            .recordFileURL(id: workRecord.id, origin: .space(.work)).path))

        let workQuarantine = fixture.store.quarantineDirectory(for: .space(.work))
        try fileManager.createDirectory(at: workQuarantine, withIntermediateDirectories: true)
        let workName = "1-run-\(UUID().uuidString).json"
        let workFile = workQuarantine.appendingPathComponent(workName)
        let workBytes = Data("{synthetic malformed work".utf8)
        try workBytes.write(to: workFile)
        let workEvidence = try #require(fixture.store.unattributedEvidence(in: .work)
            .first(where: { $0.fileURL.lastPathComponent == workName }))
        #expect(fixture.store.abandonUnattributedEvidence(workEvidence, in: .work))
        let workAbandoned = workQuarantine.appendingPathComponent("abandoned", isDirectory: true)
        let workSealed = try fileManager.contentsOfDirectory(at: workAbandoned,
            includingPropertiesForKeys: nil)
        #expect(workSealed.contains { $0.lastPathComponent.hasSuffix("-\(workName)") &&
            (try? Data(contentsOf: $0)) == workBytes })

        let legacyName = "run-\(UUID().uuidString).json"
        let legacyFile = fixture.store.directory.appendingPathComponent(legacyName)
        let legacyBytes = Data("{synthetic malformed legacy".utf8)
        try legacyBytes.write(to: legacyFile)
        let legacyEvidence = try #require(fixture.store.unattributedLegacyEvidence()
            .first(where: { $0.fileURL.lastPathComponent == legacyName }))
        #expect(fixture.store.abandonUnattributedEvidence(legacyEvidence))
        let legacyAbandoned = fixture.store.quarantineDirectory.appendingPathComponent("abandoned", isDirectory: true)
        let legacySealed = try fileManager.contentsOfDirectory(at: legacyAbandoned,
            includingPropertiesForKeys: nil)
        #expect(legacySealed.contains { $0.lastPathComponent.hasSuffix("-\(legacyName)") &&
            (try? Data(contentsOf: $0)) == legacyBytes })
    }
}
