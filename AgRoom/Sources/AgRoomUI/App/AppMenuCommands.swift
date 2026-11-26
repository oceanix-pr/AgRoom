import SwiftUI
import AgRoomCore

public enum AppMenuCommand: String, CaseIterable, Sendable {
    case newChat, search, taskCenter, artifactLibrary, toggleSidebar, noteScreenshot, noteRecording, notePaste

    public var labelKey: String {
        switch self {
        case .newChat: "chat.new"
        case .search: "search.space.title"
        case .taskCenter: "menu.task_center"
        case .artifactLibrary: "menu.artifact_library"
        case .toggleSidebar: "menu.toggle_sidebar"
        case .noteScreenshot: "notes.screenshot.selection"
        case .noteRecording: "notes.record.toggle"
        case .notePaste: "notes.paste.new"
        }
    }
}

struct NotesMenuActions {
    var enabled: Bool
    var create: () -> Void
    var save: () -> Void
    var importFile: () -> Void
    var export: () -> Void
}
private struct NotesMenuKey: FocusedValueKey { typealias Value = NotesMenuActions }
extension FocusedValues {
    var notesMenuActions: NotesMenuActions? {
        get { self[NotesMenuKey.self] }
        set { self[NotesMenuKey.self] = newValue }
    }
}

struct ChatMenuActions {
    var find: () -> Void
    var export: (() -> Void)?
    var stop: (() -> Void)?
}

struct MailMenuActions {
    var compose: (() -> Void)?
    var reply: (() -> Void)?
    var replyAll: (() -> Void)?
    var forward: (() -> Void)?
    var archive: (() -> Void)?
    var trash: (() -> Void)?
    var sync: (() -> Void)?
    var export: (() -> Void)? = nil
    var importMail: (() -> Void)? = nil
    var trashTitleKey: String = "mail.action.trash"
    var move: (() -> Void)? = nil
    var archiveUnavailableReason: String? = nil
    var trashUnavailableReason: String? = nil
    var moveUnavailableReason: String? = nil
    var manageFolders: (() -> Void)? = nil
}

private struct MailMenuKey: FocusedValueKey { typealias Value = MailMenuActions }
extension FocusedValues {
    var mailMenuActions: MailMenuActions? {
        get { self[MailMenuKey.self] }
        set { self[MailMenuKey.self] = newValue }
    }
}

private struct ChatMenuKey: FocusedValueKey { typealias Value = ChatMenuActions }
extension FocusedValues {
    var chatMenuActions: ChatMenuActions? {
        get { self[ChatMenuKey.self] }
        set { self[ChatMenuKey.self] = newValue }
    }
}

/// Menus reuse the sidebar's navigation catalogue and the existing chat actions.
public struct AppMenuCommands: Commands {
    let openPage: (HubNavItem) -> Void
    let perform: (AppMenuCommand) -> Void
    let currentSpace: () -> AppSpace?
    @FocusedValue(\.chatMenuActions) private var chat
    @FocusedValue(\.mailMenuActions) private var mail
    @FocusedValue(\.notesMenuActions) private var notes

    public init(openPage: @escaping (HubNavItem) -> Void, perform: @escaping (AppMenuCommand) -> Void, currentSpace: @escaping () -> AppSpace? = { nil }) {
        self.openPage = openPage; self.perform = perform; self.currentSpace = currentSpace
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L.string(notes != nil ? "notes.new" : (mail == nil ? "chat.new" : "mail.action.compose"))) {
                if let notes { notes.create() } else if let mail { mail.compose?() } else { perform(.newChat) }
            }.keyboardShortcut("n", modifiers: .command)
                .disabled((mail != nil && mail?.compose == nil) || notes?.enabled == false)
        }
        CommandMenu(L.string("menu.navigate")) {
            Button(L.string("search.space.title")) { perform(.search) }.keyboardShortcut("k", modifiers: .command)
            Button(L.string("menu.task_center")) { perform(.taskCenter) }.keyboardShortcut("j", modifiers: [.command, .shift])
            Button(L.string("menu.artifact_library")) { perform(.artifactLibrary) }.keyboardShortcut("o", modifiers: [.command, .shift])
            ForEach(HubNavSection.allCases, id: \.self) { section in
                Divider()
                ForEach(section.items.filter { $0 != .settings && $0 != .help }) { page in
                    Button(L.string(page.labelKey)) { openPage(page) }
                }
            }
        }
        CommandMenu(L.string("nav.notes")) {
            Button(L.string("nav.notes")) { openPage(.notes) }
            Button(L.string("notes.screenshot.selection")) { perform(.noteScreenshot) }
            Button(L.string(currentSpace().map { NotesRecordingStatus.shared.isRecording(space: $0) } == true ? "notes.stop" : "notes.record")) { perform(.noteRecording) }
            Button(L.string("notes.paste.new")) { perform(.notePaste) }
            Divider()
            Button(L.string("notes.new")) { notes?.create() }.disabled(notes?.enabled != true)
            Button(L.string("notes.save")) { notes?.save() }.disabled(notes?.enabled != true)
            Button(L.string("notes.import")) { notes?.importFile() }.disabled(notes?.enabled != true)
            Button(L.string("notes.export")) { notes?.export() }.disabled(notes?.enabled != true)
        }
        CommandMenu(L.string("nav.chat")) {
            Button(L.string("chat.search.placeholder")) { chat?.find() }
                .keyboardShortcut("f", modifiers: .command).disabled(chat == nil)
            Button(L.string("chat.session.export")) { chat?.export?() }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(chat?.export == nil)
            Divider()
            Button(L.string("chat.stop")) { chat?.stop?() }
                .keyboardShortcut(".", modifiers: .command).disabled(chat?.stop == nil)
        }
        CommandMenu(L.string("nav.mail")) {
            Button(L.string("mail.import.title")) { mail?.importMail?() }
                .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(mail?.importMail == nil)
            Button(L.string("mail.export.title")) { mail?.export?() }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(mail?.export == nil)
            Button(L.string("mail.folder.edit.manage")) { mail?.manageFolders?() }.disabled(mail?.manageFolders == nil)
            Divider()
            Button(L.string("mail.action.reply")) { mail?.reply?() }
                .keyboardShortcut("r", modifiers: .command).disabled(mail?.reply == nil)
            Button(L.string("mail.action.replyAll")) { mail?.replyAll?() }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(mail?.replyAll == nil)
            Button(L.string("mail.action.forward")) { mail?.forward?() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(mail?.forward == nil)
            Divider()
            Button(L.string("mail.action.archive")) { mail?.archive?() }
                .keyboardShortcut("a", modifiers: [.command, .control]).disabled(mail?.archive == nil)
            if let reason = mail?.archiveUnavailableReason { Text(reason).font(.caption) }
            Button(L.string("mail.move.title")) { mail?.move?() }
                .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(mail?.move == nil)
            if let reason = mail?.moveUnavailableReason { Text(reason).font(.caption) }
            Button(L.string(mail?.trashTitleKey ?? "mail.action.trash")) { mail?.trash?() }.disabled(mail?.trash == nil)
            if let reason = mail?.trashUnavailableReason { Text(reason).font(.caption) }
            Button(L.string("mail.sync.refresh")) { mail?.sync?() }
                .keyboardShortcut("r", modifiers: [.command, .control]).disabled(mail?.sync == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(L.string("menu.toggle_sidebar")) { perform(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}
