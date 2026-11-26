import Foundation
import CryptoKit
import GRDB
import Darwin

public struct NoteMediaFileStamp: Sendable, Equatable {
    public let bytes: Int
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    public static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw NoteStoreError.invalidContent }
        return try validated(value)
    }
    static func opened(_ descriptor: Int32) throws -> Self {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw NoteStoreError.invalidContent }
        return try validated(value)
    }
    private static func validated(_ value: stat) throws -> Self {
        guard value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_size > 0, value.st_size <= NoteStore.maximumFileBytes else { throw NoteStoreError.invalidContent }
        return .init(bytes: Int(value.st_size), device: UInt64(value.st_dev), inode: UInt64(value.st_ino), modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,changedSeconds: value.st_ctimespec.tv_sec,changedNanos: value.st_ctimespec.tv_nsec)
    }
}

private actor NoteMediaReader {
    let file: FileHandle
    init(_ url: URL, stamp: NoteMediaFileStamp) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NoteStoreError.invalidContent }
        do { guard try NoteMediaFileStamp.opened(descriptor) == stamp else { throw NoteStoreError.conflict } }
        catch { Darwin.close(descriptor); throw error }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func next() throws -> Data { try file.read(upToCount: NoteStore.mediaChunkBytes) ?? Data() }
    func verify(_ stamp: NoteMediaFileStamp) throws {
        guard try NoteMediaFileStamp.opened(file.fileDescriptor) == stamp else { throw NoteStoreError.conflict }
    }
    func close() throws { try file.close() }
}

extension NoteStore {
    static let mediaChunkBytes = 4 * 1024 * 1024
    static func createMediaFileSchema(_ db: Database) throws {
        let columns = try db.columns(in: "note_media").map(\.name)
        if !columns.contains("byteCount") { try db.alter(table: "note_media") { $0.add(column: "byteCount", .integer) } }
        if !columns.contains("isReady") { try db.alter(table: "note_media") { $0.add(column: "isReady", .boolean).notNull().defaults(to: true) } }
        if !columns.contains("sourceRemoved") { try db.alter(table: "note_media") { $0.add(column: "sourceRemoved",.boolean).notNull().defaults(to: false) } }
        if !columns.contains("sha256") { try db.alter(table: "note_media") { $0.add(column: "sha256", .text) } }
        if !columns.contains("uploadOwner") { try db.alter(table: "note_media") { $0.add(column: "uploadOwner", .text) } }
        if !columns.contains("uploadUntil") { try db.alter(table: "note_media") { $0.add(column: "uploadUntil", .datetime) } }
        try db.create(table: "note_media_chunks", ifNotExists: true) { t in
            t.column("mediaID", .text).notNull().references("note_media", onDelete: .cascade)
            t.column("sequence", .integer).notNull()
            t.column("contents", .blob).notNull()
            t.primaryKey(["mediaID", "sequence"])
        }
        try db.create(table: "note_import_staging", ifNotExists: true) { t in
            t.column("source", .text).primaryKey()
            t.column("noteID", .text).notNull().references("notes", onDelete: .cascade)
        }
        try db.create(table: "note_import_origins", ifNotExists: true) { t in
            t.column("source", .text).primaryKey()
            t.column("noteID", .text).notNull().references("notes", onDelete: .cascade)
        }
    }

    /// A partial file is invisible. Every chunk is bounded; a changed source rolls back the import.
    public func addMediaFile(id: UUID = UUID(), noteID: UUID, name: String, file: URL, publish: Bool = true) async throws {
        let stamp = try await Task.detached { try NoteMediaFileStamp.read(file) }.value
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty else { throw NoteStoreError.invalidContent }
        let existing: (String,String,String?,Int)? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT noteID,name,sha256,coalesce(byteCount,length(contents)) AS size FROM note_media WHERE id = ? AND isReady = 1", arguments: [id.uuidString]).map { ($0["noteID"],$0["name"],$0["sha256"],$0["size"]) }
        }
        if let existing {
            guard existing.0 == noteID.uuidString, existing.1 == safeName, existing.3 == stamp.bytes else { throw NoteStoreError.conflict }
            let hash = try await Self.digest(file)
            if let expected = existing.2 { guard expected == hash else { throw NoteStoreError.conflict } }
            else { guard NoteMediaTranscriber.sourceHash(try await mediaData(noteID: noteID,id: id)) == hash else { throw NoteStoreError.conflict } }
            return
        }
        let reader = try NoteMediaReader(file, stamp: stamp)
        let owner = UUID().uuidString
        var inserted = false
        do {
            try await queue.maintenanceWrite { db in
                try db.execute(sql: "DELETE FROM note_media WHERE id = ? AND noteID = ? AND name = ? AND isReady = 0 AND sha256 IS NULL AND (uploadUntil IS NULL OR uploadUntil <= ?)",arguments: [id.uuidString,noteID.uuidString,safeName,Date()])
                try db.execute(sql: "INSERT INTO note_media (id,noteID,name,contents,byteCount,isReady,uploadOwner,uploadUntil) VALUES (?,?,?,X'',?,0,?,?)", arguments: [id.uuidString,noteID.uuidString,safeName,stamp.bytes,owner,Date().addingTimeInterval(120)])
            }
            inserted = true
            var index = 0, count = 0, hash = SHA256()
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.next()
                if chunk.isEmpty { break }
                count += chunk.count; guard count <= stamp.bytes else { throw NoteStoreError.conflict }
                hash.update(data: chunk)
                let sequence = index
                try await queue.maintenanceWrite { db in
                    try db.execute(sql: "UPDATE note_media SET uploadUntil = ? WHERE id = ? AND uploadOwner = ? AND isReady = 0",arguments: [Date().addingTimeInterval(120),id.uuidString,owner])
                    guard db.changesCount == 1 else { throw NoteStoreError.conflict }
                    try db.execute(sql: "INSERT INTO note_media_chunks (mediaID,sequence,contents) VALUES (?,?,?)", arguments: [id.uuidString,sequence,chunk])
                }
                index += 1
            }
            try await reader.verify(stamp)
            try await reader.close()
            guard count == stamp.bytes, try await Task.detached(operation: { try NoteMediaFileStamp.read(file) }).value == stamp else { throw NoteStoreError.conflict }
            try Task.checkCancellation()
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try await queue.maintenanceWrite { db in
                try db.execute(sql: "UPDATE note_media SET isReady = ?, sha256 = ?, uploadOwner = NULL, uploadUntil = NULL WHERE id = ? AND isReady = 0 AND uploadOwner = ?", arguments: [publish,digest,id.uuidString,owner])
                guard db.changesCount == 1 else { throw NoteStoreError.conflict }
            }
        } catch {
            try? await reader.close()
            // Cleanup is unconditional on cancellation, and touches only our unpublished identity.
            if inserted {
                _ = try? await Task.detached { [queue] in
                    try await queue.maintenanceWrite { db in try db.execute(sql: "DELETE FROM note_media WHERE id = ? AND isReady = 0 AND uploadOwner = ?", arguments: [id.uuidString,owner]) }
                }.value
            }
            throw error
        }
    }

    public func writeMedia(noteID: UUID, id: UUID, to destination: URL) async throws {
        let row: (Int,String?,Int)? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT coalesce(byteCount,length(contents)) AS size,sha256,length(contents) AS inlineSize FROM note_media WHERE id = ? AND noteID = ? AND isReady = 1", arguments: [id.uuidString,noteID.uuidString]).map { ($0["size"],$0["sha256"],$0["inlineSize"]) }
        }
        guard let row else { throw NoteStoreError.missing }
        let bytes = row.0, inlineSize = row.2
        guard bytes > 0, bytes <= Self.maximumFileBytes, !FileManager.default.fileExists(atPath: destination.path) else { throw NoteStoreError.invalidContent }
        let writer = try NoteMediaWriter(destination)
        do {
            if inlineSize > 0 { try await writer.append(mediaData(noteID: noteID, id: id)) }
            else {
                var count = 0, index = 0
                while count < bytes {
                    try Task.checkCancellation()
                    let sequence = index
                    guard let chunk = try await queue.read({ db in try Data.fetchOne(db, sql: "SELECT contents FROM note_media_chunks WHERE mediaID = ? AND sequence = ?", arguments: [id.uuidString,sequence]) }), !chunk.isEmpty, chunk.count <= Self.mediaChunkBytes else { throw NoteStoreError.invalidContent }
                    count += chunk.count; guard count <= bytes else { throw NoteStoreError.invalidContent }
                    try await writer.append(chunk); index += 1
                }
            }
            let digest = try await writer.finish()
            if let expected = row.1, digest != expected { throw NoteStoreError.invalidContent }
        } catch {
            _ = try? await writer.finish()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public static func digest(_ file: URL) async throws -> String {
        let stamp = try NoteMediaFileStamp.read(file), reader = try NoteMediaReader(file, stamp: stamp)
        var hash = SHA256(), count = 0
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.next(); if chunk.isEmpty { break }
                count += chunk.count; guard count <= stamp.bytes else { throw NoteStoreError.conflict }; hash.update(data: chunk)
            }
            try await reader.verify(stamp)
            try await reader.close()
            guard count == stamp.bytes, try NoteMediaFileStamp.read(file) == stamp else { throw NoteStoreError.conflict }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { try? await reader.close(); throw error }
    }

    static func copyMediaFile(_ source: URL, to destination: URL, expectedDigest: String?) async throws {
        let stamp = try NoteMediaFileStamp.read(source)
        let reader = try NoteMediaReader(source, stamp: stamp)
        let writer: NoteMediaWriter
        do { writer = try NoteMediaWriter(destination) }
        catch { try? await reader.close(); throw error }
        do {
            var count = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.next()
                if chunk.isEmpty { break }
                count += chunk.count
                guard count <= stamp.bytes else { throw NoteStoreError.conflict }
                try await writer.append(chunk)
            }
            try await reader.verify(stamp)
            try await reader.close()
            let digest = try await writer.finish()
            guard count == stamp.bytes, try NoteMediaFileStamp.read(source) == stamp else { throw NoteStoreError.conflict }
            if let expectedDigest, expectedDigest != digest { throw NoteStoreError.invalidContent }
            try Task.checkCancellation()
        } catch {
            try? await reader.close(); _ = try? await writer.finish()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private actor NoteMediaWriter {
    private let file: FileHandle
    private var hash = SHA256()
    init(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NoteStoreError.invalidContent }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func append(_ data: Data) throws { try file.write(contentsOf: data); hash.update(data: data) }
    func finish() throws -> String { try file.close(); return hash.finalize().map { String(format: "%02x", $0) }.joined() }
}
