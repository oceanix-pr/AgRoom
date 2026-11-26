import Foundation
import Synchronization
import Testing
@testable import AgRoomCore

@Suite("Large repository text", .serialized)
struct LargeRepositoryTextTests {
    private struct Fixture {
        let base: URL
        let broadService: FileAreaService
        let scopedService: FileAreaService
        let reader: RepositoryReader

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("large-repository-text-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            let broad = FileAreaService(baseDirectory: base, additionalRoots: [base])
            try broad.ensureRoots()
            broadService = broad
            scopedService = broad.scoped(to: [broad.workspaceRoot])
            reader = try RepositoryReader(root: broad.workspaceRoot,
                service: scopedService, space: .work)
        }

        func write(_ relative: String, data: Data) throws -> URL {
            let target = reader.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: target)
            return target
        }

        func write(_ relative: String, text: String) throws -> URL {
            try write(relative, data: Data(text.utf8))
        }
    }

    private func json(_ arguments: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
    }

    private func formattedCatalog() -> (text: String, keyLine: Int) {
        let padding = String(repeating: "q", count: 990)
        var lines = ["{", "  \"sourceLanguage\": \"en\",", "  \"strings\": {"]
        lines.reserveCapacity(7_300)
        for index in 0..<7_250 {
            lines.append("    \"padding.\(index)\": {\"comment\": \"\(padding)\"},")
        }
        let keyLine = lines.count + 1
        lines += [
            "    \"critical.localized.key\": {",
            "      \"comment\": \"LARGE_CATALOG_TARGET\",",
            "      \"localizations\": {\"en\": {\"stringUnit\": {\"state\": \"translated\", \"value\": \"Old label\"}}}",
            "    },",
            "    \"after.target\": {\"comment\": \"keep this unrelated entry\"}",
            "  }",
            "}",
        ]
        return (lines.joined(separator: "\n") + "\n", keyLine)
    }

    @Test("A seven MiB catalog can be searched and read locally without a Shell tool")
    func formattedCatalogSearchAndRange() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let catalog = formattedCatalog()
        #expect(catalog.text.utf8.count > 7 * 1024 * 1024)
        let file = try fixture.write("Localizable.xcstrings", text: catalog.text)
        let search = RepositorySearchTool(reader: fixture.reader)
        let range = FilesReadRangeTool(reader: fixture.reader)
        let read = FilesReadTool(service: fixture.scopedService)
        #expect(!search.requiresConfirmation && !range.requiresConfirmation && !read.requiresConfirmation)
        #expect(search.sideEffectClass == .readOnly && range.sideEffectClass == .readOnly)

        let report = try JSONDecoder().decode(RepositorySearchTool.Report.self,
            from: Data(try await search.execute(argumentsJSON: json([
                "query": "critical.localized.key", "path": file.path,
                "context_before": 2, "context_after": 2,
            ])).utf8))
        let match = try #require(report.matches.first)
        #expect(report.matches.count == 1 && !report.truncated)
        #expect(match.path == "Localizable.xcstrings" && match.line == catalog.keyLine)
        #expect(match.text.contains("critical.localized.key"))
        #expect(match.context_before?.count == 2 && match.context_after?.count == 2)
        #expect(match.context_after?.contains { $0.text.contains("LARGE_CATALOG_TARGET") } == true)

        let rangeJSON = try await range.execute(argumentsJSON: json([
            "path": file.path, "start_line": catalog.keyLine, "end_line": catalog.keyLine + 3,
        ]))
        #expect(rangeJSON.utf8.count <= 5_500)
        let page = try JSONDecoder().decode(FilesReadRangeTool.Page.self, from: Data(rangeJSON.utf8))
        #expect(page.lines.first?.number == catalog.keyLine)
        #expect(page.lines.contains { $0.text.contains("Old label") })
        #expect(page.sha256 == ManagedTextSnapshot.digest(Data(catalog.text.utf8)))

        let crowdedJSON = try await search.execute(argumentsJSON: json([
            "query": "critical.localized.key", "path": file.path,
            "context_before": 20, "context_after": 20,
        ]))
        #expect(crowdedJSON.utf8.count <= 5_200)
        let crowded = try JSONDecoder().decode(RepositorySearchTool.Report.self,
            from: Data(crowdedJSON.utf8))
        #expect(crowded.matches.first?.text.contains("critical.localized.key") == true)
        #expect(crowded.matches.first?.context_truncated == true)

        // The same large-file read remains approval-free inside the Dispatcher,
        // with no Shell tool registered as a fallback.
        let engine = DispatcherEngine(tools: [search, range, read], systemPrompt: "synthetic fixture",
            permissionPolicy: PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil))
        let call = ToolCallRaw(id: "large-range", name: "files_read_range",
            argumentsJSON: try json([
                "path": file.path, "start_line": catalog.keyLine, "end_line": catalog.keyLine + 1,
            ]))
        guard case .finished(let response, _, let trace, _, _, _, _) = try await engine.executeCommand(call) else {
            Issue.record("The dedicated large-file reader unexpectedly requested approval")
            return
        }
        #expect(response.contains("critical.localized.key"))
        #expect(trace.first?.succeeded == true && engine.pendingApprovalID == nil)
    }

    @Test("A late match in one very long line has centered context and a direct read cursor")
    func longLineDirectCursor() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let prefix = String(repeating: "p", count: 7 * 1024 * 1024)
        let file = try fixture.write("one-line.xcstrings",
            text: prefix + "LATE_LINE_NEEDLE" + String(repeating: "s", count: 10_000) + "\n")
        let search = RepositorySearchTool(reader: fixture.reader)
        let reportJSON = try await search.execute(argumentsJSON: json([
            "query": "LATE_LINE_NEEDLE", "path": file.path,
        ]))
        #expect(reportJSON.utf8.count <= 5_200)
        let report = try JSONDecoder().decode(RepositorySearchTool.Report.self, from: Data(reportJSON.utf8))
        let match = try #require(report.matches.first)
        #expect(match.text.contains("LATE_LINE_NEEDLE"))
        #expect((match.column ?? 0) > 350)
        let cursor = try #require(match.read_cursor)

        let read = FilesReadTool(service: fixture.scopedService)
        let direct = try await read.execute(argumentsJSON: json(["path": file.path, "cursor": cursor]))
        #expect(direct.utf8.count <= 5_500)
        let directPage = try JSONDecoder().decode(ManagedTextSnapshot.Page.self, from: Data(direct.utf8))
        #expect(directPage.content.contains("LATE_LINE_NEEDLE"))
        #expect(directPage.sha256 == match.sha256)

        let rangeJSON = try await FilesReadRangeTool(reader: fixture.reader)
            .execute(argumentsJSON: json(["path": file.path, "start_line": 1, "end_line": 1]))
        #expect(rangeJSON.utf8.count <= 5_500)
        let linePage = try JSONDecoder().decode(FilesReadRangeTool.Page.self, from: Data(rangeJSON.utf8))
        #expect(linePage.lines.first?.line_truncated == true)
        let continuation = try #require(linePage.next_cursor)
        let continued = try await read.execute(argumentsJSON: json(["path": file.path, "cursor": continuation]))
        let continuedPage = try JSONDecoder().decode(ManagedTextSnapshot.Page.self, from: Data(continued.utf8))
        #expect(continuedPage.offset > 0)

        let other = try fixture.write("other.txt", text: "LATE_LINE_NEEDLE")
        await #expect(throws: (any Error).self) {
            _ = try await read.execute(argumentsJSON: json(["path": other.path, "cursor": cursor]))
        }
        try Data("changed\n".utf8).write(to: file)
        await #expect(throws: (any Error).self) {
            _ = try await read.execute(argumentsJSON: json(["path": file.path, "cursor": cursor]))
        }
    }

    @Test("Malformed UTF-8 and NUL content are not returned as source text")
    func invalidTextFailsClosed() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let malformed = try fixture.write("malformed.xcstrings", data: Data([0x61, 0x80, 0x62]))
        let nul = try fixture.write("nul.xcstrings", data: Data([0x61, 0x00, 0x62]))
        let read = FilesReadTool(service: fixture.scopedService)
        let range = FilesReadRangeTool(reader: fixture.reader)
        for file in [malformed, nul] {
            await #expect(throws: (any Error).self) {
                _ = try await read.execute(argumentsJSON: json(["path": file.path]))
            }
            await #expect(throws: (any Error).self) {
                _ = try await range.execute(argumentsJSON: json(["path": file.path]))
            }
        }
    }

    @Test("A linked or foreign file cannot become a work-space read result")
    func linksAndOtherSpaceAreRejected() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let secret = fixture.broadService.defaultChatRoot(for: .personal)
            .appendingPathComponent("secret.xcstrings")
        try Data("PERSONAL_PRIVATE_NEEDLE".utf8).write(to: secret)
        let link = fixture.reader.root.appendingPathComponent("linked.xcstrings")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let ordinary = try fixture.write("ordinary.txt", text: "work content")
        let localLink = fixture.reader.root.appendingPathComponent("local-link.txt")
        try FileManager.default.createSymbolicLink(at: localLink, withDestinationURL: ordinary)
        let read = FilesReadTool(service: fixture.scopedService)
        let range = FilesReadRangeTool(reader: fixture.reader)
        for file in [secret, link, localLink] {
            await #expect(throws: (any Error).self) {
                _ = try await read.execute(argumentsJSON: json(["path": file.path]))
            }
            await #expect(throws: (any Error).self) {
                _ = try await range.execute(argumentsJSON: json(["path": file.path]))
            }
        }
        let report = try JSONDecoder().decode(RepositorySearchTool.Report.self,
            from: Data(try await RepositorySearchTool(reader: fixture.reader)
                .execute(argumentsJSON: json(["query": "PERSONAL_PRIVATE_NEEDLE"])).utf8))
        #expect(report.matches.isEmpty)
        #expect(try Data(contentsOf: secret) == Data("PERSONAL_PRIVATE_NEEDLE".utf8))
        #expect(throws: (any Error).self) {
            try RepositoryReader(root: fixture.broadService.defaultChatRoot(for: .personal),
                service: fixture.broadService, space: .work)
        }
    }

    private func assertSubdirectoryEnumerationRejectsPersonalLink(inspect: Bool) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let workFile = try fixture.write("nested/work-only.txt", text: "WORK_ONLY")
        let workDirectory = workFile.deletingLastPathComponent()
        let retainedWorkDirectory = fixture.base.appendingPathComponent("retained-nested")
        let personalDirectory = fixture.broadService.defaultChatRoot(for: .personal)
        let personalFile = personalDirectory.appendingPathComponent("personal-secret-name.txt")
        let personalBytes = Data("PERSONAL_PRIVATE_CONTENT".utf8)
        try personalBytes.write(to: personalFile)

        // The project root remains fixed. Only this child directory changes after
        // the listing has pinned its directory descriptor and before enumeration.
        let switched = Mutex(false)
        var reader = fixture.reader
        reader.beforeDirectoryEnumeration = { directory in
            guard directory.standardizedFileURL.path == workDirectory.standardizedFileURL.path else { return }
            let firstVisit = switched.withLock { value -> Bool in
                guard !value else { return false }
                value = true
                return true
            }
            guard firstVisit else { return }
            try FileManager.default.moveItem(at: workDirectory, to: retainedWorkDirectory)
            try FileManager.default.createSymbolicLink(at: workDirectory,
                withDestinationURL: personalDirectory)
        }
        let hookedReader = reader

        if inspect {
            await #expect(throws: (any Error).self) {
                _ = try await ProjectInspectTool(reader: hookedReader).execute(argumentsJSON:
                    json(["path": workDirectory.path]))
            }
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await RepositorySearchTool(reader: hookedReader).execute(argumentsJSON:
                    json(["mode": "path", "path": workDirectory.path,
                        "query": "personal-secret-name"]))
            }
        }
        #expect(switched.withLock { $0 })
        #expect(try Data(contentsOf: personalFile) == personalBytes)
        #expect(try Data(contentsOf: retainedWorkDirectory.appendingPathComponent("work-only.txt"))
            == Data("WORK_ONLY".utf8))
    }

    @Test("Path search fails closed when a work child becomes a personal link before enumeration")
    func pathSearchRejectsSubdirectorySwap() async throws {
        try await assertSubdirectoryEnumerationRejectsPersonalLink(inspect: false)
    }

    @Test("Project inspection fails closed when a work child becomes a personal link before enumeration")
    func projectInspectRejectsSubdirectorySwap() async throws {
        try await assertSubdirectoryEnumerationRejectsPersonalLink(inspect: true)
    }

    @Test("An already cancelled parent read does not launch detached work")
    func cancelledParentRead() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = try fixture.write("cancel.xcstrings", text: String(repeating: "abc\n", count: 20_000))
        let range = FilesReadRangeTool(reader: fixture.reader)
        let rangeTask = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await range.execute(argumentsJSON: json(["path": file.path]))
        }
        await #expect(throws: CancellationError.self) { _ = try await rangeTask.value }
        let search = RepositorySearchTool(reader: fixture.reader)
        let searchTask = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await search.execute(argumentsJSON: json([
                "path": file.path, "query": "abc",
            ]))
        }
        await #expect(throws: CancellationError.self) { _ = try await searchTask.value }
    }

    @Test("Streaming text scans reject over-limit and invalid bytes")
    func scannerRejectsInvalidInput() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let overLimit = try fixture.write("too-large-for-budget.txt", text: String(repeating: "x", count: 1_024))
        #expect(throws: (any Error).self) {
            _ = try WorkspaceTextReader.scan(overLimit, root: fixture.reader.root, limit: 512) { _ in }
        }
        let malformed = try fixture.write("invalid-utf8.txt", data: Data([0x66, 0x80, 0x6f]))
        #expect(throws: (any Error).self) {
            _ = try WorkspaceTextReader.scan(malformed, root: fixture.reader.root) { _ in }
        }
        let nul = try fixture.write("embedded-nul.txt", data: Data([0x66, 0x00, 0x6f]))
        #expect(throws: (any Error).self) {
            _ = try WorkspaceTextReader.scan(nul, root: fixture.reader.root) { _ in }
        }
    }

    @Test("An explicit file over 32 MiB is rejected; directory search reports it and still finds healthy text")
    func oversizedSearchIsExplicit() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let large = try fixture.write("a-oversized.xcstrings", data: Data())
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(WorkspaceTextLimits.maximumReadBytes) + 1)
        try handle.close()
        _ = try fixture.write("z-healthy.txt", text: "HEALTHY_LARGE_SEARCH_TARGET\n")
        let search = RepositorySearchTool(reader: fixture.reader)

        await #expect(throws: (any Error).self) {
            _ = try await search.execute(argumentsJSON: json([
                "path": large.path, "query": "HEALTHY_LARGE_SEARCH_TARGET",
            ]))
        }
        let directoryJSON = try await search.execute(argumentsJSON: json([
            "path": fixture.reader.root.path, "query": "HEALTHY_LARGE_SEARCH_TARGET",
        ]))
        let report = try JSONDecoder().decode(RepositorySearchTool.Report.self,
            from: Data(directoryJSON.utf8))
        #expect(report.skipped_large_files == 1 && report.skipped_files >= 1)
        #expect(report.matches.map(\.path) == ["z-healthy.txt"])
        #expect(report.guidance?.contains("32 MiB") == true)
    }

    @Test("One-character pages reconstruct CRLF, Chinese text and emoji without losing a cursor offset")
    func oneCharacterUnicodePages() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let original = "甲👩🏽‍💻\r\n乙🌕\r\n终点"
        let file = try fixture.write("unicode-crlf.xcstrings", text: original)
        let read = FilesReadTool(service: fixture.scopedService)
        var cursor: String?
        var recovered = ""
        var pages = 0
        repeat {
            var arguments: [String: Any] = ["path": file.path, "max_chars": 1]
            if let cursor { arguments["cursor"] = cursor }
            let result = try await read.execute(argumentsJSON: json(arguments))
            #expect(result.utf8.count <= 5_500)
            let page = try JSONDecoder().decode(ManagedTextSnapshot.Page.self,
                from: Data(result.utf8))
            #expect(page.offset == recovered.count)
            #expect(page.total_characters == original.count)
            #expect(page.sha256 == ManagedTextSnapshot.digest(Data(original.utf8)))
            #expect(page.content.count == 1)
            recovered += page.content
            cursor = page.next_cursor
            pages += 1
            try #require(pages < 40)
        } while cursor != nil
        #expect(recovered == original)
    }

    @Test("A file replaced after the first streamed line cannot produce a trusted summary")
    func scannerRejectsFileReplacement() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = try fixture.write("replace-me.txt", text: "first line\nold private content\n")
        let moved = fixture.reader.root.appendingPathComponent("original.txt")
        var changed = false
        #expect(throws: (any Error).self) {
            _ = try WorkspaceTextReader.scan(file, root: fixture.reader.root) { line in
                guard line.number == 1, !changed else { return }
                changed = true
                try FileManager.default.moveItem(at: file, to: moved)
                try Data("first line\nreplacement\n".utf8).write(to: file)
            }
        }
        #expect(changed)
        #expect(try Data(contentsOf: file) == Data("first line\nreplacement\n".utf8))
        #expect(try Data(contentsOf: moved) == Data("first line\nold private content\n".utf8))
    }

    @Test("Replacing the work directory with a personal link during a scan fails closed")
    func scannerRejectsDirectoryReplacement() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = try fixture.write("same-name.txt", text: "first line\nwork content\n")
        let personal = fixture.broadService.defaultChatRoot(for: .personal)
            .appendingPathComponent("same-name.txt")
        let personalBytes = Data("first line\npersonal private content\n".utf8)
        try personalBytes.write(to: personal)
        let moved = fixture.base.appendingPathComponent("moved-workspace")
        var changed = false
        #expect(throws: (any Error).self) {
            _ = try WorkspaceTextReader.scan(file, root: fixture.reader.root) { line in
                guard line.number == 1, !changed else { return }
                changed = true
                try FileManager.default.moveItem(at: fixture.reader.root, to: moved)
                try FileManager.default.createSymbolicLink(at: fixture.reader.root,
                    withDestinationURL: personal.deletingLastPathComponent())
            }
        }
        #expect(changed)
        #expect(try Data(contentsOf: personal) == personalBytes)
        #expect(try Data(contentsOf: moved.appendingPathComponent("same-name.txt"))
            == Data("first line\nwork content\n".utf8))
    }
}
