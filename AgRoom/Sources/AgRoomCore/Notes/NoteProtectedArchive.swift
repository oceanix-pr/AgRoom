import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

/// Compatible Memonta v1 password archive: PBKDF2-HMAC-SHA256 and authenticated
/// 1 MiB AES-GCM chunks. Device keys, bookmarks and API credentials never enter it.
public enum NoteProtectedArchive {
    static let chunkSize = 1_048_576
    static let rounds: UInt32 = 600_000
    struct Header: Codable { let version: Int; let salt: Data; let iterations: UInt32 }
    struct File: Codable { let path: String; let chunks: [String]; let bytes: Int; let encryptedText: Bool }
    struct Manifest: Codable { let version: Int; let created: Date; let files: [File]; let skipped: Int }
    private struct Native: Codable { let note: WorkNote; let mediaNames: [UUID: String]; var displayNames: [UUID: String]?; var visual: NoteFilePackage.IndexVisual? }
    private static let textNames: Set<String> = ["source.txt", "ocr.txt", "summary.md", "visual.md", "transcript.json", "todos.json"]
    static func key(password: String, salt: Data) throws -> SymmetricKey {
        guard password.count >= 12, password.utf8.count <= 4096, salt.count == 16 else { throw NoteStoreError.invalidContent }
        let input = Array(password.utf8)
        var result = [UInt8](repeating: 0, count: 32)
        let status = input.withUnsafeBytes { input in salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self), input.count,
                salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &result, 32)
        } }
        guard status == kCCSuccess else { throw NoteStoreError.invalidContent }
        return SymmetricKey(data: result)
    }
    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return (2...8).contains(parts.count) && path.utf8.count < 2048 && parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && !part.contains("\\") && !part.contains(":") && !part.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }
    public static func export(_ package: NotePackage, to destination: URL, password: String) throws {
        try package.validate()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw NoteStoreError.conflict }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else { throw NoteStoreError.invalidContent }
        let key = try key(password: password, salt: salt)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".protected-note-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyyMMddHHmmss"
        let folder = formatter.string(from: package.note.createdAt)
        var files: [File] = []
        var totalBytes = 0
        func store(_ data: Data, name: String) throws {
            totalBytes += data.count
            guard totalBytes <= NotePackage.maximumBytes, data.count <= NoteStore.maximumMediaBytes else { throw NoteStoreError.tooLarge }
            let path = folder + "/" + name
            guard safePath(path) else { throw NoteStoreError.invalidContent }
            var chunks: [String] = []
            for offset in stride(from: 0, to: data.count, by: chunkSize) {
                try Task.checkCancellation()
                let part = data.subdata(in: offset..<min(offset + chunkSize, data.count)), file = UUID().uuidString + ".bin"
                let sealed = try AES.GCM.seal(part, using: key, authenticating: Data("\(path)#\(chunks.count)".utf8))
                guard let combined = sealed.combined else { throw NoteStoreError.invalidContent }
                try combined.write(to: staging.appendingPathComponent(file), options: .atomic); chunks.append(file)
            }
            files.append(.init(path: path, chunks: chunks, bytes: data.count, encryptedText: textNames.contains(name) || name.hasPrefix("summary-history/")))
        }
        let metadata: [String: Any] = ["id": package.note.id.uuidString, "title": package.note.title, "isHidden": package.note.archived,
            "itemType": package.note.transcript.isEmpty ? "quicknote" : "recording"]
        try store(JSONSerialization.data(withJSONObject: metadata), name: "meta.json")
        try store(Data(package.note.text.utf8), name: "source.txt")
        if let summary = package.note.summaries.last { try store(Data(summary.text.utf8), name: "summary.md") }
        for summary in package.note.summaries.dropLast() {
            try store(JSONEncoder().encode(summary), name: "summary-history/" + summary.id.uuidString + ".json")
        }
        let segments: [[String: Any]] = package.note.segments.map { ["startTime": $0.timestamp, "endTime": $0.timestamp + 3, "text": $0.text, "speaker": $0.speaker] }
        if !segments.isEmpty { try store(JSONSerialization.data(withJSONObject: segments), name: "transcript.json") }
        let todos: [[String: Any]] = package.note.todos.map { todo in
            var value: [String: Any] = ["id": todo.id.uuidString, "title": todo.title, "priority": [1:"high",5:"medium",9:"low"][todo.priority ?? 0] ?? "none", "status": "pending", "isUserConfirmed": false]
            if let notes = todo.notes { value["notes"] = notes }
            if let owner = todo.owner { value["owner"] = owner }
            if let url = todo.url { value["url"] = url }
            if let evidence = todo.evidenceQuote { value["evidenceQuote"] = evidence }
            if let alarm = todo.alarmOffsetMinutes { value["alarmOffsetMinutes"] = alarm }
            if let date = todo.dueDate { value["dueDate"] = date.timeIntervalSinceReferenceDate }; return value
        }
        try store(JSONSerialization.data(withJSONObject: ["source": "quicknote", "model": "", "generatedAt": Date().timeIntervalSinceReferenceDate, "items": todos]), name: "todos.json")
        var names: [UUID: String] = [:]
        for media in package.media {
            let ext = URL(fileURLWithPath: media.name).pathExtension.lowercased()
            guard ["m4a", "wav", "mp3", "aac", "caf", "flac", "ogg", "mp4", "mov", "png", "jpg", "jpeg", "heic", "webp", "m4v", "txt", "md", "json", "srt", "vtt"].contains(ext) else { throw NoteStoreError.invalidContent }
            let file = media.id.uuidString + "." + (ext == "m4v" ? "mp4" : ext); names[media.id] = file
            try store(media.data, name: file)
        }
        try store(JSONEncoder().encode(Native(note: package.note, mediaNames: names, displayNames: Dictionary(uniqueKeysWithValues: package.media.map { ($0.id, $0.name) }))), name: "agroom-note.json")
        let manifest = Manifest(version: 1, created: Date(), files: files, skipped: 0)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(manifest), using: key, authenticating: Data("Memonta-backup-v1".utf8))
        guard let bytes = sealed.combined else { throw NoteStoreError.invalidContent }
        try bytes.write(to: staging.appendingPathComponent("manifest.bin"), options: .atomic)
        try JSONEncoder().encode(Header(version: 1, salt: salt, iterations: rounds)).write(to: staging.appendingPathComponent("header.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
    }
    public static func preview(from archive: URL, password: String) throws -> [NotePackage] {
        try NoteCaptureRecovery.regularDirectory(archive)
        let header = try JSONDecoder().decode(Header.self, from: NoteCaptureRecovery.read(archive.appendingPathComponent("header.json"), maximum: 4096))
        guard header.version == 1, header.iterations == rounds else { throw NoteStoreError.invalidContent }
        let key = try key(password: password, salt: header.salt)
        let sealed = try NoteCaptureRecovery.read(archive.appendingPathComponent("manifest.bin"), maximum: 32 * 1024 * 1024)
        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data("Memonta-backup-v1".utf8))
        let manifest = try JSONDecoder().decode(Manifest.self, from: decoded)
        guard manifest.version == 1, !manifest.files.isEmpty, manifest.files.count <= 10_000 else { throw NoteStoreError.tooLarge }
        var paths = Set<String>(), chunks = Set<String>(), total = 0
        for file in manifest.files {
            guard safePath(file.path), paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  file.bytes >= 0, file.bytes <= NoteStore.maximumMediaBytes,
                  file.chunks.count == (file.bytes + chunkSize - 1) / chunkSize else { throw NoteStoreError.invalidContent }
            total += file.bytes; guard total <= NotePackage.maximumBytes else { throw NoteStoreError.tooLarge }
            for chunk in file.chunks {
                guard chunk.hasSuffix(".bin"), UUID(uuidString: String(chunk.dropLast(4))) != nil, chunks.insert(chunk).inserted else { throw NoteStoreError.invalidContent }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var entries = Set<URL>()
        for file in manifest.files {
            try Task.checkCancellation()
            let target = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NoteStoreError.invalidContent }
            let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
            var written = 0
            for (index, chunk) in file.chunks.enumerated() {
                let sealed = try NoteCaptureRecovery.read(archive.appendingPathComponent(chunk), maximum: chunkSize + 28)
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data("\(file.path)#\(index)".utf8))
                guard data.count == min(chunkSize, file.bytes - written) else { throw NoteStoreError.invalidContent }
                try handle.write(contentsOf: data); written += data.count
            }
            try handle.close()
            if target.lastPathComponent == "meta.json" { entries.insert(target.deletingLastPathComponent()) }
        }
        guard !entries.isEmpty, entries.count <= 200 else { throw NoteStoreError.invalidContent }
        return try entries.sorted(by: { $0.path < $1.path }).map { directory in
            let metadata = directory.appendingPathComponent("agroom-note.json")
            if FileManager.default.fileExists(atPath: metadata.path) {
                let native = try JSONDecoder().decode(Native.self, from: NoteCaptureRecovery.read(metadata, maximum: 8 * 1024 * 1024))
                let media = try native.mediaNames.map { id, file -> NotePackage.Media in
                    guard file == id.uuidString + "." + URL(fileURLWithPath: file).pathExtension else { throw NoteStoreError.invalidContent }
                    let data = try NoteCaptureRecovery.read(directory.appendingPathComponent(file), maximum: NoteStore.maximumMediaBytes)
                    return .init(id: id, name: native.displayNames?[id] ?? file, data: data, sha256: NoteMediaTranscriber.sourceHash(data))
                }
                let package = NotePackage(format: "agroom-note-v1", note: native.note, media: media); try package.validate(); return package
            }
            return try NoteLegacyImporter.preview(directory: directory, plaintext: true)
        }
    }
}

extension NoteProtectedArchive {
    /// File-backed variant of the same Memonta archive protocol; media never becomes one Data value.
    public static func exportFiles(_ package: NoteFilePackage, to destination: URL, password: String) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw NoteStoreError.conflict }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!) }) == errSecSuccess else { throw NoteStoreError.invalidContent }
        let key = try key(password: password,salt: salt)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".protected-note-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging,withIntermediateDirectories: false,attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian); format.dateFormat = "yyyyMMddHHmmss"
        let folder = format.string(from: package.note.createdAt)
        var files: [File] = []
        func store(_ name: String, data: Data? = nil, source: URL? = nil) throws {
            let path = folder + "/" + name
            guard safePath(path) else { throw NoteStoreError.invalidContent }
            let stamp = try source.map(NoteMediaFileStamp.read)
            let size = data?.count ?? stamp?.bytes ?? 0
            guard size <= NoteStore.maximumFileBytes else { throw NoteStoreError.tooLarge }
            let handle = try source.map { url in
                let descriptor = Darwin.open(url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw NoteStoreError.invalidContent }
                do { guard try NoteMediaFileStamp.opened(descriptor) == stamp else { throw NoteStoreError.conflict } }
                catch { Darwin.close(descriptor); throw error }
                return FileHandle(fileDescriptor: descriptor,closeOnDealloc: true)
            }; defer { try? handle?.close() }
            var offset = 0, chunks: [String] = []
            while offset < size {
                try Task.checkCancellation()
                let piece = try data.map { $0.subdata(in: offset..<min(offset + chunkSize,size)) } ?? handle?.read(upToCount: chunkSize) ?? Data()
                guard !piece.isEmpty else { throw NoteStoreError.invalidContent }
                let blob = UUID().uuidString + ".bin"
                guard let sealed = try AES.GCM.seal(piece,using: key,authenticating: Data("\(path)#\(chunks.count)".utf8)).combined else { throw NoteStoreError.invalidContent }
                try sealed.write(to: staging.appendingPathComponent(blob),options: .atomic)
                chunks.append(blob); offset += piece.count
            }
            if let source, let stamp, try NoteMediaFileStamp.read(source) != stamp { throw NoteStoreError.conflict }
            if let handle, let stamp, try NoteMediaFileStamp.opened(handle.fileDescriptor) != stamp { throw NoteStoreError.conflict }
            files.append(.init(path: path,chunks: chunks,bytes: size,encryptedText: textNames.contains(name) || name.hasPrefix("summary-history/")))
        }
        let meta: [String:Any] = ["id":package.note.id.uuidString,"title":package.note.title,"isHidden":package.note.archived,"itemType":package.note.transcript.isEmpty ? "quicknote" : "recording"]
        try store("meta.json",data: JSONSerialization.data(withJSONObject: meta))
        try store("source.txt",data: Data(package.note.text.utf8))
        if let summary = package.note.summaries.last { try store("summary.md",data: Data(summary.text.utf8)) }
        if let visual = package.note.visualNotes { try store("visual.md",data: Data(visual.utf8)) }
        for summary in package.note.summaries.dropLast() { try store("summary-history/" + summary.id.uuidString + ".json",data: JSONEncoder().encode(summary)) }
        if !package.note.segments.isEmpty {
            let segments: [[String:Any]] = package.note.segments.map { ["startTime":$0.timestamp,"endTime":$0.endTimestamp ?? $0.timestamp + 3,"text":$0.text,"speaker":$0.speaker] }
            try store("transcript.json",data: JSONSerialization.data(withJSONObject: segments))
        }
        let todos: [[String:Any]] = package.note.todos.map { todo in
            var value: [String:Any] = ["id":todo.id.uuidString,"title":todo.title,"priority":[1:"high",5:"medium",9:"low"][todo.priority ?? 0] ?? "none","status":"pending","isUserConfirmed":false]
            value["notes"] = todo.notes; value["owner"] = todo.owner; value["url"] = todo.url; value["evidenceQuote"] = todo.evidenceQuote
            value["dueDate"] = todo.dueDate?.timeIntervalSinceReferenceDate; value["alarmOffsetMinutes"] = todo.alarmOffsetMinutes
            return value
        }
        try store("todos.json",data: JSONSerialization.data(withJSONObject: ["source":"quicknote","model":"","generatedAt":Date().timeIntervalSinceReferenceDate,"items":todos]))
        var names: [UUID:String] = [:]
        for file in package.media {
            let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
            guard !ext.isEmpty, ext.count <= 16, ext.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) else { throw NoteStoreError.invalidContent }
            guard try await NoteStore.digest(file.file) == file.sha256 else { throw NoteStoreError.conflict }
            let name = file.id.uuidString + "." + ext; names[file.id] = name
            try store(name,source: file.file)
        }
        if let visual = package.visual {
            for frame in visual.frames {
                guard try await NoteStore.digest(frame.file) == frame.sha256 else { throw NoteStoreError.conflict }
                try store("frames/" + frame.id.uuidString + ".jpg",source: frame.file)
            }
        }
        try store("agroom-note.json",data: JSONEncoder().encode(Native(note: package.note,mediaNames: names,displayNames: Dictionary(uniqueKeysWithValues: package.media.map { ($0.id,$0.name) }),visual: package.visualIndex)))
        let manifest = Manifest(version: 1,created: Date(),files: files,skipped: 0)
        let manifestData = try JSONEncoder().encode(manifest)
        guard manifestData.count <= 32 * 1024 * 1024 - 28 else { throw NoteStoreError.tooLarge }
        guard let sealed = try AES.GCM.seal(manifestData,using: key,authenticating: Data("Memonta-backup-v1".utf8)).combined else { throw NoteStoreError.invalidContent }
        try sealed.write(to: staging.appendingPathComponent("manifest.bin"),options: .atomic)
        try JSONEncoder().encode(Header(version: 1,salt: salt,iterations: rounds)).write(to: staging.appendingPathComponent("header.json"),options: .atomic)
        try Task.checkCancellation(); try FileManager.default.moveItem(at: staging,to: destination)
    }
    public static func stageFiles(from archive: URL, password: String) async throws -> (URL,[URL]) {
        try NoteCaptureRecovery.regularDirectory(archive)
        let header = try JSONDecoder().decode(Header.self,from: NoteCaptureRecovery.read(archive.appendingPathComponent("header.json"),maximum: 4096))
        guard header.version == 1, header.iterations == rounds else { throw NoteStoreError.invalidContent }
        let key = try key(password: password,salt: header.salt)
        let sealed = try NoteCaptureRecovery.read(archive.appendingPathComponent("manifest.bin"),maximum: 32 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(Manifest.self,from: AES.GCM.open(AES.GCM.SealedBox(combined: sealed),using: key,authenticating: Data("Memonta-backup-v1".utf8)))
        guard manifest.version == 1, !manifest.files.isEmpty, manifest.files.count <= 100_000 else { throw NoteStoreError.invalidContent }
        var paths = Set<String>(), blobs = Set<String>(), total = 0
        for file in manifest.files {
            guard safePath(file.path), paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  file.bytes >= 0, file.bytes <= NoteStore.maximumFileBytes, file.chunks.count == (file.bytes + chunkSize - 1) / chunkSize else { throw NoteStoreError.invalidContent }
            total += file.bytes; guard total <= 1024 * 1024 * 1024 * 1024 else { throw NoteStoreError.tooLarge }
            for chunk in file.chunks { guard chunk.hasSuffix(".bin"), UUID(uuidString: String(chunk.dropLast(4))) != nil, blobs.insert(chunk).inserted else { throw NoteStoreError.invalidContent } }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
        var success = false; defer { if !success { try? FileManager.default.removeItem(at: root) } }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < Int64(total) + 32 * 1024 * 1024 { throw NoteStoreError.tooLarge }
        var entries = Set<URL>()
        for file in manifest.files {
            try Task.checkCancellation()
            let target = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
            guard FileManager.default.createFile(atPath: target.path,contents: nil,attributes: [.posixPermissions:0o600]) else { throw NoteStoreError.invalidContent }
            let handle = try FileHandle(forWritingTo: target)
            do {
                var written = 0
                for (index, chunk) in file.chunks.enumerated() {
                    try Task.checkCancellation()
                    let sealed = try NoteCaptureRecovery.read(archive.appendingPathComponent(chunk),maximum: chunkSize + 28)
                    let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed),using: key,authenticating: Data("\(file.path)#\(index)".utf8))
                    guard bytes.count == min(chunkSize,file.bytes - written) else { throw NoteStoreError.invalidContent }
                    try handle.write(contentsOf: bytes); written += bytes.count
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            if target.lastPathComponent == "meta.json" { entries.insert(target.deletingLastPathComponent()) }
        }
        guard !entries.isEmpty else { throw NoteStoreError.missing }
        success = true
        return (root,entries.sorted { $0.path < $1.path })
    }
    public static func previewFileEntry(_ directory: URL) async throws -> NoteFilePackage {
        let metadata = directory.appendingPathComponent("agroom-note.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return try await NoteLegacyImporter.previewFiles(directory: directory,plaintext: true) }
        let native = try JSONDecoder().decode(Native.self,from: NoteCaptureRecovery.read(metadata,maximum: 8 * 1024 * 1024))
        var media: [NoteFilePackage.Media] = []
        for (id, name) in native.mediaNames {
            guard URL(fileURLWithPath: name).lastPathComponent == name, name.hasPrefix(id.uuidString + ".") else { throw NoteStoreError.invalidContent }
            let file = directory.appendingPathComponent(name), stamp = try NoteMediaFileStamp.read(file)
            media.append(.init(id: id,name: native.displayNames?[id] ?? name,bytes: stamp.bytes,sha256: try await NoteStore.digest(file),file: file))
        }
        let visual = try await NoteFilePackage.readVisual(native.visual,in: directory)
        if let visual {
            guard native.note.visualMediaID == visual.mediaID, visual.sourceRemoved != media.contains(where: { $0.id == visual.mediaID }) else { throw NoteStoreError.invalidContent }
        }
        return .init(note: native.note,media: media,visual: visual)
    }
}
