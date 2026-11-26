import SwiftUI
import AppKit
import ImageIO
import CoreImage
import AgRoomCore

struct NoteImageSelection: Identifiable {
    let id = UUID()
    let image: NSImage
    let name: String
}

struct NoteImageEditor: View {
    enum Tool: String, CaseIterable { case select, pen, crop, rect, ellipse, arrow, text, mosaic }
    struct Mark: Identifiable {
        let id = UUID()
        let tool: Tool
        var points: [CGPoint]
        let color: NSColor
        let width: CGFloat
        let text: String
        let font: NSFont
    }
    struct State { var marks: [Mark] = []; var crop: CGRect? }
    let selection: NoteImageSelection
    let save: (Data) -> Void
    var pin: ((Data) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @SwiftUI.State private var tool = Tool.select
    @SwiftUI.State private var edit = State()
    @SwiftUI.State private var undo: [State] = []
    @SwiftUI.State private var redo: [State] = []
    @SwiftUI.State private var dragStart: State?
    @SwiftUI.State private var current: [CGPoint] = []
    @SwiftUI.State private var selected: UUID?
    @SwiftUI.State private var color = Color.red
    @SwiftUI.State private var width = 4.0
    @SwiftUI.State private var text = ""
    @SwiftUI.State private var fontSize = 24.0
    @SwiftUI.State private var bold = false
    @SwiftUI.State private var italic = false
    @SwiftUI.State private var failure = false
    @SwiftUI.State private var mosaicImage: NSImage?
    private var size: CGSize { selection.image.size }
    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal,showsIndicators: false) {
                HStack {
                    ForEach(Tool.allCases,id: \.self) { item in
                        Button { tool = item; current = [] } label: { Image(systemName: icon(item)).frame(width: 28,height: 24) }
                            .buttonStyle(.bordered).tint(tool == item ? .accentColor : .secondary).help(L.string("notes.image." + item.rawValue))
                    }
                    ColorPicker(L.string("notes.image.color"),selection: $color).labelsHidden()
                    Picker(L.string("notes.image.width"),selection: $width) { ForEach([2.0,4,6],id: \.self) { Text("\(Int($0))").tag($0) } }.frame(width: 74)
                    Button { if let old = undo.popLast() { redo.append(edit); edit = old; selected = nil } } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undo.isEmpty).help(L.string("notes.image.undo"))
                    Button { if let next = redo.popLast() { undo.append(edit); edit = next; selected = nil } } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redo.isEmpty).help(L.string("notes.image.redo"))
                    Button(role: .destructive) { checkpoint(); edit.marks.removeAll { $0.id == selected }; selected = nil } label: { Image(systemName: "trash") }.disabled(selected == nil).help(L.string("notes.delete"))
                }
            }
            if tool == .text {
                HStack {
                    TextField(L.string("notes.image.text"),text: $text).onChange(of: text) { text = String(text.prefix(500)) }
                    Picker(L.string("notes.image.font"),selection: $fontSize) { ForEach([14.0,24,36],id: \.self) { Text("\(Int($0))").tag($0) } }.frame(width: 90)
                    Toggle(L.string("notes.image.bold"),isOn: $bold).toggleStyle(.button)
                    Toggle(L.string("notes.image.italic"),isOn: $italic).toggleStyle(.button)
                }
            }
            GeometryReader { geometry in
                let fitted = fit(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: selection.image).resizable().frame(width: fitted.width,height: fitted.height)
                    Canvas { context, canvas in
                        for mark in edit.marks + (current.isEmpty || tool == .select || tool == .crop ? [] : [makeMark(current)]) { draw(mark,in: &context,size: canvas) }
                        if let crop = edit.crop { context.stroke(Path(rectangle(crop,size: canvas)),with: .color(.yellow),style: StrokeStyle(lineWidth: 2,dash: [5,3])) }
                        if let mark = edit.marks.first(where: { $0.id == selected }) { context.stroke(Path(bounds(mark,size: canvas).insetBy(dx: -5,dy: -5)),with: .color(.accentColor),style: StrokeStyle(lineWidth: 1,dash: [4,3])) }
                        if tool == .crop, current.count >= 2 { context.stroke(Path(box(current,size: canvas)),with: .color(.yellow),lineWidth: 2) }
                    }.frame(width: fitted.width,height: fitted.height)
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: min(1,max(0,p.x / fitted.width)),y: min(1,max(0,p.y / fitted.height))) }
                    let start = point(value.startLocation), end = point(value.location)
                    if dragStart == nil {
                        dragStart = edit
                        if tool == .select { selected = edit.marks.reversed().first { bounds($0,size: fitted).insetBy(dx: -8,dy: -8).contains(value.startLocation) }?.id }
                    }
                    if tool == .select, let selected, let original = dragStart?.marks.first(where: { $0.id == selected }), let index = edit.marks.firstIndex(where: { $0.id == selected }) {
                        edit.marks[index].points = original.points.map { CGPoint(x: min(1,max(0,$0.x + end.x - start.x)),y: min(1,max(0,$0.y + end.y - start.y))) }
                    } else if tool == .pen { if current.isEmpty { current.append(start) }; current.append(end) }
                    else { current = [start,end] }
                }.onEnded { _ in
                    guard let before = dragStart else { return }
                    if tool == .select { if selected != nil { undo.append(before); redo = [] } }
                    else if !current.isEmpty {
                        undo.append(before); redo = []
                        if tool == .crop { edit.crop = box(current,size: CGSize(width: 1,height: 1)) }
                        else if tool != .text || !text.isEmpty { edit.marks.append(makeMark(current)) }
                    }
                    current = []; dragStart = nil
                }).frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            HStack {
                Button(L.string("notes.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                if let pin { Button(L.string("notes.image.pin")) { if let data = render() { pin(data) } else { failure = true } } }
                Button(L.string("notes.image.copy")) { if let data = render() { NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType: .png) } else { failure = true } }
                Spacer()
                Text(L.string("notes.image.copy.hint")).font(.caption).foregroundStyle(.secondary)
                Button(L.string("notes.image.save")) { if let data = render() { save(data); dismiss() } else { failure = true } }.buttonStyle(.borderedProminent)
            }
            if failure { Text(L.string("notes.error")).foregroundStyle(.red) }
        }.padding(20).frame(minWidth: 820,idealWidth: 1000,minHeight: 560,idealHeight: 720)
            .task { if let source = selection.image.cgImage(forProposedRect: nil,context: nil,hints: nil), let pixel = pixelated(source) { mosaicImage = NSImage(cgImage: pixel,size: size) } }
    }
    private func checkpoint() { undo.append(edit); redo = [] }
    private func fit(in available: CGSize) -> CGSize { let scale = min(available.width / max(1,size.width),available.height / max(1,size.height)); return CGSize(width: size.width * scale,height: size.height * scale) }
    private func icon(_ t: Tool) -> String { switch t { case .select: "cursorarrow"; case .pen: "pencil.tip"; case .crop: "crop"; case .rect: "rectangle"; case .ellipse: "oval"; case .arrow: "arrow.up.right"; case .text: "textformat"; case .mosaic: "square.grid.3x3.fill" } }
    private func makeMark(_ points: [CGPoint]) -> Mark {
        var font = NSFont.systemFont(ofSize: fontSize,weight: bold ? .bold : .regular)
        if italic { font = NSFontManager.shared.convert(font,toHaveTrait: .italicFontMask) }
        return Mark(tool: tool,points: points,color: NSColor(color),width: width,text: String(text.prefix(500)),font: font)
    }
    private func box(_ points: [CGPoint], size: CGSize) -> CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x,last.x) * size.width,y: min(first.y,last.y) * size.height,width: max(0.003,abs(last.x - first.x)) * size.width,height: max(0.003,abs(last.y - first.y)) * size.height)
    }
    private func rectangle(_ normalized: CGRect,size: CGSize) -> CGRect { CGRect(x: normalized.minX * size.width,y: normalized.minY * size.height,width: normalized.width * size.width,height: normalized.height * size.height) }
    private func bounds(_ mark: Mark,size: CGSize) -> CGRect {
        if mark.tool == .text, let p = mark.points.first { let measured = (mark.text as NSString).size(withAttributes: [.font:mark.font]); return CGRect(x: p.x * size.width,y: p.y * size.height,width: measured.width * size.width / max(1,self.size.width),height: measured.height * size.height / max(1,self.size.height)) }
        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
        return CGRect(x: (xs.min() ?? 0) * size.width,y: (ys.min() ?? 0) * size.height,width: max(0.003,(xs.max() ?? 0) - (xs.min() ?? 0)) * size.width,height: max(0.003,(ys.max() ?? 0) - (ys.min() ?? 0)) * size.height)
    }
    private func path(_ mark: Mark,size: CGSize) -> Path {
        let rect = box(mark.points,size: size)
        if mark.tool == .rect { return Path(rect) }; if mark.tool == .ellipse { return Path(ellipseIn: rect) }
        var path = Path(); guard let first = mark.points.first else { return path }
        path.move(to: CGPoint(x: first.x * size.width,y: first.y * size.height))
        for p in mark.points.dropFirst() { path.addLine(to: CGPoint(x: p.x * size.width,y: p.y * size.height)) }
        if mark.tool == .arrow, let last = mark.points.last {
            let a = CGPoint(x: first.x * size.width,y: first.y * size.height), b = CGPoint(x: last.x * size.width,y: last.y * size.height)
            let angle = atan2(b.y - a.y,b.x - a.x), length = max(12,mark.width * 4) * size.width / max(1,self.size.width)
            for delta in [-0.5,0.5] { path.move(to: b); path.addLine(to: CGPoint(x: b.x - cos(angle + delta) * length,y: b.y - sin(angle + delta) * length)) }
        }
        return path
    }
    private func draw(_ mark: Mark,in context: inout GraphicsContext,size: CGSize) {
        if mark.tool == .text, let p = mark.points.first {
            let font = NSFontManager.shared.convert(mark.font,toSize: mark.font.pointSize * size.width / max(1,self.size.width))
            context.draw(Text(mark.text).font(Font(font)).foregroundStyle(Color(nsColor: mark.color)),at: CGPoint(x: p.x * size.width,y: p.y * size.height),anchor: .topLeading)
        } else if mark.tool == .mosaic, let mosaicImage {
            var clipped = context; clipped.clip(to: Path(box(mark.points,size: size)))
            clipped.draw(Image(nsImage: mosaicImage),in: CGRect(origin: .zero,size: size))
        }
        else { context.stroke(path(mark,size: size),with: .color(Color(nsColor: mark.color)),style: StrokeStyle(lineWidth: max(1,mark.width * size.width / max(1,self.size.width)),lineCap: .round,lineJoin: .round)) }
    }
    private func render() -> Data? {
        guard let source = selection.image.cgImage(forProposedRect: nil,context: nil,hints: nil), source.width <= 8192,source.height <= 8192,
              let context = CGContext(data: nil,width: source.width,height: source.height,bitsPerComponent: 8,bytesPerRow: source.width * 4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGSize(width: source.width,height: source.height)
        context.draw(source,in: CGRect(origin: .zero,size: canvas))
        context.translateBy(x: 0,y: canvas.height); context.scaleBy(x: 1,y: -1)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: true)
        let pixels = edit.marks.contains(where: { $0.tool == .mosaic }) ? pixelated(source) : nil
        for mark in edit.marks {
            context.setStrokeColor(mark.color.cgColor); context.setLineWidth(mark.width * canvas.width / max(1,size.width)); context.setLineCap(.round)
            if mark.tool == .text, let p = mark.points.first {
                let font = NSFontManager.shared.convert(mark.font,toSize: mark.font.pointSize * canvas.width / max(1,size.width))
                (mark.text as NSString).draw(at: CGPoint(x: p.x * canvas.width,y: p.y * canvas.height),withAttributes: [.font:font,.foregroundColor:mark.color])
            } else if mark.tool == .mosaic {
                let rect = box(mark.points,size: canvas).integral.intersection(CGRect(origin: .zero,size: canvas))
                if let pixels {
                    context.saveGState(); context.clip(to: rect)
                    context.translateBy(x: 0,y: canvas.height); context.scaleBy(x: 1,y: -1)
                    context.draw(pixels,in: CGRect(origin: .zero,size: canvas)); context.restoreGState()
                }
            } else { context.addPath(path(mark,size: canvas).cgPath); context.strokePath() }
        }
        guard var image = context.makeImage() else { return nil }
        if let crop = edit.crop, crop.width > 0.005, crop.height > 0.005 { guard let cut = image.cropping(to: rectangle(crop,size: canvas).integral) else { return nil }; image = cut }
        return NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:])
    }
    private func pixelated(_ source: CGImage) -> CGImage? {
        guard source.width <= 8192, source.height <= 8192, let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(CIImage(cgImage: source),forKey: kCIInputImageKey); filter.setValue(14,forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output,from: CGRect(x: 0,y: 0,width: source.width,height: source.height))
    }
}

@MainActor
final class NoteImagePins {
    private var windows: [NSWindowController] = []
    func show(_ data: Data) throws {
        windows.removeAll { $0.window?.isVisible != true }
        guard windows.count < 8, let image = NSImage(data: data) else { throw NoteStoreError.tooLarge }
        let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 480,height: 320),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        window.title = L.string("notes.image.pin"); window.level = .floating; window.contentView = view; window.center(); window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window); windows.append(controller); controller.showWindow(nil)
    }
    func close() { for window in windows { window.close() }; windows = [] }
}
