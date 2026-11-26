import Foundation
import AgRoomCore

@MainActor enum MailReferenceRoute {
    static let notification = Notification.Name("agroom.mail.openReference")
    @discardableResult static func open(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == MailSourceReference.scheme else { return false }
        NotificationCenter.default.post(name: notification, object: url)
        return true
    }
}
