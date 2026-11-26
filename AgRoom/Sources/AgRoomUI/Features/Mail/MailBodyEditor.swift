import AppKit
import SwiftUI
import AgRoomCore

@MainActor @Observable
final class MailBodyFormatControls {
    @ObservationIgnored weak var editor: NSTextView?
    private(set) var active = MailTextStyle()

    func update() {
        guard let editor else { active = []; return }
        let selection = editor.selectedRange()
        guard selection.length > 0 else { active = MailBodyEditor.style(editor.typingAttributes); return }
        var common: MailTextStyle = [.bold, .italic, .underline]
        editor.textStorage?.enumerateAttributes(in: selection) { attributes, _, stop in
            common.formIntersection(MailBodyEditor.style(attributes))
            if common.isEmpty { stop.pointee = true }
        }
        active = common
    }

    func toggle(_ mark: MailTextStyle) {
        guard let editor, editor.isEditable, let storage = editor.textStorage else { return }
        editor.window?.makeFirstResponder(editor)
        let selection = editor.selectedRange()
        update()
        let remove = active.contains(mark)
        func changed(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var style = MailBodyEditor.style(attributes)
            if remove { style.remove(mark) } else { style.insert(mark) }
            return MailBodyEditor.attributes(style)
        }
        if selection.length == 0 {
            editor.typingAttributes = changed(editor.typingAttributes)
        } else {
            guard editor.shouldChangeText(in: selection, replacementString: nil) else { return }
            let original = storage.attributedSubstring(from: selection)
            storage.beginEditing()
            original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { value, range, _ in
                storage.setAttributes(changed(value), range: NSRange(location: selection.location + range.location, length: range.length))
            }
            storage.endEditing()
            editor.didChangeText()
        }
        update()
    }
}

struct MailBodyEditor: NSViewRepresentable {
    let model: MailComposeViewModel
    let controls: MailBodyFormatControls

    static func style(_ attributes: [NSAttributedString.Key: Any]) -> MailTextStyle {
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        var style = MailTextStyle()
        if traits.contains(.bold) { style.insert(.bold) }
        if traits.contains(.italic) { style.insert(.italic) }
        if (attributes[.underlineStyle] as? NSNumber)?.intValue != 0, attributes[.underlineStyle] != nil { style.insert(.underline) }
        return style
    }

    static func attributes(_ style: MailTextStyle) -> [NSAttributedString.Key: Any] {
        var traits = NSFontDescriptor.SymbolicTraits()
        if style.contains(.bold) { traits.insert(.bold) }
        if style.contains(.italic) { traits.insert(.italic) }
        let font = NSFont.systemFont(ofSize: 14)
        var value: [NSAttributedString.Key: Any] = [
            .font: NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 14) ?? font,
            .foregroundColor: NSColor.textColor
        ]
        if style.contains(.underline) { value[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return value
    }

    // Programmatic signature, template and AI edits preserve styles in the unchanged prefix and suffix.
    static func retainedStyles(_ styles: [MailStyleSpan], from old: String, to new: String) -> [MailStyleSpan] {
        guard !styles.isEmpty else { return [] }
        let a = old as NSString, b = new as NSString, length = min(a.length, b.length)
        var prefix = 0, suffix = 0
        while prefix < length, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        if prefix < a.length, (0xDC00...0xDFFF).contains(a.character(at: prefix)) { prefix -= 1 }
        while suffix < length - prefix, a.character(at: a.length - suffix - 1) == b.character(at: b.length - suffix - 1) { suffix += 1 }
        if suffix > 0, (0xDC00...0xDFFF).contains(a.character(at: a.length - suffix)) { suffix -= 1 }
        var result: [MailStyleSpan] = []
        for span in styles {
            let head = NSIntersectionRange(span.range, NSRange(location: 0, length: prefix))
            if head.length > 0 { result.append(.init(range: head, style: span.style)) }
            let tail = NSIntersectionRange(span.range, NSRange(location: a.length - suffix, length: suffix))
            if tail.length > 0 {
                result.append(.init(range: NSRange(location: tail.location + b.length - a.length, length: tail.length), style: span.style))
            }
        }
        return result
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, controls: controls) }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = MailTextView()
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 10, height: 12)
        editor.typingAttributes = Self.attributes([])
        editor.setAccessibilityLabel(L.string("mail.compose.body"))
        editor.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = editor
        controls.editor = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = !model.isBusy && !model.isSendLocked
        let coordinator = context.coordinator, text = model.bodyText, styles = model.bodyStyles
        guard coordinator.text != text || coordinator.styles != styles else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        let value = NSMutableAttributedString(string: text, attributes: Self.attributes([]))
        for span in styles { value.setAttributes(Self.attributes(span.style), range: span.range) }
        let caret = min(editor.selectedRange().location, value.length)
        editor.textStorage?.setAttributedString(value)
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        editor.typingAttributes = caret > 0 ? value.attributes(at: caret - 1, effectiveRange: nil) : Self.attributes([])
        coordinator.text = text; coordinator.styles = styles
        // Native undo entries refer to the text that existed before the model replacement.
        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions(withTarget: editor)
        controls.update()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: MailComposeViewModel
        let controls: MailBodyFormatControls
        var text = ""
        var styles: [MailStyleSpan] = []
        var updating = false
        init(model: MailComposeViewModel, controls: MailBodyFormatControls) { self.model = model; self.controls = controls }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView, let storage = editor.textStorage else { return }
            var spans: [MailStyleSpan] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                let style = MailBodyEditor.style(value)
                guard !style.isEmpty else { return }
                if let last = spans.last, last.style == style, NSMaxRange(last.range) == range.location {
                    spans[spans.count - 1] = .init(range: NSUnionRange(last.range, range), style: style)
                } else { spans.append(.init(range: range, style: style)) }
            }
            text = editor.string; styles = spans
            model.setStyledBody(text, styles: spans)
            controls.update()
        }
        func textViewDidChangeSelection(_ notification: Notification) { if !updating { controls.update() } }
    }
}

private final class MailTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}
