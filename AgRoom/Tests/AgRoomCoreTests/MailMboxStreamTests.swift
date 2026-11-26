import AppKit
import Foundation
import GRDB
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("MBOX stream imports", .serialized)
struct MailMboxStreamTests {
    private let separator = Data("From synthetic@example.test Tue Nov 14 22:13:20 2023\n".utf8)

    private func message(_ body: Data, length: Int? = nil) -> Data {
        var header = "From: synthetic@example.test\nSubject: Stream fixture\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n"
        if let length { header += "Content-Length: \(length)\n" }
        return Data((header + "\n").utf8) + body
    }

    private func decode(_ source: Data, variant: MailMboxVariant = .automatic, chunk: Int = 64 * 1024) throws -> [(MailMboxRecordLocation, Data)] {
        var position = source.startIndex, result: [(MailMboxRecordLocation, Data)] = []
        try MailMboxCodec.decodeStream(variant: variant, read: { maximum in
            let count = min(maximum, chunk, source.endIndex - position), end = position + count
            let data = source[position..<end]; position = end
            return data
        }, consume: { index, location, original in
            #expect(index == result.count); result.append((location, original))
        })
        return result
    }

    @Test("Chunk boundaries, sliced Data and source locations do not change mboxrd originals")
    func chunksAndLocations() throws {
        let originals = [message(Data("Unicode 你好😀\r\nFrom raw line\n>From quoted\n>>From deeply quoted\n\u{0}binary\n".utf8)), message(Data("Last body\n".utf8))]
        let source = try originals.reduce(into: Data()) { $0.append(try MailMboxCodec.encode($1, date: nil).data) }
        let prefixed = Data([0, 1, 2]) + source
        for chunk in [1, 2, 3, 7, 4096, 64 * 1024] {
            let rows = try decode(prefixed[3...], chunk: chunk)
            #expect(rows.map(\.1) == originals)
            #expect(rows.allSatisfy { $0.0.variant == .mboxrd && $0.0.offset > $0.0.envelopeOffset })
            for (location, raw) in rows {
                let start = Int(location.envelopeOffset)
                let suffix = source[start...]
                let decoded = try decode(Data(suffix))
                #expect(decoded.first?.1 == raw)
                #expect(location.offset + Int64(location.byteCount) <= Int64(source.count))
            }
        }
    }

    @Test("A decoder resumed at a recorded envelope retains absolute byte positions and rejects overflowing offsets")
    func resumedOffsets() throws {
        let original = message(Data("Resume body\n".utf8)), record = try MailMboxCodec.encode(original, date: nil).data
        let source = record + record, rows = try decode(source)
        let expected = try #require(rows.last?.0)
        var position = Int(expected.envelopeOffset), count = 0
        try MailMboxCodec.decodeStream(initialOffset: expected.envelopeOffset, initialIndex: 1, read: { maximum in
            let end = min(position + maximum, source.count), data = Data(source[position..<end]); position = end; return data
        }, consume: { index, location, data in
            #expect(index == 1 && location == expected && data == original); count += 1
        })
        #expect(count == 1)
        #expect(throws: MailImportError.capacity) {
            try MailMboxCodec.decodeStream(initialOffset: Int64.max, read: { _ in record }, consume: { _, _, _ in Issue.record("Overflow published a record") })
        }
        #expect(throws: MailImportError.capacity) {
            try MailMboxCodec.decodeStream(initialIndex: Int.max, read: { _ in record }, consume: { _, _, _ in Issue.record("Overflow published an index") })
        }
    }

    @Test("Content-Length frames binary and unquoted From lines by octets, including bodies without a final newline")
    func contentLengthBodies() throws {
        let bodies = [Data("你好😀\nFrom fake@example.test Tue Nov 14 22:13:20 2023\n\u{0}binary without newline".utf8), Data()]
        let originals = bodies.map { message($0, length: $0.count) }
        let source = originals.reduce(into: Data()) { $0.append(separator); $0.append($1); $0.append(Data([10])) }
        for variant in [MailMboxVariant.automatic, .mboxcl2] {
            for chunk in [1, 5, 4096] {
                let rows = try decode(source, variant: variant, chunk: chunk)
                #expect(rows.map(\.1) == originals)
                for (location, original) in rows {
                    #expect(location.variant == .mboxcl2)
                    let bytes = source[Int(location.offset)..<(Int(location.offset) + location.byteCount)]
                    #expect(Data(bytes) == original)
                }
            }
        }
    }

    @Test("Ambiguous Content-Length quoting requires an explicit variant, and historical modes use their own From rule")
    func variantChoice() throws {
        let body = Data(">From escaped\n>>From original quote\nLast\n".utf8)
        let stored = message(body, length: body.count), source = separator + stored + Data([10])
        #expect(throws: MailImportError.variantRequired) { try decode(source) }
        #expect(try decode(source, variant: .mboxcl2).first?.1 == stored)
        let legacy = message(Data("From escaped\n>>From original quote\nLast\n".utf8), length: body.count)
        #expect(try decode(source, variant: .mboxcl).first?.1 == legacy)
        let noLength = message(body), unframed = separator + noLength + Data([10])
        #expect(try decode(unframed, variant: .mboxo).first?.1 == message(Data("From escaped\n>>From original quote\nLast\n".utf8)))
        #expect(try decode(unframed, variant: .mboxrd).first?.1 == message(Data("From escaped\n>From original quote\nLast\n".utf8)))
    }

    @Test("Every explicit variant reaches the real archive importer with its expected original bytes and readable body")
    func variantsReachArchive() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue)
        let archive = try await mail.createLocalArchive(name: "Variants", inboxName: "Inbox", trashName: "Trash", archiveName: "Archive")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let storedBody = Data(">From escaped\n>>From quoted\nLast\n".utf8)
        for variant in [MailMboxVariant.mboxrd, .mboxo, .mboxcl, .mboxcl2] {
            let hasLength = variant == .mboxcl || variant == .mboxcl2
            let input = message(storedBody, length: hasLength ? storedBody.count : nil)
            let file = root.appendingPathComponent(variant.rawValue + ".mbox")
            try (separator + input + Data([10])).write(to: file)
            let preview = try MailImportReader.read([file], variant: variant)
            #expect(preview.candidates.count == 1 && preview.failures.isEmpty)
            let batch = try await mail.importMessages(preview, archiveID: archive.id)
            let result = try #require(batch.results.first), id = try #require(result.messageID)
            #expect(result.status == .imported && result.sourceVariant == variant)
            let expectedBody: Data
            switch variant {
            case .mboxrd: expectedBody = Data("From escaped\n>From quoted\nLast\n".utf8)
            case .mboxo, .mboxcl: expectedBody = Data("From escaped\n>>From quoted\nLast\n".utf8)
            default: expectedBody = storedBody
            }
            let expected = message(expectedBody, length: hasLength ? storedBody.count : nil)
            #expect(try await mail.rawMessage(id: id)?.data == expected)
            #expect(try await mail.body(messageId: id)?.textBody?.contains("From escaped") == true)
            let repeated = try await mail.importMessages(preview, archiveID: archive.id)
            #expect(repeated.results.first?.status == .duplicate && repeated.results.first?.sourceVariant == variant)
        }
    }

    @Test("Invalid, duplicated, folded or truncated lengths never publish the affected message")
    func malformedLength() throws {
        for field in ["Content-Length: -1", "Content-Length: +3", "Content-Length: 9999999999999999999999999999999",
                      "Content-Length : 3", "Content-Length\t: 3",
                      "Content-Length: 3\nContent-Length: 3", "Content-Length: 3\n continued", "Content-Length: 200"] {
            let source = separator + Data(("Subject: Invalid\n" + field + "\n\nabc\n").utf8)
            var published = 0, position = 0
            #expect(throws: MailImportError.self) {
                try MailMboxCodec.decodeStream(read: { maximum in
                    let end = min(position + maximum, source.count), data = Data(source[position..<end]); position = end; return data
                }, consume: { _, _, _ in published += 1 })
            }
            #expect(published == 0)
        }
        let noLength = separator + message(Data("Body\n".utf8))
        #expect(throws: MailImportError.unsupported) { try decode(noLength, variant: .mboxcl2) }
        let empty = separator + message(Data())
        #expect(try decode(empty).first?.1 == message(Data()))
    }

    @Test("Virtual mailboxes larger than the former whole-file limit are consumed in bounded chunks")
    func largeVirtualSource() throws {
        let original = message(Data(repeating: 120, count: 512 * 1024) + Data([10]))
        let record = try MailMboxCodec.encode(original, date: nil).data
        let repetitions = 260
        var sourceRecord = 0, offset = 0, count = 0, readBytes = 0, largestRequest = 0
        try MailMboxCodec.decodeStream(read: { maximum in
            largestRequest = max(largestRequest, maximum)
            guard sourceRecord < repetitions else { return Data() }
            let end = min(offset + maximum, record.count), data = Data(record[offset..<end])
            readBytes += data.count; offset = end
            if offset == record.count { offset = 0; sourceRecord += 1 }
            return data
        }, consume: { index, _, raw in
            #expect(index == count && raw.count == original.count)
            if index == 0 || index == repetitions - 1 { #expect(raw == original) }
            count += 1
        })
        #expect(count == repetitions && readBytes > MailImportReader.maximumBytes)
        #expect(largestRequest <= 64 * 1024)
    }

    @Test("Cancellation after one record prevents any later record callback")
    func cancellation() async throws {
        let record = try MailMboxCodec.encode(message(Data("Body\n".utf8)), date: nil).data
        let source = record + record
        let result = await Task.detached { () -> Int in
            var position = 0, count = 0
            do {
                try MailMboxCodec.decodeStream(read: { maximum in
                    let end = min(position + maximum, source.count), data = Data(source[position..<end]); position = end; return data
                }, consume: { _, _, _ in count += 1; withUnsafeCurrentTask { $0?.cancel() } })
            } catch is CancellationError { return count }
            catch { Issue.record("Unexpected stream cancellation error: \(error)") }
            return -1
        }.value
        #expect(result == 1)
    }

    @Test("A changed source invalidates every candidate read from that file, while earlier stable files survive")
    func changedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = root.appendingPathComponent("stable.eml"), changed = root.appendingPathComponent("changing.mbox")
        try message(Data("Stable\n".utf8)).write(to: stable)
        let record = try MailMboxCodec.encode(message(Data("Changing\n".utf8)), date: nil).data
        try (record + record).write(to: changed)
        let preview = try MailImportReader.read([stable, changed]) { count in
            if count == 2 {
                do { try Data("Changed".utf8).write(to: changed) }
                catch { Issue.record("Fixture mutation failed: \(error)") }
            }
        }
        #expect(preview.candidates.count == 1 && preview.candidates[0].source == "stable.eml")
        #expect(preview.byteCount == preview.candidates[0].data.count)
        #expect(preview.failures.count == 1 && preview.failures[0].error == .changed)
        let ambiguousBody = Data(">From ambiguous\n".utf8)
        let ambiguous = separator + message(ambiguousBody, length: ambiguousBody.count) + Data([10])
        try (record + ambiguous + record).write(to: changed)
        let rejected = try MailImportReader.read([stable, changed]) { count in
            if count == 2 {
                do { try Data("Changed while framing failed".utf8).write(to: changed) }
                catch { Issue.record("Fixture mutation failed: \(error)") }
            }
        }
        #expect(rejected.candidates.count == 1 && rejected.candidates[0].source == "stable.eml")
        #expect(rejected.failures.count == 1 && rejected.failures[0].error == .changed)
    }

    @MainActor
    @Test("The import wizard reparses an ambiguous source using the chosen format, freezes busy choices and cannot act after closing")
    func wizardVariantAndClose() async throws {
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let mail = MailService(databaseQueue: queue), hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ambiguous.mbox"), body = Data(">From original quote\nBody\n".utf8)
        try (separator + message(body, length: body.count) + Data([10])).write(to: file)
        let model = MailImportModel(hub: hub, space: .work)
        model.readFiles([file]); await wait(model)
        #expect(model.requiresMboxChoice && model.preview?.candidates.isEmpty == true)
        #expect(try await MailAccountService(databaseQueue: queue, space: .work).getAll().isEmpty)
        model.setMboxVariant(.mboxcl2)
        #expect(model.busy && model.preview == nil)
        model.setMboxVariant(.mboxcl)
        #expect(model.mboxVariant == .mboxcl2)
        await wait(model)
        let candidate = try #require(model.preview?.candidates.first)
        let firstIndex = try #require(model.preview)
        let candidateData = try await firstIndex.access.original(candidate.id).data
        #expect(candidateData == message(body, length: body.count) && !model.requiresMboxChoice)
        model.setSelected(candidate.id, selected: false)
        model.setMboxVariant(.mboxcl); await wait(model)
        let revised = try #require(model.preview), revisedItem = try #require(revised.candidates.first)
        #expect(try await revised.access.original(revisedItem.id).data != candidateData && model.selectedCandidates.count == 1)
        model.setMboxVariant(.mboxcl2); await wait(model)
        model.start(); await wait(model)
        let result = try #require(model.batch?.results.first), id = try #require(result.messageID)
        #expect(result.sourceVariant == .mboxcl2)
        #expect(try await mail.rawMessage(id: id)?.data == candidateData)
        let archive = try #require(model.batch?.accountID)
        let history = try await mail.importBatches(archiveID: archive)
        #expect(history.first?.results.first?.sourceVariant == .mboxcl2)
        let backup = try await SpaceDatabaseBackupStore(queue: queue, space: "work").export()
        let restored = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(restored)
        let target = SpaceDatabaseBackupStore(queue: restored, space: "work")
        let plan = try await target.plan(backup, sourceSpace: "work")
        _ = try await target.apply(plan, willCommit: { _ in })
        #expect(try await MailService(databaseQueue: restored).importBatches(archiveID: archive).first?.results.first?.sourceVariant == .mboxcl2)
        model.prepareUndo(); await wait(model)
        let pendingUndo = try #require(model.undoPlan)
        model.close()
        #expect(model.preview == nil && model.batch == nil && !model.busy)
        model.readFiles([file]); model.start(); model.setMboxVariant(.mboxo); model.confirmUndo(pendingUndo)
        #expect(!model.busy && model.mboxVariant == .mboxcl2)
        #expect(try await mail.importBatches(archiveID: archive).count == 1)
        #expect(try await mail.rawMessage(id: id)?.data == candidateData)
    }

    @MainActor private func wait(_ model: MailImportModel) async {
        for _ in 0..<500 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy, Comment(rawValue: String(describing: model.error)))
    }
}
