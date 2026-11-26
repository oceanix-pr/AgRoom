import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Conversation workspace folders")
struct ConversationWorkspaceScopeTests {
    private struct Fixture {
        let directory: URL
        let area: FileAreaService
        let primary: URL
        let reference: URL
        let other: URL
        var roots: [URL] { [primary, reference] }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-folders-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let area = FileAreaService(baseDirectory: directory.appendingPathComponent("area"))
        try area.ensureRoots()
        let primary = area.filesRoot.appendingPathComponent("A", isDirectory: true)
        let reference = directory.appendingPathComponent("shared", isDirectory: true)
        let other = area.filesRoot.appendingPathComponent("Memonta", isDirectory: true)
        for folder in [primary, reference, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try folder.lastPathComponent.write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        }
        return Fixture(directory: directory, area: area, primary: primary, reference: reference, other: other)
    }

    private func arguments(_ path: URL) throws -> String { try MCPJSON.string(["path": path.path]) }

    @Test("A conversation reads its referenced folders and cannot read another registered workspace")
    func fileToolsEnforceScope() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let service = f.area.merging(additionalRoots: [f.other]).scoped(to: f.roots)
        let read = FilesReadTool(service: service)
        let list = FilesListTool(service: service)
        for folder in f.roots {
            #expect(try await read.execute(argumentsJSON: arguments(folder.appendingPathComponent("note.txt"))).contains(folder.lastPathComponent))
        }
        #expect(try await list.execute(argumentsJSON: "{}").contains(f.primary.path))
        await #expect(throws: FileAreaService.AreaError.unsafePath) {
            try await read.execute(argumentsJSON: arguments(f.other.appendingPathComponent("note.txt")))
        }
        await #expect(throws: FileAreaService.AreaError.unsafePath) {
            try await list.execute(argumentsJSON: arguments(f.area.filesRoot))
        }
        #expect(!read.definition.description.contains(f.other.path))
        #expect(!list.definition.description.contains(f.other.path))
        #expect(throws: FileAreaService.AreaError.unsafePath) {
            try service.merging(additionalRoots: [f.other]).resolveManaged(f.other.path)
        }
        let policy = FileAreaPolicy(service: service, space: .work, defaultWriteRoots: f.roots, spaceWriteRoots: f.roots)
        #expect(policy.writeViolation(targets: [f.reference.appendingPathComponent("new.txt").path]) == nil)
        #expect(policy.writeViolation(targets: [f.other.appendingPathComponent("new.txt").path]) != nil)
        let prompt = DispatcherToolFactory.buildSystemPrompt(agents: [], skills: [], memories: [], spaceName: "work",
            fileAreaService: service, conversationWorkspacePath: f.primary.path)
        #expect(prompt.contains(f.reference.path))
        #expect(!prompt.contains(f.other.path))
    }

    @Test("Symlinks and replaced referenced directories do not expand an existing turn's access")
    func symlinksAndReplacement() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let service = f.area.scoped(to: f.roots)
        let link = f.primary.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.other)
        #expect(throws: FileAreaService.AreaError.unsafePath) {
            try service.resolveManaged(link.appendingPathComponent("note.txt").path)
        }
        try FileManager.default.moveItem(at: f.reference, to: f.directory.appendingPathComponent("old-shared"))
        try FileManager.default.createDirectory(at: f.reference, withIntermediateDirectories: true)
        #expect(throws: FileAreaService.AreaError.unsafePath) { try service.resolveManaged(f.reference.path) }
    }

    @Test("Explicit attachments get workspace copies without making their original folder readable")
    func attachedFilesStayReadable() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let service = f.area.scoped(to: [f.primary])
        let repository = try RepositoryReader(root: f.primary, service: service, space: .work)
        let revision = try repository.revision()
        let source = f.other.appendingPathComponent("note.txt")
        let replacements = try AttachmentService.stageForConversation([source], service: service)
        let path = try #require(replacements[source.path])
        #expect(FileAreaService.isInside(URL(fileURLWithPath: path), root: f.primary))
        #expect(try await FilesReadTool(service: service).execute(argumentsJSON: MCPJSON.string(["path": path])).contains("Memonta"))
        #expect(throws: FileAreaService.AreaError.unsafePath) { try service.resolveManaged(source.path) }
        #expect(try repository.revision() == revision)
    }

    @Test("Media and shell tools cannot provide alternate access to an unreferenced folder")
    func alternateToolsEnforceScope() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let service = f.area.scoped(to: f.roots)
        let path = try arguments(f.other.appendingPathComponent("note.txt"))
        await #expect(throws: FileAreaService.AreaError.unsafePath) { try await OCRTool(fileAreaService: service).execute(argumentsJSON: path) }
        await #expect(throws: FileAreaService.AreaError.unsafePath) { try await TranscribeAudioTool(fileAreaService: service).execute(argumentsJSON: path) }
        let shell = ShellRunTool(defaultWorkingDirectory: f.primary.path, workspaceRoot: f.primary.path,
            space: .work, fileAreaService: service)
        let outside = try MCPJSON.string(["program": "/bin/ls", "arguments": [], "working_directory": f.other.path] as [String: Any])
        await #expect(throws: FileAreaService.AreaError.unsafePath) { try await shell.execute(argumentsJSON: outside) }
        let host = try MCPJSON.string(["script": "/bin/ls", "execution_mode": "host"])
        await #expect(throws: ToolExecutionFailure.self) { try await shell.execute(argumentsJSON: host) }
    }

    @MainActor
    @Test("References persist for one workspace and do not become another workspace's implicit roots")
    func registryReferences() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let file = f.directory.appendingPathComponent("workspaces.json")
        let a = ChatWorkspace(name: "A", path: f.primary.path, space: .work)
        let b = ChatWorkspace(name: "Memonta", path: f.other.path, space: .work)
        try JSONEncoder().encode([a, b]).write(to: file)
        let bookmarks = WorkspaceAccessCoordinator.Bookmarks(create: { Data($0.path.utf8) }, resolve: {
            (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false)
        })
        let coordinator = WorkspaceAccessCoordinator(root: f.directory, bookmarks: bookmarks)
        let registry = WorkspaceRegistry(fileURL: file, fileAreaService: f.area, accessCoordinator: coordinator)
        try registry.addReferencedFolders([f.reference, f.reference], to: a.id, in: .work)
        let current = try registry.requireAccess(to: a.path, in: .work, workspaceID: a.id)
        #expect(current.referencedFolders.count == 1)
        #expect(current.folderURLs == f.roots)
        #expect(try registry.requireAccess(to: b.path, in: .work, workspaceID: b.id).folderURLs == [f.other])
        #expect(throws: WorkspaceRegistry.WorkspaceError.self) { try registry.requireAccess(to: b.path, in: .work, workspaceID: a.id) }
        #expect(throws: WorkspaceRegistry.WorkspaceError.self) { try registry.requireAccess(to: a.path, in: .personal, workspaceID: a.id) }
        let reloaded = WorkspaceRegistry(fileURL: file, fileAreaService: f.area,
            accessCoordinator: WorkspaceAccessCoordinator(root: f.directory, bookmarks: bookmarks))
        #expect(try reloaded.requireAccess(to: a.path, in: .work, workspaceID: a.id).folderURLs == f.roots)
        let reference = try #require(current.referencedFolders.first)
        try registry.removeReferencedFolder(reference.id, from: a.id, in: .work)
        #expect(try registry.requireAccess(to: a.path, in: .work, workspaceID: a.id).folderURLs == [f.primary])
        #expect(FileManager.default.fileExists(atPath: f.reference.path))
        #expect(throws: WorkspaceRegistry.WorkspaceError.self) {
            try registry.addReferencedFolders([f.area.defaultChatRoot(for: .personal)], to: a.id, in: .work)
        }
    }
}

@Suite("Conversation MCP visibility")
struct ConversationMCPVisibilityTests {
    private func config() throws -> MCPServerConfig {
        var config = MCPServerConfig(name: "Memonta", endpoint: "http://127.0.0.1:42817/mcp")
        config.tools = [try MCPToolDescriptor(name: "list_entries", description: "List meetings", inputSchemaJSON: #"{"type":"object"}"#)]
        return config
    }

    @Test("An enabled service with no selected tools remains visible but supplies no tools to the model")
    func emptySelectionAndSnapshot() async throws {
        let queue = try DatabaseQueue()
        try await queue.write { try MCPServerConfigService.createSchema($0) }
        let service = MCPServerConfigService(databaseQueue: queue, space: .work)
        var config = try await service.save(config(), creating: true)
        let empty = try await MCPToolFactory.build(service: service, existingNames: [])
        let summary = MCPServerToolSummary(config: config)
        #expect(empty.isEmpty)
        #expect(summary.availability(of: summary.tools[0], exposedNames: [], mode: .workspaceWrite) == .notSelected)
        config.selectedToolNames = ["list_entries"]
        config = try await service.save(config)
        let tools = try await MCPToolFactory.build(service: service, existingNames: [])
        let engine = DispatcherEngine(tools: tools, systemPrompt: "", permissionPolicy: PermissionPolicy(mode: .workspaceWrite, fileAreaPolicy: nil),
            mcpServers: [MCPServerToolSummary(config: config)])
        let report = engine.requestReport
        #expect(report.mcpToolNames == tools.map { $0.definition.name })
        #expect(report.permissionMode == .workspaceWrite)
        let encoded = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(RequestContextReport.self, from: encoded) == report)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("credentialID"))
        #expect(!text.contains("inputSchema"))
        #expect(!text.contains("authentication"))
    }

    @Test("The panel distinguishes read-only blocks, skill filtering and settings changed after a turn starts")
    func availabilityReasons() throws {
        var config = try config()
        config.selectedToolNames = ["list_entries"]
        let summary = MCPServerToolSummary(config: config)
        let tool = summary.tools[0]
        #expect(summary.availability(of: tool, exposedNames: [tool.id], mode: .workspaceWrite) == .available)
        #expect(summary.availability(of: tool, exposedNames: [tool.id], mode: .readOnly) == .readOnlyBlocked)
        #expect(summary.availability(of: tool, exposedNames: [], mode: .workspaceWrite) == .notLoaded)
        config.revision = UUID()
        #expect(summary.availability(of: tool, exposedNames: [tool.id], mode: .workspaceWrite,
            configuredServers: [MCPServerToolSummary(config: config)]) == .configurationChanged)
        config.isEnabled = false
        let disabled = MCPServerToolSummary(config: config)
        #expect(disabled.availability(of: disabled.tools[0], exposedNames: nil, mode: .workspaceWrite) == .serverDisabled)
    }

    @MainActor
    @Test("Folder and MCP availability explanations have translations in each supported language")
    func localization() {
        let previous = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previous }
        let keys = ["workspace.folders.title", "workspace.folders.scope", "workspace.folders.busy", "workspace.folders.primary",
            "workspace.folders.add", "workspace.folders.remove", "workspace.folders.choose", "mcp.enabled.empty", "mcp.enabled.empty.short",
            "chat.mcp.title", "chat.mcp.available.count", "chat.mcp.scope", "chat.mcp.current_tab", "chat.mcp.last_tab", "chat.mcp.next_tab",
            "chat.mcp.preview", "chat.mcp.current", "chat.mcp.last", "chat.mcp.empty", "chat.mcp.read_only", "chat.mcp.none_selected",
            "chat.mcp.changed", "chat.mcp.next_turn"]
            + ["available", "serverDisabled", "notSelected", "readOnlyBlocked", "notLoaded", "configurationChanged"].map { "chat.mcp.status." + $0 }
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            LanguageManager.shared.currentLanguage = language
            for key in keys { #expect(L.string(key) != key) }
        }
    }
}
