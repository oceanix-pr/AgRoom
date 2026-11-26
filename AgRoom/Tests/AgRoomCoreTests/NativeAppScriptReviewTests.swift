import Foundation
import Testing
import CryptoKit
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Native app signed code review")
struct NativeAppScriptReviewTests {
    private static let signedApp = ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"]
    private let key = Data(repeating: 0x35, count: 32)
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("app-review-" + UUID().uuidString)
    }

    @Test("Signed approval survives service recreation; forged flags, modified code and environments do not")
    func signedReceipt() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        var definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root, space: .personal)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let reviews = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        let identity = try await reviews.identity(definition: definition, environment: "env-1")
        #expect(try await !reviews.isApproved(identity))
        try await reviews.approve(identity, definition: definition)
        let recreated = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        #expect(try await recreated.isApproved(identity))
        let changedEnvironment = try await reviews.identity(definition: definition, environment: "env-2")
        #expect(try await !reviews.isApproved(changedEnvironment))
        let wrongKey = NativeAppScriptReviewStore(workspace: workspace, signingKey: { Data(repeating: 0x36, count: 32) })
        #expect(try await !wrongKey.isApproved(identity))

        // Modify a script that was NOT the selected action: review covers the entire definition.
        let unused = definition.scripts?["analyze"]
        definition.scripts?["unused"] = unused
        definition.scripts?["unused"]?.source = "def main(inputs, context):\n    return {}\n"
        let app = try AppDirectory(url: root.appendingPathComponent(definition.id), create: false)
        try app.write(definition.encoded(), name: "app.zhiapp.json")
        let changedCode = try await reviews.identity(definition: definition, environment: "env-1")
        #expect(changedCode != identity)
        #expect(try await !reviews.isApproved(changedCode))

        // An attacker can recompute every SHA-256 and replace the identity, but cannot forge its HMAC.
        let receiptData = try app.read(NativeAppDisk.scriptReviewFile, limit: 16 * 1024)
        var forged = try #require(JSONSerialization.jsonObject(with: receiptData) as? [String: Any])
        forged["identity"] = try JSONSerialization.jsonObject(with: changedCode.encoded())
        forged["approved"] = true
        try app.write(JSONSerialization.data(withJSONObject: forged), name: NativeAppDisk.scriptReviewFile)
        #expect(try await !reviews.isApproved(changedCode))
        try await reviews.approve(changedCode, definition: definition)
        #expect(try await reviews.isApproved(changedCode))

        // Even byte-only edits require another review, without changing the semantic definition.
        var bytes = try definition.encoded(); bytes.append(0x0A)
        try app.write(bytes, name: "app.zhiapp.json")
        let byteEdit = try await reviews.identity(definition: definition, environment: "env-1")
        #expect(try await !reviews.isApproved(byteEdit))
    }

    @Test("Corrupt, symlinked and hardlinked receipts cannot approve code; unavailable signing keys fail closed")
    func receiptBoundaries() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root, space: .work)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let reviews = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        let identity = try await reviews.identity(definition: definition, environment: "env")
        try await reviews.approve(identity, definition: definition)
        let app = try AppDirectory(url: root.appendingPathComponent(definition.id), create: false)
        let valid = try app.read(NativeAppDisk.scriptReviewFile, limit: 16 * 1024)
        try app.write(Data("{\"approved\":true}".utf8), name: NativeAppDisk.scriptReviewFile)
        #expect(try await !reviews.isApproved(identity))
        try app.write(valid, name: "copied-receipt.json")
        try app.removeFile(NativeAppDisk.scriptReviewFile)
        let target = root.appendingPathComponent(definition.id).appendingPathComponent(NativeAppDisk.scriptReviewFile)
        let source = root.appendingPathComponent(definition.id).appendingPathComponent("copied-receipt.json")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        #expect(try await !reviews.isApproved(identity))
        try app.removeFile(NativeAppDisk.scriptReviewFile)
        try FileManager.default.linkItem(at: source, to: target)
        #expect(try await !reviews.isApproved(identity))
        try app.removeFile(NativeAppDisk.scriptReviewFile)
        try app.write(valid, name: NativeAppDisk.scriptReviewFile)
        let unavailable = NativeAppScriptReviewStore(workspace: workspace, signingKey: { throw NativeAppError(.unavailable) })
        await #expect(throws: NativeAppError.self) { try await unavailable.isApproved(identity) }
    }

    @Test("A review cannot bind different Python bytes hidden by Swift's Unicode string equality")
    func exactSourceRepresentation() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        var installed = try NativeAppTemplates.textStatistics()
        let source = try #require(installed.scripts?["analyze"]?.source)
        installed.scripts?["analyze"]?.source = "# caf\u{00e9}\n" + source
        var other = installed
        other.scripts?["analyze"]?.source = "# cafe\u{0301}\n" + source
        #expect(installed == other)
        #expect(try installed.encoded() != other.encoded())
        let store = NativeAppStore(directoryURL: root, space: .work)
        try await store.install(installed, replacing: nil)
        let workspace = try await store.workspace(for: installed)
        let reviews = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        await #expect(throws: NativeAppError.self) {
            try await reviews.identity(definition: other, environment: "env")
        }
    }

    @Test("Approvals cannot cross spaces, roots or installations and do not travel in backups")
    func isolationAndLifecycle() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal"), space: .personal)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let reviews = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        let identity = try await reviews.identity(definition: definition, environment: "same-env")
        try await reviews.approve(identity, definition: definition)
        let app = try AppDirectory(url: store.directoryURL.appendingPathComponent(definition.id), create: false)
        let signed = try app.read(NativeAppDisk.scriptReviewFile, limit: 16 * 1024)
        let receipt = try JSONDecoder().decode(NativeAppScriptReviewReceipt.self, from: signed)
        for space in [AppSpace.personal, .work] {
            let other = NativeAppStore(directoryURL: root.appendingPathComponent(space.rawValue + "-other"), space: space)
            try await other.install(definition, replacing: nil)
            let otherWorkspace = try await other.workspace(for: definition)
            let otherReview = NativeAppScriptReviewStore(workspace: otherWorkspace, signingKey: { key })
            let otherIdentity = try await otherReview.identity(definition: definition, environment: "same-env")
            #expect(!receipt.verifies(otherIdentity, key: key))
        }
        let backup = try await store.backup(id: definition.id, space: .personal)
        try await store.restore(backup, space: .personal, replacing: backup.fingerprint)
        let restoredWorkspace = try await store.workspace(for: definition)
        let restored = NativeAppScriptReviewStore(workspace: restoredWorkspace, signingKey: { key })
        let restoredIdentity = try await restored.identity(definition: definition, environment: "same-env")
        #expect(!receipt.verifies(restoredIdentity, key: key))
        #expect(try await !restored.isApproved(restoredIdentity))
    }

    @Test("Updates and version restores clear approval; changes during review cannot be signed")
    func reviewRaceAndUpdate() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        var definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root, space: .work)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let reviews = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        let identity = try await reviews.identity(definition: definition, environment: "env")
        try await reviews.approve(identity, definition: definition)
        let previous = definition
        let snapshot = try await store.load(id: definition.id)
        definition.manifest.version += 1
        try await store.install(definition, replacing: snapshot.revision)
        let identity2 = try await reviews.identity(definition: definition, environment: "env")
        #expect(try await !reviews.isApproved(identity2))
        await #expect(throws: NativeAppError.self) { try await reviews.approve(identity, definition: previous) }
        try await reviews.approve(identity2, definition: definition)
        let current = try await store.load(id: definition.id)
        try await store.restore(id: definition.id, replacing: current.revision)
        #expect(try await !reviews.isApproved(identity))
        try await reviews.approve(identity, definition: previous)
        let restored = try await store.load(id: definition.id)
        try await store.remove(id: definition.id, revision: restored.revision, keepData: true)
        try await store.install(previous, replacing: (try await store.loadIncludingRetained(id: definition.id)).revision)
        let reinstalled = NativeAppScriptReviewStore(workspace: try await store.workspace(for: previous), signingKey: { key })
        let freshIdentity = try await reinstalled.identity(definition: previous, environment: "env")
        #expect(try await !reinstalled.isApproved(freshIdentity))
    }

    @Test("Only a valid review response with the exact host digest may approve")
    func responseBinding() {
        #expect(NativeAppScriptModelReviewer.parse(#"{"decision":"approved","digest":"host"}"#, digest: "host") == .approved)
        #expect(NativeAppScriptModelReviewer.parse(#"{"decision":"approved","digest":"forged"}"#, digest: "host") == .invalidResponse)
        #expect(NativeAppScriptModelReviewer.parse(#"{"decision":"rejected","digest":"host"}"#, digest: "host") == .rejected)
        #expect(NativeAppScriptModelReviewer.parse("approved", digest: "host") == .invalidResponse)
    }

    private actor ReviewCalls {
        var count = 0
        func approve(_ request: NativeAppScriptReviewRequest) -> NativeAppScriptReviewDecision {
            count += 1
            return .approved
        }
    }

    @Test("Manual or failed review keeps one-shot confirmation; rejected and cancelled reviews cannot issue approval",
          .enabled(if: Self.signedApp != nil))
    func reviewOutcomes() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .work)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"))
        for unavailable in [false, true] {
            let service = NativeAppScriptService(workspace: workspace, executor: executor, reviewer: { _ in
                if unavailable { throw NativeAppError(.unavailable) }
                return .manual
            }, signingKey: { key })
            let command = try await service.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("")], records: [:], files: [:])
            #expect(!command.codeReviewed)
            guard case .needsConfirmation = try await command.engine.executeCommand(command.call) else {
                Issue.record("Unreviewed code skipped manual approval"); continue
            }
            command.engine.revokeTaskAuthorization()
            #expect(try await !service.isCodeReviewed(definition: definition))
        }
        let rejected = NativeAppScriptService(workspace: workspace, executor: executor, reviewer: { _ in .rejected }, signingKey: { key })
        await #expect(throws: NativeAppScriptError.self) {
            try await rejected.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("")], records: [:], files: [:])
        }
        let cancelled = NativeAppScriptService(workspace: workspace, executor: executor,
            reviewer: { _ in throw CancellationError() }, signingKey: { key })
        await #expect(throws: CancellationError.self) {
            try await cancelled.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("")], records: [:], files: [:])
        }
        #expect(try await !cancelled.isCodeReviewed(definition: definition))

        // A positive review arriving after a real definition update cannot authorize either version.
        let raced = NativeAppScriptService(workspace: workspace, executor: executor, reviewer: { request in
            var updated = request.definition; updated.manifest.version += 1
            let snapshot = try await store.load(id: updated.id)
            try await store.install(updated, replacing: snapshot.revision)
            return .approved
        }, signingKey: { key })
        await #expect(throws: NativeAppError.self) {
            try await raced.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("")], records: [:], files: [:])
        }
        let app = try AppDirectory(url: store.directoryURL.appendingPathComponent(definition.id), create: false)
        #expect(!app.exists(NativeAppDisk.scriptReviewFile))
    }

    @MainActor @Test("Approved functions run repeatedly with new inputs and reopen without review; tampered receipts stop prepared commands",
                     .enabled(if: Self.signedApp != nil))
    func signedExecution() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .personal)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let calls = ReviewCalls()
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"), space: .personal)
        let service = NativeAppScriptService(workspace: workspace, executor: executor,
            reviewer: { await calls.approve($0) }, signingKey: { key })
        let runtime = NativeAppRuntime(definition: definition, space: .personal, store: store, scriptService: service)
        await runtime.activate()
        for (text, lines) in [("one", 1), ("one\ntwo", 2)] {
            runtime.setValue(.string(text), key: "body")
            runtime.perform("analyze")
            let end = Date().addingTimeInterval(30)
            while runtime.isBusy && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!runtime.isBusy && runtime.pending == nil)
            #expect(runtime.error == nil, "\(runtime.error ?? "")")
            #expect(runtime.values["lines"] == .number(Double(lines)))
            #expect(runtime.codeReviewed)
        }
        #expect(await calls.count == 1)
        _ = await runtime.flush(); runtime.suspend()
        let recreated = NativeAppScriptService(workspace: workspace, executor: executor,
            reviewer: { await calls.approve($0) }, signingKey: { key })
        let command = try await recreated.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("new input")], records: [:], files: [:])
        #expect(command.codeReviewed)
        #expect(await calls.count == 1)
        let app = try AppDirectory(url: store.directoryURL.appendingPathComponent(definition.id), create: false)
        try app.write(Data("{\"approved\":true}".utf8), name: NativeAppDisk.scriptReviewFile)
        let outcome = try await command.engine.executeCommand(command.call)
        guard case .finished(_, _, let trace, _, _, _, _) = outcome else { Issue.record("Unexpected outcome"); return }
        #expect(trace.last?.succeeded == false)
        let fresh = try await recreated.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("new input")], records: [:], files: [:])
        #expect(fresh.codeReviewed)
        #expect(await calls.count == 2)
    }
    @Test("Legacy model receipts remain valid, while grant metadata is authenticated and revocations survive reopening")
    func receiptMigrationAndRevocation() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root, space: .personal)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let reviews = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        let identity = try await reviews.identity(definition: definition, environment: "env")
        struct Legacy: Encodable { let identity: NativeAppScriptReviewIdentity; let signature: Data }
        let legacy = Legacy(identity: identity, signature: Data(HMAC<SHA256>.authenticationCode(
            for: try identity.encoded(), using: SymmetricKey(data: key))))
        let app = try AppDirectory(url: root.appendingPathComponent(definition.id), create: false)
        try app.write(JSONEncoder().encode(legacy), name: NativeAppDisk.scriptReviewFile)
        #expect(try await reviews.receipt(identity)?.state == .modelApproved)
        let revision = try await reviews.revision()
        let granted = try await reviews.approve(identity, definition: definition, source: .user, expectedRevision: revision)
        #expect(granted.state == .userAuthorized)
        var forged = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(granted)) as? [String: Any])
        var metadata = try #require(forged["grant"] as? [String: Any])
        metadata["source"] = "model"; forged["grant"] = metadata
        try app.write(JSONSerialization.data(withJSONObject: forged), name: NativeAppDisk.scriptReviewFile)
        #expect(try await !reviews.isApproved(identity))
        try app.write(JSONEncoder().encode(granted), name: NativeAppDisk.scriptReviewFile)
        let oldRevision = try await reviews.revision()
        try await reviews.revoke(identity, definition: definition, expectedRevision: oldRevision)
        let reopened = NativeAppScriptReviewStore(workspace: workspace, signingKey: { key })
        #expect(try await !reopened.isApproved(identity))
        #expect(try await reopened.receipt(identity)?.grant?.source == .revoked)
        await #expect(throws: NativeAppError.self) {
            try await reviews.approve(identity, definition: definition, source: .user, expectedRevision: oldRevision)
        }
        let reauthorized = try await reopened.approve(identity, definition: definition, source: .user)
        #expect(reauthorized.signature != granted.signature)
        #expect(reauthorized.grant?.authorizationID != granted.grant?.authorizationID)
    }

    @MainActor @Test("Manual version authorization runs through confirmation and survives changed inputs, reopening and ordinary execution failures",
                     .enabled(if: Self.signedApp != nil))
    func manualVersionFlow() async throws {
        let root = directory(), key = self.key
        defer { try? FileManager.default.removeItem(at: root) }
        var definition = try NativeAppTemplates.textStatistics()
        // A failed business invocation must not discard authorization for valid future input.
        definition.scripts?["analyze"]?.source = "def main(inputs, context):\n    if inputs['text'] == 'fail':\n        raise ValueError('test')\n    return {'words': len(inputs['text'].split()), 'lines': len(inputs['text'].splitlines())}\n"
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .personal)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"), space: .personal)
        let calls = ReviewCalls()
        let service = NativeAppScriptService(workspace: workspace, executor: executor, reviewer: { request in
            _ = await calls.approve(request)
            return .manual
        }, signingKey: { key })
        let runtime = NativeAppRuntime(definition: definition, space: .personal, store: store, scriptService: service)
        await runtime.activate()
        func settle() async throws {
            let end = Date().addingTimeInterval(30)
            while runtime.isBusy && runtime.pending == nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
            #expect(runtime.pending != nil || !runtime.isBusy)
        }
        runtime.setValue(.string("one"), key: "body"); runtime.perform("analyze")
        try await settle()
        let once = try #require(runtime.pending)
        #expect(once.versionApproval != nil)
        #expect(try await !service.isCodeReviewed(definition: definition))
        runtime.decide(once, approved: true)
        try await settle()
        #expect(runtime.error == nil)
        #expect(!runtime.codeReviewed)
        runtime.setValue(.string("two"), key: "body"); runtime.perform("analyze")
        try await settle()
        #expect(await calls.count == 1) // manual result cached, not reviewed on every click
        let grant = try #require(runtime.pending)
        runtime.decide(grant, approved: true, authorizeVersion: true)
        try await settle()
        #expect(runtime.pending == nil && runtime.error == nil)
        #expect(runtime.authorizationState == .userAuthorized)
        runtime.setValue(.string("fail"), key: "body"); runtime.perform("analyze")
        try await settle()
        #expect(runtime.error != nil)
        #expect(runtime.authorizationState == .userAuthorized)
        let reopened = NativeAppScriptService(workspace: workspace, executor: executor, reviewer: { _ in
            Issue.record("Valid user grant unexpectedly invoked model review"); return .rejected
        }, signingKey: { key })
        let stale = try await reopened.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("changed")], records: [:], files: [:])
        #expect(stale.codeReviewed && stale.versionCommand == nil)
        let revoke = try await service.makeRevokeCommand(definition: definition)
        guard case .needsConfirmation = try await revoke.engine.executeCommand(revoke.call), let id = revoke.engine.pendingApprovalID else {
            Issue.record("Revocation did not require confirmation"); return
        }
        #expect(try await service.isCodeReviewed(definition: definition))
        _ = try await revoke.engine.resume(.confirmed(approvalID: id, approved: true, alwaysAllow: false, persistRule: false))
        #expect(try await !reopened.isCodeReviewed(definition: definition))
        let next = try await reopened.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("changed again")], records: [:], files: [:])
        #expect(next.reviewReason == .revoked && next.versionCommand != nil)
        let newGrant = try #require(next.versionCommand)
        _ = try await newGrant.engine.executeCommand(newGrant.call)
        let newID = try #require(newGrant.engine.pendingApprovalID)
        _ = try await newGrant.engine.resume(.confirmed(approvalID: newID, approved: true, alwaysAllow: false, persistRule: false))
        #expect(try await reopened.isCodeReviewed(definition: definition))
        let outcome = try await stale.engine.executeCommand(stale.call)
        guard case .finished(_, _, let trace, _, _, _, _) = outcome else { Issue.record("Unexpected stale call outcome"); return }
        #expect(trace.last?.succeeded == false) // reauthorization cannot revive old prepared calls
        runtime.suspend()
    }

    @Test("Saving user authorization fails before script execution; denied and cancelled version commands grant nothing",
          .enabled(if: Self.signedApp != nil))
    func manualSaveFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .work)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"))
        let service = NativeAppScriptService(workspace: workspace, executor: executor, reviewer: { _ in .manual }, signingKey: { throw NativeAppError(.unavailable) })
        let command = try await service.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("one")], records: [:], files: [:])
        let grant = try #require(command.versionCommand)
        _ = try await grant.engine.executeCommand(grant.call)
        let id = try #require(grant.engine.pendingApprovalID)
        #expect(!FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(NativeAppDisk.scriptReviewFile).path))
        let outcome = try await grant.engine.resume(.confirmed(approvalID: id, approved: true, alwaysAllow: false, persistRule: false))
        guard case .finished(_, _, let trace, _, _, _, _) = outcome else { Issue.record("Unexpected save failure outcome"); return }
        #expect(trace.last?.succeeded == false)
        do { _ = try await command.receipt.result(); Issue.record("Save failure ran script") }
        catch let error as NativeAppScriptError { #expect(error.code == .authorizationStorageUnavailable) }
        for approve in [false, true] {
            let prepared = try await service.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("one")], records: [:], files: [:])
            let candidate = try #require(prepared.versionCommand)
            _ = try await candidate.engine.executeCommand(candidate.call)
            let pending = try #require(candidate.engine.pendingApprovalID)
            if approve { candidate.engine.revokeTaskAuthorization() }
            _ = try? await candidate.engine.resume(.confirmed(approvalID: pending, approved: approve, alwaysAllow: false, persistRule: false))
            #expect(!FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(NativeAppDisk.scriptReviewFile).path))
        }
    }

}
