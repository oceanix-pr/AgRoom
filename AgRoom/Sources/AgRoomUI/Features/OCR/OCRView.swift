import SwiftUI
import AppKit
import AgRoomCore

// MARK: - Screen Region Picker

/// 全屏遮罩框选器：用户在屏幕上拖拽选择区域，返回屏幕坐标矩形（Esc 取消）
enum ScreenRegionPicker {

    /// 全局窗口持有盒子（避免裸全局变量，并发安全）
    private final class WindowHolder: @unchecked Sendable {
        var window: NSWindow?
    }

    @MainActor
    private static let holder = WindowHolder()

    @MainActor static func cancel() {
        (holder.window?.contentView as? SelectionOverlayView)?.onSelection = nil
        holder.window?.orderOut(nil)
        holder.window = nil
    }

    @MainActor
    static func pick(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlay = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        overlay.onSelection = { rect in
            Task { @MainActor in
                ScreenRegionPicker.holder.window?.orderOut(nil)
                ScreenRegionPicker.holder.window = nil
            }
            // 视图坐标 → 屏幕坐标（视图原点在屏幕左下角）
            if let rect {
                let screenRect = CGRect(
                    x: screen.frame.minX + rect.minX,
                    y: screen.frame.minY + rect.minY,
                    width: rect.width,
                    height: rect.height
                )
                completion(screenRect)
            } else {
                completion(nil)
            }
        }
        window.contentView = overlay
        holder.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
    }
}

private final class SelectionOverlayView: NSView {
    var onSelection: ((CGRect?) -> Void)?

    private var startPoint: CGPoint?
    private var selectionRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let result = selectionRect.width > 4 && selectionRect.height > 4 ? selectionRect : nil
        onSelection?(result)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onSelection?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 半透明遮罩
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if !selectionRect.isEmpty {
            // 选中区域透出原色
            NSColor.clear.setFill()
            selectionRect.fill()
            NSColor.systemOrange.setStroke()
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 2
            path.stroke()
        }
    }
}

// MARK: - OCR View

/// OCR 页：文件 / 剪贴板 / 屏幕区域框选三种来源，结果可复制、可存知识库
public struct OCRView: View {
    let hub: Hub
    private let space: AppSpace
    @State private var ocrTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var generation = UUID()

    @State private var resultText = ""
    @State private var statusMessage: String?
    /// 保存知识库时是否 AI 结构化（默认开）；整理中禁用保存按钮防并发
    @State private var aiStructure = true
    @State private var isStructuring = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    public init(hub: Hub) {
        self.hub = hub
        self.space = hub.spaceStore.current
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.string("ocr.title"))
                .font(.title2)
                .fontWeight(.bold)

            Text(L.string("ocr.notice"))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button(action: recognizeFromFile) {
                    Label(L.string("ocr.from_file"), systemImage: "photo")
                }
                Button(action: recognizeFromClipboard) {
                    Label(L.string("ocr.from_clipboard"), systemImage: "clipboard")
                }
                Button(action: recognizeFromScreen) {
                    Label(L.string("ocr.from_screen"), systemImage: "rectangle.dashed.and.cursorarrow")
                }
                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            if let message = statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            TextEditor(text: $resultText)
                .font(.system(size: 13, design: .monospaced))
                .border(Color.secondary.opacity(0.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Button(action: copyResult) {
                    Label(L.string("ocr.copy"), systemImage: "doc.on.doc")
                }
                .disabled(resultText.isEmpty)

                Button(action: saveToKnowledge) {
                    Label(L.string("ocr.save_knowledge"), systemImage: "books.vertical")
                }
                .disabled(resultText.isEmpty || isStructuring)

                // AI 结构化：保存时把杂乱识别文本整理为「标题 + 要点 + 关键数据」
                Toggle(isOn: $aiStructure) {
                    Text(L.string("ocr.ai_structure"))
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help(L.string("ocr.ai_structure.help"))
                .disabled(resultText.isEmpty || isStructuring)

                if isStructuring {
                    ProgressView().controlSize(.small)
                }

                Spacer()
                Text("\(resultText.count) " + L.string("chat.usage.chars"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .onDisappear { generation = UUID(); ocrTask?.cancel(); saveTask?.cancel(); ScreenRegionPicker.cancel() }
        .alert(L.string("common.error"), isPresented: $showErrorAlert) {
            Button(L.string("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sources

    private func recognizeFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OCRService.supportedExtensions.compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runOCR {
            try await OCRService.recognizeCancellable(imageURL: url)
        }
    }

    private func recognizeFromClipboard() {
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) else {
            errorMessage = L.string("ocr.clipboard_empty")
            showErrorAlert = true
            return
        }
        // Read encoded bytes: creating and re-encoding NSImage here would decode on the main actor.
        runOCR {
            try await OCRService.recognizeCancellable(imageData: data)
        }
    }

    private func recognizeFromScreen() {
        // 权限预检（规范：先 preflight 再动作）
        guard OCRService.screenCapturePermitted else {
            let granted = OCRService.requestScreenCapturePermission()
            errorMessage = granted
                ? L.string("ocr.screen_restart_needed")
                : L.string("ocr.screen_denied")
            showErrorAlert = true
            return
        }
        guard let screen = NSScreen.main else { return }

        // 先截屏（避免遮罩入图），再展示框选器
        ocrTask?.cancel()
        let id = UUID()
        generation = id
        ocrTask = Task {
            let screenshot: CGImage
            do {
                screenshot = try await OCRService.captureMainDisplay()
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.ocr_capture")
                showErrorAlert = true
                return
            }
            let screenFrame = screen.frame
            guard !Task.isCancelled, generation == id else { return }

            ScreenRegionPicker.pick(on: screen) { region in
                guard let region, generation == id else { return }
                runOCR {
                    guard let cropped = OCRService.crop(screenshot, regionInPoints: region, screenFrameInPoints: screenFrame) else {
                        throw OCRService.OCRError.cannotLoadImage
                    }
                    return try await OCRService.recognizeCancellable(cgImage: cropped)
                }
            }
        }
    }

    // MARK: - Helpers

    private func runOCR(_ work: @escaping @Sendable () async throws -> String) {
        ocrTask?.cancel()
        let id = UUID()
        generation = id
        isWorking = true
        statusMessage = nil
        let job = Task.detached { try Task.checkCancellation(); return try await work() }
        ocrTask = Task {
            do {
                let text = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, generation == id else { return }
                    isWorking = false
                    resultText = text
            } catch is CancellationError {
            } catch {
                guard generation == id else { return }
                    isWorking = false
                    errorMessage = L.actionableError(error, fallbackKey: "error.actionable.ocr_recognize")
                    showErrorAlert = true
            }
        }
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)
        statusMessage = L.string("ocr.copied")
    }

    private func saveToKnowledge() {
        // AI 结构化（可关）：整理为标题+要点；失败/关闭时回退原始文本
        guard !isStructuring, let service = hub.makeKnowledgeService(for: space) else {
            errorMessage = L.string("error.database"); showErrorAlert = true; return
        }
        let input = resultText
        let structure = aiStructure
        isStructuring = true
        saveTask = Task {
            defer { isStructuring = false }
            var title = "OCR " + AppDate.string(from: Date())
            var content = input
            if structure, let provider = try? await hub.makeActiveProvider(for: space, source: "ocr") {
                if let structured = try? await Self.structureOCR(text: input, provider: provider) {
                    title = structured.title
                    content = structured.content
                }
            }
            let item = KnowledgeItem(
                title: title,
                content: content,
                kind: .document,
                tags: ["ocr"]
            )
            do {
                try Task.checkCancellation()
                try await service.save(item)
                guard !Task.isCancelled else { return }
                statusMessage = L.string("browser.saved")
            } catch is CancellationError {
            } catch {
                errorMessage = L.actionableError(error, fallbackKey: "error.actionable.ocr_save")
                showErrorAlert = true
            }
        }
    }

    /// OCR 文本 AI 结构化：标题（≤20 字）+ 要点化正文（保留全部事实，不改数值）
    static func structureOCR(text: String, provider: CloudProvider) async throws -> (title: String, content: String) {
        let generator = AIAssistGenerator(provider: provider)
        let system = """
        You restructure OCR output into a knowledge-base entry.
        Return EXACTLY two lines:
        Line 1 (starting with "TITLE: "): a concise title, max 20 chars, in the SAME language as the source.
        Line 2 onwards (starting with "CONTENT: "): a structured markdown summary — bullet points of key facts,
        with a "## Key Data" section listing numbers/dates/amounts verbatim.
        Preserve ALL facts; never invent or alter numbers. Keep it under 1500 chars.
        """
        let output = try await generator.text(system: system, user: "OCR output:\n\(String(text.prefix(6000)))")
        guard output.hasPrefix("TITLE:") else { throw AIAssistGenerator.AssistError.emptyOutput }
        let remainder = String(output.dropFirst("TITLE:".count))
        let parts = remainder.components(separatedBy: "CONTENT:")
        let title = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = parts.count > 1 ? parts.dropFirst().joined(separator: "CONTENT:").trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !title.isEmpty, !content.isEmpty else { throw AIAssistGenerator.AssistError.emptyOutput }
        return (String(title.prefix(60)), content)
    }
}
