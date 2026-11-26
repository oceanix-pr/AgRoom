import Foundation
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Documentation extraction and skill workflow")
struct DocumentationSkillTests {
    private let root = URL(string: "https://manual.test/docs/v2/")!

    private func temporarySkills() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("documentation-test-\(UUID())/work/skills")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func arguments(_ values: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
    }
    private func object(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
    private func loader() -> WebDocumentLoader {
        return WebDocumentLoader { url, _ in
            switch url.path {
            case "/sitemap.xml":
                return .extract("<urlset><url><loc>https://manual.test/docs/v2/errors</loc></url><url><loc>https://manual.test/private</loc></url></urlset>", url: url, contentType: "application/xml")
            case "/docs/v2/", "/docs/v2":
                return .extract("""
                    <html><head><title>SDK v2</title></head><body>
                    <nav><a href="setup#install">Install</a><a href="setup#use">Same chapter</a><a href="https://outside.test/docs/">External</a><a href="/docs/v1/">Old version</a><a href="delete">Delete</a><a href="search?q=secret">Query</a></nav>
                    <main><h1>SDK v2</h1><p>Use this version for uploads.</p></main></body></html>
                    """, url: url)
            case "/docs/v2/setup":
                return .extract("<h1>Install SDK</h1><pre><code class='language-python'>def upload():\n    return Client&lt;File&gt;()\n</code></pre>" + String(repeating: "example 中文🙂\n", count: 1600), url: url)
            case "/docs/v2/errors":
                return .extract("# Errors\n\nRetry only idempotent uploads.\n", url: url, contentType: "text/markdown")
            default: throw WebDocumentError.unavailable
            }
        }
    }
    private func collect(_ store: DocumentationStore, limit: Int = 8, id: UUID? = nil, refresh: Bool = false) async throws -> DocumentationCollection {
        try await store.collect(seed: root, scope: root, goal: "Implement uploads", version: "2", id: id, limit: limit, retry: false, refresh: refresh)
    }
    private func readAll(_ store: DocumentationStore, id: UUID) async throws {
        let snapshot = try store.snapshot(id)
        for page in snapshot.pages where page.document != nil {
            var next: Int? = 0
            while let offset = next {
                let result = try object(await store.read(id, pageID: page.id, offset: offset, limit: 7000))
                next = result["next_offset"] as? Int
            }
        }
    }

    @Test("Preserves headings, code indentation, generics, tables and ordinary links")
    func structuredExtraction() throws {
        let document = WebDocument.extract("""
            <html><head><title>Upload &amp; Download</title><script>let fake = '<main>FAKE</main>';</script></head>
            <body><nav>MENU</nav><main><h2>Upload</h2><p>Read <a href="../v2/api">the API</a>.</p>
            <pre><code class="language-python"><span>def main():</span>\n    return List&lt;T&gt;(&quot;🙂&quot;)\n</code></pre>
            <table><tr><th>Field</th><th>Type</th></tr><tr><td>file</td><td>bytes</td></tr></table>
            <p>&#x4E2D;&#25991;</p></main></body></html>
            """, url: root)
        #expect(document.title == "Upload & Download")
        #expect(document.markdown.contains("## Upload"))
        #expect(document.markdown.contains("```python\ndef main():\n    return List<T>(\"🙂\")\n```"))
        #expect(document.markdown.contains("| file | bytes |"))
        #expect(document.markdown.contains("中文"))
        #expect(!document.markdown.contains("MENU"))
        #expect(!document.markdown.contains("FAKE"))
        #expect(document.links.first?.url == "https://manual.test/docs/v2/api")
        #expect(!document.truncated)
    }

    @Test("Full Unicode and Markdown text survives consecutive chunks beyond the former 4000-character cap")
    func fullTextPagination() async throws {
        let text = "# Swift API\n```swift\nlet value: Box<T> = .init()\n```\n" + String(repeating: "中文🙂 content\n", count: 3000)
        let loader = WebDocumentLoader { url, _ in .extract(text, url: url, contentType: "text/markdown") }
        let tool = WebFetchTool(loader: loader)
        var offset = 0
        var rebuilt = ""
        repeat {
            let result = try object(await tool.execute(argumentsJSON: arguments(["url": root.absoluteString, "offset": offset, "limit": 3333])))
            rebuilt += try #require(result["content"] as? String)
            #expect(result["source_truncated"] as? Bool == false)
            guard let next = result["next_offset"] as? Int else { break }
            offset = next
        } while true
        #expect(rebuilt == text)
        let oversized = WebDocument.extract(String(repeating: "x", count: 130_000), url: root, contentType: "text/plain")
        #expect(oversized.truncated)
        #expect(oversized.markdown.count == 120_000)
    }

    @Test("The engine delivers complete escaped chunks and coverage counts only those delivered characters")
    func engineKeepsReadReceipts() async throws {
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let escaped = String(repeating: "\"\\\n\u{0001}中文🙂", count: 4000)
        let loader = WebDocumentLoader { url, _ in
            if url.path == "/sitemap.xml" { throw WebDocumentError.unavailable }
            return .extract(escaped, url: url, contentType: "text/plain")
        }
        let store = DocumentationStore(skillsDirectory: folder, loader: loader)
        let value = try await collect(store, limit: 1)
        let tool = DocumentationReadTool(store: store)
        let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
        let outcome = try await engine.executeCommand(.init(id: "chunk", name: "docs_read",
            argumentsJSON: arguments(["collection_id": value.id.uuidString, "page_id": 1, "limit": 16_000])))
        guard case .finished(let text, _, _, _, _, _, _) = outcome else { Issue.record("Expected a read-only result"); return }
        let result = try object(text)
        let delivered = try #require(result["content"] as? String)
        #expect(text.count > 6000)
        #expect(text.count <= 24_000)
        #expect(delivered == String(escaped.prefix(delivered.count)))
        #expect(result["next_offset"] as? Int == delivered.count)
        #expect(try store.snapshot(value.id).pages.first?.readCharacters == delivered.count)
    }

    @Test("Large manifests page through every chapter without clipping a continuation receipt")
    func manifestPagination() throws {
        let pages = (1...100).map { DocumentationCollection.Page(id: $0, url: root.appendingPathComponent("chapter-\($0)").absoluteString, title: String(repeating: "Chapter ", count: 20)) }
        let value = DocumentationCollection(id: UUID(), seedURL: root.absoluteString, scopeURL: root.absoluteString,
                                            goal: "Upload", version: "2", createdAt: Date(), pages: pages)
        var next: Int? = 0
        var ids: [Int] = []
        while let offset = next {
            let json = try value.modelManifest(offset: offset)
            #expect(json.count <= 24_000)
            let manifest = try object(json)
            ids += (manifest["pages"] as? [[String: Any]] ?? []).compactMap { $0["page_id"] as? Int }
            next = manifest["next_page_offset"] as? Int
        }
        #expect(ids == Array(1...100))
    }

    @Test("Discovery stays inside the selected version directory and ignores actions and credentials")
    func scopeAndRedirects() async throws {
        #expect(WebDocumentURL.contains(root.appendingPathComponent("setup"), in: root))
        for raw in ["https://manual.test/docs/v20/setup", "https://manual.test/docs/v2/../../private", "https://outside.test/docs/v2/", "http://manual.test/docs/v2/", "https://u:p@manual.test/docs/v2/"] {
            #expect(!WebDocumentURL.contains(URL(string: raw)!, in: root))
        }
        #expect(WebDocumentURL.canonical("http://localhost:8080/docs") != nil)
        #expect(WebDocumentURL.canonical("https://u:p@manual.test/docs") == nil)
        #expect(!WebDocumentURL.chapter(URL(string: "https://manual.test/docs/v2/logout")!, scope: root))
        #expect(!WebDocumentURL.chapter(URL(string: "https://manual.test/docs/v2/search?q=1")!, scope: root))
        let redirected = WebDocumentLoader { _, _ in .extract("outside", url: URL(string: "https://outside.test/")!, contentType: "text/plain") }
        await #expect(throws: WebDocumentError.self) { _ = try await redirected.load(root, scope: root) }
    }

    @Test("A bounded crawl resumes after reopening and reports only observed chapter coverage")
    func crawlResume() async throws {
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let first = DocumentationStore(skillsDirectory: folder, loader: loader())
        let initial = try await collect(first, limit: 1)
        #expect(initial.pages.filter { $0.document != nil }.count == 1)
        #expect(!initial.complete)
        #expect(initial.pages.count == 3)
        #expect(initial.pages.allSatisfy { $0.url.hasPrefix(root.absoluteString) })
        #expect(initial.sitemap == "parsed")
        let reopened = DocumentationStore(skillsDirectory: folder, loader: loader())
        let completed = try await collect(reopened, id: initial.id)
        #expect(completed.complete)
        #expect(!completed.allFetchedPagesRead)
        try await readAll(reopened, id: completed.id)
        #expect(try reopened.snapshot(completed.id).allFetchedPagesRead)
        let manifest = try object(await reopened.read(completed.id, pageID: nil, offset: 0, limit: 100))
        #expect(manifest["runtime_verified"] as? Bool == false)
        #expect(manifest["scope_exhausted"] as? Bool == true)
    }

    @Test("Unread source material cannot be installed; saved sources and development tools round-trip")
    func createWithEvidence() async throws {
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let research = DocumentationStore(skillsDirectory: folder, loader: loader())
        let collection = try await collect(research, limit: 1)
        let skills = SkillStore(directoryURL: folder)
        let tool = SkillCreateTool(store: skills, pythonExecutor: nil, documentationStore: research,
                                  availableToolNames: SkillGenerator.knownToolNames)
        let args = try arguments(["name": "sdk-upload", "alias": "SDK 上传", "description": "Implement SDK v2 uploads", "content": "## Inputs\nA source file.\n## Steps\n1. Read the SDK examples.\n2. Edit the project.\n## Verification\nBuild and test with project_build after approval.\n## Failure handling\nReport failing checks.",
                                  "allowed_tools": "repo_search, files_read, files_edit, project_build", "documentation_id": collection.id.uuidString,
                                  "verification_plan": ["steps": ["Review and run the project's upload tests with project_build."], "expected_result": "Upload tests pass against the requested SDK version.", "failure_handling": "Stop and report failing checks and missing configuration."]])
        #expect(throws: (any Error).self) { try tool.validateArguments(argumentsJSON: args) }
        #expect(try skills.list().isEmpty)
        try await readAll(research, id: collection.id)
        let requirement = DispatcherEngine.confirmationRequirement(.init(id: "save", name: "skill_create", argumentsJSON: args),
            toolsByName: ["skill_create": tool], authorizedKeys: [], permissionPolicy: .init(mode: .workspaceWrite, fileAreaPolicy: nil))
        #expect(requirement != nil)
        #expect(requirement?.presentation?.documentation?.partial == true)
        #expect(requirement?.presentation?.documentation?.readPages == 1)
        let summary = try await tool.execute(argumentsJSON: args)
        #expect(summary.contains("Coverage is partial"))
        let skill = try #require(skills.list().first)
        #expect(SkillToolDeclaration(rawValue: skill.allowedTools).names == Set(["repo_search", "files_read", "files_edit", "project_build"]))
        let sources = try skills.readFile(name: skill.name, relativePath: "references/documentation/sources.json")
        #expect(sources.contains("requested_version"))
        #expect(sources.contains("pending"))
        #expect(skill.content.contains("references/documentation/index.md"))
        #expect(try skills.readFile(name: skill.name, relativePath: "references/documentation/verification-plan.md").contains("not executed"))
        #expect(skills.validationRecord(name: skill.name).executed == false)
        let oldKey = tool.executionAuthorizationKey(argumentsJSON: args)
        _ = try await collect(research, limit: 1, id: collection.id, refresh: true)
        #expect(tool.executionAuthorizationKey(argumentsJSON: args) != oldKey)
        #expect(throws: (any Error).self) { try tool.validateArguments(argumentsJSON: args) }
    }

    @Test("Saved long references can be read completely through the engine's skill_file route")
    func savedReferencePagination() async throws {
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = SkillStore(directoryURL: folder)
        let body = String(repeating: "SDK code example 中文🙂\n", count: 1800)
        _ = try store.installPackage(Skill(name: "sdk", description: "SDK", content: "Read references/long.md with skill_file."),
                                     scripts: [], references: [("references/long.md", body)], overwrite: false)
        let tool = SkillFileTool(store: store, allowedSkillNames: ["sdk"])
        var next: Int? = 0
        var rebuilt = ""
        while let offset = next {
            let engine = DispatcherEngine(tools: [tool], systemPrompt: "")
            let outcome = try await engine.executeCommand(.init(id: "read", name: "skill_file",
                argumentsJSON: arguments(["name": "sdk", "path": "references/long.md", "offset": offset])))
            guard case .finished(let text, _, _, _, _, _, _) = outcome else { Issue.record("Expected a reference chunk"); return }
            let result = try object(text)
            rebuilt += try #require(result["content"] as? String)
            next = result["next_offset"] as? Int
        }
        #expect(rebuilt == body)
    }

    @Test("A previously missing source cannot become an approved write after concurrent collection")
    func missingSourceIdentity() async throws {
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let research = DocumentationStore(skillsDirectory: folder, loader: loader())
        let skills = SkillStore(directoryURL: folder)
        let tool = SkillCreateTool(store: skills, pythonExecutor: nil, documentationStore: research, availableToolNames: SkillGenerator.knownToolNames)
        let id = DocumentationStore.collectionID(seed: root, scope: root, goal: "Implement uploads", version: "2")
        let args = try arguments(["name": "sdk", "alias": "SDK", "description": "SDK upload", "content": "Read the source and implement uploads.",
                                  "documentation_id": id.uuidString,
                                  "verification_plan": ["steps": ["Build and run upload tests after approval."], "expected_result": "Tests pass.", "failure_handling": "Stop on errors."]])
        let oldIdentity = try #require(tool.executionAuthorizationKey(argumentsJSON: args))
        _ = try await collect(research, limit: 1)
        try await readAll(research, id: id)
        #expect(tool.executionAuthorizationKey(argumentsJSON: args) != oldIdentity)
        await #expect(throws: ToolExecutionFailure.self) { _ = try await tool.execute(argumentsJSON: args, authorizationKey: oldIdentity) }
        #expect(try skills.list().isEmpty)
    }

    @Test("Large source manifests stay readable as normal skill files")
    func sourceBundleBounds() throws {
        let pages = (1...100).map { id -> DocumentationCollection.Page in
            let url = root.appendingPathComponent(String(repeating: "chapter", count: 500) + "-\(id)")
            let doc = WebDocument.extract("Chapter \(id)", url: url, contentType: "text/plain")
            return .init(id: id, url: url.absoluteString, title: String(repeating: "中文", count: 100), status: "fetched",
                         document: doc, readRanges: [[0, doc.markdown.count]])
        }
        let value = DocumentationCollection(id: UUID(), seedURL: root.absoluteString, scopeURL: root.absoluteString,
                                            goal: "Upload", version: "2", createdAt: Date(), pages: pages)
        let files = try value.references()
        #expect(files.allSatisfy { $0.content.utf8.count <= SkillStore.maxFileBytes })
        #expect(files.first(where: { $0.path == "references/documentation/sources.json" })?.content.contains("page_manifests") == true)
    }

    @Test("Rendered chapter capture checks space, chapter identity and source changes")
    func renderedCapture() async throws {
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let failing = WebDocumentLoader { _, _ in throw WebDocumentError.unavailable }
        let research = DocumentationStore(skillsDirectory: folder, loader: failing)
        let collection = try await collect(research, limit: 1)
        #expect(collection.pages.first?.status == "failed")
        let rendered = WebDocument.extract("<main><h1>SDK v2</h1><pre>def upload():\n    return 1\n</pre></main>", url: root, retrieval: "browser")
        let text = try object(await research.capture(collection.id, pageID: 1, document: rendered, offset: 0, limit: 10))
        #expect(text["next_offset"] as? Int == 10)
        #expect(!((try research.snapshot(collection.id)).allFetchedPagesRead))
        try await readAll(research, id: collection.id)
        #expect(try research.snapshot(collection.id).allFetchedPagesRead)
        let otherPage = WebDocument.extract("other", url: root.appendingPathComponent("unrelated"), retrieval: "browser")
        await #expect(throws: (any Error).self) { _ = try await research.capture(collection.id, pageID: 1, document: otherPage, offset: 0, limit: 100) }
        let personalFolder = folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("personal/skills")
        try FileManager.default.createDirectory(at: personalFolder, withIntermediateDirectories: true)
        let personal = DocumentationStore(skillsDirectory: personalFolder, loader: failing)
        #expect(throws: (any Error).self) { _ = try personal.snapshot(collection.id) }
        let changed = WebDocument.extract("<main><h1>Changed</h1><p>New API</p></main>", url: root, retrieval: "browser")
        _ = try await research.capture(collection.id, pageID: 1, document: changed, offset: 0, limit: 1)
        #expect(!((try research.snapshot(collection.id)).allFetchedPagesRead))
    }

    @Test("Unknown and explicitly empty tool declarations cannot widen permissions")
    func toolDeclarations() throws {
        for raw in ["[]", "missing_tool", "not-a-valid-tool()"] {
            let result = SkillGenerator.validatePackage(.init(skill: Skill(name: "fixture", description: "fixture", content: "Use the supplied context.", allowedTools: raw)))
            #expect(result.package.skill.allowedTools == "[]")
            #expect(SkillToolDeclaration(rawValue: result.package.skill.allowedTools) == .explicitEmpty)
        }
        let skill = Skill(name: "fixture", description: "fixture", content: "Read, edit and test.", allowedTools: "repo_search files_read files_edit project_build")
        let valid = SkillGenerator.validatePackage(.init(skill: skill))
        #expect(SkillToolDeclaration(rawValue: valid.package.skill.allowedTools).names?.count == 4)
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let tool = SkillCreateTool(store: SkillStore(directoryURL: folder))
        #expect(throws: (any Error).self) { try tool.validateArguments(argumentsJSON: arguments(["allowed_tools": "invented_tool"])) }
    }

    @Test("Cancellation leaves a resumable checkpoint and symlink stores are rejected")
    func cancellationAndLinks() async throws {
        let folder = try temporarySkills()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let slow = WebDocumentLoader { url, _ in
            try await Task.sleep(for: .seconds(30))
            return .extract("text", url: url, contentType: "text/plain")
        }
        let research = DocumentationStore(skillsDirectory: folder, loader: slow)
        let task = Task { try await collect(research) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let id = DocumentationStore.collectionID(seed: root, scope: root, goal: "Implement uploads", version: "2")
        #expect(try research.snapshot(id).pages.first?.status == "pending")
        let resumed = DocumentationStore(skillsDirectory: folder, loader: loader())
        #expect(try await collect(resumed, id: id).complete)
        let linkFolder = folder.appendingPathComponent("linked-skills")
        try FileManager.default.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkFolder.appendingPathComponent(".documentation"), withDestinationURL: folder.appendingPathComponent(".documentation"))
        let unsafe = DocumentationStore(skillsDirectory: linkFolder, loader: loader())
        #expect(throws: (any Error).self) { _ = try unsafe.snapshot(id) }
        let personal = folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("personal")
        try FileManager.default.createSymbolicLink(at: personal, withDestinationURL: folder.deletingLastPathComponent())
        let crossSpaceAlias = DocumentationStore(skillsDirectory: personal.appendingPathComponent("skills"), loader: loader())
        #expect(throws: (any Error).self) { _ = try crossSpaceAlias.snapshot(id) }
    }
}

@Suite("Rendered documentation browser reading", .serialized)
@MainActor
struct DocumentationBrowserTests {
    @Test("Documentation confirmation renders source coverage and verification state in three languages",
           .enabled(if: ProcessInfo.processInfo.environment["AGROOM_DOCUMENTATION_SNAPSHOT_DIR"] != nil))
    func confirmationSnapshots() async throws {
        _ = NSApplication.shared
        let output = try #require(ProcessInfo.processInfo.environment["AGROOM_DOCUMENTATION_SNAPSHOT_DIR"])
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            let source = ToolApprovalPresentation.Documentation(url: "https://manual.test/docs/v2/", scope: "https://manual.test/docs/v2/", version: "2",
                collectedPages: 8, readPages: 8, missingPages: 3, partial: true, skillAlias: "SDKUpload", skillDescription: "Upload files using SDK v2", verificationStepCount: 3)
            let presentation = ToolApprovalPresentation(executionKind: .fileMutation, resourceAccess: .init(verified: true),
                network: .init(allowed: false), childProcesses: .init(allowed: false), reasonCode: "documentation_skill", constraintSources: ["space"], executionDetails: [], documentation: source)
            let pending = PendingConfirmation(messageId: UUID(), toolName: "skill_create", argumentsDisplay: "alias: SDKUpload\ncontent: Upload files using SDK v2",
                requirement: .init(kind: .normal, scope: .tool, presentation: presentation))
            let view = NSHostingView(rootView: ConfirmationCard(pending: pending, onDecision: { _ in })
                .frame(width: 560).padding(16).background(Color(nsColor: .windowBackgroundColor)))
            let height = max(500, view.fittingSize.height)
            #expect(height < 1000)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 592, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(120))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("documentation-\(language.rawValue).png"))
            #expect(!L.string("documentation.confirm.title").hasPrefix("documentation."))
        }
    }

    @Test("Reads rendered long content and code without copying login fields or changing the real DOM")
    func renderedDocument() async throws {
        _ = NSApplication.shared
        let service = BrowserService(space: .work, dataStore: .nonPersistent())
        let tab = service.addTab()
        let longText = String(repeating: "Long developer manual 中文🙂 ", count: 700)
        tab.webView.loadHTMLString("""
            <html><head><title>Rendered SDK</title></head><body>
            <form><input type="password" value="FIXTURE_SECRET"><textarea>PRIVATE_FIELD</textarea></form>
            <main><h1>SDK</h1><p>\(longText)</p><pre><code>def run():\n    return 1\n</code></pre></main>
            <script>var paragraph = document.createElement('p'); paragraph.textContent = 'DYNAMIC_CHAPTER'; document.querySelector('main').appendChild(paragraph);</script>
            </body></html>
            """, baseURL: URL(string: "https://manual.test/docs/v2/"))
        let deadline = Date().addingTimeInterval(15)
        while (tab.webView.isLoading || tab.webView.title != "Rendered SDK") && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let doc = try await service.readDocument(tabId: tab.id)
        #expect(doc.retrieval == "browser")
        #expect(doc.markdown.count > 12_000)
        #expect(doc.markdown.contains("DYNAMIC_CHAPTER"))
        #expect(doc.markdown.contains("    return 1"))
        #expect(!doc.markdown.contains("FIXTURE_SECRET"))
        #expect(!doc.markdown.contains("PRIVATE_FIELD"))
        #expect(try await tab.webView.evaluateJavaScript("document.querySelectorAll('input').length") as? Int == 1)
    }
}
