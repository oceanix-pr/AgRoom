import Foundation
import CryptoKit
import GRDB

public enum MailSourceReferenceError: String, Error, Sendable { case invalid, differentSpace, missing }

/// Opaque, read-only local reference. No subject, address, body or credentials in the URL.
public struct MailSourceReference: Sendable, Equatable {
    public static let scheme = "agroom-mail"
    public let space: AppSpace
    public let accountID: UUID
    public let messageID: UUID
    public let fingerprint: String
    public init(message: MailMessage, space: AppSpace) {
        self.space = space; accountID = message.accountId; messageID = message.id
        fingerprint = Self.fingerprint(message)
    }
    public init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 512,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.user == nil, parts.password == nil, parts.port == nil,
              let space = parts.host.flatMap(AppSpace.init(rawValue:)), parts.fragment == nil else { throw MailSourceReferenceError.invalid }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, let account = UUID(uuidString: String(path[1])),
              let message = UUID(uuidString: String(path[2])), let items = parts.queryItems, items.count == 1,
              items[0].name == "v1", let hash = items[0].value, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MailSourceReferenceError.invalid }
        self.space = space; accountID = account; messageID = message; fingerprint = hash
    }
    public var url: URL {
        // All components are closed enums, UUIDs or validated hexadecimal values.
        URL(string: "\(Self.scheme)://\(space.rawValue)/\(accountID.uuidString)/\(messageID.uuidString)?v1=\(fingerprint)")!
    }
    private static func fingerprint(_ message: MailMessage) -> String {
        // Moving a message changes its folder/UID, but preserves this local source identity.
        let fields = [message.id.uuidString, message.accountId.uuidString, message.messageId ?? "", message.subject,
                      message.fromAddress, message.date.map { String($0.timeIntervalSince1970.bitPattern) } ?? ""]
        var data = Data()
        for field in fields { data.append(contentsOf: "\(field.utf8.count):".utf8); data.append(contentsOf: field.utf8) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func matches(_ message: MailMessage) -> Bool {
        message.accountId == accountID && message.id == messageID && Self.fingerprint(message) == fingerprint
    }
}

extension MailService {
    /// Synchronous, credential-free snapshot for an approval card. Execution reads it again.
    func replySource(id: UUID) throws -> MailMessage {
        let capture = ToolArtifactCapture.current
        return try databaseQueue.read { db in
            guard let message = try MailMessageRow.fetchOne(db, key: id.uuidString)?.toMessage() else { throw MailSourceReferenceError.missing }
            if let target = capture?.mailTarget {
                guard case .message(let url) = target, let ref = try? MailSourceReference(url: url),
                      ref.space == capture?.origin.space, ref.matches(message) else { throw MailSourceReferenceError.missing }
            }
            return message
        }
    }

    public func resolveSourceReference(_ reference: MailSourceReference, in space: AppSpace) async throws -> MailMessage {
        guard reference.space == space else { throw MailSourceReferenceError.differentSpace }
        return try await databaseQueue.read { db in
            guard let message = try MailMessageRow.fetchOne(db, key: reference.messageID.uuidString)?.toMessage(),
                  reference.matches(message),
                  try MailAccountRow.fetchOne(db, key: reference.accountID.uuidString) != nil else { throw MailSourceReferenceError.missing }
            return message
        }
    }
}
