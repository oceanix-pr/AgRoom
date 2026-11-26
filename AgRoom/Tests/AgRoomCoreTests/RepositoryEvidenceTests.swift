import Foundation
import Testing
@testable import AgRoomCore

@Suite("Repository evidence and batched search")
struct RepositoryEvidenceTests {
    private func read(_ id: String, lines: ClosedRange<Int>, digest: String = String(repeating: "a", count: 64), partial: Bool = false) throws -> [EngineMessage] {
        let page = FilesReadRangeTool.Page(path: "/fixture/Value.swift", sha256: digest, total_lines: 40,
            lines: lines.map { .init(number: $0, text: "line \($0): " + String(repeating: "value ", count: 80), line_truncated: partial) }, next_line: nil)
        return [.init(role: .assistant, text: "", toolCalls: [.init(id: id, name: "files_read_range", argumentsJSON: "{}")]),
            .init(role: .toolResult, text: try CodingJSON.encode(page), toolCallId: id)]
    }

    @Test("Overlapping ranges consolidate losslessly while call/result IDs remain paired")
    func overlappingEvidence() throws {
        let messages = try read("first", lines: 1...8) + read("second", lines: 4...10)
        let before = RepositoryEvidence.references(in: messages)
        let consolidated = try #require(RepositoryEvidence.consolidate(messages))
        #expect(consolidated.map(\.toolCallId) == messages.map(\.toolCallId))
        #expect(TokenEstimator.estimate(messages: consolidated) < TokenEstimator.estimate(messages: messages))
        let page = try JSONDecoder().decode(FilesReadRangeTool.Page.self, from: Data(consolidated[3].text.utf8))
        #expect(page.lines.map(\.number) == Array(1...10))
        #expect(page.lines.first?.text.contains("line 1:") == true)
        let references = RepositoryEvidence.references(in: consolidated, previous: before)
        #expect(references.allSatisfy { $0.bodyInContext })
        #expect(references.first?.ranges == [.init(start: 1, end: 10)])
        #expect(consolidated[1].text.contains("second"))
        let report = RequestContextReport()
        var updated = report; updated.repositoryEvidence = references
        #expect(try JSONDecoder().decode(RequestContextReport.self, from: JSONEncoder().encode(updated)) == updated)
    }

    @Test("Partial lines, digest changes and signed prefixes are never merged as complete current evidence")
    func unsafeConsolidation() throws {
        let old = try read("old", lines: 1...8)
        let changed = try read("changed", lines: 1...8, digest: String(repeating: "b", count: 64))
        #expect(RepositoryEvidence.consolidate(old + changed) == nil)
        #expect(RepositoryEvidence.references(in: old + changed).last?.superseded == true)
        let partial = try read("partial", lines: 1...1, partial: true)
        let repeatedPartial = try read("partial-again", lines: 1...1, partial: true)
        #expect(RepositoryEvidence.consolidate(partial + repeatedPartial) == nil)
        #expect(RepositoryEvidence.references(in: partial).first?.partial == true)
        var signed = try old + read("second", lines: 4...10)
        signed[0].continuation = .init(responsesItemsJSON: #"[{"type":"reasoning","encrypted_content":"opaque"}]"#)
        #expect(RepositoryEvidence.consolidate(signed) == nil)
    }

    @Test("Compaction loses no receipt but requires rehydration when source text leaves context")
    func rehydrationAndInvalidation() throws {
        let source = try read("source", lines: 1...8)
        var receipts = RepositoryEvidence.references(in: source)
        receipts[0].invalidated = true
        let repeated = RepositoryEvidence.references(in: source, previous: receipts)
        #expect(repeated.first?.invalidated == true)
        let fresh = RepositoryEvidence.references(in: try source + read("fresh", lines: 1...8), previous: receipts)
        #expect(fresh.first?.invalidated == false)
        var compacted = source
        compacted[1].text = "[Context compressed to stay within the token budget: original source omitted]"
        let missing = RepositoryEvidence.references(in: compacted, previous: receipts)
        #expect(missing.count == 1 && missing[0].bodyInContext == false)
        let checkpoint = RepositoryEvidence.checkpoint(missing)
        #expect(checkpoint.contains("files_read_range") && checkpoint.contains("/fixture/Value.swift"))
    }

    @Test("Batch queries scan once, retain query attribution and support glob, count and path-only outputs")
    func batchSearch() async throws {
        let fixture = try CodingWorkflowTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try fixture.file("Sources/A.swift", "alpha beta\nalpha\nnone\n")
        _ = try fixture.file("Sources/Nested/B.swift", "beta\n")
        _ = try fixture.file("Sources/Generated.swift", "alpha beta\n")
        _ = try fixture.file("Notes.txt", "alpha beta\n")
        let tool = RepositorySearchTool(reader: fixture.reader)
        let report = try await decode(tool, #"{"queries":["alpha","beta"],"include":["Sources/**/*.swift"],"exclude":["**/Generated.swift"],"output":"count"}"#)
        #expect(report.scanned_files == 2)
        #expect(report.matching_lines == [2, 2])
        #expect(report.matching_files == [1, 2])
        #expect(report.matches.isEmpty && report.count_is_exact)
        let paths = try await decode(tool, #"{"queries":["alpha","beta"],"include":["Sources/**/*.swift"],"exclude":["**/Generated.swift"],"output":"paths"}"#)
        #expect(paths.matches.map(\.path) == ["Sources/A.swift", "Sources/Nested/B.swift"])
        #expect(paths.matches.allSatisfy { $0.line == nil && $0.text == $0.path })
        let matches = try await decode(tool, #"{"queries":["alpha","beta"],"path":"Sources/A.swift"}"#)
        #expect(matches.scanned_files == 1)
        #expect(matches.matches.first?.query_indices == [0, 1])
        #expect(matches.matches.map(\.line) == [1, 2])
        await #expect(throws: ToolExecutionFailure.self) { _ = try await tool.execute(argumentsJSON: #"{"query":"alpha","queries":["beta"]}"#) }
        await #expect(throws: ToolExecutionFailure.self) { _ = try await tool.execute(argumentsJSON: #"{"queries":[]}"#) }
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: #"{"query":"alpha","path":"../outside"}"#) }
    }

    private func decode(_ tool: RepositorySearchTool, _ arguments: String) async throws -> RepositorySearchTool.Report {
        try JSONDecoder().decode(RepositorySearchTool.Report.self, from: Data(try await tool.execute(argumentsJSON: arguments).utf8))
    }
}
