import SwiftUI
import AppKit
import os.signpost

// MARK: - Selectable Text View

/// 只读可选中的富文本视图：鼠标整体框选、⌘C/Ctrl+C 拷贝、右键「拷贝/全选」菜单。
///
/// 高度自适应：用**独立的** `NSLayoutManager` / `NSTextContainer` 按实际宽度完成排版，
/// 以 `usedRect`（以及结尾换行的额外行片段）计算高度。不能用 `boundingRect`：
/// 引用/列表的制表位可能让它只量到首行，得到远小于实际排版的高度。
/// 高度缓存保存在视图内部，键为「内容修订号 + 精确宽度」；`sizeThatFits` 与
/// `intrinsicContentSize` 共用同一测量路径，测量过程不修改屏幕上的文本视图。
@MainActor
final class SelectableTextView: NSTextView {

    private var currentProse: MarkdownProse?
    var currentAttributed: NSAttributedString? { currentProse?.attributedString }

    /// 独立测量栈：不挂在屏幕上的文本视图里，避免 sizeThatFits 过程中改动画布尺寸
    private let measurementStorage = NSTextStorage()
    private let measurementLayoutManager = NSLayoutManager()
    private let measurementContainer = NSTextContainer(
        containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private var isMeasurementStackConfigured = false

    /// 内容修订号：每次 setText 递增；与精确宽度共同构成高度缓存键
    private var contentRevision: UInt = 0
    private var heightCache: [HeightCacheKey: CGFloat] = [:]
    /// 单个富文本段的小缓存上限（窗口拖动会产生多个宽度，超出后整体清空）
    private static let heightCacheLimit = 12

    private struct HeightCacheKey: Hashable {
        let revision: UInt
        let width: CGFloat
    }

    static func make(attributed: NSAttributedString) -> SelectableTextView {
        make(prose: MarkdownProse(parts: [attributed]))
    }

    static func make(prose: MarkdownProse) -> SelectableTextView {
        let view = SelectableTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.allowsUndo = false
        view.usesFontPanel = false
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineBreakMode = .byWordWrapping
        // 测量容器使用同一套行距与非连续排版开关，避免两套排版结果漂移
        view.layoutManager?.usesFontLeading = true
        view.layoutManager?.allowsNonContiguousLayout = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setProse(prose)
        return view
    }

    private(set) var lastEditedRange = NSRange(location: 0, length: 0)

    func setText(_ attributed: NSAttributedString) {
        setProse(MarkdownProse(parts: [attributed]))
    }

    func setProse(_ prose: MarkdownProse) {
        guard currentProse !== prose else { return }
        let id = OSSignpostID(log: MarkdownTiming.log)
        os_signpost(.begin, log: MarkdownTiming.log, name: "Markdown TextKit update", signpostID: id)
        defer { os_signpost(.end, log: MarkdownTiming.log, name: "Markdown TextKit update", signpostID: id) }
        let previous = currentProse
        var shared = prose.prefix(sharedWith: previous)
        currentProse = prose
        if shared.count == prose.parts.count, shared.count == previous?.parts.count { return }
        // A trailing CR and the inserted paragraph separator can form one CRLF
        // grapheme. Include that part when checking the edit boundary.
        if shared.count > 0 {
            let last = prose.parts[shared.count - 1].string as NSString
            if last.length > 0, last.character(at: last.length - 1) == 13 {
                shared.count -= 1
                shared.length -= last.length + (shared.count > 0 ? 1 : 0)
            }
        }
        let oldTail = previous?.suffix(from: shared.count)
        let newTail = prose.suffix(from: shared.count)
        let prefix = oldTail.map { Self.commonPrefix($0, newTail) } ?? 0
        let oldLength = oldTail?.length ?? 0
        if prefix == oldLength, prefix == newTail.length { return }
        ensureMeasurementStack()
        let replacement = newTail.attributedSubstring(from: NSRange(location: prefix, length: newTail.length - prefix))
        let range = NSRange(location: shared.length + prefix, length: oldLength - prefix)
        lastEditedRange = range
        if let textStorage { textStorage.replaceCharacters(in: range, with: replacement) }
        measurementStorage.replaceCharacters(in: range, with: replacement)
        contentRevision &+= 1
        heightCache.removeAll(keepingCapacity: true)
        invalidateIntrinsicContentSize()
    }

    private static func commonPrefix(_ old: NSAttributedString, _ new: NSAttributedString) -> Int {
        let a = old.string as NSString, b = new.string as NSString
        let limit = min(a.length, b.length)
        var prefix = 0
        while prefix < limit, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var cursor = 0
        while cursor < prefix {
            var oldRange = NSRange(), newRange = NSRange()
            let oldAttributes = old.attributes(at: cursor, effectiveRange: &oldRange)
            let newAttributes = new.attributes(at: cursor, effectiveRange: &newRange)
            guard (oldAttributes as NSDictionary).isEqual(newAttributes) else { prefix = cursor; break }
            cursor = min(NSMaxRange(oldRange), NSMaxRange(newRange))
        }
        // Never edit between the UTF-16 units of a grapheme (emoji, accents).
        if prefix < a.length { prefix = min(prefix, a.rangeOfComposedCharacterSequence(at: prefix).location) }
        if prefix < b.length { prefix = min(prefix, b.rangeOfComposedCharacterSequence(at: prefix).location) }
        return prefix
    }

    /// 指定宽度下文本排版所需高度（与应用显示的 AppKit 排版同源）
    func heightForWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        let key = HeightCacheKey(revision: contentRevision, width: width)
        if let cached = heightCache[key] { return cached }

        let id = OSSignpostID(log: MarkdownTiming.log)
        os_signpost(.begin, log: MarkdownTiming.log, name: "Markdown TextKit layout", signpostID: id)
        defer { os_signpost(.end, log: MarkdownTiming.log, name: "Markdown TextKit layout", signpostID: id) }
        let height = measureHeight(width: width)
        guard height.isFinite, height >= 0 else { return 0 }
        if heightCache.count >= Self.heightCacheLimit {
            heightCache.removeAll(keepingCapacity: true)
        }
        heightCache[key] = height
        return height
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: bounds.width, height: heightForWidth(bounds.width))
    }

    /// 仅在宽度真正变化时失效固有高度。
    /// 不能在 layout() 里无条件失效：那会在每次 AppKit 布局后重新把窗口标记为
    /// 「需要再来一轮 Update Constraints」，标记数只增不减，累积超过窗口视图数后
    /// AppKit 抛 NSException（_postWindowNeedsUpdateConstraints）并以 SIGTRAP 终止
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    /// 富内容附件在纯文本剪贴板中使用 LaTeX / alt，避免复制出对象占位字符。
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        let selected = selectedRange()
        guard selected.length > 0 else { return false }
        let output = NSMutableString()
        storage.enumerateAttribute(.markdownAlternative, in: selected) { value, range, _ in
            output.append((value as? String) ?? (storage.string as NSString).substring(with: range))
        }
        return pboard.setString(output as String, forType: .string)
    }

    // Ctrl+C：有选区即拷贝（⌘C 走系统 Edit 菜单响应链，无需拦截）
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "c",
           flags == .control, selectedRange().length > 0 {
            copy(self)
            return
        }
        super.keyDown(with: event)
    }

    // 右键菜单：拷贝（有选区时可用）+ 全选。
    // 右键时先夺取第一响应者，保证选区高亮可见、菜单动作可靠派发
    override func menu(for event: NSEvent) -> NSMenu? {
        if let responder = window?.firstResponder, responder !== self {
            window?.makeFirstResponder(self)
        }
        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: L.string("common.copy"),
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = selectedRange().length > 0
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let selectAllItem = NSMenuItem(
            title: L.string("common.select_all"),
            action: #selector(selectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        return menu
    }

    // MARK: - Measurement

    private func ensureMeasurementStack() {
        guard !isMeasurementStackConfigured else { return }
        isMeasurementStackConfigured = true
        measurementContainer.widthTracksTextView = false
        measurementContainer.heightTracksTextView = false
        measurementContainer.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        measurementContainer.lineBreakMode = textContainer?.lineBreakMode ?? .byWordWrapping
        measurementLayoutManager.usesFontLeading = true
        measurementLayoutManager.allowsNonContiguousLayout = false
        measurementStorage.addLayoutManager(measurementLayoutManager)
        measurementLayoutManager.addTextContainer(measurementContainer)
    }

    private func measureHeight(width: CGFloat) -> CGFloat {
        guard measurementStorage.length > 0 else { return 0 }
        ensureMeasurementStack()

        let inset = textContainerInset
        let contentWidth = width - inset.width * 2
        guard contentWidth.isFinite, contentWidth > 0 else { return 0 }

        measurementContainer.containerSize = NSSize(
            width: contentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        measurementContainer.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        measurementContainer.lineBreakMode = textContainer?.lineBreakMode ?? .byWordWrapping

        measurementLayoutManager.ensureLayout(for: measurementContainer)
        var used = measurementLayoutManager.usedRect(for: measurementContainer)

        // 结尾换行会生成额外行片段；只取 usedRect 会少算最后一行
        if measurementLayoutManager.extraLineFragmentTextContainer === measurementContainer {
            let extra = measurementLayoutManager.extraLineFragmentRect
            if extra.height > 0 {
                used = used.union(extra)
            }
        }

        // 防御：测量容器自身若未覆盖全文，改用全文字形包围盒兜底，避免再次产生裁切
        let glyphRange = measurementLayoutManager.glyphRange(for: measurementContainer)
        let allGlyphsLaidOut = glyphRange.location != NSNotFound
            && NSMaxRange(glyphRange) >= measurementLayoutManager.numberOfGlyphs
        if !allGlyphsLaidOut {
            measurementLayoutManager.ensureLayout(forCharacterRange: NSRange(
                location: 0,
                length: measurementStorage.length
            ))
            let allGlyphs = NSRange(location: 0, length: measurementLayoutManager.numberOfGlyphs)
            if allGlyphs.length > 0 {
                used = used.union(measurementLayoutManager.boundingRect(
                    forGlyphRange: allGlyphs,
                    in: measurementContainer
                ))
            }
        }

        let height = used.maxY + inset.height * 2
        return ceil(max(0, height))
    }
}

// MARK: - Representable

/// Markdown 富文本段（NSTextView 渲染）：保持渲染效果的前提下整体框选与拷贝。
/// 高度测量与缓存由 `SelectableTextView` 内部持有，不在 SwiftUI 层按对象身份缓存：
/// 实例地址可能被复用，且宽度分桶会把不同换行结果混在一起。
struct SelectableMarkdownTextView: NSViewRepresentable {
    let prose: MarkdownProse

    init(attributed: NSAttributedString) { prose = MarkdownProse(parts: [attributed]) }
    init(prose: MarkdownProse) { self.prose = prose }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            return MailReferenceRoute.open(url)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelectableTextView {
        let view = SelectableTextView.make(prose: prose)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SelectableTextView, context: Context) {
        nsView.setProse(prose)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextView, context: Context) -> CGSize? {
        // 宽度必须有限且为正：SwiftUI 布局（如 NavigationStack 切换）可能提议 .infinity，
        // 无限宽度下排版结果无意义，回退 AppKit 自身尺寸
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.heightForWidth(width))
    }
}
