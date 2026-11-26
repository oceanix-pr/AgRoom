import CryptoKit
import Foundation

public enum MailAttachmentError: Error, Sendable { case capacity, invalidMetadata, corrupt, sourceNotReady }
public enum MailForwardAttachmentsState: String, Codable, Sendable { case pending, loaded, omitted }

/// Drafts own bytes, not a path or a persistent authorization to an external file.
public struct MailDraftAttachment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let sourceAttachmentID: UUID?
    public let sha256: String
    public static let maximumFileBytes = 25 * 1024 * 1024
    public static let maximumTotalBytes = 32 * 1024 * 1024
    public static let maximumCount = 20
    public static let maximumSerializedBytes = 48 * 1024 * 1024

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data, sourceAttachmentID: UUID? = nil) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.data = data
        self.sourceAttachmentID = sourceAttachmentID
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case id, filename, mimeType, data, sourceAttachmentID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), filename: try values.decode(String.self, forKey: .filename),
            mimeType: try values.decode(String.self, forKey: .mimeType), data: try values.decode(Data.self, forKey: .data),
            sourceAttachmentID: try values.decodeIfPresent(UUID.self, forKey: .sourceAttachmentID))
    }

    public static func validate(_ attachments: [Self]) throws {
        guard attachments.count <= maximumCount, Set(attachments.map(\.id)).count == attachments.count else { throw MailAttachmentError.capacity }
        var bytes = 0
        for item in attachments {
            guard item.data.count <= maximumFileBytes, item.data.count <= maximumTotalBytes - bytes else { throw MailAttachmentError.capacity }
            bytes += item.data.count
            guard !item.filename.isEmpty, item.filename.utf8.count <= 240, item.filename != ".", item.filename != "..",
                  !item.filename.contains("/"), !item.filename.contains("\\"), item.filename.rangeOfCharacter(from: .controlCharacters) == nil,
                  item.mimeType.range(of: #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#, options: .regularExpression) != nil else {
                throw MailAttachmentError.invalidMetadata
            }
        }
    }
}
