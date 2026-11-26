import Foundation
import CryptoKit
import Security

/// Explicitly selected single Memonta entry only. Never scans the original
/// database, other entries, or any other space; legacy credentials are read-only.
public enum NoteLegacyImporter {
    public static func previewCollection(directory: URL, allowLegacyKeychain: Bool = false) throws -> [NotePackage] {
        try NoteCaptureRecovery.regularDirectory(directory)
        var entries: [URL] = []
        func collect(_ root: URL, months: Bool) throws {
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard children.count <= 10_000 else { throw NoteStoreError.tooLarge }
            for child in children {
                try Task.checkCancellation()
                if child.lastPathComponent.range(of: #"^\d{12}(\d{2})?(-[1-9]\d*)?$"#, options: .regularExpression) != nil {
                    try NoteCaptureRecovery.regularDirectory(child); entries.append(child)
                    guard entries.count <= 200 else { throw NoteStoreError.tooLarge }
                } else if months, child.lastPathComponent.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
                    try NoteCaptureRecovery.regularDirectory(child); try collect(child, months: false)
                }
            }
        }
        try collect(directory, months: true)
        guard !entries.isEmpty else { throw NoteStoreError.missing }
        var packages: [NotePackage] = [], bytes = 0
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let package = try preview(directory: entry, allowLegacyKeychain: allowLegacyKeychain)
            bytes += package.media.reduce(0) { $0 + $1.data.count } + (try JSONEncoder().encode(package.note).count)
            guard bytes <= NotePackage.maximumBytes else { throw NoteStoreError.tooLarge }
            packages.append(package)
        }
        return packages
    }
    public static func preview(directory: URL, key: Data? = nil, allowLegacyKeychain: Bool = false, plaintext: Bool = false, includeMedia: Bool = true) throws -> NotePackage {
        try NoteCaptureRecovery.regularDirectory(directory)
        var key = key
        func readText(_ name: String) throws -> String? {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NoteStoreError.invalidContent }
            if values.fileSize == 0 { return "" }
            let data = try NoteCaptureRecovery.read(url, maximum: 8 * 1024 * 1024)
            guard let value = String(data: data, encoding: .utf8) else { throw NoteStoreError.invalidContent }
            if plaintext { return value }
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let combined = Data(base64Encoded: candidate), combined.count >= 28 else { return value }
            if key == nil, allowLegacyKeychain {
                var result: CFTypeRef?
                let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
                    kSecAttrService: "com.Memonta.encryption", kSecAttrAccount: "encryption_key",
                    kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else { throw NoteStoreError.missing }
                key = data
            }
            guard let key, key.count == 32 else { throw NoteStoreError.missing }
            let decrypted = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key))
            guard let plaintext = String(data: decrypted, encoding: .utf8) else { throw NoteStoreError.invalidContent }
            return plaintext
        }
        var note = WorkNote(title: directory.lastPathComponent)
        let folderDate = directory.lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
        if [12,14].contains(folderDate.count) {
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = folderDate.count == 14 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"; formatter.isLenient = false
            if let date = formatter.date(from: folderDate) { note.createdAt = date; note.updatedAt = date }
        }
        if let metadata = try readText("meta.json") {
            struct Metadata: Decodable { var title: String?; var fileName: String?; var isHidden: Bool? }
            let value = try JSONDecoder().decode(Metadata.self, from: Data(metadata.utf8))
            note.title = value.title ?? value.fileName ?? note.title
            note.archived = value.isHidden ?? false
        }
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("meta.json").path), let title = try readText("title.txt"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        note.text = [try readText("source.txt"), try readText("ocr.txt")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if let transcript = try readText("transcript.json"), !transcript.isEmpty {
            struct Segment: Decodable { let startTime: Double; var endTime: Double?; let text: String; let speaker: String? }
            let values = try JSONDecoder().decode([Segment].self, from: Data(transcript.utf8))
            guard values.count <= 100_000, values.allSatisfy({ $0.startTime.isFinite && $0.startTime >= 0 && ($0.endTime.map { $0.isFinite } ?? true) }) else { throw NoteStoreError.invalidContent }
            note.segments = values.map { NoteSegment(timestamp: $0.startTime, endTimestamp: $0.endTime, speaker: $0.speaker ?? "", text: $0.text) }
            note.transcript = values.map(\.text).joined(separator: "\n")
        }
        let history = directory.appendingPathComponent("summary-history")
        if FileManager.default.fileExists(atPath: history.path) {
            try NoteCaptureRecovery.regularDirectory(history)
            let files = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            guard files.count <= 98 else { throw NoteStoreError.tooLarge }
            struct Revision: Decodable { let id: UUID; let date: Date; let text: String }
            var summaries: [NoteSummary] = []
            for file in files where file.pathExtension == "json" {
                guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { throw NoteStoreError.invalidContent }
                if let text = try readText("summary-history/" + file.lastPathComponent) {
                    let revision = try JSONDecoder().decode(Revision.self, from: Data(text.utf8))
                    var summary = NoteSummary(text: revision.text); summary.id = revision.id; summary.date = revision.date
                    summaries.append(summary)
                }
            }
            note.summaries = summaries.sorted { $0.date < $1.date }
        }
        note.visualNotes = try readText("visual.md")
        for file in ["summary.md"] {
            if let text = try readText(file), !text.isEmpty { note.summaries.append(NoteSummary(text: text)) }
        }
        if let todos = try readText("todos.json"), !todos.isEmpty {
            struct Todo: Decodable {
                let title: String; var dueDate: Date?
                var sourceSeekURL: String?; var notes: String?; var owner: String?; var priority: String?; var url: String?; var alarmOffsetMinutes: Int?; var evidenceQuote: String?
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { value in
                let container = try value.singleValueContainer()
                if let number = try? container.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: number) }
                let text = try container.decode(String.self), formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
                guard let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { throw NoteStoreError.invalidContent }
                return date
            }
            let data = Data(todos.utf8)
            struct Document: Decodable { let items: [Todo] }
            let values: [Todo]
            if let array = try? decoder.decode([Todo].self,from: data) { values = array }
            else { values = try decoder.decode(Document.self,from: data).items }
            note.todos = values.map { value in
                var todo = NoteTodo(title: value.title); todo.dueDate = value.dueDate
                todo.notes = value.notes; todo.owner = value.owner; todo.url = value.url; todo.evidenceQuote = value.evidenceQuote
                todo.priority = ["high": 1, "medium": 5, "low": 9, "none": 0][value.priority ?? "none"]
                todo.alarmOffsetMinutes = value.alarmOffsetMinutes
                if let raw = value.sourceSeekURL, let url = URL(string: raw), url.scheme?.lowercased() == "memonta", url.host?.lowercased() == "seek", let seconds = Double(url.lastPathComponent), seconds.isFinite, seconds >= 0 { todo.sourceTimestamp = seconds }
                return todo
            }
        }
        let extensions: Set<String> = ["m4a", "wav", "mp3", "aac", "caf", "flac", "ogg", "mp4", "mov", "m4v", "png", "jpg", "jpeg", "heic", "webp"]
        let files = try (includeMedia ? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []).filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 256 else { throw NoteStoreError.tooLarge }
        var media: [NotePackage.Media] = [], total = 0
        for url in files {
            let data = try NoteCaptureRecovery.read(url, maximum: NoteStore.maximumMediaBytes)
            total += data.count; guard total <= NotePackage.maximumBytes else { throw NoteStoreError.tooLarge }
            media.append(.init(id: UUID(), name: url.lastPathComponent, data: data, sha256: NoteMediaTranscriber.sourceHash(data)))
        }
        let package = NotePackage(format: "agroom-note-v1", note: note, media: media)
        try package.validate(); return package
    }
}
