import SwiftUI
import AgRoomCore

struct GlobalHotkeySettingsSection: View {
    @State private var toggleKey = GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.toggleKey, fallback: 49)
    @State private var toggleModifiers = GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.toggleModifiers, fallback: GlobalHotkeyPreferences.commandOption)
    @State private var captureKey = GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.captureKey, fallback: 1)
    @State private var captureModifiers = GlobalHotkeyPreferences.key(GlobalHotkeyPreferences.captureModifiers, fallback: GlobalHotkeyPreferences.commandControlOption)
    @AppStorage(GlobalHotkeyPreferences.statusKey) private var status = 0
    private let keys: [(String, Int)] = [("Space",49),("A",0),("B",11),("C",8),("D",2),("E",14),("F",3),("G",5),("H",4),("I",34),("J",38),("K",40),("L",37),("M",46),("N",45),("O",31),("P",35),("Q",12),("R",15),("S",1),("T",17),("U",32),("V",9),("W",13),("X",7),("Y",16),("Z",6)]
    var body: some View {
        Section(L.string("notes.settings.hotkeys")) {
            row("notes.settings.hotkeys.window", key: $toggleKey, modifiers: $toggleModifiers)
            row("notes.screenshot.selection", key: $captureKey, modifiers: $captureModifiers)
            if toggleKey == captureKey && toggleModifiers == captureModifiers {
                Text(L.string("notes.settings.hotkeys.conflict")).foregroundStyle(.red)
            } else if status != 0 { Text(L.string("notes.settings.hotkeys.failed")).foregroundStyle(.red) }
            Button(L.string("notes.settings.hotkeys.apply")) {
                let defaults = UserDefaults.standard
                defaults.set(toggleKey, forKey: GlobalHotkeyPreferences.toggleKey)
                defaults.set(toggleModifiers, forKey: GlobalHotkeyPreferences.toggleModifiers)
                defaults.set(captureKey, forKey: GlobalHotkeyPreferences.captureKey)
                defaults.set(captureModifiers, forKey: GlobalHotkeyPreferences.captureModifiers)
                NotificationCenter.default.post(name: GlobalHotkeyPreferences.didChange, object: nil)
            }
                .disabled(toggleKey == captureKey && toggleModifiers == captureModifiers)
            Text(L.string("notes.settings.hotkeys.hint")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func row(_ title: String, key: Binding<Int>, modifiers: Binding<Int>) -> some View {
        HStack {
            Text(L.string(title))
            Spacer()
            Picker(L.string("notes.settings.hotkeys.modifiers"), selection: modifiers) {
                Text("⌥⌘").tag(GlobalHotkeyPreferences.commandOption)
                Text("⌃⌥⌘").tag(GlobalHotkeyPreferences.commandControlOption)
                Text("⇧⌘").tag(GlobalHotkeyPreferences.commandShift)
                Text("⌃⌘").tag(GlobalHotkeyPreferences.commandControl)
            }.labelsHidden().frame(width: 110)
            Picker(L.string("notes.settings.hotkeys.key"), selection: key) {
                ForEach(keys, id: \.1) { Text($0.0).tag($0.1) }
            }.labelsHidden().frame(width: 90)
        }
    }
}
