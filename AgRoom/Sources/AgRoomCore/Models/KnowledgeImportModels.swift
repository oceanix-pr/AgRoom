import Foundation

public struct KnowledgeLocation: Codable, Equatable, Sendable {
    public var page: Int?
    public var slide: Int?
    public var sheet: String?
    public var cellRange: String?
    public var chapter: String?
    public var anchor: String?
    public var startTime: Double?
    public var endTime: Double?
    /// Normalized rectangle in the source page, when supplied by the extractor.
    public var rectangle: [Double]?
    public init(page: Int? = nil, slide: Int? = nil, sheet: String? = nil,
                cellRange: String? = nil, chapter: String? = nil, anchor: String? = nil,
                startTime: Double? = nil, endTime: Double? = nil, rectangle: [Double]? = nil) {
        self.page = page; self.slide = slide; self.sheet = sheet; self.cellRange = cellRange
        self.chapter = chapter; self.anchor = anchor; self.startTime = startTime
        self.endTime = endTime; self.rectangle = rectangle
    }
}

public struct KnowledgeBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: String
    public var text: String
    public var location: KnowledgeLocation
    public var startOffset: Int
    /// Table cells retain their coordinates, raw value and formula independently of Markdown.
    public var cells: [KnowledgeCell]?
    public init(kind: String = "paragraph", text: String, location: KnowledgeLocation = .init(),
                cells: [KnowledgeCell]? = nil) {
        self.id = UUID(); self.kind = kind; self.text = text; self.location = location
        self.startOffset = 0; self.cells = cells
    }
}

public struct KnowledgeCell: Codable, Equatable, Sendable {
    public var reference: String
    public var value: String
    public var formula: String?
    public var type: String?
    public init(reference: String, value: String, formula: String? = nil, type: String? = nil) {
        self.reference = reference; self.value = value; self.formula = formula; self.type = type
    }
}

public struct KnowledgeExtraction: Codable, Equatable, Sendable {
    public var title: String
    public var blocks: [KnowledgeBlock]
    public var warnings: [String]
    public var parser: String
    public var metadata: [String: String]
    public var content: String { blocks.map(\.text).joined(separator: "\n\n") }
    public init(title: String, blocks: [KnowledgeBlock], warnings: [String] = [],
                parser: String, metadata: [String: String] = [:]) {
        self.title = title; self.warnings = warnings; self.parser = parser; self.metadata = metadata
        var offset = 0
        self.blocks = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
            var block = $0; block.startOffset = offset; offset += block.text.count + 2; return block
        }
    }
}

public enum KnowledgeImportError: String, Error, LocalizedError, Sendable {
    case unsupported, unreadable, empty, tooLarge, encrypted, archiveInvalid, encoding,
         targetMissing, changed, conflict, converterMissing, speechUnavailable, mediaUnsupported,
         permission, sourceMissing, corrupt, timedOut
    public var errorDescription: String? { "knowledge.import.error.\(rawValue)" }
}

public struct KnowledgeImportOptions: Codable, Equatable, Sendable {
    public enum OCRMode: String, Codable, CaseIterable, Sendable { case automatic, textOnly, force }
    public var ocr: OCRMode = .automatic
    public var encoding: String = "automatic"
    public var language: String = "zh-CN"
    public var preserveFolders = true
    public var includeHidden = false
    public var includeNotes = true
    public var videoFrames = true
    public var firstPage: Int? = nil
    public var lastPage: Int? = nil
    public init() {}
    public var identity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return "knowledge-extract-v1:" + String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

public struct KnowledgeRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var item: KnowledgeItem
    public var sourceID: UUID?
    public var assetPath: String?
    public var assetHash: String?
    public var parser: String
    public var blocks: [KnowledgeBlock]
    public var warnings: [String]
    public var metadata: [String: String]
    public var origin: String
    public var createdAt: Date
    public var parentID: UUID?
    public init(item: KnowledgeItem, extraction: KnowledgeExtraction, origin: String,
                sourceID: UUID? = nil, assetPath: String? = nil, assetHash: String? = nil,
                parentID: UUID? = nil) {
        self.id = UUID(); self.item = item; self.sourceID = sourceID
        self.assetPath = assetPath; self.assetHash = assetHash; self.parser = extraction.parser
        self.blocks = extraction.blocks; self.warnings = extraction.warnings
        self.metadata = extraction.metadata; self.origin = origin; self.createdAt = Date(); self.parentID = parentID
    }
}

public struct KnowledgeSource: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var itemID: UUID
    public var key: String
    public var path: String
    public var hash: String
    public var profile: String
    public var importedRevisionID: UUID
    public var collectionID: UUID?
    public var missing: Bool
    public var suppressed: Bool
    public var updatedAt: Date
    public var requiresSelection: Bool? = nil
}

public struct KnowledgeImportCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var path: String
    public var relativeFolder: String
    public var rootPath: String
    public var bookmark: Data?
    public var size: Int64
    public var supported: Bool
    public init(path: String, relativeFolder: String = "", rootPath: String, bookmark: Data? = nil,
                size: Int64, supported: Bool) {
        self.path = path; self.relativeFolder = relativeFolder; self.rootPath = rootPath
        self.bookmark = bookmark; self.size = size; self.supported = supported
    }
}

public struct KnowledgeImportBatch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var baseID: UUID?
    public var folderID: UUID?
    public var options: KnowledgeImportOptions
    public var candidates: [KnowledgeImportCandidate]
    public var collectionID: UUID?
    public var createdAt: Date = Date()
    public init(baseID: UUID?, folderID: UUID? = nil, options: KnowledgeImportOptions = .init(),
                candidates: [KnowledgeImportCandidate], collectionID: UUID? = nil) {
        self.baseID = baseID; self.folderID = folderID; self.options = options
        self.candidates = candidates; self.collectionID = collectionID
    }
}

public struct KnowledgeImportTask: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case queued, extracting, committed, skipped, conflict, failed, cancelled }
    public var id: UUID
    public var batchID: UUID
    public var candidate: KnowledgeImportCandidate
    public var state: State = .queued
    public var errorCode: String?
    public var revisionID: UUID?
    public var updatedAt = Date()
    public var isFinished: Bool { [.committed, .skipped].contains(state) }
}

public struct KnowledgeSourceCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var path: String
    public var bookmark: Data?
    public var baseID: UUID
    public var folderID: UUID?
    public var options: KnowledgeImportOptions
    public var paused = false
    public var lastScan: Date?
    public var errorCode: String?
    public init(path: String, bookmark: Data?, baseID: UUID, folderID: UUID?, options: KnowledgeImportOptions) {
        self.path = path; self.bookmark = bookmark; self.baseID = baseID
        self.folderID = folderID; self.options = options
    }
}

public struct KnowledgeImportReport: Sendable {
    public var imported = 0
    public var skipped = 0
    public var conflicts = 0
    public var failures = 0
    public init() {}
}

public enum KnowledgeImportDisposition: String, Sendable { case new, duplicate, unchanged, update, conflict }
public enum KnowledgeImportDecision: String, CaseIterable, Codable, Sendable { case skip, save, copy }

/// Preview contents are immutable; commit rechecks both the source bytes and the
/// live entry. A filename or a restored batch is never a file access grant.
public struct KnowledgeImportPreview: Identifiable, Sendable {
    public let id: UUID
    public let space: AppSpace
    public let selectedURL: URL
    public let candidate: KnowledgeImportCandidate
    public let extraction: KnowledgeExtraction
    public let sourceHash: String
    public let disposition: KnowledgeImportDisposition
    public let source: KnowledgeSource?
    public let existingItem: KnowledgeItem?
    public let expectedContentHash: String?
    public let options: KnowledgeImportOptions
}

public struct KnowledgeSourceStatus: Identifiable, Sendable {
    public enum State: String, Sendable { case current, changed, missing, needsSelection, failed }
    public let source: KnowledgeSource
    public let state: State
    public let edited: Bool
    public var id: UUID { source.id }
}
