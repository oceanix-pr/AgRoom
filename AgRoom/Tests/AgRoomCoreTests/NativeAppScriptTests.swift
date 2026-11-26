import Foundation
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Native app Python functions")
struct NativeAppScriptTests {
    private static let signedApp = ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"]
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-python-" + UUID().uuidString)
    }

    @Test("DSL v1 stays compatible and v2 validates code, input, output and capability references")
    func schema() throws {
        let original = try NativeAppTemplates.note()
        #expect(try NativeAppDefinition.decode(original.encoded()) == original)
        let app = try NativeAppTemplates.textStatistics()
        #expect(try NativeAppDefinition.decode(app.encoded()) == app)
        var invalid = app
        invalid.manifest.dslVersion = 1
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.scripts?["analyze"]?.timeoutSeconds = 121
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["analyze"]?.resultBindings = ["body": "lines"]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["analyze"]?.inputs = [:]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.scripts?["analyze"]?.requirements = ["--index-url=https://example.com"]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        invalid = app; invalid.actions["analyze"]?.recordInputs = ["rows": .init(source: "absent", limit: 20)]
        #expect(throws: NativeAppError.self) { try invalid.validate() }
        var object = try #require(JSONSerialization.jsonObject(with: app.encoded()) as? [String: Any])
        var scripts = try #require(object["scripts"] as? [String: [String: Any]])
        scripts["analyze"]?["network"] = true
        object["scripts"] = scripts
        #expect(throws: NativeAppError.self) { try NativeAppDefinition.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test("Record snapshots read beyond UI pagination, refuse truncation, and isolate app files")
    func snapshots() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("personal/apps"), space: .personal)
        let definition = try NativeAppTemplates.note()
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        for index in 0..<60 {
            try await workspace.saveRecord(id: UUID(), collection: "notes", title: "Row \(index)", content: "private", replacing: nil)
        }
        let all = try await workspace.scriptInputs(values: ["text": .string("引号 '\"\n$(not-a-command)")],
            records: ["rows": .init(collection: "notes", search: "", limit: 60)], files: [:])
        let payload = try JSONDecoder().decode(NativeAppScriptInputs.Payload.self, from: all.payload)
        #expect(payload.records["rows"]?.count == 60)
        #expect(payload.inputs["text"] == .string("引号 '\"\n$(not-a-command)"))
        do {
            _ = try await workspace.scriptInputs(values: [:], records: ["rows": .init(collection: "notes", search: "", limit: 59)], files: [:])
            Issue.record("An incomplete query was accepted")
        } catch let error as NativeAppScriptError { #expect(error.code == .queryTooLarge) }
        var other = definition; other.manifest.id = "other-app"
        try await store.install(other, replacing: nil)
        let otherWorkspace = try await store.workspace(for: other)
        let id = UUID()
        try await otherWorkspace.saveFile(id: id, name: "private.csv", data: Data("secret".utf8))
        await #expect(throws: NativeAppError.self) {
            _ = try await workspace.scriptInputs(values: [:], records: [:], files: ["csv": id])
        }
        let ownID = UUID()
        try await workspace.saveFile(id: ownID, name: "data.csv", data: Data("frozen".utf8))
        let frozen = try await workspace.scriptInputs(values: [:], records: [:], files: ["csv": ownID])
        let file = try #require(try await workspace.files().first)
        try await workspace.deleteFile(file)
        #expect(frozen.files["csv"] == Data("frozen".utf8))
        let work = NativeAppStore(directoryURL: root.appendingPathComponent("work/apps"), space: .work)
        try await work.install(definition, replacing: nil)
        let workWorkspace = try await work.workspace(for: definition)
        let isolated = try await workWorkspace.scriptInputs(values: [:], records: ["rows": .init(collection: "notes", search: "", limit: 60)], files: [:])
        #expect(try JSONDecoder().decode(NativeAppScriptInputs.Payload.self, from: isolated.payload).records["rows"]?.isEmpty == true)
    }

    @Test("Typed results ignore diagnostic stdout and reject mismatched values and linked artifacts")
    func resultProtocol() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try AppDirectory(url: root, create: true)
        let artifacts = try directory.child("artifacts", create: true)
        try directory.write(Data(#"{"lines":2,"words":4}"#.utf8), name: "result.json")
        try artifacts.write(Data("output".utf8), name: "report.txt")
        let execution = PythonExecutionResult(outcome: .exited(0), stdout: String(repeating: "log", count: 4000), stderr: "", duration: 0, outputDirectory: root)
        let script = try #require(NativeAppTemplates.textStatistics().scripts?["analyze"])
        let result = try NativeAppScriptService.collect(execution, script: script)
        #expect(result.values["lines"] == .number(2))
        #expect(result.artifacts.first?.data == Data("output".utf8))
        try directory.write(Data(#"{"lines":true,"words":4}"#.utf8), name: "result.json")
        #expect(throws: NativeAppScriptError.self) { try NativeAppScriptService.collect(execution, script: script) }
        try directory.write(Data(#"{"lines":2,"words":4,"unexpected":1}"#.utf8), name: "result.json")
        #expect(throws: NativeAppScriptError.self) { try NativeAppScriptService.collect(execution, script: script) }
        try directory.write(Data(#"{"lines":2,"words":4}"#.utf8), name: "result.json")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("artifacts/alias"), withDestinationURL: root.appendingPathComponent("result.json"))
        #expect(throws: NativeAppScriptError.self) { try NativeAppScriptService.collect(execution, script: script) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("artifacts/alias"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("result.json"), to: root.appendingPathComponent("artifacts/hardlink"))
        #expect(throws: NativeAppScriptError.self) { try NativeAppScriptService.collect(execution, script: script) }
    }

    @MainActor @Test("Script previews cannot run code or access real files")
    func preview() async throws {
        let runtime = NativeAppRuntime(definition: try NativeAppTemplates.textStatistics(), space: .personal, preview: true)
        await runtime.activate()
        runtime.perform("analyze")
        #expect(!runtime.isBusy && runtime.pending == nil && runtime.availableFiles.isEmpty)
        #expect(runtime.values["lines"] == .number(0))
        runtime.suspend()
    }

    @Test("Run directory creation refuses symlink ancestors without creating files outside its root")
    func runDirectoryBoundary() throws {
        let root = directory(), outside = directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("redirected")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: NativeAppError.self) { try PythonExecutor(workspaceRoot: link).workspaceDir() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @MainActor @Test("Signed application functions support approval, JSON results and separately approved artifact saving",
                     .enabled(if: Self.signedApp != nil))
    func signedWindowFlow() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .personal)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"), space: .personal)
        let service = NativeAppScriptService(workspace: workspace, executor: executor)
        let runtime = NativeAppRuntime(definition: definition, space: .personal, store: store, scriptService: service)
        await runtime.activate()
        runtime.setValue(.string("hello world\n第三行"), key: "body")
        runtime.perform("analyze")
        try await until { runtime.pending != nil || !runtime.isBusy }
        let rejected = try #require(runtime.pending)
        #expect(runtime.values["lines"] == .number(0))
        runtime.decide(rejected, approved: false)
        try await until { !runtime.isBusy }
        #expect(runtime.values["lines"] == .number(0))
        runtime.perform("analyze")
        try await until { runtime.pending != nil || !runtime.isBusy }
        runtime.decide(try #require(runtime.pending), approved: true)
        try await until { !runtime.isBusy }
        #expect(runtime.error == nil, "\(runtime.error ?? "")")
        #expect(runtime.values["lines"] == .number(2))
        #expect(runtime.values["words"] == .number(3))
        #expect(try await workspace.files().isEmpty)
        runtime.saveArtifact(try #require(runtime.scriptArtifacts.first))
        try await until { runtime.pending != nil || !runtime.isBusy }
        #expect(try await workspace.files().isEmpty)
        runtime.decide(try #require(runtime.pending), approved: true)
        try await until { !runtime.isBusy }
        #expect(try await workspace.files().first?.name == "statistics.json")
        #expect(runtime.scriptArtifacts.isEmpty)
        _ = await runtime.flush(); runtime.suspend()
    }

    @Test("Signed functions receive frozen attachments and cannot access the live application directory",
          .enabled(if: Self.signedApp != nil))
    func signedFilesAndRevocation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var definition = try NativeAppTemplates.textStatistics()
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .work)
        definition.actions["analyze"]?.fileInputs = ["csv": .init(literal: .string("unused"))]
        definition.scripts?["analyze"]?.source = """
        from pathlib import Path
        def main(inputs, context):
            assert Path(context['files']['csv']['path']).read_text() == 'a,b\\n1,2'
            try:
                Path(\(String(reflecting: root.appendingPathComponent("apps/text-statistics/data.sqlite").path))).read_bytes()
                raise RuntimeError('live application directory escaped')
            except PermissionError:
                pass
            print('diagnostic' * 2000)
            return {'lines': 2, 'words': 4}
        """
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let id = UUID()
        try await workspace.saveFile(id: id, name: "data.csv", data: Data("a,b\n1,2".utf8))
        let service = NativeAppScriptService(workspace: workspace, executor: try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs")))
        let command = try await service.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("quotes '\"\n中文")], records: [:], files: ["csv": id])
        guard case .needsConfirmation = try await command.engine.executeCommand(command.call) else { Issue.record("Skipped approval"); return }
        let approval = try #require(command.engine.pendingApprovalID)
        _ = try await command.engine.resume(.confirmed(approvalID: approval, approved: true, alwaysAllow: false, persistRule: false))
        #expect(try await command.receipt.result().values["words"] == .number(4))
        let revoked = try await service.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("")], records: [:], files: ["csv": id])
        _ = try await revoked.engine.executeCommand(revoked.call)
        let oldApproval = try #require(revoked.engine.pendingApprovalID)
        let current = try await store.load(id: definition.id)
        definition.manifest.version += 1
        try await store.install(definition, replacing: current.revision)
        let outcome = try await revoked.engine.resume(.confirmed(approvalID: oldApproval, approved: true, alwaysAllow: false, persistRule: false))
        guard case .finished(_, _, let trace, _, _, _, _) = outcome else { Issue.record("Unexpected outcome"); return }
        #expect(trace.last?.succeeded == false)
    }

    @Test("Signed functions fail without running when dependencies are missing and reject failed or oversized outputs",
          .enabled(if: Self.signedApp != nil))
    func signedFailureSemantics() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for scenario in ["dependencies", "timeout", "result"] {
            var definition = try NativeAppTemplates.textStatistics()
            definition.manifest.id = "failure-" + scenario
            let body = "from pathlib import Path\ndef main(inputs, context):\n    Path(context['outputDirectory'], 'partial.txt').write_text('partial')\n"
            if scenario == "dependencies" {
                definition.scripts?["analyze"]?.requirements = ["agroom-uninstalled-regression-package==1"]
                definition.scripts?["analyze"]?.source = body + "    raise RuntimeError('must not execute')\n"
            } else if scenario == "timeout" {
                definition.scripts?["analyze"]?.timeoutSeconds = 1
                definition.scripts?["analyze"]?.source = body + "    import time\n    time.sleep(5)\n    return {'lines': 7, 'words': 8}\n"
            } else {
                definition.scripts?["analyze"]?.source = body + "    return {'lines': 'wrong type', 'words': 4}\n"
            }
            let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .work)
            try await store.install(definition, replacing: nil)
            let workspace = try await store.workspace(for: definition)
            let service = NativeAppScriptService(workspace: workspace, executor: try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs-" + scenario)))
            let command = try await service.prepare(definition: definition, actionID: "analyze", inputs: ["text": .string("")], records: [:], files: [:])
            _ = try await command.engine.executeCommand(command.call)
            let approval = try #require(command.engine.pendingApprovalID)
            let outcome = try await command.engine.resume(.confirmed(approvalID: approval, approved: true, alwaysAllow: false, persistRule: false))
            guard case .finished(_, _, let trace, _, _, _, _) = outcome else { Issue.record("Unexpected outcome"); return }
            #expect(trace.last?.succeeded == false)
            do {
                _ = try await command.receipt.result()
                Issue.record("A failed function returned a successful result")
            } catch let error as NativeAppScriptError {
                #expect(error.code == (scenario == "dependencies" ? .missingDependencies : scenario == "timeout" ? .executionFailed : .invalidResult))
            }
            #expect(try await workspace.files().isEmpty)
        }
    }

    @MainActor @Test("Stopping and switching spaces discard pending approvals and late Python results",
                     .enabled(if: Self.signedApp != nil))
    func signedCancellation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var definition = try NativeAppTemplates.textStatistics()
        definition.scripts?["analyze"]?.source = "import time\ndef main(inputs, context):\n    time.sleep(3)\n    return {'lines': 42, 'words': 42}\n"
        let store = NativeAppStore(directoryURL: root.appendingPathComponent("apps"), space: .work)
        try await store.install(definition, replacing: nil)
        let workspace = try await store.workspace(for: definition)
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"))
        let runtime = NativeAppRuntime(definition: definition, space: .work, store: store,
            scriptService: NativeAppScriptService(workspace: workspace, executor: executor))
        await runtime.activate()
        runtime.perform("analyze")
        try await until { runtime.pending != nil || !runtime.isBusy }
        runtime.decide(try #require(runtime.pending), approved: true)
        try await Task.sleep(for: .milliseconds(200))
        runtime.stopOperation()
        #expect(!runtime.isBusy && runtime.pending == nil)
        runtime.perform("analyze")
        try await until { runtime.pending != nil || !runtime.isBusy }
        let stale = try #require(runtime.pending)
        runtime.suspend()
        runtime.decide(stale, approved: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!runtime.isActive && !runtime.isBusy && runtime.pending == nil)
        #expect(runtime.values["lines"] == .number(0))
        #expect(runtime.scriptArtifacts.isEmpty)
    }

    @MainActor private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NativeAppScriptError(.executionFailed, details: "Timed out waiting for the test runtime")
    }
}
