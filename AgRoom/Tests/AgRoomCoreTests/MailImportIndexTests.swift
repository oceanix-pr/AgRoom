import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Indexed mail import")
struct MailImportIndexTests {
    private let draft = MailImportArchiveDraft(name: "Indexed archive", inbox: "Inbox", trash: "Trash", archive: "Archive")
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-index-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func original(_ subject: String, body: String = "Owned original body\n") -> Data {
        Data("From: sender@example.test\nTo: recipient@example.test\nSubject: \(subject)\nMessage-ID: <\(subject)@example.test>\nContent-Type: text/plain; charset=utf-8\n\n\(body)".utf8)
    }
    private func service() throws -> (DatabaseQueue, MailService) {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        return (queue, MailService(databaseQueue: queue))
    }

    @Test("A real mailbox larger than the old whole-preview limit indexes and imports every distinct original")
    func largeMailbox() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Large.mbox")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        let body = String(repeating: String(repeating: "x", count: 1023) + "\n", count: 1024)
        for number in 0..<129 {
            try writer.write(contentsOf: MailMboxCodec.encode(original("Large-\(number)", body: body), date: nil).data)
        }
        try writer.close()
        let indexed = try await MailImportReader.index([url])
        #expect(indexed.candidates.count == 129 && indexed.failures.isEmpty)
        #expect(indexed.byteCount > MailImportReader.maximumBytes)
        let (queue, mail) = try service()
        let review = try await mail.reviewImportMapping(indexed, archiveID: nil, draft: draft, rules: [:])
        #expect(try await queue.read { try MailAccountRow.fetchCount($0) } == 0)
        let batch = try await mail.importMappedMessages(indexed, review: review)
        #expect(batch.results.count == 129 && batch.results.allSatisfy { $0.status == .imported })
        #expect(try await mail.messageCount(in: .space) == 129)
        let storedBytes = try await queue.read { try Int64.fetchOne($0, sql: "SELECT SUM(length(data)) FROM mail_raw_messages") }
        #expect(storedBytes == indexed.byteCount)
        for position in [0, 128] {
            let result = batch.results[position], id = try #require(result.messageID)
            #expect(try await mail.rawMessage(id: id)?.data == original("Large-\(position)", body: body))
        }
        await indexed.access.close()
    }

    @Test("Indexed ranges restore transport quotes and length-framed binary originals for every supported variant")
    func rangeVariants() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rd = original("RD", body: "From start\n>From nested\n>>From deep\n")
        let rdURL = root.appendingPathComponent("rd.mbox")
        try MailMboxCodec.encode(rd, date: nil).data.write(to: rdURL)
        let rdIndex = try await MailImportReader.index([rdURL])
        let rdItem = try #require(rdIndex.candidates.first)
        #expect(try await rdIndex.access.original(rdItem.id).data == rd)
        await rdIndex.access.close()
        let envelope = Data("From sender@example.test Tue Nov 14 22:13:20 2023\n".utf8)
        for variant in [MailMboxVariant.mboxo, .mboxcl, .mboxcl2] {
            let body = Data([0, 255, 10]) + Data(">From old quote\n>>From deep\nFrom body\nEnd".utf8)
            let header = Data("From: sender@example.test\nSubject: Length fixture\nContent-Length: \(body.count)\n\n".utf8)
            let url = root.appendingPathComponent(variant.rawValue + ".mbox")
            if variant == .mboxo {
                let stored = original("Old", body: ">From escaped\n>>From unchanged\n")
                try (envelope + stored + Data([10])).write(to: url)
            } else { try (envelope + header + body + Data([10, 10])).write(to: url) }
            let index = try await MailImportReader.index([url], variant: variant)
            let item = try #require(index.candidates.first)
            let data = try await index.access.original(item.id).data
            #expect(item.sourceVariant == variant)
            if variant == .mboxcl2 { #expect(data == header + body) }
            else if variant == .mboxcl { #expect(data == header + Data([0, 255, 10]) + Data("From old quote\n>>From deep\nFrom body\nEnd".utf8)) }
            else { #expect(data == original("Old", body: "From escaped\n>>From unchanged\n")) }
            await index.access.close()
        }
    }

    @Test("A changed file loses all of its indexed records, while earlier stable sources and truthful scan progress remain")
    func changedDuringScan() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let stable = root.appendingPathComponent("stable.eml"), changing = root.appendingPathComponent("changing.mbox")
        try original("Stable").write(to: stable)
        let old = try MailMboxCodec.encode(original("Old"), date: nil).data + MailMboxCodec.encode(original("Later"), date: nil).data
        try old.write(to: changing)
        let updates = Mutex<[MailImportReadProgress]>([])
        let indexed = try await MailImportReader.index([stable, changing]) { value in
            updates.withLock { $0.append(value) }
            if value.phase == .parsing, value.completedFiles == 1, value.records == 2 {
                // Mutation deliberately occurs outside the progress-storage lock.
                do { try Data("Changed source".utf8).write(to: changing) } catch { Issue.record(error) }
            }
        }
        #expect(indexed.candidates.count == 1 && indexed.candidates.first?.envelope.subject == "Stable")
        #expect(indexed.failures.count == 1 && indexed.failures.first?.error == .changed)
        let phases = updates.withLock { $0 }
        #expect(phases.contains { $0.phase == .scanning && $0.totalBytes == nil })
        #expect(phases.last?.completedFiles == 2 && phases.last?.discoveredFiles == 2)
        #expect(phases.filter { $0.phase == .parsing }.allSatisfy { $0.readBytes <= ($0.totalBytes ?? 0) })
        await indexed.access.close()
    }

    @Test("Replacement, symlinks, changed ancestors and closed sessions cannot supply indexed originals")
    func sourceIdentityAndClose() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Selected"), inner = directory.appendingPathComponent("Outer/Inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let url = inner.appendingPathComponent("one.eml"), data = original("Identity")
        try data.write(to: url)
        let indexed = try await MailImportReader.index([directory]), item = try #require(indexed.candidates.first)
        let moved = directory.appendingPathComponent("Kept")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("Outer"), to: moved)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Outer"), withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: moved.appendingPathComponent("Inner"), to: inner)
        await #expect(throws: MailImportError.changed) { try await indexed.access.original(item.id) }
        let reselected = try await MailImportReader.index([directory]), refreshed = try #require(reselected.candidates.first)
        try data.write(to: url, options: .atomic)
        await #expect(throws: MailImportError.changed) { try await reselected.access.original(refreshed.id) }
        let again = try await MailImportReader.index([directory]), last = try #require(again.candidates.first)
        let target = root.appendingPathComponent("other.eml"); try data.write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        await #expect(throws: MailImportError.changed) { try await again.access.original(last.id) }
        await again.access.close()
        await #expect(throws: MailImportError.changed) { try await again.access.original(last.id) }
        await indexed.access.close(); await reselected.access.close()
    }

    @Test("Closing the source after a committed item retains that receipt and prevents subsequent source reads or writes")
    func closeDuringImport() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<3).map { number -> URL in
            let url = root.appendingPathComponent("\(number).eml"); try original("Item-\(number)").write(to: url); return url
        }
        let indexed = try await MailImportReader.index(urls), (_, mail) = try service()
        let review = try await mail.reviewImportMapping(indexed, archiveID: nil, draft: draft, rules: [:])
        let batch = try await mail.importMappedMessages(indexed, review: review) { done, _ in
            if done == 1 { await indexed.access.close() }
        }
        #expect(batch.results.map(\.status) == [.imported, .failed, .failed])
        #expect(batch.results.dropFirst().allSatisfy { $0.error == .changed })
        #expect(try await mail.messageCount(in: .space) == 1)
        #expect(try await mail.importBatches(archiveID: batch.accountID).first?.results.first?.status == .imported)
        let fresh = try await MailImportReader.index(urls)
        await #expect(throws: MailImportError.changed) { try await mail.importMappedMessages(fresh, review: review) }
        await fresh.access.close()
    }
}
