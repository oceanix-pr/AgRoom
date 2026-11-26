import Foundation
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Runnable task templates")
@MainActor
struct TaskTemplateTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("task-template-" + UUID().uuidString).resolvingSymlinksInPath() }

    @Test("Template installation is space bound, atomic, does not execute and never overwrites an existing skill", arguments: SkillTaskTemplate.allCases)
    func installation(_ template: SkillTaskTemplate) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let work = SkillStore(directoryURL: root.appendingPathComponent("work/skills"))
        let personal = SkillStore(directoryURL: root.appendingPathComponent("personal/skills"))
        let model = SkillTaskTemplateModel(template: template, store: work, space: .work, isCurrent: { true })
        #expect(model.canInstall && !model.canRun)
        let name = try #require(await model.install())
        #expect(model.canRun && !model.canInstall && model.result == nil)
        let folder = try work.folderURL(for: name)
        #expect(try work.readFile(name: name, relativePath: "references/" + template.sampleFile) == template.sampleInput)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("scratch/report.json").path))
        #expect(work.validationRecord(name: name).wasExecuted == false)
        try work.writeFile(name: name, relativePath: "SKILL.md", content: "User edited content must survive")
        let copy = try template.install(in: work, alias: "Template copy", description: "Test")
        #expect(copy != name)
        #expect(try work.readFile(name: name, relativePath: "SKILL.md") == "User edited content must survive")
        #expect(await personal.listSnapshot().isEmpty)
        model.close(); #expect(!model.canRun)
        let foreign = SkillTaskTemplateModel(template: template, store: work, space: .personal, isCurrent: { true })
        #expect(!foreign.canInstall)
        #expect(await foreign.install() == nil)
    }

    @Test("Both bundled scripts really run in the signed sandbox and fail when their acceptance output is changed",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil), arguments: SkillTaskTemplate.allCases)
    func actualSample(_ template: SkillTaskTemplate) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(directoryURL: root.appendingPathComponent("work/skills"))
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root.appendingPathComponent("runs"))
        let model = SkillTaskTemplateModel(template: template, store: store, space: .work, isCurrent: { true }, makeExecutor: { executor })
        let name = try #require(await model.install())
        await model.run()
        #expect(model.result?.wasExecuted == true && model.sampleMatches, "\(model.result?.scripts.first?.message ?? "No execution result")")
        #expect(template.matchesSampleOutput(try store.readFile(name: name, relativePath: "scratch/report.json").replacingOccurrences(of: "\n", with: "")))
        try store.writeFile(name: name, relativePath: "references/expected.json", content: "{}")
        await model.run()
        #expect(model.result?.outcome == .failed && !model.sampleMatches)
        #expect(model.result?.scripts.first?.message.contains("did not match") == true)
    }

    @Test("Real input differs from the sample and malformed source data stays visible in the actual report",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SANDBOX_APP"] != nil))
    func actualInput() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(directoryURL: root.appendingPathComponent("work/skills")), template = SkillTaskTemplate.csvQuality
        let name = try template.install(in: store, alias: "CSV", description: "Test")
        let source = root.appendingPathComponent("input.csv"), body = "first,second\na,b\nwrong\nc,\n"
        try body.write(to: source, atomically: true, encoding: .utf8)
        let executor = try ScriptAppSandboxTests().makeExecutor(root: root)
        let result = try await executor.executeSkillScript(entryURL: store.scriptURL(name: name, relativePath: "scripts/main.py"),
            skillRoot: store.folderURL(for: name), arguments: ["--input", source.path])
        #expect(result.succeeded, "\(result.displayOutput)")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String:Any])
        #expect(report["row_count"] as? Int == 3 && report["malformed_rows"] as? [Int] == [2])
        #expect((report["missing_by_column"] as? [String:Int])?["second"] == 1)
        #expect(!template.matchesSampleOutput(result.stdout))
        #expect(try String(contentsOf: source, encoding: .utf8) == body)
    }

    @Test("Business task mini apps execute sample and custom calculations in preview without installing or accessing a space", arguments: [true, false])
    func appSamples(_ quote: Bool) async throws {
        let app = try quote ? NativeAppTemplates.quoteEstimate() : NativeAppTemplates.workHours()
        #expect(app.scripts == nil && app.capabilities == nil && app.dataSources.isEmpty)
        #expect(try NativeAppDefinition.decode(app.encoded()) == app)
        let preview = NativeAppRuntime(definition: app, space: .personal, preview: true)
        await preview.activate()
        #expect(preview.values["expression"] == .string("") && preview.values["result"] == .string(""))
        preview.perform("sample"); preview.perform("calculate")
        #expect(preview.values["result"] == .string(quote ? "396" : "13.5"))
        preview.setValue(.string("2 × 50"), key: "expression"); preview.perform("calculate")
        #expect(preview.values["result"] == .string("100") && preview.pending == nil)
        preview.setValue(.string("1/0"), key: "expression"); preview.perform("calculate")
        #expect(preview.error != nil && preview.values["result"] == .string("100"))
        preview.suspend()
    }
}
