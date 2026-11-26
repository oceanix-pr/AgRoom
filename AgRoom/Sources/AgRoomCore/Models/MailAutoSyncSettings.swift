import Foundation

public struct MailAutoSyncSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var intervalMinutes = 5
    public var notifications = false
    public init() {}
    public func validate() throws {
        guard [1, 5, 15, 30, 60].contains(intervalMinutes) else { throw MailSearchError.invalidFilter }
    }
}

public struct MailAutoSyncStamp: Codable, Sendable {
    public let endpointFingerprint: String
    public let uidValidity: UInt32?
    public let highestUID: UInt32
    public init(endpointFingerprint: String, uidValidity: UInt32?, highestUID: UInt32) {
        self.endpointFingerprint = endpointFingerprint; self.uidValidity = uidValidity; self.highestUID = highestUID
    }
}

public struct MailAutoSyncBaseline: Codable, Sendable {
    public var stamps: [String: MailAutoSyncStamp] = [:]
    public init() {}
}
