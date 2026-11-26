import CryptoKit
import Darwin
import Foundation

/// Descriptive metadata only: no message bytes, URL, bookmark or file handle.
public struct MailImportMetadata: Identifiable, Sendable {
    public let id: UUID
    public let source: String
    public let folder: String
    public let envelope: MailImportedEnvelope
    public let sha256: String
    public let byteCount: Int
    public let sourceVariant: MailMboxVariant?
    public var locator: MailImportRecordLocator? = nil
    var identity: MailImportIdentity { .init(folder: folder, sha256: sha256, byteCount: byteCount) }
}

extension MailImportCandidate {
    var metadata: MailImportMetadata { .init(id: id, source: source, folder: folder, envelope: envelope, sha256: sha256, byteCount: data.count, sourceVariant: sourceVariant) }
}

public struct MailImportIndexedPreview: Sendable {
    public let access: MailImportSourceAccess
    public var candidates: [MailImportMetadata]
    public var failures: [MailImportResult]
    public var duplicates: Set<UUID> = []
    public var duplicateMatches: [UUID: MailImportDuplicateMatch] = [:]
    public var byteCount: Int64
}

public struct MailImportReadProgress: Sendable {
    public enum Phase: String, Sendable { case scanning, parsing }
    public let phase: Phase
    public let discoveredFiles: Int
    public let completedFiles: Int
    public let records: Int
    public let readBytes: Int64
    public let totalBytes: Int64?
}

extension MailImportReader {
    public static func index(_ urls: [URL], variant: MailMboxVariant = .automatic,
                             progress: @escaping @Sendable (MailImportReadProgress) -> Void = { _ in }) async throws -> MailImportIndexedPreview {
        let access = MailImportSourceAccess()
        return try await access.scan(urls, variant: variant, progress: progress)
    }
}

/// All directory handles and mutable source state belong to this actor. The UI
/// retains its picker grants while this session is usable, and closes the
/// session on dismissal or source replacement. It is never serialized.
public actor MailImportSourceAccess {
    public nonisolated let id = UUID()
    private struct Root { let directory: AppDirectory; let url: URL }
    private struct DirectoryIdentity: Equatable {
        let device: Int64, inode: UInt64
        init(_ directory: AppDirectory) throws {
            var info = stat()
            guard fstat(directory.fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw MailImportError.changed }
            device = Int64(info.st_dev); inode = UInt64(info.st_ino)
        }
    }
    private struct File {
        let root: UUID
        let components: [String]
        let directories: [DirectoryIdentity]
        let source: String
        let folder: String
        let identity: MailImportFileIdentity
        let isEML: Bool
    }
    private struct Record { let file: UUID; let location: MailMboxRecordLocation?; let metadata: MailImportMetadata }
    private var roots: [UUID: Root] = [:]
    private var files: [UUID: File] = [:]
    private var records: [UUID: Record] = [:]
    private var candidates: [MailImportMetadata] = []
    private var failures: [MailImportResult] = []
    private var bytes: Int64 = 0
    private var metadataBytes = 0
    private var closed = false
    private var scanned = false
    fileprivate init() {}

    public func close() { closed = true; records = [:]; candidates = []; failures = []; files = [:]; roots = [:] }

    func validateSelection(_ selected: [MailImportMetadata]) throws {
        try Task.checkCancellation()
        guard !closed, scanned else { throw MailImportError.changed }
        for item in selected {
            guard let stored = records[item.id]?.metadata, stored.identity == item.identity,
                  Data(stored.source.utf8) == Data(item.source.utf8), stored.sourceVariant == item.sourceVariant else { throw MailImportError.changed }
        }
    }

    public func original(_ itemID: UUID) throws -> MailImportCandidate {
        try Task.checkCancellation()
        guard !closed, let record = records[itemID], let source = files[record.file] else { throw MailImportError.changed }
        let file = try open(source)
        let original: Data
        if let location = record.location {
            let stored = try file.readRange(offset: location.offset, count: location.byteCount, limit: MailService.rawMessageByteLimit * 2)
            original = try MailMboxCodec.decodeIndexedRecord(stored, variant: location.variant)
        } else { original = try file.readAll(limit: MailService.rawMessageByteLimit) }
        try file.validate(); try Task.checkCancellation()
        let item = record.metadata
        guard original.count == item.byteCount, Self.digest(original) == item.sha256 else { throw MailImportError.changed }
        return .init(id: item.id, source: item.source, folder: item.folder, envelope: item.envelope, data: original, sha256: item.sha256, sourceVariant: item.sourceVariant)
    }

    fileprivate func scan(_ urls: [URL], variant: MailMboxVariant,
                          progress: @Sendable (MailImportReadProgress) -> Void) throws -> MailImportIndexedPreview {
        guard !closed, !scanned, urls.count <= MailImportReader.maximumItems else { throw MailImportError.capacity }
        scanned = true
        do {
            var inventory: [UUID] = [], inspected = 0, total: Int64 = 0
            var rootPaths: [Data: UUID] = [:]
            func failed(_ source: String, _ error: MailImportError) throws {
                guard records.count + failures.count < MailImportReader.maximumItems else { throw MailImportError.capacity }
                failures.append(.init(id: UUID(), source: source, subject: "", status: .failed, error: error))
            }
            func root(_ directory: AppDirectory) throws -> UUID {
                let url = try directory.kernelURL(), key = Data(url.path.utf8)
                if let id = rootPaths[key] { return id }
                // Keep a bounded number of pinned roots, never one descriptor
                // per message or per discovered file.
                guard roots.count < 128 else { throw MailImportError.capacity }
                let id = UUID(); roots[id] = .init(directory: directory, url: url); rootPaths[key] = id
                return id
            }
            func discover(_ directory: AppDirectory, name: String, source: String, folder: String, rootID: UUID, components: [String], chain: [DirectoryIdentity]) throws {
                let ext = (name as NSString).pathExtension.lowercased()
                guard ext == "eml" || ext == "mbox" || name.lowercased() == "mbox" else { try failed(source, .unsupported); return }
                let file = try MailImportSourceFile(parent: directory, name: name)
                let next = total.addingReportingOverflow(file.byteCount)
                guard !next.overflow, file.byteCount <= 64 * 1024 * 1024 * 1024,
                      next.partialValue <= 64 * 1024 * 1024 * 1024, inventory.count < MailImportReader.maximumItems else { throw MailImportError.capacity }
                if ext == "eml", file.byteCount > MailService.rawMessageByteLimit { try failed(source, .capacity); return }
                let id = UUID()
                files[id] = .init(root: rootID, components: components + [name], directories: chain, source: source, folder: folder, identity: file.identity, isEML: ext == "eml")
                inventory.append(id); total = next.partialValue
                progress(.init(phase: .scanning, discoveredFiles: inventory.count, completedFiles: 0, records: 0, readBytes: 0, totalBytes: nil))
            }
            func walk(_ directory: AppDirectory, source: String, rootID: UUID, components: [String], chain: [DirectoryIdentity], depth: Int) throws {
                try Task.checkCancellation()
                guard depth <= 12 else { try failed(source, .capacity); return }
                let names = try directory.names(limit: MailImportReader.maximumItems)
                for name in names.sorted() where !name.hasPrefix(".") {
                    try Task.checkCancellation(); inspected += 1
                    guard inspected <= MailImportReader.maximumItems else { throw MailImportError.capacity }
                    let relative = source + "/" + name
                    var info = stat()
                    guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { try failed(relative, .unreadable); continue }
                    do {
                        if info.st_mode & S_IFMT == S_IFDIR {
                            let child = try directory.child(name, create: false)
                            try walk(child, source: relative, rootID: rootID, components: components + [name], chain: chain + [DirectoryIdentity(child)], depth: depth + 1)
                        } else if info.st_mode & S_IFMT == S_IFREG {
                            let ext = (name as NSString).pathExtension.lowercased()
                            if ext == "eml" || ext == "mbox" || name.lowercased() == "mbox" {
                                try discover(directory, name: name, source: relative, folder: source, rootID: rootID, components: components, chain: chain)
                            }
                        } else { try failed(relative, .unreadable) }
                    } catch is CancellationError { throw CancellationError() }
                    catch MailImportError.capacity { throw MailImportError.capacity }
                    catch { try failed(relative, (error as? MailImportError) ?? .unreadable) }
                }
            }
            progress(.init(phase: .scanning, discoveredFiles: 0, completedFiles: 0, records: 0, readBytes: 0, totalBytes: nil))
            for url in urls {
                try Task.checkCancellation()
                guard url.isFileURL else { try failed(url.lastPathComponent, .unreadable); continue }
                do {
                    let parent = try AppDirectory(url: url.deletingLastPathComponent(), create: false), name = url.lastPathComponent
                    var info = stat()
                    guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw MailImportError.unreadable }
                    if info.st_mode & S_IFMT == S_IFDIR {
                        let directory = try parent.child(name, create: false), rootID = try root(directory)
                        try walk(directory, source: name, rootID: rootID, components: [], chain: [], depth: 0)
                    } else {
                        try discover(parent, name: name, source: name, folder: "", rootID: root(parent), components: [], chain: [])
                    }
                } catch is CancellationError { throw CancellationError() }
                catch MailImportError.capacity { throw MailImportError.capacity }
                catch { try failed(url.lastPathComponent, (error as? MailImportError) ?? .unreadable) }
            }
            var readBytes: Int64 = 0
            let fileCount = inventory.count, totalBytes = total
            progress(.init(phase: .parsing, discoveredFiles: inventory.count, completedFiles: 0, records: 0, readBytes: 0, totalBytes: total))
            for (position, fileID) in inventory.enumerated() {
                try Task.checkCancellation()
                guard let source = files[fileID] else { throw MailImportError.changed }
                let before = candidates.count, failuresBefore = failures.count, bytesBefore = bytes, metadataBefore = metadataBytes
                let fileBaseBytes = readBytes
                var opened: MailImportSourceFile?
                do {
                    let file = try open(source); opened = file
                    func accept(_ data: Data, index: Int?, location: MailMboxRecordLocation?) throws {
                        try Task.checkCancellation()
                        guard candidates.count + failures.count < MailImportReader.maximumItems else { throw MailImportError.capacity }
                        let label = source.source + (index.map { "#\($0 + 1)" } ?? "")
                        do {
                            let envelope = try MailFoundationAdapter.importedEnvelope(data)
                            let name = (source.components.last! as NSString).deletingPathExtension
                            let folder = source.isEML ? source.folder : [source.folder, name].filter { !$0.isEmpty && $0.lowercased() != "mbox" }.joined(separator: "/")
                            var item = MailImportMetadata(id: UUID(), source: label, folder: folder, envelope: envelope, sha256: Self.digest(data), byteCount: data.count, sourceVariant: location?.variant)
                            item.locator = .init(fileSource: source.source, location: location)
                            let addresses = [envelope.from] + envelope.to + envelope.cc + envelope.replyTo
                            let cost = [label, folder, envelope.subject, envelope.messageID ?? "", envelope.references ?? ""].reduce(0) { $0 + $1.utf8.count }
                                + addresses.reduce(0) { $0 + $1.name.utf8.count + $1.address.utf8.count }
                            guard cost <= 128 * 1024, metadataBytes <= 64 * 1024 * 1024 - cost else { throw MailImportError.capacity }
                            records[item.id] = .init(file: fileID, location: location, metadata: item)
                            candidates.append(item); bytes += Int64(data.count); metadataBytes += cost
                        } catch is CancellationError { throw CancellationError() }
                        catch MailImportError.capacity { throw MailImportError.capacity }
                        catch { try failed(label, (error as? MailImportError) ?? .invalidMessage) }
                        progress(.init(phase: .parsing, discoveredFiles: fileCount, completedFiles: position, records: candidates.count, readBytes: fileBaseBytes + file.offset, totalBytes: totalBytes))
                    }
                    if source.isEML { try accept(file.readAll(limit: MailService.rawMessageByteLimit), index: nil, location: nil) }
                    else {
                        try MailMboxCodec.decodeStream(variant: variant, read: { try file.read(maximum: $0) }) { index, location, data in
                            try accept(data, index: index, location: location)
                        }
                    }
                    try file.validate()
                } catch is CancellationError { throw CancellationError() }
                catch {
                    var failure = (error as? MailImportError) ?? .unreadable
                    if let opened { do { try opened.validate() } catch { failure = .changed } }
                    if failure == .capacity { throw failure }
                    if failure == .changed {
                        for item in candidates[before...] { records[item.id] = nil }
                        candidates.removeSubrange(before...); failures.removeSubrange(failuresBefore...); bytes = bytesBefore; metadataBytes = metadataBefore
                    }
                    try failed(source.source, failure)
                }
                readBytes += opened?.offset ?? 0
                progress(.init(phase: .parsing, discoveredFiles: inventory.count, completedFiles: position + 1, records: candidates.count, readBytes: readBytes, totalBytes: total))
            }
            return .init(access: self, candidates: candidates, failures: failures, byteCount: bytes)
        } catch { close(); throw error }
    }

    private func open(_ source: File) throws -> MailImportSourceFile {
        guard !closed, let root = roots[source.root], let name = source.components.last else { throw MailImportError.changed }
        do {
            try root.directory.verifyIdentity(at: root.url)
            var parent = root.directory
            guard source.directories.count == source.components.count - 1 else { throw MailImportError.changed }
            for (index, component) in source.components.dropLast().enumerated() {
                parent = try parent.child(component, create: false)
                guard try DirectoryIdentity(parent) == source.directories[index] else { throw MailImportError.changed }
            }
            let file = try MailImportSourceFile(parent: parent, name: name)
            guard file.identity == source.identity else { throw MailImportError.changed }
            return file
        } catch is CancellationError { throw CancellationError() }
        catch { throw MailImportError.changed }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
