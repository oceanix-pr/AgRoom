import Foundation
import Testing
@testable import AgRoomCore

@Suite("Coding diagnostic evidence")
struct CodingDiagnosticTests {
    @Test("Warnings cannot bury later errors and duplicates retain locations and counts")
    func prioritizeAndGroup() {
        let warnings = (0..<100).map { "File.swift:\($0 + 1):1: warning: warning \($0)" }.joined(separator: "\n")
        let output = warnings + "\nA.swift:10:2: error: cannot find 'Value' in scope\n"
            + "B.swift:20:3: error: cannot find 'Value' in scope\n"
            + "A.swift:10:2: error: cannot find 'Value' in scope\nC.swift:2: note: candidate is here"
        let diagnostics = CodingBuildDiagnostics.parse(output)
        #expect(diagnostics.first?.severity == "error")
        #expect(diagnostics.first?.occurrences == 3)
        #expect(diagnostics.first?.relatedLocations?.first?.path == "B.swift")
        #expect(diagnostics.count <= 40)
    }

    @Test("Elapsed test time is not a new failure but numeric compiler details remain distinct")
    func stableSignatures() throws {
        let tests = CodingBuildDiagnostics.parse("Test Parser failed after 0.1 seconds\nTest Parser failed after 5 seconds")
        #expect(tests.count == 1 && tests.first?.occurrences == 2)
        let compiler = CodingBuildDiagnostics.parse("A.swift:1: error: expected timeout 10 seconds\nA.swift:2: error: expected timeout 20 seconds")
        #expect(compiler.count == 2)
        let old = Data(#"{"severity":"error","message":"old"}"#.utf8)
        let restored = try JSONDecoder().decode(CodingDiagnostic.self, from: old)
        #expect(restored.occurrences == nil && restored.relatedLocations == nil)
    }

    @Test("Historical failures survive repair and reload without overriding the latest real check")
    func failureHistory() async throws {
        let fixture = try CodingWorkflowTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try fixture.file("Value.swift", "let value = 1")
        let runtime = fixture.runtime()
        try await runtime.begin(request: "Repair and test")
        let revision = try fixture.reader.revision()
        let diagnostic = CodingDiagnostic(path: "Value.swift", line: 1, column: 1, severity: "error", message: "broken")
        func receipt(_ succeeded: Bool, unknownInputs: Bool = false, changedOutput: Bool = false) -> CodingVerification {
            .init(runID: runtime.runID, action: "swift_test", directory: fixture.reader.root.path,
                exitCode: succeeded ? 0 : 1, succeeded: succeeded,
                inputRevision: unknownInputs ? nil : revision, outputRevision: unknownInputs ? nil : (changedOutput ? "changed" : revision),
                logPath: "fixture.log", diagnostics: succeeded ? [] : [diagnostic])
        }
        for _ in 0..<3 { try await runtime.recordVerification(receipt(false)) }
        let history = try #require(try await runtime.state()?.failedAttempts)
        #expect(CodingTaskRuntime.failureProgress(history).joined().contains("repeated_identical_failures=3"))
        #expect(CodingTaskRuntime.failureProgress([receipt(false, unknownInputs: true), receipt(false, unknownInputs: true)]).joined().contains("unchanged_inputs=false"))
        #expect(CodingTaskRuntime.failureProgress([receipt(false, changedOutput: true), receipt(false)]).joined().contains("unchanged_inputs=false"))
        try await runtime.recordVerification(receipt(true))
        #expect(try await runtime.assessment().code == .codeChecksPassed)
        let reloaded = fixture.runtime(session: runtime.sessionID, run: runtime.runID)
        try await reloaded.begin(request: nil)
        #expect(try await reloaded.state()?.failedAttempts?.count == 3)
        #expect(try await reloaded.prompt().contains("failure is historical") == true)
        try Data("let value = 2".utf8).write(to: fixture.reader.root.appendingPathComponent("Value.swift"))
        #expect(try await reloaded.assessment().code == .codeRevisionChanged)
    }
}
