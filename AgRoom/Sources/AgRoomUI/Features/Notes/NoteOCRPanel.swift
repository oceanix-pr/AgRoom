import AppKit
import SwiftUI

@MainActor
final class NoteOCRPanel {
    private var window: NSPanel?
    func show(text: String) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L.string("notes.ocr.pinned"); panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: NoteOCRPanelContent(text: text))
        panel.center(); panel.makeKeyAndOrderFront(nil)
        window = panel
    }
    func close() { window?.close(); window = nil }
}
private struct NoteOCRPanelContent: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(L.string("notes.ocr.pinned")).font(.headline); Spacer(); Button(L.string("notes.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } }
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(16).frame(minWidth: 300, minHeight: 200)
    }
}
