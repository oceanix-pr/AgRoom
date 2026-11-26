import SwiftUI
import AgRoomCore

// MARK: - Image Viewer Sheet

/// 图片浏览器：查看消息附件大图，支持复制到剪贴板、保存到磁盘、缩放、关闭。
/// 默认「适尺寸」显示：图片完整可见且不超过原始像素（小图不放大、大图缩小到适配）
struct ImageViewerSheet: View {
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss

    /// 图片一次性加载（避免 body 每次求值重复读盘）
    @State private var image: NSImage?
    /// 用户缩放倍率（1.0 = 适尺寸基准）
    @State private var zoom: CGFloat = 1.0
    /// 适尺寸缩放比（图片适配可视区的比例，≤ 1），随窗口尺寸实时更新
    @State private var fitScale: CGFloat = 1.0

    /// 实际显示缩放比（适尺寸基准 × 用户缩放）
    private var displayScale: CGFloat { fitScale * zoom }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(attachment.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L.string("common.close"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let image {
                imageCanvas(image: image)
            } else {
                ContentUnavailableView(
                    L.string("chat.imageviewer.missing"),
                    systemImage: "photo.badge.exclamationmark"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: copyImage) {
                    Label(L.string("chat.imageviewer.copy"), systemImage: "doc.on.doc")
                }
                Button(action: saveImage) {
                    Label(L.string("chat.imageviewer.save"), systemImage: "square.and.arrow.down")
                }

                Divider()
                    .frame(height: 16)

                // 缩放控制：缩小 / 百分比 / 放大 / 重置为适尺寸
                Button(action: zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(zoom <= 0.1)
                .help(L.string("chat.imageviewer.zoom.out"))

                Text("\(Int((displayScale * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(minWidth: 42)

                Button(action: zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(zoom >= 8)
                .help(L.string("chat.imageviewer.zoom.in"))

                Button(action: resetZoom) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(zoom == 1.0)
                .help(L.string("chat.imageviewer.zoom.reset"))

                Spacer()
                Button(L.string("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        // 默认 16:10（960×600），Sheet 窗口居中于父窗口；可手动拖拽边缘自由调整大小
        .frame(minWidth: 480, idealWidth: 960, maxWidth: .infinity, minHeight: 320, idealHeight: 600, maxHeight: .infinity)
        .background(SheetResizeEnabler())
        .task {
            image = NSImage(contentsOfFile: attachment.path)
        }
    }

    // MARK: - Zoom

    private func zoomIn() {
        zoom = min(8, zoom * 1.25)
    }

    private func zoomOut() {
        zoom = max(0.1, zoom / 1.25)
    }

    private func resetZoom() {
        zoom = 1.0
    }

    /// 适尺寸缩放比：完整可见且不超过 100%（留 32pt 边距）
    private static func fitScale(image: NSImage, container: CGSize) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0,
              container.width > 0, container.height > 0 else { return 1.0 }
        let scale = min(
            (container.width - 32) / image.size.width,
            (container.height - 32) / image.size.height,
            1.0
        )
        return max(scale, 0.05)
    }

    /// 画布：适尺寸基准 × 用户缩放；超出可视区时滚动平移
    /// （onGeometryChange 布局后回调，替代 GeometryReader+onChange 的布局期写状态）
    private func imageCanvas(image: NSImage) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
                .resizable()
                .frame(
                    width: image.size.width * displayScale,
                    height: image.size.height * displayScale
                )
                .padding(16)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            let scale = Self.fitScale(image: image, container: newSize)
            guard abs(scale - fitScale) > 0.001 else { return }
            // 布局回调里不直接写观察态：延后到下一次主线程轮次，
            // 否则会在 AppKit 更新约束途中再次请求更新约束（理由与崩溃栈见 `SplitColumnWidth`）
            Task { @MainActor in
                guard abs(scale - fitScale) > 0.001 else { return }
                fitScale = scale
            }
        }
    }

    /// 复制图片到剪贴板
    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// 保存图片（NSSavePanel，默认 PNG，沿用原文件名）
    private func saveImage() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (attachment.name as NSString).deletingPathExtension + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // NSImage → PNG 数据写盘
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
        } catch {
            HubLogger.shared.error("Image save failed: \(HubLogger.safeErrorSummary(error))")
        }
    }
}

// MARK: - Sheet Resize Enabler

/// 让 SwiftUI Sheet 的宿主窗口支持手动拖拽调整大小
/// （macOS 上 Sheet 默认固定尺寸，需在窗口样式掩码中补上 .resizable）
struct SheetResizeEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> HookView { HookView() }
    func updateNSView(_ nsView: HookView, context: Context) {}

    /// 让承载 Sheet 的 NSWindow 变为可拖拉调整大小。
    /// 只在挂载到窗口时补插 .resizable：立即一次 + 主队列延迟一次
    /// （SwiftUI 可能在内容挂载后才重置样式掩码，延迟重试可覆盖；
    /// 绝不能在 layout() 里改窗口样式——那会在 AppKit 布局期触发
    /// layoutSubtreeIfNeeded 递归，导致界面卡死）
    final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyResizable()
            // 延迟到当前布局周期结束再补一次
            DispatchQueue.main.async { [weak self] in
                self?.applyResizable()
            }
        }

        private func applyResizable() {
            guard let window, !window.styleMask.contains(.resizable) else { return }
            window.styleMask.insert(.resizable)
        }
    }
}
