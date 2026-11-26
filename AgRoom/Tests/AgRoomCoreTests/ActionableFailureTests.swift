import Foundation
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@MainActor
@Suite("Actionable user errors")
struct ActionableFailureTests {
    @Test("file, database, network, and team failures are localized without private diagnostics")
    func safeLocalizedFailures() {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        let privatePath = "/PRIVATE-CLIENT-PATH-41"
        let missing = FileAreaService.AreaError.notFound(privatePath)
        let busy = NSError(domain: "GRDB.DatabaseError", code: 261,
            userInfo: [NSLocalizedDescriptionKey: "SECRET SQL at \(privatePath)"])
        let unknown = NSError(domain: "PrivateProvider", code: 73,
            userInfo: [NSLocalizedDescriptionKey: "SECRET SERVER at \(privatePath)"])
        let provider = LLMError.networkError(statusCode: 401, message: "SECRET RESPONSE at \(privatePath)")
        let partial = TeamWriteBatchRevertError.partial(.init(outcomes: [
            .init(recordID: UUID(), path: privatePath, error: "SECRET FILE CONTENT")
        ]))

        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            #expect(L.actionableError(missing, fallbackKey: "error.actionable.files") == L.string("error.actionable.missing"))
            #expect(L.actionableError(busy, fallbackKey: "error.actionable.team") == L.string("error.actionable.database_busy"))
            #expect(L.actionableError(MaintenanceError.busy, fallbackKey: "error.database") == L.string("error.actionable.database_busy"))
            #expect(L.actionableError(MaintenanceError.unavailable, fallbackKey: "error.actionable.team") == L.string("error.database"))
            #expect(L.actionableError(URLError(.timedOut), fallbackKey: "error.actionable.team") == L.string("error.actionable.network"))
            #expect(L.actionableError(unknown, fallbackKey: "error.actionable.agents_load") == L.string("error.actionable.agents_load"))
            #expect(L.actionableError(provider, fallbackKey: "error.actionable.provider_connection")
                == L.string("error.actionable.provider_key"))
            #expect(L.actionableError(KnowledgeOrganizationError.folderMissing,
                fallbackKey: "knowledge.error.operation") == L.string("knowledge.error.folderMissing"))
            #expect(L.actionableError(OCRService.OCRError.noTextFound,
                fallbackKey: "error.actionable.ocr_recognize") == L.string("error.actionable.ocr_no_text"))
            #expect(L.actionableError(TranscriptionService.TranscriptionError.notAuthorized,
                fallbackKey: "error.actionable.audio_transcribe") == L.string("error.actionable.speech_permission"))
            #expect(L.actionableError(TeamWriteRevertError.changedSinceWrite, fallbackKey: "error.actionable.team")
                == L.string("team.writes.error.changed"))
            let partialMessage = L.actionableError(partial, fallbackKey: "error.actionable.team")
            #expect(partialMessage.contains("1"))
            for message in [L.actionableError(missing, fallbackKey: "error.actionable.files"),
                            L.actionableError(busy, fallbackKey: "error.actionable.team"),
                            L.actionableError(unknown, fallbackKey: "error.actionable.agents_load"),
                            L.actionableError(provider, fallbackKey: "error.actionable.provider_connection"),
                            partialMessage] {
                #expect(!message.contains(privatePath))
                #expect(!message.contains("SECRET"))
            }
        }
    }

    @Test("a failed folder read is visible and retrying returns to an available folder")
    func folderReadFailureIsNotAnEmptyFolder() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agroom-file-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FilesViewModel(service: FileAreaService(baseDirectory: root), workspaceRoots: { [] })
        model.navigate(to: root.appendingPathComponent("files/missing", isDirectory: true))
        #expect(model.entries.isEmpty)
        #expect(model.loadError == L.string("error.actionable.missing"))
        model.refresh()
        #expect(model.selectedFolder == model.service.filesRoot)
        #expect(model.loadError == nil)
    }

    @Test("script permission failures keep private diagnostics out of every language")
    func safeScriptPermissionFailures() {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        let privatePath = "/PRIVATE-CLIENT-RULE-PATH-41"
        let privateDetail = "SECRET RULE DATA at \(privatePath)"
        let ruleErrors: [(ShellApprovalRuleStore.StoreError, String)] = [
            (.corrupt(privateDetail), "permissions.error.ruleCorrupt"),
            (.unavailable(privateDetail), "permissions.error.ruleUnavailable"),
            (.writeFailed, "permissions.error.ruleWriteFailed")
        ]
        let recoveryErrors: [(Error, String)] = [
            (TaskFileRecoveryError.changedSinceWrite, "permissions.recovery.reason.changed"),
            (TaskFileRecoveryError.missingFile, "permissions.recovery.reason.missing"),
            (TaskFileRecoveryError.noPreviousVersion, "permissions.recovery.reason.newFile"),
            (TaskFileRecoveryError.wrongSpace, "permissions.recovery.reason.unsafe"),
            (TaskFileRecoveryError.symlink, "permissions.recovery.reason.unsafe"),
            (NSError(domain: "PrivateRecovery", code: 42,
                     userInfo: [NSLocalizedDescriptionKey: privateDetail]),
             "permissions.recovery.reason.unavailable")
        ]

        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            for (error, reasonKey) in ruleErrors {
                for actionKey in ["permissions.error.revokeFailed", "permissions.error.clearFailed"] {
                    let message = ScriptPermissionsViewModel.ruleMutationFailureMessage(error, actionKey: actionKey)
                    #expect(message == L.format(actionKey, L.string(reasonKey)))
                    #expect(!message.contains(privatePath))
                    #expect(!message.contains("SECRET"))
                }
                #expect(L.string(reasonKey) != reasonKey)
            }
            for (error, reasonKey) in recoveryErrors {
                let message = ScriptPermissionsViewModel.restoreFailureMessage(error)
                #expect(message == L.format("permissions.recovery.failed", L.string(reasonKey)))
                #expect(!message.contains(privatePath))
                #expect(!message.contains("SECRET"))
                #expect(L.string(reasonKey) != reasonKey)
            }
            let message = ScriptPermissionsViewModel.restoreFailureMessage(
                TaskFileRecoveryError.changedSinceWrite
            )
            switch language {
            case .english: #expect(message.contains("Could not complete"))
            case .simplifiedChinese: #expect(message.contains("无法完成"))
            case .traditionalChinese: #expect(message.contains("無法完成"))
            case .system: break
            }
        }
    }

    @Test("a corrupt approval rule file remains intact after a failed clear and can be reloaded")
    func corruptRuleFileIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agroom-rule-failure-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("PRIVATE-RULE-PATH.json")
        let corruptData = Data("{ private contents".utf8)
        try corruptData.write(to: file)
        var recoveryStoreLookups = 0
        let model = ScriptPermissionsViewModel(
            space: .personal,
            store: ShellApprovalRuleStore(fileURL: file),
            auditLog: nil,
            recoveryStore: nil,
            recoveryStoreProvider: {
                recoveryStoreLookups += 1
                return nil
            },
            fileAreaService: FileAreaService(baseDirectory: root)
        )

        await model.load()
        if case .corrupt = model.rulesState {
            // The UI state intentionally has no associated raw file error.
        } else {
            Issue.record("The damaged rule file must not look like an empty rule list")
        }
        await model.clearAll()
        #expect(try Data(contentsOf: file) == corruptData)
        #expect(model.errorMessage?.contains(file.path) == false)
        #expect(model.errorMessage?.contains("private contents") == false)

        try Data("[]".utf8).write(to: file)
        await model.load()
        if case .loaded(let rules) = model.rulesState {
            #expect(rules.isEmpty)
        } else {
            Issue.record("Reload should show the repaired rule file")
        }
        #expect(recoveryStoreLookups == 2)
    }
}

@MainActor
@Suite("Quit and skill import failure paths")
struct ExitAndImportRegressionTests {
    @Test func failedMailDraftPreventsQuitAndCanBeRetried() async {
        var drafts = ["first", "latest unsaved text", "last"]
        var stored: [Int: String] = [:]
        var attempts: [Int] = []
        var failOne = true
        var notesPrepared = 0
        @MainActor func attemptQuit() async -> Bool {
            await AppQuitSequence.shouldQuit(markdown: { true }, mail: {
                let failures = await MailComposeWindowCoordinator.failedDrafts(in: Array(drafts.indices)) { id in
                    attempts.append(id)
                    if failOne && id == 1 { return false }
                    stored[id] = drafts[id]
                    return true
                }
                return failures.isEmpty
            }, nativeApps: { true }, prepareNotes: { notesPrepared += 1; return true },
            handoff: { true }, resumeNotes: {}, resumeApps: {})
        }
        let first = await attemptQuit()
        #expect(!first && notesPrepared == 0)
        #expect(attempts == [0, 1, 2])
        #expect(stored == [0: "first", 2: "last"])
        failOne = false
        drafts[1] += " after retry"
        let retry = await attemptQuit()
        #expect(retry && notesPrepared == 1)
        #expect(stored[1] == "latest unsaved text after retry")
    }

    @Test func cancellationNeverPausesNotesDuringDraftChecks() async {
        let cases: [(String, [String])] = [
            ("markdown", ["markdown"]),
            ("native", ["markdown", "mail", "native", "resumeApps"]),
            ("notes", ["markdown", "mail", "native", "notes", "resumeNotes", "resumeApps"]),
            ("handoff", ["markdown", "mail", "native", "notes", "handoff", "resumeNotes", "resumeApps"]),
            ("none", ["markdown", "mail", "native", "notes", "handoff"])
        ]
        for (blocked, expected) in cases {
            var calls: [String] = []
            @MainActor func stage(_ name: String) -> Bool { calls.append(name); return name != blocked }
            let quit = await AppQuitSequence.shouldQuit(
                markdown: { stage("markdown") }, mail: { stage("mail") }, nativeApps: { stage("native") },
                prepareNotes: { stage("notes") }, handoff: { stage("handoff") },
                resumeNotes: { calls.append("resumeNotes") }, resumeApps: { calls.append("resumeApps") })
            #expect(quit == (blocked == "none"))
            #expect(calls == expected)
        }
    }

    @Test func importPreflightCleansOnlyItsOwnCopy() throws {
        enum PreflightError: Error { case invalidArchive }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("original.zip")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let pending = try StagedSkillImport(from: source, in: root) { try Data(contentsOf: $0) }
        #expect(pending.preview == bytes)
        let baseline = Set(try fm.contentsOfDirectory(atPath: root.path))
        for _ in 0..<3 {
            do {
                _ = try StagedSkillImport<Void>(from: source, in: root) { copy in
                    #expect(copy != source)
                    #expect(try Data(contentsOf: copy) == bytes)
                    throw PreflightError.invalidArchive
                }
                Issue.record("Preflight failure was swallowed")
            } catch PreflightError.invalidArchive {}
            #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == baseline)
        }
        do {
            _ = try StagedSkillImport<Void>(from: root.appendingPathComponent("missing.zip"), in: root) { _ in
                Issue.record("Preflight must not run after a failed copy")
            }
            Issue.record("Copy failure was swallowed")
        } catch { /* Missing source. The directory allocated for this attempt must be gone. */ }
        #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == baseline)
        #expect(try Data(contentsOf: pending.zipURL) == bytes)
        pending.discard()
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["original.zip"])
        #expect(try Data(contentsOf: source) == bytes)
    }
}
