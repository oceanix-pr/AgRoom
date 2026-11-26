import SwiftUI
import AppKit
import AgRoomCore

// MARK: - Editor Handle

/// 暴露 NSTextView 插入能力给工具栏
@MainActor
final class MarkdownEditorHandle {
    weak var textView: NSTextView?

    func insert(_ snippet: String) {
        guard let textView else { return }
        textView.insertText(snippet, replacementRange: textView.selectedRange())
    }
}

// MARK: - NSTextView Representable

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let handle: MarkdownEditorHandle

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text
        handle.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

// MARK: - Markdown Snippets

/// 工具栏插入片段（纯函数，可测试）
enum MarkdownSnippets {
    static let bold = "****"
    static let heading = "\n## "
    static let list = "\n- "
    static let inlineCode = "``"
    static let codeBlock = "\n```\ncode\n```\n"
    static let link = "[text](url)"
}

// MARK: - Markdown Editor View

/// Markdown 编辑器：左编辑（NSTextView）右预览（实时渲染），⌘S 原子保存
public struct MarkdownEditorView: View {
    let hub: Hub
    private let space: AppSpace
    @State private var savedText = ""
    @State private var busy = false
    @State private var draftTask: Task<Void, Never>?
    @State private var suggestedName = "untitled.md"

    @State private var text = ""
    @State private var fileURL: URL?
    @State private var isDirty = false
    @State private var statusMessage: String?
    private let handle = MarkdownEditorHandle()

    public init(hub: Hub) {
        self.hub = hub
        self.space = hub.spaceStore.current
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                MarkdownTextEditor(text: $text, handle: handle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: text) { _, _ in
                        isDirty = text != savedText
                        scheduleDraftSave()
                    }

                Divider()

                ScrollView {
                    MarkdownPreview(content: text, documentID: fileURL?.absoluteString ?? "editor", sourceContext: .scoped(to: space, baseURL: fileURL?.deletingLastPathComponent()))
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            }
            Divider()
            statusBar
        }
        .disabled(busy)
        .task {
            do {
                if text.isEmpty, let recovered = try await MarkdownDraftLifecycle.load(space: space), !Task.isCancelled {
                    text = recovered.text; suggestedName = recovered.suggestedName
                    isDirty = true
                    statusMessage = L.string("md.draft.restored")
                }
            } catch { statusMessage = "ERR:" + L.errorDescription(error) }
        }
        .onDisappear {
            draftTask?.cancel()
            updateRecoveryDraft()
            Task { try? await MarkdownDraftLifecycle.persist(space: space) }
        }
        // ⌘S 保存（隐藏按钮承载快捷键）
        .background(
            Button("", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .alert(L.string("common.error"), isPresented: Binding(
            get: { statusMessage?.hasPrefix("ERR:") == true },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(String((statusMessage ?? "").dropFirst(4)))
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: openFile) {
                Label(L.string("md.open"), systemImage: "folder")
            }
            Button(action: newFile) {
                Label(L.string("md.new"), systemImage: "doc.badge.plus")
            }
            Button(action: save) {
                Label(L.string("common.save"), systemImage: "square.and.arrow.down")
            }
            .disabled(!isDirty && fileURL != nil || fileURL == nil && text.isEmpty)

            Divider().frame(height: 16)

            snippetButton("bold", MarkdownSnippets.bold)
            snippetButton("heading", MarkdownSnippets.heading)
            snippetButton("list.bullet", MarkdownSnippets.list)
            snippetButton("chevron.left.forwardslash.chevron.right", MarkdownSnippets.inlineCode)
            snippetButton("text.alignleft", MarkdownSnippets.codeBlock)
            snippetButton("link", MarkdownSnippets.link)

            Spacer()

            if let url = fileURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func snippetButton(_ icon: String, _ snippet: String) -> some View {
        Button(action: { handle.insert(snippet) }) {
            Image(systemName: icon)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
    }

    private var statusBar: some View {
        HStack {
            Text("\(text.count) " + L.string("chat.usage.chars"))
                .font(.caption2)
                .foregroundColor(.secondary)
            if isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
            }
            Spacer()
            if let message = statusMessage, !message.hasPrefix("ERR:") {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - Actions

    private func updateRecoveryDraft() {
        MarkdownDraftLifecycle.update(isDirty ? MarkdownRecoveryDraft(text: text, suggestedName: fileURL?.lastPathComponent ?? suggestedName) : nil, space: space)
    }
    private func scheduleDraftSave() {
        updateRecoveryDraft()
        draftTask?.cancel()
        draftTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await MarkdownDraftLifecycle.persist(space: space)
            } catch is CancellationError {
            } catch { statusMessage = "ERR:" + L.string("md.draft.save_failed") }
        }
    }
    private func confirmReplacement(_ action: @escaping () -> Void) {
        guard isDirty else { action(); return }
        let alert = NSAlert()
        alert.messageText = L.string("md.unsaved.title")
        alert.informativeText = L.string("md.unsaved.message")
        alert.addButton(withTitle: L.string("common.save"))
        alert.addButton(withTitle: L.string("md.discard"))
        alert.addButton(withTitle: L.string("common.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveThen(action)
        case .alertSecondButtonReturn: action()
        default: break
        }
    }
    private func newFile() {
        confirmReplacement {
            fileURL = nil; savedText = ""; text = ""; isDirty = false
            suggestedName = "untitled.md"
            scheduleDraftSave()
        }
    }
    private func openFile() {
        confirmReplacement {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText, .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            busy = true
            Task {
                defer { busy = false }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let value = try await Task.detached { try BoundedDocumentIO.read(url) }.value
                    savedText = value; text = value; fileURL = url; suggestedName = url.lastPathComponent
                    isDirty = false; statusMessage = nil
                    scheduleDraftSave()
                } catch { statusMessage = "ERR:" + L.errorDescription(error) }
            }
        }
    }
    private func save() { saveThen(nil) }
    private func saveThen(_ completion: (() -> Void)?) {
        var target = fileURL
        if target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = suggestedName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        guard let url = target, !busy else { return }
        let value = text
        guard value.utf8.count <= BoundedDocumentIO.limit else { statusMessage = "ERR:" + L.string("error.response_too_large"); return }
        busy = true
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await Task.detached { try Data(value.utf8).write(to: url, options: .atomic) }.value
                savedText = value; fileURL = url; isDirty = text != value
                statusMessage = L.string("md.saved")
                scheduleDraftSave()
                busy = false
                completion?()
            } catch { busy = false; statusMessage = "ERR:" + L.errorDescription(error) }
        }
    }

}

// MARK: - Markdown Preview

/// 编辑器复用聊天、技能与知识预览的同一渲染链路。
struct MarkdownPreview: View {
    let content: String
    var documentID = ""
    var sourceContext = MarkdownSourceContext()

    var body: some View {
        MarkdownView(text: content, documentID: documentID, sourceContext: sourceContext)
    }
}
