import Foundation

public enum MailListOrder: String, Codable, Sendable, CaseIterable { case newest, oldest, sender, subject }
public enum MailListDensity: String, Codable, Sendable, CaseIterable { case comfortable, compact }
public struct MailListPresentation: Codable, Sendable, Equatable {
    public var order: MailListOrder = .newest
    public var snippetLines = 2
    public var density: MailListDensity = .comfortable
    public init() {}
    public func validate() throws {
        guard (0...4).contains(snippetLines) else { throw MailSearchError.invalidFilter }
    }
}
