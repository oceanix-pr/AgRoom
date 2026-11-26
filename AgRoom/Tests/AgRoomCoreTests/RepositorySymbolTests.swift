import Foundation
import Testing
@testable import AgRoomCore

struct RepositorySymbolTests {
    @Test("LSP framing is incremental and rejects ambiguous or oversized frames")
    func framing() throws {
        let frame = try SourceKitLSPTransport.Framer.encode(["id": 1, "result": "中文"])
        var framer = SourceKitLSPTransport.Framer(), packets: [Data] = []
        for byte in frame { packets += try framer.append(Data([byte])) }
        #expect(packets.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: packets[0]) as? [String: Any])
        #expect(object["result"] as? String == "中文")
        #expect(try framer.append(frame + frame).count == 2)
        #expect(throws: ToolExecutionFailure.self) { try framer.append(Data("Content-Length: 1\r\nContent-Length: 2\r\n\r\nx".utf8)) }
        var large = SourceKitLSPTransport.Framer()
        #expect(throws: ToolExecutionFailure.self) { try large.append(Data("Content-Length: 9999999999\r\n\r\n".utf8)) }
    }

    @Test("Text navigation never starts LSP and native navigation retains host execution approval")
    func permissionsAndFallback() async throws {
        let f = try CodingWorkflowTests.Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try f.file("Account.swift", "struct Account {}\nlet value = Account()\n")
        let tool = RepositorySymbolsTool(reader: f.reader, space: .work, query: { _ in
            Issue.record("Text backend must not start a process"); throw CancellationError()
        })
        let text = #"{"action":"definitions","path":"Account.swift","line":2,"column":13}"#
        let native = #"{"action":"definitions","backend":"sourcekit_lsp","path":"Account.swift","line":2,"column":13}"#
        #expect(tool.permissionClass(argumentsJSON: text) == .readOnly)
        #expect(!tool.requiresConfirmation(argumentsJSON: text))
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "fixture", permissionPolicy: .init(mode: .readOnly, fileAreaPolicy: nil))
        guard case .finished(let report, _, _, _, _, _, _) = try await engine.executeCommand(.init(id: "text", name: "repo_symbols", argumentsJSON: text)) else {
            Issue.record("Text navigation should run without approval"); return
        }
        #expect(report.contains("\"semantic\":false") && report.contains("Account.swift"))
        #expect(tool.permissionClass(argumentsJSON: native) == .codeExecution)
        #expect(tool.requiresHardConfirmation(argumentsJSON: native))
        for mode in [PermissionMode.readOnly, .workspaceWrite] {
            let denied = PermissionPolicy(mode: mode, fileAreaPolicy: nil).assess(toolName: "repo_symbols",
                permissionClass: tool.permissionClass(argumentsJSON: native), argumentsJSON: native, skillWorkspace: nil)
            guard case .deny = denied else { Issue.record("Host LSP must be denied in \(mode)"); continue }
        }
        let host = DispatcherEngine(tools: [tool], systemPrompt: "fixture", permissionPolicy: .init(mode: .dangerFullAccess, fileAreaPolicy: nil))
        guard case .needsConfirmation = try await host.executeCommand(.init(id: "native", name: "repo_symbols", argumentsJSON: native)) else {
            Issue.record("Native project query must require fresh confirmation"); return
        }
        #expect(host.pendingAutoReviewRequest()?.requirement.kind == .hard)
        await #expect(throws: (any Error).self) {
            try await tool.execute(argumentsJSON: #"{"action":"read_symbol","symbol":"Account","path":"../escape.swift"}"#)
        }
    }

    @Test("Semantic locations are scoped; symbol reads retain a current digest and evidence identity")
    func scopedResults() async throws {
        let f = try CodingWorkflowTests.Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let file = try f.file("Account.swift", "struct Account {\n let value = 1\n}\n")
        let tool = RepositorySymbolsTool(reader: f.reader, space: .work, query: { request in
            if request.method == "textDocument/documentSymbol" {
                return Data(#"[{"name":"Account","range":{"start":{"line":0,"character":0},"end":{"line":2,"character":1}}}]"#.utf8)
            }
            return try JSONSerialization.data(withJSONObject: [
                ["uri": file.absoluteString, "range": ["start": ["line": 0, "character": 7], "end": ["line": 0, "character": 14]]],
                ["uri": "file:///etc/passwd", "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]]
            ])
        })
        let definitions = try await tool.execute(argumentsJSON: #"{"action":"definitions","backend":"sourcekit_lsp","path":"Account.swift","line":1,"column":8}"#)
        let object = try #require(JSONSerialization.jsonObject(with: Data(definitions.utf8)) as? [String: Any])
        #expect((object["locations"] as? [Any])?.count == 1 && object["excluded_locations"] as? Int == 1)
        #expect(!definitions.contains("passwd"))
        #expect((object["index_status"] as? [String: Any])?["complete"] as? Bool == false)
        let read = try await tool.execute(argumentsJSON: #"{"action":"read_symbol","backend":"sourcekit_lsp","symbol":"Account","path":"Account.swift"}"#)
        let page = try JSONDecoder().decode(FilesReadRangeTool.Page.self, from: Data(read.utf8))
        #expect(page.lines.count == 3 && page.sha256.count == 64)
        let messages: [EngineMessage] = [.init(role: .assistant, text: "", toolCalls: [
            .init(id: "c", name: "tools_invoke", argumentsJSON: #"{"name":"repo_symbols","arguments_json":"{}"}"#)]),
            .init(role: .toolResult, text: read, toolCallId: "c")]
        #expect(RepositoryEvidence.references(in: messages).first?.symbol == "Account")
        #expect(TokenEstimator.breakdown(messages: messages, tools: []).sourceEvidence > 0)
    }

    @Test("A changed source invalidates a semantic lookup and cancellation never becomes text success")
    func staleAndCancelled() async throws {
        let f = try CodingWorkflowTests.Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let file = try f.file("Value.swift", "let value = 1\n")
        let args = #"{"action":"references","backend":"sourcekit_lsp","path":"Value.swift","line":1,"column":5}"#
        let stale = RepositorySymbolsTool(reader: f.reader, space: .work, query: { _ in
            try Data("let value = 2\n".utf8).write(to: file); return Data("[]".utf8)
        })
        await #expect(throws: ToolExecutionFailure.self) { try await stale.execute(argumentsJSON: args) }
        let cancelled = RepositorySymbolsTool(reader: f.reader, space: .work, query: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await cancelled.execute(argumentsJSON: args) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_SOURCEKIT_LSP"] == "1"))
    func realSourceKitSymbolRead() async throws {
        let f = try CodingWorkflowTests.Fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try f.file("Account.swift", "struct Account {\n let balance = 42\n}\n")
        let scopedReader = try RepositoryReader(root: f.reader.root, service: f.service.scoped(to: [f.reader.root]), space: .work)
        let tool = RepositorySymbolsTool(reader: scopedReader, space: .work)
        let read = try await tool.execute(argumentsJSON: #"{"action":"read_symbol","backend":"sourcekit_lsp","path":"Account.swift","symbol":"Account"}"#)
        let object = try #require(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
        #expect(object["backend"] as? String == "sourcekit_lsp")
        #expect(object["symbol"] as? String == "Account")
        #expect((object["lines"] as? [Any])?.count == 3)
    }
}
