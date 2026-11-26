import SwiftUI
import AgRoomCore

struct MarkdownRichBlock: View {
    let resource: MarkdownRenderedResource?
    let failed: Bool
    let source: String
    let language: String
    var alternative = ""
    var isImage = false
    var failure: MarkdownResourceError?
    var typography = ReadingTypography()
    @State private var showingImage = false
    @State private var showingSource = false

    private var isDiagram: Bool { language.lowercased() == "mermaid" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let resource {
                HStack(spacing: 12) {
                    if !isImage {
                        Button(L.string("common.copy")) { copySource() }
                        Button(L.string("md.resource.source")) { showingSource.toggle() }
                    }
                    Spacer(minLength: 0)
                    Button { showingImage = true } label: {
                        Label(L.string("md.resource.expand"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Button { showingImage = true } label: {
                    MarkdownResourceImage(image: resource.displayImage, fillsWidth: isDiagram)
                        .allowsHitTesting(false)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(isImage ? (alternative.isEmpty ? L.string("md.image") : alternative) : language)
                .help(L.string("md.resource.expand"))
                if showingSource { CodeBlockView(code: source, language: language, typography: typography) }
            } else {
                HStack(spacing: 6) {
                    if !failed { ProgressView().controlSize(.mini) }
                    Label(L.string(failed ? (failure?.messageKey ?? "md.resource.failed") : "md.resource.loading"), systemImage: failed ? "exclamationmark.triangle" : "photo")
                    if isImage, !alternative.isEmpty { Text(alternative).textSelection(.enabled) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !isImage { CodeBlockView(code: source, language: language, typography: typography) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: source) { _, _ in showingImage = false; showingSource = false }
        .sheet(isPresented: $showingImage) {
            if let resource {
                MarkdownResourcePreview(resource: resource, name: isImage ? alternative : language, initiallyFitsWidth: isDiagram)
            }
        }
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }
}

/// 图表使用容器的全部宽度；高度只由比例决定，不额外压缩长图。
struct MarkdownResourceImage: NSViewRepresentable {
    let image: NSImage
    var fillsWidth = false

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignLeft
        view.image = image
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) { view.image = image }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        let size = image.size
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? size.width
        let width = max(1, fillsWidth ? proposedWidth : min(proposedWidth, size.width))
        return CGSize(width: width, height: width * max(1, size.height) / max(1, size.width))
    }
}

enum MarkdownPreviewZoom: Equatable {
    case fitWidth
    case fitWindow
    case actual(CGFloat)

    func scale(content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let scale: CGFloat
        switch self {
        case .fitWidth: scale = viewport.width / content.width
        case .fitWindow: scale = min(viewport.width / content.width, viewport.height / content.height, 1)
        case .actual(let value): scale = value
        }
        return min(16, max(0.02, scale))
    }
}

/// 预览复用已校验的内存资源，图表优先用 PDF 矢量表示，缩放时不重新运行脚本。
struct MarkdownResourcePreview: View {
    let resource: MarkdownRenderedResource
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: MarkdownPreviewZoom

    init(resource: MarkdownRenderedResource, name: String, initiallyFitsWidth: Bool = false) {
        self.resource = resource
        self.name = name
        self._zoom = State(initialValue: initiallyFitsWidth ? .fitWidth : .fitWindow)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(name.isEmpty ? L.string("md.image") : name).lineLimit(1)
                Spacer()
                Button(L.string("chat.imageviewer.copy"), action: copyImage)
                Button(L.string("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            GeometryReader { geometry in
                let viewport = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 40))
                let scale = zoom.scale(content: resource.displayImage.size, viewport: viewport)
                VStack(spacing: 8) {
                    MarkdownZoomCanvas(image: resource.displayImage, scale: scale, anchorsTop: zoom == .fitWidth) { value in zoom = .actual(value) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 12) {
                        Button { zoom = .actual(max(0.02, scale / 1.25)) } label: { Image(systemName: "minus.magnifyingglass") }
                            .help(L.string("chat.imageviewer.zoom.out"))
                            .accessibilityLabel(L.string("chat.imageviewer.zoom.out"))
                        Text("\(Int((scale * 100).rounded()))%")
                            .monospacedDigit().frame(minWidth: 52)
                        Button { zoom = .actual(min(16, scale * 1.25)) } label: { Image(systemName: "plus.magnifyingglass") }
                            .help(L.string("chat.imageviewer.zoom.in"))
                            .accessibilityLabel(L.string("chat.imageviewer.zoom.in"))
                        Divider().frame(height: 16)
                        Button(L.string("md.resource.fit_width")) { zoom = .fitWidth }
                        Button(L.string("md.resource.fit_window")) { zoom = .fitWindow }
                        Button("100%") { zoom = .actual(1) }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.borderless)
                    .frame(height: 32)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 1_000, maxWidth: .infinity, minHeight: 320, idealHeight: 720, maxHeight: .infinity)
        .background(SheetResizeEnabler())
    }

    private func copyImage() {
        let board = NSPasteboard.general
        board.clearContents()
        if let pdf = resource.vectorPDF {
            board.declareTypes([.pdf, .tiff], owner: nil)
            board.setData(pdf, forType: .pdf)
            if let tiff = resource.image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        } else { board.writeObjects([resource.image]) }
    }
}

struct MarkdownZoomCanvas: NSViewRepresentable {
    let image: NSImage
    let scale: CGFloat
    var anchorsTop = false
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> MarkdownZoomScrollView {
        let view = MarkdownZoomScrollView()
        view.hasHorizontalScroller = true
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.scrollerStyle = .overlay
        view.drawsBackground = false
        view.borderType = .noBorder
        view.documentView = view.canvas
        return view
    }

    func updateNSView(_ view: MarkdownZoomScrollView, context: Context) {
        view.onZoom = onZoom
        view.update(image: image, scale: scale, anchorsTop: anchorsTop)
    }
}

@MainActor
final class MarkdownZoomScrollView: NSScrollView {
    fileprivate let canvas = MarkdownCanvasDocument()
    private var scale: CGFloat = 1
    private var hasLaidOutImage = false
    var onZoom: ((CGFloat) -> Void)?

    func update(image: NSImage, scale: CGFloat, anchorsTop: Bool) {
        let previous = self.scale
        let preserveFocus = hasLaidOutImage
        let oldOrigin = canvas.imageView.frame.origin
        let focus = CGPoint(x: (contentView.bounds.midX - oldOrigin.x) / previous,
                            y: ((anchorsTop ? contentView.bounds.minY : contentView.bounds.midY) - oldOrigin.y) / previous)
        let changed = abs(previous - scale) > 0.0001
        self.scale = scale
        canvas.imageView.image = image
        layoutCanvas()
        if changed, preserveFocus {
            // 宽度适配时保留当前阅读位置的顶部，手动缩放则保留视口中心。
            let origin = CGPoint(x: anchorsTop ? 0 : canvas.imageView.frame.minX + focus.x * scale - contentView.bounds.width / 2,
                                 y: canvas.imageView.frame.minY + focus.y * scale - (anchorsTop ? 0 : contentView.bounds.height / 2))
            scroll(to: origin)
        }
    }

    override func layout() {
        super.layout()
        layoutCanvas()
    }

    override func magnify(with event: NSEvent) {
        onZoom?(min(16, max(0.02, scale * (1 + event.magnification))))
    }

    private func layoutCanvas() {
        guard let image = canvas.imageView.image, contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let viewport = contentView.bounds.size
        let documentSize = CGSize(width: max(viewport.width, size.width), height: max(viewport.height, size.height))
        canvas.setFrameSize(documentSize)
        canvas.imageView.frame = NSRect(x: (documentSize.width - size.width) / 2, y: (documentSize.height - size.height) / 2,
                                        width: size.width, height: size.height)
        hasLaidOutImage = true
    }

    fileprivate func scroll(to origin: CGPoint) {
        let rect = contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size))
        contentView.scroll(to: rect.origin)
        reflectScrolledClipView(contentView)
    }
}

@MainActor
fileprivate final class MarkdownCanvasDocument: NSView {
    let imageView = MarkdownPanImageView()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
fileprivate final class MarkdownPanImageView: NSImageView {
    private var dragOrigin: CGPoint?
    private var scrollOrigin = CGPoint.zero

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        scrollOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, let scroll = enclosingScrollView as? MarkdownZoomScrollView else { return }
        scroll.scroll(to: CGPoint(x: scrollOrigin.x - (event.locationInWindow.x - dragOrigin.x),
                                  y: scrollOrigin.y + (event.locationInWindow.y - dragOrigin.y)))
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil { NSCursor.pop() }
        dragOrigin = nil
    }
}
