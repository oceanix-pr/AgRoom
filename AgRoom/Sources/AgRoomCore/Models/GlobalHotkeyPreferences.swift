import Foundation

public enum GlobalHotkeyPreferences {
    public static let didChange = Notification.Name("agroom.hotkeys.changed")
    public static let toggleKey = "agroom.hotkey.toggle.key"
    public static let toggleModifiers = "agroom.hotkey.toggle.modifiers"
    public static let captureKey = "agroom.hotkey.capture.key"
    public static let captureModifiers = "agroom.hotkey.capture.modifiers"
    public static let statusKey = "agroom.hotkey.registrationStatus"
    // Carbon modifier bit masks; Core does not import platform UI.
    public static let commandOption = 2304
    public static let commandControlOption = 6400
    public static let commandShift = 768
    public static let commandControl = 4352
    public static func key(_ name: String, fallback: Int) -> Int { UserDefaults.standard.object(forKey: name) as? Int ?? fallback }
}
