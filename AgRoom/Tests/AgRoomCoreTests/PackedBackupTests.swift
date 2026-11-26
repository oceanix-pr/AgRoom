import Foundation
import GRDB
import Testing
@testable import AgRoomCore

@Suite("Packed backup contents and recovery", .serialized)
@MainActor
struct PackedBackupTests {
    private struct Stack {
        let root: URL
        let space: AppSpace
        let queue: DatabaseQueue
        let registry: WorkspaceRegistry
        let backup: BackupService
        var store: TaskArtifactStore { .init(databaseQueue: queue, space: space, previewRoot: root.appendingPathComponent("previews")) }
        var sessions: SessionService { .init(databaseQueue: queue) }
    }

    private func stack(_ root: URL, space: AppSpace = .work) throws -> Stack {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("space.sqlite").path)
        try DatabaseBootstrap.prepareSpace(queue)
        let area = FileAreaService(baseDirectory: root.appendingPathComponent("file-area"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"), fileAreaService: area)
        let backup = BackupService(sessionService: .init(databaseQueue: queue), memoryService: .init(databaseQueue: queue),
            skillStore: SkillStore(directoryURL: root.appendingPathComponent("skills")), spaceName: space.rawValue,
            workspacesProvider: { await registry.workspaces(for: space) }, attachmentsDirectory: root.appendingPathComponent("attachments"),
            audioDirectory: root.appendingPathComponent("audio"), fileAreaService: area,
            adoptWorkspaces: { try await registry.adoptRestored($0, in: space) }, removeWorkspaces: { try await registry.removeRestored($0, in: space) })
        return .init(root: root, space: space, queue: queue, registry: registry, backup: backup)
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("packed-backup-" + UUID().uuidString).resolvingSymlinksInPath()
    }

    private func capture(_ data: Data, in stack: Stack, name: String = UUID().uuidString,
                         session: UUID? = nil, run: UUID = UUID()) async throws -> TaskArtifact {
        let workspace = try #require(stack.registry.defaultWorkspace(for: stack.space))
        let file = workspace.url.appendingPathComponent(name + ".bin")
        try data.write(to: file)
        let artifact = try await stack.store.capture(file, root: workspace.url, logicalPath: nil,
            origin: .init(space: stack.space, sessionID: session, runID: run, workspaceID: workspace.id.uuidString, operationID: name, tool: "python_execute"))
        try FileManager.default.removeItem(at: file)
        return artifact
    }

    private func ditto(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func unpack(_ zip: URL, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ditto(["-x", "-k", zip.path, directory.path])
    }

    private func readBackup(_ root: URL) throws -> SpaceDatabaseBackup {
        try JSONDecoder().decode(SpaceDatabaseBackup.self, from: Data(contentsOf: root.appendingPathComponent("space-data.json")))
    }

    private func inline(_ backup: SpaceDatabaseBackup, from contents: SpaceBackupBlobs) throws -> SpaceDatabaseBackup {
        var result = backup
        for table in result.tables.indices {
            for row in result.tables[table].rows.indices {
                result.tables[table].rows[row] = try result.tables[table].rows[row].map { value in
                    if case .blobFile(let ref) = value { return .blob(try contents.read(ref)) }
                    return value
                }
            }
        }
        return result
    }

    @Test("Historical binary outputs exceeding the old JSON budget restore without their originals and undo preserves later results")
    func largeRetainedResults() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"), space: .personal)
        let sessionID = UUID(), runID = UUID(), size = 54 * 1024 * 1024, total = 5
        // Distinct historical contents exceed the former Base64 JSON budget
        // and span multiple binary parts while remaining within package limits.
        #expect(total * ((size + 2) / 3 * 4) > SpaceDatabaseBackupStore.maximumBytes)
        var artifacts: [TaskArtifact] = []
        for index in 0..<total {
            artifacts.append(try await capture(Data(repeating: UInt8(index + 1), count: size), in: source,
                name: "large-\(index)", session: sessionID, run: runID))
        }
        let workspace = try #require(source.registry.defaultWorkspace(for: .work))
        var session = ChatSession(id: sessionID, title: "Binary report", workspaceId: workspace.id.uuidString)
        session.messages = [.init(role: .assistant, content: "Historical outputs", trace: [.init(toolName: "python_execute",
            argumentsPreview: "", resultPreview: "", artifacts: artifacts, duration: 1, succeeded: true)], runStatus: .succeeded)]
        try await source.sessions.save(session)
        let zip = root.appendingPathComponent("large.zip")
        _ = try await source.backup.export(to: zip)
        let extracted = root.appendingPathComponent("extracted"); try unpack(zip, into: extracted)
        let metadata = try Data(contentsOf: extracted.appendingPathComponent("space-data.json"))
        #expect(metadata.count < 1024 * 1024)
        let backup = try readBackup(extracted)
        #expect(backup.blobReferences.count == total)
        let parts = try FileManager.default.contentsOfDirectory(at: extracted.appendingPathComponent("space-blobs"), includingPropertiesForKeys: nil)
        #expect(parts.count == 2)
        #expect(try parts.reduce(0) { $0 + ((try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) } == total * size)
        let inspection = try await target.backup.inspect(from: zip)
        #expect(inspection.spaceMismatch && inspection.corruptSections.isEmpty)
        await #expect(throws: BackupError.self) { _ = try await target.backup.restore(from: zip) }
        let restored = try await target.backup.restore(from: zip, allowCrossSpace: true, expectedFingerprint: inspection.packageFingerprint)
        #expect(restored.verificationSucceeded)
        let records = try await target.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM artifact_versions WHERE length(contents)=?", arguments: [size]) }
        #expect(records == total)
        for (index, artifact) in artifacts.enumerated() {
            let copies = try await target.store.artifacts(runID: runID, operationID: "large-\(index)")
            let copy = try #require(copies.first)
            #expect(copy.versionID == artifact.versionID && copy.sourceSpace == .personal)
            let preview = try await target.store.materialize(copy)
            #expect(try BackupFileIO.receipt(preview.lastPathComponent,
                in: AppDirectory(url: preview.deletingLastPathComponent(), create: false), limit: size).sha256 == artifact.sha256)
            #expect(!FileManager.default.fileExists(atPath: artifact.path))
        }
        let point = try #require(restored.restorePointID)
        let pointRoot = target.root.appendingPathComponent("restore-points/" + point.uuidString.lowercased())
        let recovery = try Data(contentsOf: pointRoot.appendingPathComponent("recovery.json"))
        #expect(recovery.count < 2 * 1024 * 1024)
        let later = try await capture(Data("created after restore".utf8), in: target)
        try await target.backup.undoRestorePoint(id: point)
        #expect(try await target.store.versions(of: later).count == 1)
        #expect(try await target.sessions.fetch(id: sessionID) == nil)
        #expect(try await target.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM artifact_versions") } == 1)
        #expect(try await source.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM artifact_versions") } == total)
    }

    @Test("Many tiny and duplicate results share binary parts; an empty retained output remains distinct from missing contents")
    func smallResultsAndEmptyBlob() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let contents = SpaceBackupBlobs(root: root)
        var refs = Set<SpaceBackupBlobReference>()
        for index in 0..<700 {
            let data = Data("binary result \(index)\u{0}\u{ff}".utf8)
            let ref = try contents.put(data); refs.insert(ref)
            #expect(try contents.put(data) == ref)
        }
        let empty = try contents.put(Data()); refs.insert(empty)
        try contents.validateInventory(refs)
        #expect(try contents.read(empty).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let artifact = try await capture(Data(), in: source)
        let zip = root.appendingPathComponent("empty.zip"); _ = try await source.backup.export(to: zip)
        _ = try await target.backup.restore(from: zip)
        let loaded = try #require(try await target.store.versions(of: artifact).first?.artifact)
        #expect(loaded.contentRetained == true)
        let preview = try await target.store.materialize(loaded)
        #expect(try Data(contentsOf: preview).isEmpty)
    }

    @Test("Malformed, missing, linked and unreferenced binary ranges are rejected", arguments: ["missing", "modified", "short", "symlink", "hardlink", "extra-file", "extra-bytes", "overlap", "gap", "negative", "overflow", "bad-sha"])
    func unsafeContents(_ kind: String) throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let contents = SpaceBackupBlobs(root: root.appendingPathComponent("contents"))
        let a = try contents.put(Data("abcd".utf8)), b = try contents.put(Data("efgh".utf8))
        var refs: Set<SpaceBackupBlobReference> = [a, b]
        let file = contents.root.appendingPathComponent(a.fileName)
        switch kind {
        case "missing": try FileManager.default.removeItem(at: file)
        case "modified": try Data("abcdefgh".uppercased().utf8).write(to: file)
        case "short": try Data("abc".utf8).write(to: file)
        case "symlink", "hardlink":
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: file, to: outside)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside) }
            else { try FileManager.default.linkItem(at: outside, to: file) }
        case "extra-file": try Data().write(to: contents.root.appendingPathComponent("unexpected.bin"))
        case "extra-bytes": try Data("abcdefghi".utf8).write(to: file)
        case "overlap": refs = [a, .init(sha256: a.sha256, byteCount: 4, part: a.part, offset: 0), .init(sha256: b.sha256, byteCount: 4, part: a.part, offset: 2)]
        case "gap": refs = [a]
        case "negative": refs = [.init(sha256: a.sha256, byteCount: -1, part: a.part, offset: 0)]
        case "overflow": refs = [.init(sha256: a.sha256, byteCount: Int.max, part: a.part, offset: Int.max)]
        default: refs = [.init(sha256: "../invalid", byteCount: 4, part: a.part, offset: 0)]
        }
        #expect(throws: (any Error).self) { try contents.validateInventory(refs) }
    }

    @Test("Portable references are limited to artifact contents; transient fingerprints and false retained values cannot be imported")
    func invalidPortableCells() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        _ = try await capture(Data("trusted binary".utf8), in: source)
        let contents = SpaceBackupBlobs(root: root.appendingPathComponent("contents"))
        let original = try await SpaceDatabaseBackupStore(queue: source.queue, space: "work", blobs: contents).export()
        let index = try #require(original.tables.firstIndex { $0.name == "artifact_versions" })
        let table = original.tables[index], content = try #require(table.columns.firstIndex(of: "contents"))
        let ref = try #require(original.blobReferences.first)
        let store = SpaceDatabaseBackupStore(queue: target.queue, space: "work", blobs: contents)
        for column in ["id", "path", "metadata"] {
            var bad = original; bad.tables[index].rows[0][try #require(table.columns.firstIndex(of: column))] = .blobFile(ref)
            let rejected = bad
            await #expect(throws: (any Error).self) { _ = try await store.plan(rejected, sourceSpace: "work") }
        }
        for value in [SpaceBackupValue.blobFingerprint(sha256: ref.sha256, byteCount: ref.byteCount), .integer(1), .text("not binary")] {
            var bad = original; bad.tables[index].rows[0][content] = value
            let rejected = bad
            await #expect(throws: (any Error).self) { _ = try await store.plan(rejected, sourceSpace: "work") }
        }
        let metadata = try #require(table.columns.firstIndex(of: "metadata"))
        guard case .blob(let encoded) = table.rows[0][metadata] else { Issue.record("Missing test metadata"); return }
        var removed = try TaskArtifactStore.decode(encoded, space: .work)
        removed.artifact.contentRetained = false; removed.artifact.retentionReason = .removedByUser
        var malformedRemoval = original
        malformedRemoval.tables[index].rows[0][metadata] = .blob(try JSONEncoder().encode(removed))
        malformedRemoval.tables[index].rows[0][content] = .integer(1)
        let rejectedRemoval = malformedRemoval
        await #expect(throws: (any Error).self) { _ = try await store.plan(rejectedRemoval, sourceSpace: "work") }
        #expect(try await target.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM artifact_versions") } == 0)
    }

    @Test("A package with recomputed section checksums still cannot import an invalid binary range")
    func forgedPackageReference() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        _ = try await capture(Data("binary evidence".utf8), in: source)
        let old = try await capture(Data("destination remains intact".utf8), in: target)
        let zip = root.appendingPathComponent("original.zip"); _ = try await source.backup.export(to: zip)
        let extracted = root.appendingPathComponent("extracted"); try unpack(zip, into: extracted)
        var backup = try readBackup(extracted)
        let index = try #require(backup.tables.firstIndex { $0.name == "artifact_versions" })
        let column = try #require(backup.tables[index].columns.firstIndex(of: "contents"))
        let ref = try #require(backup.blobReferences.first)
        backup.tables[index].rows[0][column] = .blobFile(.init(sha256: ref.sha256, byteCount: ref.byteCount, part: ref.part, offset: 1))
        let bytes = try JSONEncoder().encode(backup)
        try bytes.write(to: extracted.appendingPathComponent("space-data.json"))
        let manifestURL = extracted.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var sections = try #require(manifest["sections"] as? [[String: Any]])
        let section = try #require(sections.firstIndex { $0["path"] as? String == "space-data.json" })
        sections[section]["sha256"] = SpaceBackupBlobs.digest(bytes); sections[section]["byteCount"] = bytes.count
        manifest["sections"] = sections
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let forged = root.appendingPathComponent("forged.zip"); try ditto(["-c", "-k", extracted.path, forged.path])
        await #expect(throws: (any Error).self) { _ = try await target.backup.inspect(from: forged) }
        await #expect(throws: (any Error).self) { _ = try await target.backup.restore(from: forged) }
        #expect(try await target.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM artifact_versions") } == 1)
        #expect(try await target.store.versions(of: old).count == 1)
        #expect(try await target.backup.restorePoints().isEmpty)
    }

    @Test("A failed commit journal leaves binary database rows unchanged and its durable receipt can safely recover after restart")
    func journalFailureWithContentFiles() async throws {
        enum Injected: Error { case journal }
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let old = try await capture(Data("original historical output".utf8), in: target)
        let incoming = try await capture(Data(repeating: 42, count: 128 * 1024), in: source)
        let sourceBlobs = SpaceBackupBlobs(root: root.appendingPathComponent("source-blobs"))
        let archive = try await SpaceDatabaseBackupStore(queue: source.queue, space: "work", blobs: sourceBlobs).export()
        let recovery = root.appendingPathComponent("recovery"), contentsRoot = recovery.appendingPathComponent("database-blobs")
        let contents = SpaceBackupBlobs(root: contentsRoot)
        let frozen = try archive.replacingBlobReferences(contents.copy(archive.blobReferences, from: sourceBlobs))
        let store = SpaceDatabaseBackupStore(queue: target.queue, space: "work", blobs: contents)
        let plan = try await store.plan(frozen, sourceSpace: "work")
        let journal = recovery.appendingPathComponent("plan.json")
        await #expect(throws: Injected.self) {
            _ = try await store.apply(plan) { observed in
                try JSONEncoder().encode(observed).write(to: journal, options: .atomic)
                throw Injected.journal
            }
        }
        #expect(try await target.store.versions(of: incoming).isEmpty)
        let later = try await capture(Data("created after failed commit".utf8), in: target)
        let reopened = SpaceDatabaseBackupStore(queue: target.queue, space: "work", blobs: .init(root: contentsRoot))
        let durable = try JSONDecoder().decode(SpaceDatabaseRestorePlan.self, from: Data(contentsOf: journal))
        #expect(durable.after?.count("artifact_versions") == 2)
        try await reopened.rollback(durable)
        #expect(try await target.store.versions(of: old).count == 1)
        #expect(try await target.store.versions(of: later).count == 1)
        #expect(try await target.store.versions(of: incoming).isEmpty)
    }

    @Test("Version-five inline archives and legacy inline recovery points upgrade without losing timestamp precision")
    func legacyArchiveAndRecovery() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let oldArtifact = try await capture(Data(repeating: 7, count: 128 * 1024), in: target)
        let newArtifact = try await capture(Data(repeating: 9, count: 128 * 1024), in: source)
        let zip = root.appendingPathComponent("current.zip"); _ = try await source.backup.export(to: zip)
        let extracted = root.appendingPathComponent("extracted"); try unpack(zip, into: extracted)
        let oldBackup = try inline(readBackup(extracted), from: .init(root: extracted.appendingPathComponent("space-blobs")))
        let bytes = try JSONEncoder().encode(oldBackup)
        try bytes.write(to: extracted.appendingPathComponent("space-data.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(BackupManifest.self, from: Data(contentsOf: extracted.appendingPathComponent("manifest.json")))
        let sections = current.sections?.filter { $0.path != "space-blobs" }.map { section in
            section.path == "space-data.json" ? BackupManifest.Section(path: section.path, count: oldBackup.recordCount,
                byteCount: bytes.count, sha256: SpaceBackupBlobs.digest(bytes)) : section
        }
        let legacy = BackupManifest(formatVersion: 5, appVersion: current.appVersion, space: current.space, createdAt: current.createdAt,
            sessionCount: current.sessionCount, memoryCount: current.memoryCount, skillCount: current.skillCount, sections: sections, coverage: current.coverage)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: extracted.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: extracted.appendingPathComponent("space-blobs"))
        let oldZip = root.appendingPathComponent("legacy.zip"); try ditto(["-c", "-k", extracted.path, oldZip.path])
        #expect(try await target.backup.inspect(from: oldZip).corruptSections.isEmpty)
        let result = try await target.backup.restore(from: oldZip)
        let id = try #require(result.restorePointID)
        let point = target.root.appendingPathComponent("restore-points/" + id.uuidString.lowercased())
        let journal = point.appendingPathComponent("recovery.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        let database = try #require(object["database"])
        var plan = try JSONDecoder().decode(SpaceDatabaseRestorePlan.self, from: JSONSerialization.data(withJSONObject: database))
        let contents = SpaceBackupBlobs(root: point.appendingPathComponent("database-blobs"))
        plan = .init(before: try inline(plan.before, from: contents), incoming: try inline(plan.incoming, from: contents),
            after: try plan.after.map { try inline($0, from: contents) }, preservedDeliveryDrafts: plan.preservedDeliveryDrafts)
        object["database"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
        try JSONSerialization.data(withJSONObject: object).write(to: journal, options: .atomic)
        try FileManager.default.removeItem(at: contents.root)
        let listed = try await target.backup.restorePoints()
        #expect(listed.first?.id == id)
        let updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        let rewritten = try JSONDecoder().decode(SpaceDatabaseRestorePlan.self,
            from: JSONSerialization.data(withJSONObject: #require(updated["database"])))
        #expect(!rewritten.before.blobReferences.isEmpty && !rewritten.incoming.blobReferences.isEmpty)
        try await target.backup.undoRestorePoint(id: id)
        let oldPreview = try await target.store.materialize(oldArtifact)
        #expect(try Data(contentsOf: oldPreview) == Data(repeating: 7, count: 128 * 1024))
        #expect(try await target.store.versions(of: oldArtifact).first?.artifact.createdAt == oldArtifact.createdAt)
        #expect(try await target.store.versions(of: newArtifact).isEmpty)
    }

    @Test("Task cancellation before or after database publication completes rollback under the original maintenance lease", arguments: [0.4, 0.6])
    func cancelledRestore(_ threshold: Double) async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let before = try await capture(Data("destination historical bytes".utf8), in: target)
        let imported = try await capture(Data("incoming historical bytes".utf8), in: source)
        var session = ChatSession(title: "Cancel after publication")
        session.messages = [.init(role: .assistant, content: "Incoming", runStatus: .succeeded)]
        try await source.sessions.save(session)
        let zip = root.appendingPathComponent("cancel.zip"); _ = try await source.backup.export(to: zip)
        let backup = target.backup
        let task = Task {
            try await backup.restore(from: zip, progress: { value in
                if value >= threshold { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; Issue.record("A cancelled restore cannot report success") }
        catch let error as BackupError { guard case .rolledBack = error else { Issue.record("Rollback did not finish: \(error)"); return } }
        #expect(try await target.sessions.fetch(id: session.id) == nil)
        #expect(try await target.store.versions(of: imported).isEmpty)
        let preview = try await target.store.materialize(before)
        #expect(try String(contentsOf: preview, encoding: .utf8) == "destination historical bytes")
        #expect(!FileManager.default.fileExists(atPath: target.root.appendingPathComponent("backup-restore-recovery").path))
        #expect(try await target.backup.restorePoints().isEmpty)
    }

    @Test("Cancellation is observed across database queue hops, and cancelled exports preserve the existing archive")
    func cancelledExportAndQueueRead() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source"))
        _ = try await capture(Data("retained result".utf8), in: source)
        let gate = CancellationGate(), contentsRoot = root.appendingPathComponent("contents")
        let store = SpaceDatabaseBackupStore(queue: source.queue, space: "work", blobs: .init(root: contentsRoot, cancellation: gate))
        gate.markCancelled()
        await #expect(throws: CancellationError.self) { _ = try await store.export() }
        #expect(!FileManager.default.fileExists(atPath: contentsRoot.path))
        let zip = root.appendingPathComponent("existing.zip"), oldBytes = Data("existing backup must survive".utf8)
        try oldBytes.write(to: zip)
        let backup = source.backup
        let task = Task { try await backup.export(to: zip, progress: { value in
            if value >= 0.35 { withUnsafeCurrentTask { $0?.cancel() } }
        }) }
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(try Data(contentsOf: zip) == oldBytes)
    }

    @Test("Trigger-deleted historical results are restored from the durable after-image while unrelated later results survive")
    func triggerHistoryAndChangedAfterImage() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let old = try await capture(Data(repeating: 3, count: 128 * 1024), in: target)
        let oldID = try #require(old.versionID).uuidString
        let item = KnowledgeItem(title: "Imported knowledge", content: "activates a destination trigger")
        try await KnowledgeService(databaseQueue: source.queue).save(item)
        try await target.queue.write { db in
            // Trigger text is test-owned SQL, never supplied by an archive.
            try db.execute(sql: "CREATE TRIGGER erase_history AFTER INSERT ON knowledge_items BEGIN DELETE FROM artifact_versions WHERE id='\(oldID)'; END")
        }
        let sourceContents = SpaceBackupBlobs(root: root.appendingPathComponent("source-blobs"))
        let archive = try await SpaceDatabaseBackupStore(queue: source.queue, space: "work", blobs: sourceContents).export()
        let recovery = root.appendingPathComponent("recovery")
        let blobs = SpaceBackupBlobs(root: recovery.appendingPathComponent("database-blobs"))
        let store = SpaceDatabaseBackupStore(queue: target.queue, space: "work", blobs: blobs)
        let plan = try await store.plan(archive, sourceSpace: "work")
        let journal = recovery.appendingPathComponent("plan.json")
        _ = try await store.apply(plan) { try JSONEncoder().encode($0).write(to: journal, options: .atomic) }
        #expect(try await target.store.versions(of: old).isEmpty)
        let later = try await capture(Data("unrelated later output".utf8), in: target)
        let moved = root.appendingPathComponent("moved-recovery")
        try FileManager.default.moveItem(at: recovery, to: moved)
        let durable = try JSONDecoder().decode(SpaceDatabaseRestorePlan.self, from: Data(contentsOf: moved.appendingPathComponent("plan.json")))
        let reopened = SpaceDatabaseBackupStore(queue: target.queue, space: "work", blobs: .init(root: moved.appendingPathComponent("database-blobs")))
        try await reopened.verify(durable)
        try await reopened.rollback(durable)
        #expect(try await target.store.versions(of: later).count == 1)
        let preview = try await target.store.materialize(old)
        #expect(try Data(contentsOf: preview) == Data(repeating: 3, count: 128 * 1024))
        #expect(try await KnowledgeService(databaseQueue: target.queue).get(id: item.id) == nil)
    }

    @Test("Corrupted private recovery bytes prevent undo before changing restored user data")
    func corruptRecoveryPreflight() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try stack(root.appendingPathComponent("source")), target = try stack(root.appendingPathComponent("target"))
        let old = try await capture(Data("old bytes".utf8), in: target)
        let new = try await capture(Data("new bytes".utf8), in: source)
        let zip = root.appendingPathComponent("restore.zip"); _ = try await source.backup.export(to: zip)
        let restored = try await target.backup.restore(from: zip), id = try #require(restored.restorePointID)
        let point = target.root.appendingPathComponent("restore-points/" + id.uuidString.lowercased())
        let contents = point.appendingPathComponent("database-blobs")
        let file = try #require(FileManager.default.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil).first)
        try Data("corrupted".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await target.backup.undoRestorePoint(id: id) }
        #expect(try await target.store.versions(of: old).count == 1)
        #expect(try await target.store.versions(of: new).count == 1)
        #expect(FileManager.default.fileExists(atPath: point.appendingPathComponent("recovery.json").path))
        #expect(!FileManager.default.fileExists(atPath: target.root.appendingPathComponent("backup-restore-recovery").path))
    }
}
