import SwiftUI
import AppKit
import ImageIO
import AgRoomCore

enum ImageKnowledgeSaveResult {
    case saved
    case discarded
}

@MainActor
enum ImageKnowledgeSaveOperation {
    static func run(
        item: KnowledgeItem,
        originSpace: AppSpace,
        isCurrent: () -> Bool,
        service: KnowledgeService?
    ) async throws -> ImageKnowledgeSaveResult {
        guard isCurrent(), !Task.isCancelled else { return .discarded }
        guard let service else { throw SpaceSearchError.unavailable }
        try await service.save(item)
        return isCurrent() && !Task.isCancelled ? .saved : .discarded
    }
}

// MARK: - Image Viewer View

/// 图片浏览器：缩放/平移/旋转、同目录翻页、EXIF 信息、一键 OCR
public struct ImageViewerView: View {
    let hub: Hub

    @State private var imageURLs: [URL] = []
    @State private var currentIndex: Int?
    @State private var nsImage: NSImage?
    @State private var exifEntries: [(String, String)] = []

    @State private var zoom: CGFloat = 1.0
    @State private var gestureZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var gesturePan: CGSize = .zero
    @State private var rotation: Double = 0

    @State private var showOCRSheet = false
    @State private var ocrText = ""
    @State private var ocrError: String?
    @State private var ocrSaveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    public init(hub: Hub) {
        self.hub = hub
    }

    private var currentURL: URL? {
        guard let index = currentIndex, imageURLs.indices.contains(index) else { return nil }
        return imageURLs[index]
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if nsImage != nil {
                HStack(spacing: 0) {
                    imageCanvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    exifPanel
                        .frame(width: 240)
                }
            } else {
                ContentUnavailableView(
                    L.string("images.empty"),
                    systemImage: "photo",
                    description: Text(L.string("images.empty.desc"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showOCRSheet) {
            ocrSheet
                .onDisappear { ocrSaveTask?.cancel() }
        }
        .onDisappear { ocrSaveTask?.cancel() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: openImage) {
                Label(L.string("images.open"), systemImage: "folder")
            }

            if currentURL != nil {
                Button(action: previousImage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentIndex ?? 0 <= 0)

                Button(action: nextImage) {
                    Image(systemName: "chevron.right")
                }
                .disabled((currentIndex ?? 0) >= imageURLs.count - 1)

                Text("\((currentIndex ?? 0) + 1) / \(imageURLs.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { rotation = (rotation + 90).truncatingRemainder(dividingBy: 360) }) {
                    Image(systemName: "rotate.right")
                }

                Button(action: {
                    zoom = 1.0
                    pan = .zero
                    rotation = 0
                }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help(L.string("images.reset"))

                Button(action: runOCR) {
                    Label("OCR", systemImage: "text.viewfinder")
                }

                if let url = currentURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Canvas

    private var imageCanvas: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom * gestureZoom)
                    .rotationEffect(.degrees(rotation))
                    .offset(x: pan.width + gesturePan.width, y: pan.height + gesturePan.height)
                    .gesture(
                        DragGesture()
                            .onChanged { gesturePan = $0.translation }
                            .onEnded { value in
                                pan.width += value.translation.width
                                pan.height += value.translation.height
                                gesturePan = .zero
                            }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { gestureZoom = $0 }
                            .onEnded { value in
                                zoom = min(8.0, max(0.2, zoom * value))
                                gestureZoom = 1.0
                            }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - EXIF Panel

    private var exifPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("EXIF / " + L.string("images.info"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if exifEntries.isEmpty {
                    Text(L.string("images.no_info"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(exifEntries, id: \.0) { key, value in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(value)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - OCR Sheet

    private var ocrSheet: some View {
        VStack(spacing: 12) {
            Text("OCR")
                .font(.title3)
                .fontWeight(.bold)
            if let error = ocrError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            TextEditor(text: $ocrText)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 520, height: 320)
                .border(Color.secondary.opacity(0.2))
            HStack {
                Button(L.string("common.cancel")) {
                    ocrSaveTask?.cancel()
                    showOCRSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.string("ocr.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ocrText, forType: .string)
                }
                .disabled(ocrText.isEmpty)
                Button(L.string("ocr.save_knowledge")) {
                    saveOCRToKnowledge()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ocrText.isEmpty || ocrSaveTask != nil)
            }
            .frame(width: 520)
        }
        .padding(20)
    }

    // MARK: - Actions

    private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OCRService.supportedExtensions.compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDirectory(of: url)
    }

    /// 加载同目录图片列表并定位到所选文件
    private func loadDirectory(of url: URL) {
        let dir = url.deletingLastPathComponent()
        let extensionSet = Set(OCRService.supportedExtensions)
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        imageURLs = contents
            .filter { extensionSet.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        currentIndex = imageURLs.firstIndex(of: url) ?? 0
        loadImage(at: currentIndex ?? 0)
    }

    private func previousImage() {
        guard let index = currentIndex, index > 0 else { return }
        loadImage(at: index - 1)
    }

    private func nextImage() {
        guard let index = currentIndex, index < imageURLs.count - 1 else { return }
        loadImage(at: index + 1)
    }

    private func loadImage(at index: Int) {
        guard imageURLs.indices.contains(index) else { return }
        let url = imageURLs[index]
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = L.string("images.load_failed")
            showErrorAlert = true
            return
        }
        currentIndex = index
        nsImage = image
        zoom = 1.0
        pan = .zero
        gesturePan = .zero
        gestureZoom = 1.0
        rotation = 0
        loadEXIF(url: url)
    }

    private func loadEXIF(url: URL) {
        exifEntries = []
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return
        }
        var entries: [(String, String)] = []
        let interestingKeys: [CFString] = [
            kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
            kCGImagePropertyDPIWidth, kCGImagePropertyColorModel,
            kCGImagePropertyHasAlpha, kCGImagePropertyFileSize
        ]
        for key in interestingKeys {
            if let value = properties[key] {
                entries.append((key as String, "\(value)"))
            }
        }
        // 相机元数据（若存在）
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] {
                entries.append(("TIFF.Make", "\(make)"))
            }
            if let model = tiff[kCGImagePropertyTIFFModel] {
                entries.append(("TIFF.Model", "\(model)"))
            }
        }
        exifEntries = entries
    }

    private func runOCR() {
        guard let url = currentURL else { return }
        ocrText = ""
        ocrError = nil
        showOCRSheet = true
        Task.detached {
            do {
                let text = try OCRService.recognize(imageURL: url)
                await MainActor.run { ocrText = text }
            } catch {
                await MainActor.run { ocrError = L.actionableError(error, fallbackKey: "error.actionable.ocr_recognize") }
            }
        }
    }

    private func saveOCRToKnowledge() {
        guard ocrSaveTask == nil else { return }
        let originSpace = hub.spaceStore.current
        let knowledge = hub.makeKnowledgeService(for: originSpace)
        let item = KnowledgeItem(
            title: (currentURL?.deletingPathExtension().lastPathComponent ?? "OCR") + " (OCR)",
            content: ocrText,
            kind: .document,
            tags: ["ocr"]
        )
        ocrSaveTask = Task {
            defer { ocrSaveTask = nil }
            do {
                let result = try await ImageKnowledgeSaveOperation.run(
                    item: item,
                    originSpace: originSpace,
                    isCurrent: { hub.spaceStore.current == originSpace && showOCRSheet },
                    service: knowledge
                )
                if case .saved = result { showOCRSheet = false }
            } catch is CancellationError {
                // Dismissing the sheet or switching space cancels the pending save.
            } catch {
                if hub.spaceStore.current == originSpace && showOCRSheet {
                    ocrError = L.actionableError(error, fallbackKey: "error.actionable.ocr_save")
                }
            }
        }
    }
}
