import AppKit
import Foundation
import GRDB
import Observation
import QuickLookUI
import SwiftUI
import Synchronization
import Testing
import Vision
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Native task center loading", .serialized)
@MainActor
struct ProductTaskCenterHostTests {
    @Test("The completed edit card groups paths, opens file diffs, and only undoes changes after confirmation")
    func completedEditCard() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let root = host.root.standardizedFileURL.resolvingSymlinksInPath()
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        let scope = TaskArtifactEditScope(sessionID: UUID(), runID: UUID(), workspace: .init(name: "Sample", path: root.path, space: .work))
        var artifacts: [TaskArtifact] = []
        let examples = [("Sources/Editor.swift", "old editor", "new editor"), ("Tests/Editor.swift", "old test", "new test"),
                        ("Notes.md", "first draft", "second draft\nextra line")]
        for (path, before, after) in examples {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(after.utf8).write(to: file)
            let version = try await store.capture(file, root: root, logicalPath: nil, origin: .init(space: .work,
                sessionID: scope.sessionID, runID: scope.runID, workspaceID: scope.workspace.id.uuidString, operationID: path,
                tool: "files_edit", writeRootIdentities: [root.path: try TaskDirectoryIdentity.capture(root)]),
                baseline: .existing(Data(before.utf8)), expectedContents: Data(after.utf8))
            artifacts.append(version)
        }
        let view = TaskResultArtifactsView(artifacts: artifacts + [artifacts[0]], roots: [root], store: store, undoScope: scope,
            canConfirmUndo: { $0 == scope }, onUse: { _ in }, onContinueSnapshot: { _, _ in }, onContinue: { _ in })
        let window = mount(view.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), width: 720, height: 220)
        defer { window.attachedSheet?.close(); window.close() }
        _ = try await waitRendered(window, containing: L.format("product.edits.count", 3))
        _ = try await waitRendered(window, containing: "Tests/Editor.swift")
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("edited-files-summary.png"))
        }
        try await pressButton(L.string("product.edits.review"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        _ = try await waitRendered(sheet, containing: "new editor")
        try await pressButton(L.string("common.close"), in: sheet)
        try await wait(window) { window.attachedSheet == nil }
        try await pressButton("Tests/Editor.swift", in: window)
        try await wait(window) { window.attachedSheet != nil }
        let selected = try #require(window.attachedSheet)
        _ = try await waitRendered(selected, containing: "new test")
        try await pressButton(L.string("common.close"), in: selected)
        try await wait(window) { window.attachedSheet == nil }
        try await pressButton(L.string("product.edits.undo"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        try await pressButton(L.string("common.cancel"), in: try #require(window.attachedSheet))
        try await wait(window) { window.attachedSheet == nil }
        #expect(try String(contentsOf: root.appendingPathComponent("Notes.md"), encoding: .utf8) == "second draft\nextra line")
        try await pressButton(L.string("product.edits.undo"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        try await pressButton(L.string("product.edits.undo"), in: try #require(window.attachedSheet))
        _ = try await waitRendered(window, containing: L.string("product.edits.undone"))
        #expect(try String(contentsOf: root.appendingPathComponent("Notes.md"), encoding: .utf8) == "first draft")
    }

    @Test("Artifact cards expose immutable changes, inline review and a full review sheet")
    func artifactDiffCard() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        let file = host.root.appendingPathComponent("Sample.swift")
        try Data("let value = 2\n".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "native-review", tool: "files_edit"),
            baseline: .existing(Data("let value = 1\n".utf8)))
        try FileManager.default.removeItem(at: file)
        let window = mount(TaskArtifactsView(artifacts: [artifact], roots: [host.root], store: store, onContinue: { _ in }).padding(), width: 950)
        defer { window.attachedSheet?.close(); window.close() }
        try await pressButton(L.string("product.artifact.diff.show"), in: window)
        _ = try await waitRendered(window, containing: "let value = 1")
        _ = try await waitRendered(window, containing: "let value = 2")
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("artifact-diff-unified.png"))
        }
        try await pressButton(L.string("product.artifact.diff.split"), in: window)
        _ = try await waitRendered(window, containing: "let value = 1")
        _ = try await waitRendered(window, containing: "let value = 2")
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("artifact-diff-split.png"))
        }
        try await pressButton(L.string("product.artifact.diff.expand"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        _ = try await waitRendered(sheet, containing: "let value = 1")
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(sheet, to: URL(fileURLWithPath: directory).appendingPathComponent("artifact-diff-review.png"))
        }
        try await pressButton(L.string("common.close"), in: sheet)
        try await wait(window) { window.attachedSheet == nil }
        try await pressButton(L.string("product.artifact.diff.hide"), in: window)
        _ = try await waitRendered(window, containing: L.string("product.artifact.diff.show"))
        try await store.removeRetainedContents([artifact])
        #expect(try await store.librarySummary().retainedBytes == 0)
    }

    @MainActor private final class HostDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    }
    private struct Host {
        let root: URL
        let queue: DatabaseQueue
        let hub: Hub
        let model: ChatViewModel
        let registry: WorkspaceRegistry
        let jobs: JobCenter
    }
    @MainActor private final class FolderPickerProbe {
        var presentations = 0
        private var continuation: CheckedContinuation<URL?, Never>?

        func choose() async -> URL? {
            presentations += 1
            return await withCheckedContinuation { continuation = $0 }
        }

        func complete(_ url: URL?) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: url)
        }
    }
    private enum HostFailure: Error { case timeout }
    @Observable final class FirstResultExecutionState {
        var running = true
        var inspections = 0
        var verified = false
    }
    private struct FirstResultLifecycleHost: View {
        let state: FirstResultExecutionState
        let progress: FirstResultProgress
        let session: ChatSession
        let store: TaskArtifactStore
        let preferences: ProductPreferencesService
        var body: some View {
            FirstResultReviewCard(progress: progress, session: session, isRunning: state.running, roots: [], store: store, preferences: preferences,
                isCurrent: {
                    state.inspections += 1
                    return !state.running && FirstResultReview.matches($0, session: session)
                }, onResume: {}, onVerified: { _ in state.verified = true }, onError: { Issue.record("\($0)") })
                .padding()
        }
    }

    private func fixture() throws -> Host {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-center-host-" + UUID().uuidString)
        let queue = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(queue)
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: queue), artifactPreviewsRoot: root.appendingPathComponent("artifact-cache"))
        let registry = WorkspaceRegistry(fileURL: root.appendingPathComponent("workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: root.appendingPathComponent("files")))
        let model = ChatViewModel(hub: hub, workspaceRegistry: registry, observeHostServices: false,
            handoffStore: DaemonHandoffStore(baseDirectory: root), draftDefaults: nil)
        model.workspaces = registry.workspaces(for: .work)
        return .init(root: root, queue: queue, hub: hub, model: model, registry: registry,
            jobs: JobCenter(historyFileURL: root.appendingPathComponent("history.json")))
    }

    private func mount<Content: View>(_ content: Content, width: Double = 720, height: Double = 640) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        window.orderFront(nil)
        return window
    }

    private func texts(_ view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextView)?.string ?? (view as? NSTextField)?.stringValue ?? (view.accessibilityValue() as? String)
        return (own.map { [$0] } ?? []) + view.subviews.flatMap { texts($0) }
    }

    private nonisolated static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private func renderedText(_ window: NSWindow, matching value: String? = nil, nativeScale: Bool = false) async throws -> String {
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let view = try #require(window.contentView)
        let data = try snapshotData(view, nativeScale: nativeScale)
        let language = LanguageManager.shared.activeLanguageCode
        // SwiftUI's nonselectable text is not an AppKit child. Read actual pixels
        // instead of asserting against model state or changing the product for a test.
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
            if let value {
                request.customWords = [value] + value.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty && $0 != value }
            }
            try VNImageRequestHandler(data: data).perform([request])
            let target = value.map(Self.normalized)
            return (request.results ?? []).compactMap { observation in
                let candidates = observation.topCandidates(target == nil ? 1 : 10)
                if let target, !target.isEmpty,
                   let match = candidates.first(where: { Self.normalized($0.string).contains(target) }) {
                    return match.string
                }
                return candidates.first?.string
            }.joined(separator: " ")
        }.value
    }

    private func visibleLabels(in window: NSWindow) -> [String] {
        guard let root = window.contentView else { return [] }
        let screenRect = window.convertToScreen(root.convert(root.visibleRect, to: nil))
        var seen = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ object: AnyObject, depth: Int) {
            guard depth < 40, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor || view.visibleRect.isEmpty { return }
            if let text = object as? NSTextView, let layout = text.layoutManager, let container = text.textContainer {
                let rect = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
                let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
                let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                labels.append((text.string as NSString).substring(with: range))
            }
            if let node = object as? any NSAccessibilityProtocol {
                let frame = node.accessibilityFrame()
                if node.accessibilityRole() == .staticText, !frame.isEmpty, screenRect.contains(frame) {
                    labels += [node.accessibilityValue() as? String, node.accessibilityLabel()].compactMap { $0 }
                }
                for child in node.accessibilityChildren() ?? [] { visit(child as AnyObject, depth: depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return labels
    }

    private func waitRendered(_ window: NSWindow, containing value: String,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        let target = Self.normalized(value)
        var last = ""
        for attempt in 0..<20 {
            // Thin caption glyphs rasterize differently at native and doubled size.
            // Both paths read this window's visible pixels and require an exact match.
            let text = try await renderedText(window, matching: value, nativeScale: !attempt.isMultiple(of: 2))
            last = text
            if Self.normalized(text).contains(target) { return text }
            let native = visibleLabels(in: window)
            if native.contains(where: { Self.normalized($0).contains(target) }) {
                return ([text] + native).joined(separator: "\n")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            let root = URL(fileURLWithPath: directory)
            try snapshot(window, to: root.appendingPathComponent("rendered-text-failure.png"))
            try ("Expected: " + value + "\n" + last).write(to: root.appendingPathComponent("rendered-text-failure.txt"), atomically: true, encoding: .utf8)
        }
        Issue.record("Expected visible text '\(value)'. Recognized: \(last.prefix(900))", sourceLocation: sourceLocation)
        throw HostFailure.timeout
    }

    private func wait(_ window: NSWindow, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<300 {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Native condition did not settle", sourceLocation: sourceLocation)
        throw HostFailure.timeout
    }

    private func pressButton(_ title: String, in window: NSWindow, identifier: String? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) async throws {
        func button(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button($0) }.first
        }
        let view = try #require(window.contentView)
        if window.sheetParent == nil {
            if !window.styleMask.contains(.titled) { window.styleMask = [.titled] }
            window.makeKeyAndOrderFront(nil)
        }
        else { window.makeKey() }
        try await Task.sleep(for: .milliseconds(60))
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if let native = button(view) { native.performClick(nil); return }
        var visited = Set<ObjectIdentifier>()
        func accessiblePress(_ object: AnyObject, depth: Int = 0) -> Bool {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return false }
            if let button = object as? any NSAccessibilityButton, button.accessibilityLabel() == title,
               button.accessibilityFrame().width > 0, button.accessibilityFrame().height > 0,
               button.accessibilityPerformPress() { return true }
            if let node = object as? any NSAccessibilityProtocol {
                if let identifier, node.accessibilityIdentifier() == identifier,
                   node.isAccessibilityEnabled(), !node.accessibilityFrame().isEmpty,
                   node.accessibilityPerformPress() { return true }
                if node.accessibilityRole() == .button, node.isAccessibilityEnabled(),
                   node.accessibilityLabel() == title || node.accessibilityTitle() == title,
                   node.accessibilityFrame().width > 0, node.accessibilityFrame().height > 0,
                   node.accessibilityPerformPress() { return true }
                for child in node.accessibilityChildren() ?? [] {
                    if accessiblePress(child as AnyObject, depth: depth + 1) { return true }
                }
            }
            if let native = object as? NSView {
                for child in native.subviews where !child.isHidden {
                    if accessiblePress(child, depth: depth + 1) { return true }
                }
            }
            return false
        }
        if accessiblePress(view) { return }
        if title == L.string("common.close"), window.sheetParent != nil,
           let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
               windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
           window.performKeyEquivalent(with: escape) { return }
        if window.sheetParent != nil,
           title == L.string("knowledge.import.choose") || title == L.string("knowledge.import.commit") {
            let choose = title == L.string("knowledge.import.choose")
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: choose ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: choose ? "o" : "\r", charactersIgnoringModifiers: choose ? "o" : "\r", isARepeat: false, keyCode: choose ? 31 : 36),
               window.performKeyEquivalent(with: event) { return }
        }
        // Some SwiftUI controls have no NSButton child. Locate the button text in
        // this test window's own bitmap and deliver events only to that window.
        var recognized: (CGPoint?, String) = (nil, "")
        for attempt in 0..<20 {
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let data = try snapshotData(view, nativeScale: !attempt.isMultiple(of: 2))
            let language = LanguageManager.shared.activeLanguageCode
            recognized = try await Task.detached { () throws -> (CGPoint?, String) in
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
                request.customWords = [title]
                try VNImageRequestHandler(data: data).perform([request])
                var exactMatches: [(CGPoint, String)] = []
                var fuzzyMatches: [(CGPoint, String)] = []
                var substitutions: [(CGPoint, String)] = []
                let target = Array(title.lowercased())
                let hasDigits = title.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
                // OCR may drop the spaces around a localized version number.
                // Map the whitespace-insensitive match back to the real pixels.
                func titleRange(in value: String) -> (Range<String.Index>, Bool)? {
                    // Vision commonly renders a typographic ellipsis as three
                    // periods. Keep the match tied to the original image range.
                    let alternatives = [title,
                        title.replacingOccurrences(of: "…", with: "..."),
                        title.replacingOccurrences(of: "...", with: "…")]
                    for candidate in alternatives {
                        if let range = value.range(of: candidate, options: .caseInsensitive) { return (range, true) }
                    }
                    let indices = value.indices.filter { !value[$0].isWhitespace }
                    let compact = String(indices.map { value[$0] })
                    if let range = alternatives.lazy.compactMap({ candidate in
                        compact.range(of: String(candidate.filter { !$0.isWhitespace }),
                            options: .caseInsensitive)
                    }).first, !range.isEmpty {
                        let start = compact.distance(from: compact.startIndex, to: range.lowerBound)
                        let end = compact.distance(from: compact.startIndex, to: range.upperBound)
                        return (indices[start]..<value.index(after: indices[end - 1]), true)
                    }
                    // A symbol beside a short SwiftUI button can be folded
                    // into its OCR line, with one letter also misread (for
                    // example the image's Project → Proiect). Accept only a
                    // complete short label with exactly one substituted glyph.
                    let decoration = CharacterSet.whitespacesAndNewlines
                        .union(.symbols).union(.punctuationCharacters)
                    let label = value.trimmingCharacters(in: decoration)
                    let expected = Array(title.lowercased())
                    let observed = Array(label.lowercased())
                    guard !hasDigits, expected.count >= 8, observed.count == expected.count,
                          zip(expected, observed).allSatisfy({ $0.isWhitespace == $1.isWhitespace }),
                          zip(expected, observed).filter({ $0 != $1 }).count == 1 else { return nil }
                    guard let range = value.range(of: label) else { return nil }
                    return (range, false)
                }
                for observation in request.results ?? [] {
                    if let text = observation.topCandidates(1).first {
                        let characters = Array(text.string.lowercased())
                        if !hasDigits, target.count >= 4, characters.count == target.count,
                           zip(target, characters).filter({ $0 != $1 }).count == 1 {
                            substitutions.append((CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY), text.string))
                        }
                    }
                    guard let text = observation.topCandidates(10).first(where: { titleRange(in: $0.string) != nil }),
                          let (range, exact) = titleRange(in: text.string),
                          let bounds = try text.boundingBox(for: range)?.boundingBox else { continue }
                    let match = (CGPoint(x: bounds.midX, y: bounds.midY), text.string)
                    if exact { exactMatches.append(match) } else { fuzzyMatches.append(match) }
                }
                // Help text can repeat a button's label. Prefer the actual short
                // label over a paragraph that merely mentions the same action.
                if let exact = exactMatches.min(by: { $0.1.count < $1.1.count }) { return (exact.0, exact.1) }
                if let fuzzy = fuzzyMatches.min(by: { $0.1.count < $1.1.count }) { return (fuzzy.0, fuzzy.1) }
                // Vision can substitute one glyph in a small button (副 → 到).
                // Accept only one complete, unambiguous label in this owned view;
                // callers still verify the actual decision, bytes and receipt.
                if substitutions.count == 1 { return (substitutions[0].0, substitutions[0].1) }
                return (nil, (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            }.value
            if recognized.0 != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if recognized.0 == nil {
            // Small labels in a toolbar or composer can merge into a nearby icon.
            // Scan overlapping tiles at full resolution and map the exact text back to the window.
            let data = try snapshotData(view)
            let language = LanguageManager.shared.activeLanguageCode
            let focused = try await Task.detached { () throws -> (CGPoint?, String) in
                guard let image = NSBitmapImageRep(data: data)?.cgImage else { return (nil, "") }
                let width = CGFloat(image.width), height = CGFloat(image.height)
                let size = CGSize(width: ceil(width * 0.6), height: ceil(height * 0.6))
                var matches: [(CGPoint, String)] = []
                for y in [0, height - size.height] {
                    for x in [0, width - size.width] {
                        let crop = CGRect(origin: CGPoint(x: x, y: y), size: size)
                        guard let tile = image.cropping(to: crop) else { continue }
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = language == "en" ? ["en-US"] : [language, "en-US"]
                        request.customWords = [title]
                        try VNImageRequestHandler(cgImage: tile).perform([request])
                        for observation in request.results ?? [] {
                            guard let candidate = observation.topCandidates(10).first(where: { $0.string.localizedCaseInsensitiveContains(title) }),
                                  let range = candidate.string.range(of: title, options: .caseInsensitive),
                                  let bounds = try candidate.boundingBox(for: range)?.boundingBox else { continue }
                            let point = CGPoint(x: (crop.minX + bounds.midX * crop.width) / width,
                                y: 1 - (crop.minY + (1 - bounds.midY) * crop.height) / height)
                            matches.append((point, candidate.string))
                        }
                    }
                }
                guard let best = matches.min(by: { $0.1.count < $1.1.count }) else { return (nil, "") }
                return (best.0, best.1)
            }.value
            if focused.0 != nil { recognized = focused }
        }
        if recognized.0 == nil, let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            let root = URL(fileURLWithPath: directory)
            try snapshot(window, to: root.appendingPathComponent("source-button-failure.png"))
            try ("Looking for: " + title + "\n" + recognized.1).write(to: root.appendingPathComponent("source-button-failure.txt"), atomically: true, encoding: .utf8)
            func describe(_ view: NSView, depth: Int = 0) -> String {
                let own = "\(String(repeating: " ", count: depth))\(type(of: view)) \(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden)\n"
                return own + view.subviews.map { describe($0, depth: depth + 1) }.joined()
            }
            try describe(view).write(to: root.appendingPathComponent("source-button-hierarchy.txt"), atomically: true, encoding: .utf8)
        }
        let normalized = try #require(recognized.0, "Could not locate '\(title)' in the test window", sourceLocation: sourceLocation)
        let local = NSPoint(x: normalized.x * view.bounds.width,
            y: (view.isFlipped ? 1 - normalized.y : normalized.y) * view.bounds.height)
        let location = view.convert(local, to: nil)
        try window.sendTestClick(at: location, matching: title)
    }

    /// Operates only the file panel opened by this fixture's named action. The
    /// native panel and export code run unchanged; selected destinations are temporary.
    private func chooseExport(panel: NSSavePanel, title: String, destination: URL, folder: Bool, action: () async throws -> Void) async throws {
        let configured = Mutex(false), chosen = Mutex(false), diagnostic = Mutex("no timer callback"), deadline = Date().addingTimeInterval(15)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let status = "title=\(panel.title ?? "") visible=\(panel.isVisible) running=\(NSApp.isRunning) policy=\(NSApp.activationPolicy().rawValue)"
                diagnostic.withLock { $0 = status }
                guard panel.title == title, panel.isVisible else { return }
                if Date() > deadline { panel.cancel(nil); return }
                if !configured.withLock({ value in let previous = value; value = true; return previous }) {
                    panel.directoryURL = folder ? destination : destination.deletingLastPathComponent()
                    if !folder { panel.nameFieldStringValue = destination.lastPathComponent }
                    return
                }
                let directory = folder ? destination : destination.deletingLastPathComponent()
                guard panel.directoryURL?.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else { return }
                if !folder, panel.url?.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path {
                    configured.withLock { $0 = false }; return
                }
                chosen.withLock { $0 = true }
                panel.makeKey()
                if let button = panel.defaultButtonCell?.controlView as? NSButton { button.performClick(nil) }
                else {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { continue }
                        if type == .keyDown, panel.performKeyEquivalent(with: event) { continue }
                        panel.sendEvent(event)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        try await action()
        for _ in 0..<300 {
            if chosen.withLock({ $0 }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Export panel did not appear: \(diagnostic.withLock { $0 })")
        throw HostFailure.timeout
    }

    @Test("The rendered task-center source button routes to the saved answer in its own space")
    func sourceButtonNavigation() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        var session = ChatSession(title: "Source navigation fixture")
        let answer = ChatMessage(role: .assistant, content: "The source answer", runStatus: .succeeded, taskRun: .init())
        session.messages = [.init(role: .user, content: "Find the source answer"), answer]
        try await SessionService(databaseQueue: host.queue).save(session)
        let routed = Mutex<ProductRoute?>(nil)
        let observer = NotificationCenter.default.addObserver(forName: ProductRoute.notification, object: nil, queue: .main) { note in
            if let route = note.object as? ProductRoute { routed.withLock { $0 = route } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let window = mount(TaskCenterPanel(hub: host.hub, model: host.model, jobCenter: host.jobs, daemonSnapshot: { _ in ([], [], [:]) }))
        defer { window.close() }
        try await wait(window) { texts(window.contentView).contains(answer.content) }
        try await pressButton(L.string("product.tasks.open_source"), in: window)
        try await wait(window) { routed.withLock { $0 != nil } }
        let route = try #require(routed.withLock { $0 })
        #expect(route.space == .work && route.page == "chat" && route.sessionID == session.id && route.messageID == answer.id)
        #expect(route.runID == answer.taskRun?.id)
        let sourceID = try #require(route.sessionID)
        #expect(await host.model.openTaskSource(sessionID: sourceID, messageID: route.messageID))
        #expect(host.model.sourceMessageFocus?.messageID == answer.id && host.model.activeSessionId == session.id)
        #expect(!host.model.isAnyRunning)
    }

    @Test("The native reuse button preserves source mode and prepares a saved separate draft without taking unassigned input")
    func nativeReuseRequestDraft() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        var source = ChatSession(title: "Reusable coding request")
        source.mode = .coding; source.workspaceId = host.model.workspaces.first(where: \.isDefault)?.id.uuidString
        source.messages = [.init(role: .user, content: "Review the synthetic project"),
            .init(role: .assistant, content: "NATIVE REUSABLE RESULT 2048", runStatus: .failed, taskRun: .init())]
        try await service.save(source); await host.model.load()
        host.model.activeSessionId = nil
        let input = host.root.appendingPathComponent("unassigned-draft.txt")
        try Data("Unassigned attachment".utf8).write(to: input)
        host.model.inputText = "Keep my unassigned question"; host.model.addAttachments([input])
        let routed = Mutex<ProductRoute?>(nil)
        let observer = NotificationCenter.default.addObserver(forName: ProductRoute.notification, object: nil, queue: .main) { note in
            if let route = note.object as? ProductRoute { routed.withLock { $0 = route } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let window = mount(TaskCenterPanel(hub: host.hub, model: host.model, jobCenter: host.jobs, daemonSnapshot: { _ in ([], [], [:]) }))
        defer { window.attachedSheet?.close(); window.close() }
        try await wait(window) { texts(window.contentView).contains("NATIVE REUSABLE RESULT 2048") }
        try await pressButton(L.string("product.tasks.details"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let detail = try #require(window.attachedSheet)
        _ = try await waitRendered(detail, containing: L.string("product.tasks.reuse_request"))
        try await pressButton(L.string("product.tasks.reuse_request"), in: detail)
        try await wait(detail) { routed.withLock { $0 != nil } }
        let route = try #require(routed.withLock { $0 })
        #expect(route.draft == "Review the synthetic project" && route.draftMode == .coding && route.space == .work)
        #expect(await host.model.prepareProductDraft(try #require(route.draft), workspaceID: route.workspaceID, mode: route.draftMode))
        let draft = try #require(host.model.activeSessionId)
        #expect(draft != source.id && host.model.session(id: draft)?.mode == .coding && host.model.pendingAttachments.isEmpty)
        #expect(host.model.inputText == route.draft && !host.model.isAnyRunning)
        #expect(try await service.fetch(id: draft)?.messages.isEmpty == true)
        let preserved = try #require(host.model.drafts.first { $0.key != draft && $0.value == "Keep my unassigned question" }?.key)
        #expect(try await service.fetch(id: preserved) != nil)
        host.model.activeSessionId = preserved
        #expect(host.model.inputText == "Keep my unassigned question" && host.model.pendingAttachments == [input])
        #expect(try await service.fetch(id: source.id)?.messages == source.messages)
    }

    @Test("Native copy and follow-up buttons use the exact saved result and keep the current conversation draft")
    func nativeCopyAndFollowUp() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        var source = ChatSession(title: "Follow-up source")
        var answer = ChatMessage(role: .assistant, content: "EXACT SAVED RESULT 4096\nSecond line.", runStatus: .succeeded, taskRun: .init())
        answer.inputTokens = 0; answer.outputTokens = 0
        source.messages = [.init(role: .user, content: "Fixture question"), answer]
        try await service.save(source); await host.model.load()
        host.model.activeSessionId = source.id; host.model.inputText = "Existing source draft"
        let item = try #require(try await ProductTaskCenterStore(databaseQueue: host.queue, space: .work).page().items.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var followUp: String?
        let window = mount(ProductTaskDetailView(hub: host.hub, model: host.model, item: item, job: nil, jobCenter: host.jobs,
            copyResult: { pasteboard.clearContents(); pasteboard.setString($0, forType: .string) },
            onOpen: {}, onReuse: { _ in }, onContinue: { _, _ in }, onContinueSnapshot: { _, _, _ in }, onFollowUp: { followUp = $0 }))
        defer { window.close() }
        _ = try await waitRendered(window, containing: "EXACT SAVED RESULT 4096")
        let tokens = try await renderedText(window)
        #expect(tokens.range(of: #"\b0\s*/\s*0\b"#, options: .regularExpression) != nil)
        try await pressButton(L.string("product.tasks.copy_result"), in: window)
        #expect(pasteboard.string(forType: .string) == answer.content)
        try await pressButton(L.string("product.tasks.follow_up"), in: window)
        let prompt = try #require(followUp)
        #expect(prompt.contains(item.title) && prompt.contains(answer.content))
        #expect(await host.model.prepareProductDraft(prompt))
        #expect(host.model.activeSessionId != source.id && host.model.inputText == prompt && !host.model.isAnyRunning)
        #expect(host.model.drafts[source.id] == "Existing source draft")
        #expect(try await service.fetch(id: source.id)?.messages == source.messages)
    }

    @Test("A routed draft stops on save failure or expired navigation without replacing existing text or attachments")
    func productDraftSaveFailure() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        let source = ChatSession(title: "Protected unsent draft")
        try await service.save(source); await host.model.load()
        host.model.activeSessionId = source.id; host.model.inputText = "Keep this text"
        let file = host.root.appendingPathComponent("draft-source.txt"); try Data("Keep this file".utf8).write(to: file)
        host.model.addAttachments([file])
        #expect(await host.model.prepareProductDraft("Expired route", isCurrent: { false }) == false)
        #expect(try await service.getSummaries().count == 1)
        let id = source.id.uuidString
        try await host.queue.write { db in try db.execute(sql: "CREATE TRIGGER reject_product_draft BEFORE INSERT ON chat_sessions WHEN NEW.id <> '\(id)' BEGIN SELECT RAISE(FAIL,'fixture'); END") }
        #expect(await host.model.prepareProductDraft("New request") == false)
        #expect(host.model.activeSessionId == source.id && host.model.inputText == "Keep this text" && host.model.pendingAttachments == [file])
        #expect(try await service.getSummaries().count == 1)
        try await host.queue.write { try $0.execute(sql: "DROP TRIGGER reject_product_draft") }
        #expect(await host.model.prepareProductDraft("New request"))
        #expect(host.model.inputText == "New request" && host.model.pendingAttachments.isEmpty && !host.model.isAnyRunning)
        host.model.activeSessionId = source.id
        #expect(host.model.inputText == "Keep this text" && host.model.pendingAttachments == [file])
    }

    @Test("Opening an older archived answer loads its full source, focuses it repeatedly and preserves the selected answer version")
    func olderSourceNavigation() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        var old = ChatSession(title: "Archived long conversation")
        old.isArchived = true
        old.messages = (0..<130).map { .init(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "Message \($0)") }
        old.messages[1].variations = [.init(question: "Original request", content: "Older attempt"), .init(question: "Current request", content: "Message 1")]
        old.messages[1].activeVariationIndex = 1
        let target = old.messages[1]
        try await service.save(old)
        try await service.save(ChatSession(title: "Current conversation"))
        await host.model.load()
        #expect(host.model.session(id: old.id)?.isMessagesLoaded == false)
        #expect(await host.model.openTaskSource(sessionID: old.id, messageID: target.id))
        let firstFocus = host.model.sourceMessageFocus?.id
        #expect(host.model.activeSessionId == old.id && host.model.sessionFilter == .archived)
        #expect(host.model.session(id: old.id)?.messages.count == 130 && host.model.session(id: old.id)?.messageOffset == 0)
        #expect(host.model.sourceMessageFocus?.messageID == target.id)
        #expect(await host.model.openTaskSource(sessionID: old.id, messageID: target.id))
        #expect(host.model.sourceMessageFocus?.id != firstFocus)
        #expect(try await service.fetch(id: old.id)?.messages == old.messages)
        #expect(await host.model.openTaskSource(sessionID: old.id))
        #expect(host.model.sourceMessageFocus == nil)
        #expect(await host.model.openTaskSource(sessionID: UUID()) == false)
        #expect(host.model.errorMessage == L.string("product.tasks.source_unavailable"))
    }

    @Test("Opening a saved waiting answer restores its confirmation card without running or approving the operation")
    func sourceWithPendingConfirmation() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        var source = ChatSession(title: "Saved approval")
        let answer = ChatMessage(role: .assistant, content: "Review the write", runStatus: .waitingForConfirmation)
        source.messages = [.init(role: .user, content: "Fixture request"), answer]
        source.pendingConfirmation = .init(messageId: answer.id, toolName: "files_write", argumentsDisplay: "test-owned pending write")
        try await service.save(source)
        #expect(try await service.getMessagePage(id: source.id).pendingConfirmation == source.pendingConfirmation)
        #expect(try await service.getMessagesDetailed(id: source.id).pendingConfirmation == source.pendingConfirmation)
        #expect(await host.model.openTaskSource(sessionID: source.id, messageID: answer.id))
        #expect(host.model.pendingConfirmation?.messageId == answer.id)
        #expect(host.model.sourceMessageFocus?.messageID == answer.id && !host.model.isAnyRunning)
        #expect(try await service.fetch(id: source.id)?.pendingConfirmation == source.pendingConfirmation)
    }

    @Test("Ordinary cold conversation loading restores the saved confirmation with its message page")
    func coldConversationConfirmation() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        var source = ChatSession(title: "Cold confirmation fixture")
        let answer = ChatMessage(role: .assistant, content: "Still awaiting approval", runStatus: .waitingForConfirmation)
        source.messages = [.init(role: .user, content: "Fixture request"), answer]
        source.pendingConfirmation = .init(messageId: answer.id, toolName: "files_write", argumentsDisplay: "test-only request")
        try await SessionService(databaseQueue: host.queue).save(source)
        await host.model.load()
        for _ in 0..<100 {
            if host.model.pendingConfirmation != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.model.pendingConfirmation?.messageId == answer.id && !host.model.isAnyRunning)
        #expect(!host.model.isAwaitingApproval(source.id))
    }

    @Test("A restored confirmation cannot authorize a new model run")
    func restoredConfirmationIsReviewOnly() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        var source = ChatSession(title: "Interrupted delegation")
        let answer = ChatMessage(role: .assistant, content: "Earlier child steps may have run",
            runStatus: .waitingForConfirmation)
        source.messages = [.init(role: .user, content: "Fixture request"), answer]
        source.pendingConfirmation = .init(messageId: answer.id, toolName: "agent → skill_run_script",
            argumentsDisplay: "review-only operation")
        try await service.save(source)
        #expect(await host.model.openTaskSource(sessionID: source.id, messageID: answer.id))
        #expect(host.model.pendingConfirmation?.approvalID == nil)

        host.model.confirmPending(approved: true, alwaysAllow: true, persistRule: true)

        #expect(host.model.pendingConfirmation?.messageId == answer.id)
        #expect(host.model.inputText.isEmpty)
        #expect(host.model.session(id: source.id)?.messages.count == 2)
        #expect(try await service.fetch(id: source.id)?.pendingConfirmation?.messageId == answer.id)

        await host.model.endInterruptedConfirmation()
        #expect(host.model.pendingConfirmation == nil)
        #expect(host.model.session(id: source.id)?.messages.last?.runStatus == .recoveryRequired)
        let saved = try #require(try await service.fetch(id: source.id))
        #expect(saved.pendingConfirmation == nil)
        #expect(saved.messages.last?.runStatus == .recoveryRequired)
        #expect(saved.messages.count == 2)
    }

    @Test("A team source outside the recent page is selected in the native task board")
    func olderTeamSourceMount() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = TeamTaskStore(databaseQueue: host.queue), id = UUID()
        for index in 0...200 {
            let goal = index == 0 ? "Requested older collaboration" : "Recent collaboration \(index)"
            let plan = TeamPlan(goal: goal, subtasks: [])
            let report = TeamTaskReport(taskID: index == 0 ? id : UUID(), goal: goal, status: .completed, subtasks: [], artifacts: [],
                usage: .init(), openQuestions: [], errors: [], startedAt: Date(), finishedAt: Date())
            try await store.save(plan: plan, report: report)
        }
        #expect(try await store.listTasks(limit: 200).contains(where: { $0.id == id }) == false)
        let item = try #require(try await ProductTaskCenterStore(databaseQueue: host.queue, space: .work)
            .page(source: .team, search: "Requested older collaboration").items.first)
        let route = ProductRoute.source(item, space: .work)
        #expect(route.taskID == id)
        let window = mount(TeamTasksView(hub: host.hub, source: route), width: 1150, height: 720)
        defer { window.close() }
        try await wait(window) { texts(window.contentView).contains("Requested older collaboration") }
        #expect(try await store.task(id: id)?.status == .completed)
    }

    @Test("A scheduled source opens and scrolls to the requested run beyond the recent history page")
    func olderScheduledRunMount() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let taskStore = ScheduledTaskStore(databaseQueue: host.queue), runStore = ScheduledRunStore(databaseQueue: host.queue)
        var task = ScheduledTask(name: "Requested schedule", prompt: "Read fixture", schedule: .init(rule: .daily(hour: 9, minute: 0)))
        task.enabled = false
        try await taskStore.save(task)
        let requested = ScheduledRun(taskID: task.id, taskName: task.name, trigger: .manual, scheduledFor: nil, status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1), summary: "SAVED HISTORICAL RESULT 4812")
        try await runStore.insert(requested)
        for index in 0..<55 {
            try await runStore.insert(.init(taskID: task.id, taskName: task.name, trigger: .manual, scheduledFor: nil,
                status: .succeeded, startedAt: Date(timeIntervalSince1970: Double(index + 2)), summary: "Recent run \(index)"))
        }
        #expect(try await runStore.runs(taskID: task.id).contains(where: { $0.id == requested.id }) == false)
        let item = try #require(try await ProductTaskCenterStore(databaseQueue: host.queue, space: .work)
            .page(source: .scheduled, search: "SAVED HISTORICAL RESULT 4812").items.first)
        let route = ProductRoute.source(item, space: .work)
        #expect(route.taskID == task.id && route.runID == requested.id)
        let window = mount(ScheduledTasksView(hub: host.hub, source: route, observeHostServices: false), width: 1150, height: 720)
        defer { window.close() }
        _ = try await waitRendered(window, containing: "SAVED HISTORICAL RESULT 4812")
        #expect(try await runStore.runs(taskID: task.id, limit: 100).count == 56)
        #expect(try await taskStore.task(id: task.id)?.enabled == false)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("scheduled-source.png"))
        }
    }

    @Test("Cold mounting the task center loads actual current-space results with a bounded initial page")
    func coldCenterMount() async throws {
        let host = try fixture()
        let previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {} }
        defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        var waiting = ChatSession(title: "Old waiting request")
        waiting.messages = [.init(role: .user, content: "Old waiting request"), .init(role: .assistant, content: "Awaiting user choice",
            runStatus: .waitingForInput, taskRun: .init(startedAt: Date(timeIntervalSince1970: 1)))]
        try await service.save(waiting)
        for index in 0..<45 {
            var session = ChatSession(title: "Finished \(index)")
            session.messages = [.init(role: .user, content: session.title), .init(role: .assistant, content: "Saved result \(index)",
                runStatus: .succeeded, taskRun: .init(startedAt: Date(timeIntervalSince1970: Double(index + 2))))]
            try await service.save(session)
        }
        let window = mount(TaskCenterPanel(hub: host.hub, model: host.model, jobCenter: host.jobs, daemonSnapshot: { _ in ([], [], [:]) }))
        defer { window.close() }
        try await wait(window) { texts(window.contentView).contains("Saved result 44") }
        #expect(!texts(window.contentView).contains("Awaiting user choice"))
        #expect(!host.model.isAnyRunning && host.model.sessions.isEmpty)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("task-center.png"))
        }
        let center = try #require(host.hub.makeTaskCenterStore(for: .work))
        #expect(try await center.clearFinished() == 45)
        // LazyVStack may retain removed AppKit text views in its reuse cache.
        // Check the rendered page rather than treating those children as visible.
        _ = try await waitRendered(window, containing: "Awaiting user choice")
        let visible = try await renderedText(window)
        #expect(!visible.localizedCaseInsensitiveContains("Saved result 44"))
    }

    @Test("The task center confirms row and bulk removal and keeps the original job receipts")
    func manualHistoryRemoval() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let jobs = try #require(host.hub.makeJobRunStore(for: .work))
        let center = try #require(host.hub.makeTaskCenterStore(for: .work))
        var failed = BackgroundJob(name: "Failed export", kind: "export", space: .work)
        failed.state = .failed
        try jobs.saveCompleted([failed])
        let panel = TaskCenterPanel(hub: host.hub, model: host.model, jobCenter: host.jobs,
            handoffStore: DaemonHandoffStore(baseDirectory: host.root), daemonSnapshot: { _ in ([], [], [:]) })
        let window = mount(panel)
        defer { window.attachedSheet?.close(); window.close() }
        let remove = L.string("product.tasks.clear_one")
        _ = try await waitRendered(window, containing: remove)
        try await pressButton(remove, in: window)
        try await wait(window) { window.attachedSheet != nil }
        try await pressButton(L.string("common.cancel"), in: try #require(window.attachedSheet))
        try await wait(window) { window.attachedSheet == nil }
        #expect(try await center.page().items.map(\.sourceID) == [failed.id])

        try await pressButton(remove, in: window)
        try await wait(window) { window.attachedSheet != nil }
        // A second eligible item arrives while the row confirmation is open.
        var index = BackgroundJob(name: "Interrupted index", kind: "knowledge-index-work", space: .work)
        index.state = .interrupted
        try jobs.saveCompleted([index])
        try await pressButton(remove, in: try #require(window.attachedSheet))
        _ = try await waitRendered(window, containing: index.name)
        #expect(try await center.page().items.map(\.sourceID) == [index.id])

        let bulk = L.string("product.tasks.clear_finished")
        try await pressButton(bulk, in: window)
        try await wait(window) { window.attachedSheet != nil }
        try await pressButton(bulk, in: try #require(window.attachedSheet))
        _ = try await waitRendered(window, containing: L.string("product.tasks.empty"))
        #expect(try await jobs.run(id: failed.id)?.state == .failed)
        #expect(try await jobs.run(id: index.id)?.state == .interrupted)
    }

    @Test("A mounted job detail receives and displays the persisted terminal result through the scoped live stream")
    func liveJobDetail() async throws {
        let host = try fixture(), release = Mutex(false), entered = Mutex(false)
        let previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {} }
        defer { release.withLock { $0 = true }; try? FileManager.default.removeItem(at: host.root) }
        let id = host.jobs.submit(name: "Fixture export", kind: "test", space: .work, origin: "settings", historyStore: host.hub.makeJobRunStore(for: .work)) { context in
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            context.reportResult("The saved fixture result")
        }
        for _ in 0..<300 {
            if entered.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 })
        let jobs = host.jobs.snapshot(space: .work)
        let page = try await host.hub.makeTaskCenterStore(for: .work)?.page(jobs: jobs)
        let item = try #require(page?.items.first { $0.sourceID == id })
        let view = ProductTaskDetailView(hub: host.hub, model: host.model, item: item,
            job: jobs.first { $0.id == id }, jobCenter: host.jobs, onOpen: {}, onReuse: { _ in }, onContinue: { _, _ in }, onContinueSnapshot: { _, _, _ in }, onFollowUp: { _ in })
        let window = mount(view, width: 700, height: 650)
        defer { window.close() }
        // Let the mounted detail subscribe while the real fixture job is still active.
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        release.withLock { $0 = true }
        try await wait(window) { host.jobs.snapshot().first { $0.id == id }?.state == .succeeded
            && texts(window.contentView).contains("The saved fixture result") }
        #expect(try await host.hub.makeJobRunStore(for: .work)?.run(id: id)?.state == .succeeded)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("task-job-detail.png"))
        }
    }

    @Test("Interrupted index jobs expose a review action and route to Knowledge & Memory settings", arguments: [false, true])
    func handleInterruptedIndexJob(openSettings: Bool) async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeJobRunStore(for: .work))
        var job = BackgroundJob(name: L.string("embedding.index.job"), kind: "knowledge-index-work", space: .work, origin: "knowledge")
        job.state = .running
        try await store.recordStarted(job)
        let id = job.id
        try await host.queue.write {
            try $0.execute(sql: "UPDATE product_job_runs SET hostID='previous-process' WHERE id=?", arguments: [id.uuidString])
        }

        let routed = Mutex<ProductRoute?>(nil)
        let observer = NotificationCenter.default.addObserver(forName: ProductRoute.notification, object: nil, queue: nil) { note in
            routed.withLock { $0 = note.object as? ProductRoute }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let window = mount(TaskCenterPanel(hub: host.hub, model: host.model, jobCenter: host.jobs,
            handoffStore: DaemonHandoffStore(baseDirectory: host.root), daemonSnapshot: { _ in ([], [], [:]) }))
        defer { window.close() }
        _ = try await waitRendered(window, containing: L.string("jobs.history.handle"))
        try await pressButton(L.string("jobs.history.handle"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let detail = try #require(window.attachedSheet)
        _ = try await waitRendered(detail, containing: L.string("jobs.interrupted.acknowledge"))
        if openSettings {
            try await pressButton(L.string("jobs.interrupted.index.settings"), in: detail)
            try await wait(window) { routed.withLock { $0 != nil } }
            let route = try #require(routed.withLock { $0 })
            #expect(route.space == .work && route.page == "settings" && route.settingsTab == .knowledge)
            #expect(try await store.run(id: id)?.state == .interrupted)
        } else {
            try await pressButton(L.string("jobs.interrupted.acknowledge"), in: detail)
            _ = try await waitRendered(detail, containing: L.string("jobs.state.interruptionAcknowledged"))
            #expect(try await store.run(id: id)?.state == .interruptionAcknowledged)
            try await pressButton(L.string("common.close"), in: detail)
            try await wait(window) { window.attachedSheet == nil }
            _ = try await waitRendered(window, containing: L.string("jobs.state.interruptionAcknowledged"))
            #expect(host.jobs.snapshot(space: .work).isEmpty)
        }
    }

    @Test("The native task detail cancels active knowledge extraction and settles its import receipt without saving content")
    func cancelKnowledgeJobFromDetail() async throws {
        let host = try fixture(), entered = Mutex(false)
        let previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let knowledge = KnowledgeService(databaseQueue: host.queue)
        let service = KnowledgeImportService(service: knowledge, space: .work) { snapshot, _ in
            entered.withLock { $0 = true }
            try await Task.sleep(for: .seconds(30))
            return .init(title: "Cancelled source", blocks: [.init(text: String(decoding: snapshot.data, as: UTF8.self))], parser: "fixture")
        }
        let url = host.root.appendingPathComponent("cancel-source.txt")
        try Data("Do not save a cancelled extraction".utf8).write(to: url)
        let importer = KnowledgeImportModel(service: service, baseID: nil, folderID: nil, jobs: host.jobs)
        let importWindow = mount(KnowledgeImportSheet(model: importer, onFinished: {}), width: 960, height: 700)
        defer { importer.cancel(); importWindow.close() }
        importer.prepare([url])
        try await wait(importWindow) { entered.withLock { $0 } && importer.activeJobID != nil }
        let id = try #require(importer.activeJobID), batch = try #require(importer.batch)
        defer { host.jobs.cancel(id: id) }
        let jobs = host.jobs.snapshot(space: .work)
        let page = try await ProductTaskCenterStore(databaseQueue: host.queue, space: .work).page(jobs: jobs)
        let item = try #require(page.items.first { $0.sourceID == id })
        #expect(item.origin == "knowledge" && item.status == .running)
        let detail = mount(ProductTaskDetailView(hub: host.hub, model: host.model, item: item,
            job: jobs.first { $0.id == id }, jobCenter: host.jobs, onOpen: {}, onReuse: { _ in },
            onContinue: { _, _ in }, onContinueSnapshot: { _, _, _ in }, onFollowUp: { _ in }), width: 700, height: 650)
        defer { detail.close() }
        _ = try await waitRendered(detail, containing: L.string("jobs.cancel"))
        try await pressButton(L.string("jobs.cancel"), in: detail)
        try await wait(detail) { !importer.working && host.jobs.snapshot().first { $0.id == id }?.state == .cancelled }
        #expect(importer.rows.first?.state == .failed && importer.rows.first?.error == L.string("jobs.state.cancelled"))
        #expect(try await service.tasks(batchID: batch.id).first?.state == .cancelled)
        #expect(try await knowledge.getAll().isEmpty)
        #expect(try await service.makeJobRunStore().run(id: id)?.state == .cancelled)
    }

    @Test("A grouped result uses its own latest revision and applies an explicit historical selection to every action")
    func groupedArtifactVersionActions() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        let file = host.root.appendingPathComponent("grouped-result.txt"), run = UUID()
        var revisions: [TaskArtifact] = []
        for index in 1...3 {
            try Data("Retained revision \(index)".utf8).write(to: file)
            revisions.append(try await store.capture(file, root: host.root, logicalPath: nil,
                origin: .init(space: .work, sessionID: nil, runID: index == 3 ? UUID() : run,
                    workspaceID: nil, operationID: "revision-\(index)", tool: "files_edit")))
        }
        try FileManager.default.removeItem(at: file)
        let continued = Mutex<TaskArtifact?>(nil), exportURL = host.root.appendingPathComponent("chosen-version.txt")
        let view = TaskArtifactsView(artifacts: [revisions[0], revisions[1], revisions[0]], roots: [], store: store,
            onContinueSnapshot: { artifact, url in
                #expect((try? String(contentsOf: url, encoding: .utf8)) == "Retained revision \(artifact.version ?? 0)")
                continued.withLock { $0 = artifact }
            }, chooseExportDestination: { _ in .selected(exportURL) }, onContinue: { _ in Issue.record("Expected a retained snapshot") })
            .padding()
        let window = mount(view, width: 840, height: 480)
        defer { window.close() }
        _ = try await waitRendered(window, containing: file.lastPathComponent)
        try await pressButton(L.string("product.artifact.continue"), in: window)
        try await wait(window) { continued.withLock { $0?.id == revisions[1].id } }
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            let root = URL(fileURLWithPath: directory)
            try snapshot(window, to: root.appendingPathComponent("artifact-grouped-wide.png"))
            window.setContentSize(NSSize(width: 340, height: 480))
            _ = try await waitRendered(window, containing: L.string("product.artifact.continue"))
            try snapshot(window, to: root.appendingPathComponent("artifact-grouped-narrow.png"))
            window.setContentSize(NSSize(width: 840, height: 480))
        }
        try await pressButton(L.format("product.artifact.version", 2), in: window)
        _ = try await waitRendered(window, containing: L.format("product.artifact.version", 1))
        try await pressButton(L.format("product.artifact.version", 1), in: window)
        try await pressButton(L.string("product.artifact.continue"), in: window)
        try await wait(window) { continued.withLock { $0?.id == revisions[0].id } }
        try await pressButton(L.string("product.artifact.export"), in: window)
        try await wait(window) { FileManager.default.fileExists(atPath: exportURL.path) }
        #expect(try String(contentsOf: exportURL, encoding: .utf8) == "Retained revision 1")
    }

    @Test("Artifact cards display retained revisions after the original is removed",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] != nil))
    func artifactCards() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = TaskArtifactStore(databaseQueue: host.queue, space: .work, previewRoot: host.root.appendingPathComponent("previews"))
        let path = host.root.appendingPathComponent("project-report.md"), run = UUID()
        try Data("First historical report".utf8).write(to: path)
        let first = try await store.capture(path, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: run, workspaceID: nil, operationID: "first", tool: "python_execute"))
        try Data("Second historical report".utf8).write(to: path)
        let firstID = try #require(first.versionID)
        let second = try await store.capture(path, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: run, workspaceID: nil, operationID: "second", tool: "files_edit", inputVersionIDs: [firstID]))
        try FileManager.default.removeItem(at: path)
        var artifacts = [first, second]
        for name in ["Sources/WaveformService.swift", "Tests/WaveformService.swift", "WaveformStrip.swift", "RecordingDetailView.swift", "RecordingService.swift"] {
            let file = host.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Synthetic source for native layout inspection".utf8).write(to: file)
            artifacts.append(try await store.capture(file, root: host.root, logicalPath: nil,
                origin: .init(space: .work, sessionID: nil, runID: run, workspaceID: nil, operationID: name, tool: "files_edit")))
            try FileManager.default.removeItem(at: file)
        }
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"]))
        let oldLanguage = LanguageManager.shared.currentLanguage, oldLarge = InterfaceTypographyPreferences.shared.isLarge
        defer { LanguageManager.shared.currentLanguage = oldLanguage; InterfaceTypographyPreferences.shared.isLarge = oldLarge }
        for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
            LanguageManager.shared.currentLanguage = language
            for dark in [false, true] {
                for width in [340.0, 840.0] {
                    InterfaceTypographyPreferences.shared.isLarge = width == 340
                    let view = TaskArtifactsView(artifacts: artifacts, roots: [], store: store, onContinueSnapshot: { _, _ in }, onContinue: { _ in })
                        .padding().environment(\.colorScheme, dark ? .dark : .light)
                    let window = mount(view, width: width, height: 1000)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    defer { window.close() }
                    _ = try await waitRendered(window, containing: L.format("product.artifact.file_count", 6))
                    try snapshot(window, to: directory.appendingPathComponent("artifacts-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
    }

    @Test("The native artifact library loads unsaved results without requiring a conversation receipt")
    func artifactLibraryMount() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = TaskArtifactStore(databaseQueue: host.queue, space: .work, previewRoot: host.root.appendingPathComponent("previews"))
        for index in 0..<43 {
            let file = host.root.appendingPathComponent("recoverable-report-\(index).txt")
            try Data("Retained before conversation save".utf8).write(to: file)
            _ = try await store.capture(file, root: host.root, logicalPath: nil,
                origin: .init(space: .work, sessionID: UUID(), runID: UUID(), workspaceID: nil, operationID: UUID().uuidString, tool: "python_execute"))
        }
        let window = mount(ArtifactLibraryView(store: store), width: 880, height: 650)
        defer { window.close() }
        try await wait(window) { texts(window.contentView).joined(separator: " ").contains("recoverable-report-") }
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("artifact-library.png"))
        }
    }

    @Test("A pending artifact attachment pins its copy until it is removed from the composer")
    func pendingArtifactPin() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let store = TaskArtifactStore(databaseQueue: host.queue, space: .work, previewRoot: host.root.appendingPathComponent("previews"))
        let file = host.root.appendingPathComponent("draft.md"); try Data("Exact selected version".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "draft", tool: "python_execute"))
        let copy = try await store.materialize(artifact)
        host.model.attachArtifactSnapshot(artifact, url: copy, store: store)
        #expect(host.model.pendingAttachments == [copy])
        await #expect(throws: TaskArtifactError.previewInUse) { try await store.clearPreviewCache() }
        host.model.removeAttachment(copy)
        var cleaned = false
        for _ in 0..<30 {
            do { try await store.clearPreviewCache(); cleaned = true; break }
            catch TaskArtifactError.previewInUse { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(cleaned && host.model.pendingAttachments.isEmpty)
        #expect(try await store.librarySummary().retainedVersions == 1)
    }

    @Test("Continuing a retained result finds a cold archived source and keeps each conversation's unsent files and pins")
    func continuationDraftOwnership() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue), store = try #require(host.hub.makeArtifactStore(for: .work))
        var source = ChatSession(title: "Archived result source"); source.isArchived = true
        try await service.save(source)
        let current = ChatSession(title: "Unsent current draft"); try await service.save(current)
        let file = host.root.appendingPathComponent("historical-result.txt"), raw = host.root.appendingPathComponent("unsent-source.txt")
        try Data("Retained source result".utf8).write(to: file); try Data("Current draft attachment".utf8).write(to: raw)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: source.id, runID: UUID(), workspaceID: nil, operationID: "continuation", tool: "python_execute"))
        try FileManager.default.removeItem(at: file)
        let copy = try await store.materialize(artifact)
        await host.model.load()
        host.model.activeSessionId = current.id
        host.model.inputText = "Keep this existing draft"; host.model.addAttachments([raw])
        #expect(host.model.session(id: source.id)?.isMessagesLoaded == false)
        #expect(await host.model.prepareArtifactContinuation(artifact, sessionID: source.id, workspaceID: nil, snapshot: copy))
        #expect(host.model.activeSessionId == source.id && host.model.sessionFilter == .archived)
        #expect(host.model.pendingAttachments == [copy] && !host.model.isAnyRunning)
        let prompt = host.model.inputText
        host.model.setSessionFilter(.active); host.model.activeSessionId = current.id
        #expect(host.model.inputText == "Keep this existing draft" && host.model.pendingAttachments == [raw])
        await #expect(throws: TaskArtifactError.previewInUse) { try await store.clearPreviewCache() }
        host.model.setSessionFilter(.archived); host.model.activeSessionId = source.id
        #expect(host.model.inputText == prompt && host.model.pendingAttachments == [copy])
        host.model.removeAttachment(copy)
        var cleaned = false
        for _ in 0..<30 {
            do { try await store.clearPreviewCache(); cleaned = true; break }
            catch TaskArtifactError.previewInUse { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(cleaned)
        #expect(try await service.fetch(id: source.id)?.isArchived == true)
        #expect(try await service.fetch(id: current.id)?.messages.isEmpty == true)
    }

    @Test("An occupied or waiting source keeps its state while continuation prepares a separate draft", arguments: [false, true])
    func occupiedSourceContinuation(_ waiting: Bool) async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue), store = try #require(host.hub.makeArtifactStore(for: .work))
        var source = ChatSession(title: "Occupied source"); source.mode = .coding
        let message = ChatMessage(role: .assistant, content: "Existing answer", runStatus: waiting ? .waitingForConfirmation : .succeeded)
        source.messages = [.init(role: .user, content: "Original request"), message]
        if waiting { source.pendingConfirmation = .init(messageId: message.id, toolName: "files_write", argumentsDisplay: "existing pending write") }
        try await service.save(source)
        let file = host.root.appendingPathComponent("continue.txt"), raw = host.root.appendingPathComponent("other-input.txt")
        try Data("Chosen revision".utf8).write(to: file); try Data("Do not move to another draft".utf8).write(to: raw)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: source.id, runID: UUID(), workspaceID: nil, operationID: "occupied", tool: "files_write"))
        let copy = try await store.materialize(artifact)
        await host.model.load()
        host.model.activeSessionId = source.id
        if !waiting { host.model.inputText = "Existing unsent request"; host.model.addAttachments([raw]) }
        #expect(await host.model.prepareArtifactContinuation(artifact, sessionID: source.id, workspaceID: nil, snapshot: copy))
        let continuationID = try #require(host.model.activeSessionId)
        #expect(continuationID != source.id && host.model.session(id: continuationID)?.mode == .coding)
        #expect(host.model.pendingAttachments == [copy] && !host.model.isAnyRunning)
        host.model.activeSessionId = source.id
        if waiting { #expect(try await service.fetch(id: source.id)?.pendingConfirmation == source.pendingConfirmation) }
        else { #expect(host.model.inputText == "Existing unsent request" && host.model.pendingAttachments == [raw]) }
        host.model.activeSessionId = continuationID
        host.model.deleteSession(id: continuationID)
        for _ in 0..<100 {
            if host.model.session(id: continuationID) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.model.session(id: continuationID) == nil)
        #expect(host.model.pendingAttachments == (waiting ? [] : [raw]))
        #expect(host.model.drafts[continuationID] == nil)
    }

    @Test("Failed conversation deletion keeps the visible conversation and unsent draft for retry")
    func failedDeleteKeepsConversationAndDraft() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue)
        let session = ChatSession(title: "Keep on failure")
        try await service.save(session)
        await host.model.load()
        host.model.activeSessionId = session.id
        host.model.inputText = "Unsent private draft"
        host.model.saveDraftForActive()
        try await host.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_chat_delete BEFORE DELETE ON chat_sessions BEGIN SELECT RAISE(ABORT, 'synthetic deletion failure'); END")
        }

        host.model.deleteSession(id: session.id)
        for _ in 0..<100 {
            if host.model.errorMessage == L.string("chat.session.delete_failed") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.model.errorMessage == L.string("chat.session.delete_failed"))
        #expect(host.model.session(id: session.id) != nil)
        #expect(host.model.activeSessionId == session.id)
        #expect(host.model.drafts[session.id] == "Unsent private draft")
        #expect(try await service.fetch(id: session.id) != nil)

        try await host.queue.write { db in try db.execute(sql: "DROP TRIGGER reject_chat_delete") }
        host.model.errorMessage = nil
        host.model.deleteSession(id: session.id)
        for _ in 0..<100 {
            if host.model.session(id: session.id) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.model.session(id: session.id) == nil)
        #expect(host.model.drafts[session.id] == nil)
        #expect(try await service.fetch(id: session.id) == nil)
    }

    @Test("Space task center shows only a neutral warning for unknown legacy evidence")
    func unknownLegacyEvidenceRequiresGlobalMaintenance() async throws {
        let host = try fixture()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let priorLanguage = LanguageManager.shared.currentLanguage
        LanguageManager.shared.currentLanguage = .english
        defer { LanguageManager.shared.currentLanguage = priorLanguage }
        let store = DaemonHandoffStore(baseDirectory: host.root)
        try Data("SYNTHETIC_UNKNOWN_PRIVATE_BODY".utf8).write(to:
            store.directory.appendingPathComponent("run-\(UUID().uuidString).json"))
        #expect(!store.unattributedLegacyEvidence().isEmpty)

        let panel = TaskCenterPanel(hub: host.hub, model: host.model,
            jobCenter: host.jobs, handoffStore: store,
            daemonSnapshot: { _ in ([], [], [:]) })
        let taskWindow = mount(panel, width: 820, height: 620)
        defer { taskWindow.close() }
        let taskText = try await waitRendered(taskWindow, containing: "App-wide Maintenance")
        #expect(!taskText.contains("SYNTHETIC_UNKNOWN_PRIVATE_BODY"))
        #expect(!taskText.contains(L.string("product.recovery.global.open")))
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(taskWindow, to: URL(fileURLWithPath: directory)
                .appendingPathComponent("task-center-neutral-legacy-evidence.png"))
        }

        let maintenanceWindow = mount(GlobalLegacyRecoverySheet(store: store), width: 690, height: 540)
        defer { maintenanceWindow.close() }
        _ = try await waitRendered(maintenanceWindow, containing: "App-wide scope")
        let maintenanceText = try await waitRendered(maintenanceWindow, containing: "Record to review")
        #expect(!maintenanceText.contains("SYNTHETIC_UNKNOWN_PRIVATE_BODY"))
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(maintenanceWindow, to: URL(fileURLWithPath: directory)
                .appendingPathComponent("global-legacy-maintenance.png"))
        }
    }

    @Test("Missing or foreign snapshot copies cannot switch the active draft or replace its contents")
    func invalidContinuationPreservesDraft() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue), store = try #require(host.hub.makeArtifactStore(for: .work))
        let current = ChatSession(title: "Current draft"); try await service.save(current)
        let file = host.root.appendingPathComponent("version.txt"); try Data("Original bytes".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "guarded", tool: "python_execute"))
        let copy = try await store.materialize(artifact)
        await host.model.load(); host.model.inputText = "Do not replace me"; host.model.addAttachments([file])
        var foreign = artifact; foreign.sourceSpace = .personal
        #expect(await host.model.prepareArtifactContinuation(foreign, sessionID: nil, workspaceID: nil, snapshot: copy) == false)
        try FileManager.default.removeItem(at: copy)
        #expect(await host.model.prepareArtifactContinuation(artifact, sessionID: nil, workspaceID: nil, snapshot: copy) == false)
        #expect(host.model.activeSessionId == current.id && host.model.inputText == "Do not replace me" && host.model.pendingAttachments == [file])
        #expect(!host.model.isAnyRunning && host.model.sessions.count == 1)
    }

    @Test("Native task details continue the selected historical copy after its original file is removed")
    func nativeArtifactContinuation() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue), store = try #require(host.hub.makeArtifactStore(for: .work))
        var session = ChatSession(title: "Native continuation source")
        let file = host.root.appendingPathComponent("selected-history.txt"), run = ProductTaskIdentity()
        try Data("The historical copy used for continuation".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: session.id, runID: run.id, workspaceID: nil, operationID: "native", tool: "python_execute"))
        session.messages = [.init(role: .user, content: "Produce the fixture"), .init(role: .assistant, content: "Saved historical result", trace: [.init(toolName: "python_execute",
            argumentsPreview: "", resultPreview: "", artifacts: [artifact], duration: 1, succeeded: true)], runStatus: .succeeded, taskRun: run)]
        try await service.save(session); try FileManager.default.removeItem(at: file)
        let window = mount(TaskCenterPanel(hub: host.hub, model: host.model, jobCenter: host.jobs, daemonSnapshot: { _ in ([], [], [:]) }))
        defer { window.attachedSheet?.close(); window.close() }
        try await wait(window) { texts(window.contentView).contains("Saved historical result") }
        try await pressButton(L.string("product.tasks.details"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let detail = try #require(window.attachedSheet)
        _ = try await waitRendered(detail, containing: "selected-history.txt")
        try await pressButton(L.string("product.artifact.continue"), in: detail)
        try await wait(window) { host.model.pendingAttachments.count == 1 }
        let copy = try #require(host.model.pendingAttachments.first)
        #expect(host.model.activeSessionId == session.id && copy.path != artifact.path && host.model.inputText.contains(copy.lastPathComponent))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "The historical copy used for continuation")
        #expect(!host.model.isAnyRunning)
    }

    @Test("The native preview presents the retained copy and protects it until its sheet closes")
    func nativeArtifactPreview() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        let file = host.root.appendingPathComponent("preview-proof.txt"), bytes = Data("Preview the actual historical version".utf8)
        try bytes.write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "preview", tool: "python_execute"))
        try FileManager.default.removeItem(at: file)
        let window = mount(TaskArtifactsView(artifacts: [artifact], roots: [], store: store, onContinue: { _ in }).padding())
        defer { window.attachedSheet?.close(); window.close() }
        _ = try await waitRendered(window, containing: artifact.name)
        try await pressButton(L.string("product.artifact.preview"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let preview = try #require(window.attachedSheet)
        func previewURL(_ view: NSView?) -> URL? {
            guard let view else { return nil }
            if let quickLook = view as? QLPreviewView { return quickLook.previewItem?.previewItemURL }
            return view.subviews.lazy.compactMap { previewURL($0) }.first
        }
        try await wait(preview) { previewURL(preview.contentView) != nil }
        let url = try #require(previewURL(preview.contentView))
        #expect(url.path != file.path && url.lastPathComponent.contains("v1"))
        #expect(try Data(contentsOf: url) == bytes)
        await #expect(throws: TaskArtifactError.previewInUse) { try await store.clearPreviewCache() }
        try await pressButton(L.string("common.close"), in: preview)
        try await wait(window) { window.attachedSheet == nil }
        var cleared = false
        for _ in 0..<100 {
            do { try await store.clearPreviewCache(); cleared = true; break }
            catch TaskArtifactError.previewInUse { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(cleared)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Native single and whole-run exports write exact retained bytes and show their result locations",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_NATIVE_PANEL_CONFIRMATION"] == "1"))
    func nativeArtifactExports() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        var artifacts: [TaskArtifact] = []
        let bytes = [Data([0, 255, 1, 128]), Data("A second actual output".utf8)]
        for index in 0..<2 {
            let file = host.root.appendingPathComponent(index == 0 ? "export-proof-one.bin" : "export-proof-two.bin"); try bytes[index].write(to: file)
            artifacts.append(try await store.capture(file, root: host.root, logicalPath: nil,
                origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "export-\(index)", tool: "python_execute")))
            try FileManager.default.removeItem(at: file)
        }
        let savePanel = NSSavePanel(), folderPanel = NSOpenPanel()
        savePanel.directoryURL = host.root
        let single = mount(TaskArtifactsView(artifacts: [artifacts[0]], roots: [], store: store, makeSavePanel: { savePanel }, onContinue: { _ in }).padding())
        defer { single.close() }
        _ = try await waitRendered(single, containing: artifacts[0].name)
        let exported = host.root.appendingPathComponent(artifacts[0].name)
        try await chooseExport(panel: savePanel, title: L.string("product.artifact.export"), destination: exported, folder: false) {
            try await pressButton(L.string("product.artifact.export"), in: single)
        }
        do { try await wait(single) { FileManager.default.fileExists(atPath: exported.path) } }
        catch {
            Issue.record("Export did not complete: visible=\(savePanel.isVisible) url=\(savePanel.url?.path ?? "none") key=\(NSApp.keyWindow?.title ?? "none")")
            savePanel.cancel(nil)
            throw error
        }
        #expect(try Data(contentsOf: exported) == bytes[0])
        _ = try await waitRendered(single, containing: exported.lastPathComponent)
        single.close()
        let all = mount(TaskArtifactsView(artifacts: artifacts, roots: [], store: store, makeFolderPanel: { folderPanel }, onContinue: { _ in }).padding())
        defer { all.close() }
        _ = try await waitRendered(all, containing: artifacts[1].name)
        let destination = host.root.appendingPathComponent("all-exports")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        folderPanel.directoryURL = destination
        try await chooseExport(panel: folderPanel, title: L.string("product.artifact.exportAll"), destination: destination, folder: true) {
            try await pressButton(L.string("product.artifact.exportAll"), in: all)
        }
        try await wait(all) { ((try? FileManager.default.contentsOfDirectory(atPath: destination.path).count) ?? 0) == 1 }
        let output = try #require(FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).first)
        try await wait(all) { ((try? FileManager.default.contentsOfDirectory(atPath: output.path).count) ?? 0) == 2 }
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(try Data(contentsOf: files[0]) == bytes[0] && Data(contentsOf: files[1]) == bytes[1])
        _ = try await waitRendered(all, containing: L.format("product.artifact.export.success", 2))
    }

    @Test("Export buttons publish exact binary versions and result receipts after the destination chooser confirms")
    func artifactExportActions() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work)), bytes = [Data([0, 255, 128, 1]), Data("Exact second result".utf8)]
        var artifacts: [TaskArtifact] = [], intermediate: [TaskArtifact] = []
        for index in 0..<2 {
            let file = host.root.appendingPathComponent(index == 0 ? "binary-one.bin" : "binary-two.bin")
            if index == 0 {
                try Data("Intermediate contents must not be exported as a separate file".utf8).write(to: file)
                intermediate.append(try await store.capture(file, root: host.root, logicalPath: nil,
                    origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: UUID().uuidString, tool: "python_execute")))
            }
            try bytes[index].write(to: file)
            artifacts.append(try await store.capture(file, root: host.root, logicalPath: nil,
                origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: UUID().uuidString, tool: "python_execute")))
            try FileManager.default.removeItem(at: file)
        }
        let singleURL = host.root.appendingPathComponent("exported-copy.bin"), folderURL = host.root.appendingPathComponent("exported-bundle")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let single = mount(TaskArtifactsView(artifacts: [artifacts[0]], roots: [], store: store,
            chooseExportDestination: { panel in
                #expect(panel.nameFieldStringValue == artifacts[0].name)
                return .selected(singleURL)
            }, onContinue: { _ in }).padding())
        defer { single.close() }
        _ = try await waitRendered(single, containing: artifacts[0].name)
        try await pressButton(L.string("product.artifact.export"), in: single)
        try await wait(single) { FileManager.default.fileExists(atPath: singleURL.path) }
        #expect(try Data(contentsOf: singleURL) == bytes[0])
        _ = try await waitRendered(single, containing: singleURL.lastPathComponent)
        let all = mount(TaskArtifactsView(artifacts: intermediate + artifacts, roots: [], store: store,
            chooseExportDestination: { panel in #expect(panel is NSOpenPanel); return .selected(folderURL) }, onContinue: { _ in }).padding())
        defer { all.close() }
        _ = try await waitRendered(all, containing: artifacts[1].name)
        try await pressButton(L.string("product.artifact.exportAll"), in: all)
        try await wait(all) { ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path).count) ?? 0) == 1 }
        let output = try #require(FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil).first)
        try await wait(all) { ((try? FileManager.default.contentsOfDirectory(atPath: output.path).count) ?? 0) == 2 }
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(try Data(contentsOf: files[0]) == bytes[0] && Data(contentsOf: files[1]) == bytes[1])
        // The destination and both files are checked byte-for-byte above. Read
        // the human receipt instead of asking OCR to distinguish random UUID
        // glyphs such as 0/O in the generated directory name.
        _ = try await waitRendered(all, containing: L.format("product.artifact.export.success", 2))
        try await store.clearPreviewCache()
    }

    @Test("The real system export chooser opens and cancels without writing or retaining a preview lease",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_TEST_NATIVE_PANEL_CONFIRMATION"] == "1"))
    func nativeExportCancellation() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work)), file = host.root.appendingPathComponent("cancel-export.txt")
        try Data("Do not publish on cancellation".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "cancel", tool: "files_write"))
        let panel = NSSavePanel(), uses = Mutex(0)
        let window = mount(TaskArtifactsView(artifacts: [artifact], roots: [], store: store, onUse: { _ in uses.withLock { $0 += 1 } },
            makeSavePanel: { panel }, onContinue: { _ in }).padding())
        defer { if panel.isVisible { panel.cancel(nil) }; window.close() }
        _ = try await waitRendered(window, containing: artifact.name)
        try await pressButton(L.string("product.artifact.export"), in: window)
        try await wait(window) { panel.isVisible }
        panel.cancel(nil)
        try await wait(window) { !panel.isVisible }
        var cleared = false
        for _ in 0..<100 {
            do { try await store.clearPreviewCache(); cleared = true; break }
            catch TaskArtifactError.previewInUse { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(cleared && uses.withLock { $0 } == 0)
        #expect(try await store.librarySummary().retainedVersions == 1)
    }

    @Test("Cancelled or failed destination selection preserves versions and releases the export usage", arguments: [false, true])
    func exportChoiceFailure(_ failed: Bool) async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work)), file = host.root.appendingPathComponent("cancelled-choice.txt")
        try Data("Keep this source".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "choice", tool: "files_write"))
        let returned = Mutex(false), uses = Mutex(0)
        let window = mount(TaskArtifactsView(artifacts: [artifact], roots: [], store: store, onUse: { _ in uses.withLock { $0 += 1 } },
            chooseExportDestination: { _ in returned.withLock { $0 = true }; return failed ? .failed : .cancelled }, onContinue: { _ in }).padding())
        defer { window.close() }
        _ = try await waitRendered(window, containing: artifact.name)
        try await pressButton(L.string("product.artifact.export"), in: window)
        try await wait(window) { returned.withLock { $0 } }
        if failed { _ = try await waitRendered(window, containing: L.string("product.artifact.export.failed")) }
        var cleared = false
        for _ in 0..<100 {
            do { try await store.clearPreviewCache(); cleared = true; break }
            catch TaskArtifactError.previewInUse { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(cleared && uses.withLock { $0 } == 0)
        #expect(try await store.librarySummary().retainedVersions == 1 && String(contentsOf: file, encoding: .utf8) == "Keep this source")
    }

    @Test("An unassigned composer draft keeps its text and files when an orphan result is continued")
    func unassignedContinuationDraft() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work)), file = host.root.appendingPathComponent("orphan-result.txt")
        try Data("Orphan historical output".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "orphan", tool: "python_execute"))
        let copy = try await store.materialize(artifact)
        await host.model.load()
        #expect(host.model.activeSessionId == nil)
        host.model.inputText = "Keep the unassigned draft"; host.model.addAttachments([file])
        #expect(await host.model.prepareArtifactContinuation(artifact, sessionID: nil, workspaceID: nil, snapshot: copy))
        let target = try #require(host.model.activeSessionId)
        #expect(host.model.pendingAttachments == [copy] && host.model.sessions.count == 2)
        let old = try #require(host.model.sessions.first { $0.id != target })
        host.model.activeSessionId = old.id
        #expect(host.model.inputText == "Keep the unassigned draft" && host.model.pendingAttachments == [file])
        #expect(!host.model.isAnyRunning)
    }

    @Test("A mounted artifact card refreshes its historical-copy status after confirmed removal")
    func removedArtifactRefresh() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = TaskArtifactStore(databaseQueue: host.queue, space: .work, previewRoot: host.root.appendingPathComponent("previews"))
        let file = host.root.appendingPathComponent("historical.md"); try Data("Saved result".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: nil, runID: UUID(), workspaceID: nil, operationID: "history", tool: "python_execute"))
        let view = TaskArtifactsView(artifacts: [artifact], roots: [], store: store, onContinue: { _ in }).padding()
        let window = mount(view)
        defer { window.close() }
        let removed = L.string("product.artifact.removed")
        let before = try await waitRendered(window, containing: "historical.md")
        #expect(!before.contains(removed))
        try await store.removeRetainedContents([artifact])
        do { _ = try await waitRendered(window, containing: removed) }
        catch {
            if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
                let root = URL(fileURLWithPath: directory)
                try snapshot(window, to: root.appendingPathComponent("artifact-removal-failure.png"))
                try texts(window.contentView).joined(separator: "\n").write(to: root.appendingPathComponent("artifact-removal-failure.txt"), atomically: true, encoding: .utf8)
            }
            throw error
        }
        #expect(artifact.contentRetained == true)
    }

    @Test("First task goes through native setup, real execution and approval, restart, retained preview and useful-result acknowledgement")
    func firstTaskJourney() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let preferences = ProductPreferencesService(databaseQueue: host.queue)
        let config = LLMProviderConfig(name: "First task fixture", endpoint: "https://first-task.invalid/v1", model: "fixture")
        let setup = FirstTaskSetupModel(space: .work, preferences: preferences, fetchProviders: { [config] }, probe: { _ in
            do { return .success(try await FirstTaskFixtureProvider.make().generate(prompt: "ping", config: .init(maxTokens: 8, temperature: 0))) }
            catch { return .failure(error) }
        }, isCurrentSpace: { host.hub.spaceStore.current == .work })
        var requested: FirstTaskRequest?
        let setupWindow = mount(OnboardingView(hub: host.hub, setup: setup, onFinish: { requested = $0 }), width: 720, height: 720)
        defer { setupWindow.close() }
        try await wait(setupWindow) { setup.isLoaded }
        try await pressButton(L.string("product.setup.test"), in: setupWindow)
        try await wait(setupWindow) { setup.connected }
        try await pressButton(L.string("product.setup.begin"), in: setupWindow)
        try await wait(setupWindow) { requested != nil }
        let request = try #require(requested)
        #expect(request.template == "organize" && request.files.isEmpty && request.prompt.contains(L.string("product.setup.sample.organize")))
        setupWindow.close()

        var selectedProvider: UUID?
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        let model = ChatViewModel(hub: host.hub, workspaceRegistry: host.registry, observeHostServices: false, draftDefaults: nil,
            makeEngine: { context in
                let root = URL(fileURLWithPath: context.settings.workspacePath)
                let files = FileAreaService(baseDirectory: host.root.appendingPathComponent("files"), scopedRoots: [root])
                let policy = FileAreaPolicy(service: files, space: context.space, defaultWriteRoots: [root])
                return DispatcherEngine(provider: FirstTaskFixtureProvider.make(destination: root.appendingPathComponent("source-report.md")),
                    tools: [FilesWriteTool(service: files, space: context.space)], systemPrompt: "Produce a Markdown report from the supplied evidence.",
                    fileAreaPolicy: policy, executionContext: .init(space: context.space, sessionID: context.sessionID, runID: context.runID,
                        permissionPolicy: PermissionPolicy(mode: context.settings.permissionMode, fileAreaPolicy: policy)), artifactStore: store)
            }, selectProvider: { selectedProvider = $0 })
        await model.load()
        model.preferredPermissionMode = .workspaceWrite
        model.inputText = "Keep the previous draft"
        #expect(await model.startFirstTask(request))
        let sessionID = try #require(model.activeSessionId)
        #expect(selectedProvider == config.id)
        let progress = try #require(try await preferences.load(FirstResultProgress.self, key: "first-result.progress"))
        #expect(progress.sessionID == sessionID && progress.startedAt == request.startedAt)
        #expect(try await SessionService(databaseQueue: host.queue).fetch(id: sessionID) != nil)
        try await wait(setupWindow) { model.pendingConfirmation != nil && !model.isRunningHere }
        let pending = try #require(model.pendingConfirmation)
        var didApprove = false
        let approvalWindow = mount(ConfirmationCard(pending: pending) { decision in
            didApprove = decision.approved
            model.confirmPending(approved: decision.approved, alwaysAllow: decision.allowRound, persistRule: decision.persistRule)
        }.padding().frame(width: 700, height: 600, alignment: .top))
        defer { approvalWindow.close() }
        let workspace = try #require(model.taskWorkspace(id: model.session(id: sessionID)?.workspaceId))
        #expect(!FileManager.default.fileExists(atPath: workspace.url.appendingPathComponent("source-report.md").path))
        #expect(try await preferences.metrics().firstResultSeconds == nil)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(approvalWindow, to: URL(fileURLWithPath: directory).appendingPathComponent("first-task-approval.png"))
        }
        try await pressButton(L.string("chat.confirm.approve_once"), in: approvalWindow)
        try #require(didApprove)
        try await wait(approvalWindow) { !model.isRunningHere && model.pendingConfirmation == nil }
        let completed = try #require(model.session(id: sessionID))
        try #require(completed.messages.last?.runStatus == .succeeded, "\(completed.messages.last?.content ?? "No answer")")
        let artifact = try #require(completed.messages.last?.trace?.flatMap(\.allArtifacts).first)
        #expect(try String(contentsOfFile: artifact.path, encoding: .utf8) == FirstTaskFixtureProvider.report)
        #expect(try await ProductTaskRunStore(databaseQueue: host.queue).summaries().count == 1)
        let prior = try #require(model.sessions.first { $0.id != sessionID })
        #expect(try await SessionService(databaseQueue: host.queue).fetch(id: prior.id) != nil)
        model.activeSessionId = prior.id
        #expect(model.inputText == "Keep the previous draft")
        try FileManager.default.removeItem(atPath: artifact.path)
        approvalWindow.close()

        let restarted = ChatViewModel(hub: host.hub, workspaceRegistry: host.registry, observeHostServices: false, draftDefaults: nil)
        await restarted.openTaskSource(sessionID: sessionID, messageID: completed.messages.last?.id)
        let saved = try #require(restarted.session(id: sessionID))
        let inspection = try #require(try await FirstResultReview.inspect(progress: progress, session: saved, roots: workspace.folderURLs, store: store))
        #expect(FirstResultReview.matches(inspection, session: saved))
        let copy = try await store.materialize(artifact)
        #expect(try String(contentsOf: copy, encoding: .utf8) == FirstTaskFixtureProvider.report)
        let preview = mount(TaskArtifactsView(artifacts: [artifact], roots: workspace.folderURLs, store: store, onContinue: { _ in }).padding())
        defer { preview.close() }
        _ = try await waitRendered(preview, containing: artifact.name)
        try await pressButton(L.string("product.artifact.preview"), in: preview)
        try await wait(preview) { preview.attachedSheet != nil }
        let previewSheet = try #require(preview.attachedSheet)
        func quickLook(_ view: NSView?) -> QLPreviewView? {
            guard let view else { return nil }
            return (view as? QLPreviewView) ?? view.subviews.lazy.compactMap { quickLook($0) }.first
        }
        try await wait(previewSheet) { quickLook(previewSheet.contentView)?.previewItem?.previewItemURL == copy }
        try await pressButton(L.string("common.close"), in: previewSheet)
        try await wait(preview) { preview.attachedSheet == nil }
        preview.close()

        var verified: FirstResultProgress?, reviewError: String?
        let review = mount(FirstResultReviewCard(progress: progress, session: saved, isRunning: false,
            roots: workspace.folderURLs, store: store, preferences: preferences,
            isCurrent: { FirstResultReview.matches($0, session: restarted.activeSessionId.flatMap { restarted.session(id: $0) }) },
            onResume: {}, onVerified: { verified = $0 }, onError: { reviewError = $0 }).padding(), width: 860, height: 160)
        defer { review.close() }
        _ = try await waitRendered(review, containing: L.string("product.setup.check.title"))
        try await pressButton(L.string("product.setup.check.confirm"), in: review)
        try await wait(review) { verified != nil || reviewError != nil }
        #expect(reviewError == nil && verified?.verifiedAt != nil)
        #expect(try await preferences.metrics().firstResultSeconds != nil)
        #expect(try await preferences.metrics().tasksWithArtifacts == 1)
        let isolated = try DatabaseQueue(); try DatabaseBootstrap.prepareSpace(isolated)
        #expect(try await ProductPreferencesService(databaseQueue: isolated).metrics().firstResultSeconds == nil)
    }

    @Test("Native knowledge import previews actual files before saving and skips a duplicate through its ordinary action")
    func nativeKnowledgeImport() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let knowledge = KnowledgeService(databaseQueue: host.queue), imports = KnowledgeImportService(service: knowledge, space: .work)
        let one = host.root.appendingPathComponent("review-one.txt"), two = host.root.appendingPathComponent("review-two.md")
        try Data("KNOWLEDGE REVIEW 2048: publish read-only first.".utf8).write(to: one)
        try Data("KNOWLEDGE REVIEW 2048: publish read-only first.".utf8).write(to: two)
        let model = KnowledgeImportModel(service: imports, baseID: nil, folderID: nil, jobs: host.jobs)
        var finished = false
        var didChoose = false
        let window = mount(KnowledgeImportSheet(model: model, chooseSources: { didChoose = true; return [one, two] }, onFinished: { finished = true }), width: 960, height: 700)
        defer { window.attachedSheet?.close(); window.close() }
        _ = try await waitRendered(window, containing: L.string("knowledge.import.preview.title"))
        try await pressButton(L.string("knowledge.import.choose"), in: window)
        try await wait(window) { didChoose }
        do { try await wait(window) { !model.working && model.rows.count == 2 && model.rows.allSatisfy { $0.state == .ready } } }
        catch {
            Issue.record("Import model: \(model.errorText ?? "no error"), rows=\(model.rows.map { String(describing: $0.state) })")
            if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] { try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("knowledge-import-failure.png")) }
            throw error
        }
        #expect(try await knowledge.getAll().isEmpty)
        _ = try await waitRendered(window, containing: "KNOWLEDGE REVIEW 2048")
        #expect(model.rows[1].decision == .skip)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("knowledge-import-preview.png"))
        }
        try await pressButton(L.string("knowledge.import.commit"), in: window)
        try await wait(window) { finished && !model.working }
        #expect(try await knowledge.getAll().count == 1)
        #expect(model.rows.map(\.state) == [.saved, .skipped])
        try await pressButton(L.string("common.close"), in: window)
    }

    @Test("Native knowledge source maintenance locates a missing source, previews its replacement, updates and opens retained versions")
    func nativeKnowledgeSourceUpdate() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        let suite = "knowledge-source-host-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: host.root) }
        let knowledge = KnowledgeService(databaseQueue: host.queue), imports = KnowledgeImportService(service: knowledge, space: .work)
        let original = host.root.appendingPathComponent("source-lifecycle.txt")
        try Data("ORIGINAL KNOWLEDGE 2048".utf8).write(to: original)
        let preview = try await imports.prepare(url: original)
        let batch = try await imports.beginBatch(candidates: [preview.candidate], baseID: nil, folderID: nil, options: preview.options)
        _ = try await imports.commit(preview, decision: .save, batchID: batch.id, taskID: preview.id)
        let item = try #require(try await knowledge.getAll().first)
        let replacement = host.root.appendingPathComponent("relocated-source.txt")
        try Data("UPDATED KNOWLEDGE 4096".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: original)
        let browser = KnowledgeBrowserModel(service: knowledge, space: .work, preferences: preferences)
        await browser.reload(); browser.selection = .item(item.id)
        var didChoose = false
        let window = mount(KnowledgeView(model: browser, jobCenter: host.jobs, chooseImportFiles: { didChoose = true; return [replacement] }).frame(width: 1120, height: 740), width: 1120, height: 740)
        defer { window.attachedSheet?.close(); window.close() }
        try await wait(window) { browser.selectedItem?.id == item.id }
        _ = try await waitRendered(window, containing: L.string("knowledge.source.title"))
        try await pressButton(L.string("knowledge.source.title"), in: window)
        _ = try await waitRendered(window, containing: L.string("knowledge.source.check"))
        try await pressButton(L.string("knowledge.source.check"), in: window)
        let missingCaption = Self.normalized(L.string("knowledge.source.state.missing"))
        try await wait(window) {
            visibleLabels(in: window).contains { Self.normalized($0) == missingCaption }
        }
        try await pressButton(L.string("knowledge.source.update"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try await pressButton(L.string("knowledge.import.choose"), in: sheet)
        try await wait(sheet) { didChoose }
        do { _ = try await waitRendered(sheet, containing: "UPDATED KNOWLEDGE 4096") }
        catch {
            let batches = try await imports.batches()
            var state = "Text: \(texts(sheet.contentView))\n"
            for batch in batches { state += "\(batch.id): \(try await imports.tasks(batchID: batch.id).map(\.state))\n" }
            if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
                try state.write(to: URL(fileURLWithPath: directory).appendingPathComponent("knowledge-sheet-diagnostic.txt"), atomically: true, encoding: .utf8)
            }
            throw error
        }
        #expect(try await knowledge.get(id: item.id)?.content == "ORIGINAL KNOWLEDGE 2048")
        try await pressButton(L.string("knowledge.import.commit"), in: sheet)
        try await wait(sheet) { browser.selectedItem?.content == "UPDATED KNOWLEDGE 4096" }
        try await pressButton(L.string("common.close"), in: sheet)
        try await wait(window) { window.attachedSheet == nil }
        let versions = try await imports.revisions(itemID: item.id)
        #expect(versions.count == 2 && versions.contains { $0.item.content == "ORIGINAL KNOWLEDGE 2048" })
        try await pressButton(L.string("knowledge.source.title"), in: window)
        _ = try await waitRendered(window, containing: L.string("knowledge.source.version.latest"))
        try await pressButton(L.string("knowledge.source.version.latest"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let version = try #require(window.attachedSheet)
        _ = try await waitRendered(version, containing: "UPDATED KNOWLEDGE 4096")
        try await pressButton(L.string("common.close"), in: version)
    }

    private func snapshot(_ window: NSWindow, to url: URL) throws {
        let view = try #require(window.contentView)
        try snapshotData(view).write(to: url)
    }

    private func snapshotData(_ view: NSView, nativeScale: Bool = false) throws -> Data {
        let size = view.bounds.size
        let bitmap: NSBitmapImageRep
        if nativeScale {
            bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        } else {
            let scale = max(2, view.window?.backingScaleFactor ?? 1)
            bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let original = try #require(bitmap.cgImage)
        let context = try #require(CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // A sheet's material is painted by its window, outside contentView's
        // cached bitmap. Composite that transparent background before OCR so
        // actual black text does not become black text on a black background.
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.setFillColor(CGColor(gray: dark ? 0.12 : 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        context.fill(rect); context.draw(original, in: rect)
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    @Test("Native unified search previews a saved source, opens its identity and appends only the inspected reference")
    func nativeSpaceSearchReference() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let service = SessionService(databaseQueue: host.queue), session = ChatSession(title: "Search draft")
        try await service.save(session); await host.model.load(); host.model.activeSessionId = session.id
        host.model.inputText = "Existing instructions"
        let attachment = host.root.appendingPathComponent("search-attachment.txt")
        try Data("Keep attachment".utf8).write(to: attachment); host.model.addAttachments([attachment])
        let item = KnowledgeItem(title: "NATIVE SEARCH REFERENCE 3024", content: "INSPECTED SOURCE CONTENT 3024")
        try await KnowledgeService(databaseQueue: host.queue).save(item)
        let model = SpaceSearchModel(service: .init(databaseQueue: host.queue, space: .work,
            catalogDirectory: host.root.appendingPathComponent("work")), isCurrent: { true })
        model.kind = .knowledge; model.query = "NATIVE SEARCH REFERENCE"
        var route: ProductRoute?, quoted = false, action: SpaceSearchAction?
        let window = mount(SpaceSearchView(model: model, onOpen: { route = SpaceSearchRoutes.source($0) }, onQuote: {
            try host.model.appendSearchReference($0, expectedSessionID: session.id); quoted = true
        }, onAction: { action = $0 }), width: 1000, height: 700)
        defer { window.close() }
        _ = try await waitRendered(window, containing: item.content)
        try await pressButton(L.string("search.space.open_source"), in: window)
        #expect(route?.contentID == item.id.uuidString && route?.page == "knowledge" && route?.space == .work)
        try await pressButton(L.string("search.space.quote"), in: window)
        try await wait(window) { quoted }
        #expect(host.model.inputText.contains("> " + item.content) && host.model.inputText.hasPrefix("Existing instructions"))
        #expect(host.model.pendingAttachments == [attachment] && !host.model.isAnyRunning)
        #expect(try await service.fetch(id: session.id)?.messages.isEmpty == true)
        model.query = ">"
        _ = try await waitRendered(window, containing: L.string("chat.new"))
        try await pressButton(L.string("chat.new"), in: window)
        try await wait(window) { action != nil }
        #expect(action == .newChat && host.model.activeSessionId == session.id)
    }

    @Test("A search route opens an archived job older than the task center's first page")
    func nativeSearchOlderJob() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        var oldest = BackgroundJob(name: "Search archive target", kind: "fixture", space: .work,
            submittedAt: Date(timeIntervalSince1970: 1))
        oldest.state = .succeeded; oldest.finishedAt = Date(timeIntervalSince1970: 2)
        oldest.resultText = "NATIVE SEARCH OLDER JOB 9080"
        var jobs = [oldest]
        for index in 1...45 {
            var job = BackgroundJob(name: "Later search job \(index)", kind: "fixture", space: .work,
                submittedAt: Date(timeIntervalSince1970: Double(index + 10)))
            job.state = .succeeded; job.finishedAt = job.submittedAt.addingTimeInterval(1); jobs.append(job)
        }
        try ProductJobRunStore(databaseQueue: host.queue, space: .work).saveCompleted(jobs)
        let search = SpaceSearchService(databaseQueue: host.queue, space: .work)
        let hit = try #require(try await search.search("NATIVE SEARCH OLDER JOB", kind: .job).hits.first)
        let route = SpaceSearchRoutes.source(try await search.preview(hit))
        #expect(route.showTasks && route.runID == oldest.id)
        let window = mount(TaskCenterPanel(hub: host.hub, model: host.model, jobCenter: host.jobs,
            initialJobID: route.runID, daemonSnapshot: { _ in ([], [], [:]) }))
        defer { window.attachedSheet?.close(); window.close() }
        try await wait(window) { window.attachedSheet != nil }
        let detail = try #require(window.attachedSheet)
        _ = try await waitRendered(detail, containing: "NATIVE SEARCH OLDER JOB 9080")
    }

    @Test("An artifact search route selects an older version outside the first page and keeps it on refresh")
    func nativeSearchOlderArtifact() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        let file = host.root.appendingPathComponent("earliest-search-output.txt")
        try Data("EARLY RETAINED RESULT 6048".utf8).write(to: file)
        let runID = UUID(), sessionID = UUID()
        let first = try await store.capture(file, root: host.root, logicalPath: file.lastPathComponent,
            origin: .init(space: .work, sessionID: sessionID, runID: runID, workspaceID: nil, operationID: "first-search", tool: "files_write"))
        let versionID = try #require(first.versionID)
        for index in 1...42 {
            let url = host.root.appendingPathComponent("later-output-\(index).txt")
            try Data("Later saved output".utf8).write(to: url)
            _ = try await store.capture(url, root: host.root, logicalPath: url.lastPathComponent,
                origin: .init(space: .work, sessionID: sessionID, runID: runID, workspaceID: nil, operationID: "later-search-\(index)", tool: "files_write"))
        }
        try FileManager.default.removeItem(at: file)
        #expect(try await store.libraryPage().items.contains { $0.id == versionID } == false)
        let window = mount(ArtifactLibraryView(store: store, roots: { _ in [host.root] }, initialVersionID: versionID), width: 880, height: 650)
        defer { window.attachedSheet?.close(); window.close() }
        _ = try await waitRendered(window, containing: file.lastPathComponent)
        try await pressButton(L.string("common.refresh"), in: window)
        _ = try await waitRendered(window, containing: file.lastPathComponent)
        try await pressButton(L.string("product.artifact.preview"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        _ = try await waitRendered(try #require(window.attachedSheet), containing: "EARLY RETAINED RESULT 6048")
    }

    @Test("A conversation schedule receipt opens the real editor and creates no task until confirmation", arguments: [false, true])
    func nativeScheduledDraftConfirmation(_ confirm: Bool) async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let text = try await ScheduledDraftTool(space: .work).execute(argumentsJSON: #"{"name":"NATIVE SCHEDULE DRAFT 4321","prompt":"Inspect only the synthetic source","rule":"daily","time_zone":"UTC","hour":9,"minute":30,"max_tokens":20000,"max_seconds":30}"#)
        let draft = try ScheduledTaskDraft.read(text, space: .work)
        var message = ChatMessage(role: .assistant, content: "Synthetic schedule draft")
        message.trace = [.init(toolName: "schedule_draft", argumentsPreview: "", resultPreview: text, resultFull: text, duration: 0, succeeded: true)]
        let route = Mutex<ProductRoute?>(nil)
        let observer = NotificationCenter.default.addObserver(forName: ProductRoute.notification, object: nil, queue: .main) { note in
            if let value = note.object as? ProductRoute { route.withLock { $0 = value } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let card = mount(ScheduledDraftCards(message: message, space: .work).padding(), width: 740, height: 260)
        defer { card.close() }
        _ = try await waitRendered(card, containing: "NATIVE SCHEDULE DRAFT 4321")
        try await pressButton(L.string("scheduled.draft.preview"), in: card)
        try await wait(card) { route.withLock { $0 != nil } }
        let routed = try #require(route.withLock { $0 })
        #expect(routed.scheduledDraft?.id == draft.id && routed.space == .work && routed.page == "scheduled")
        #expect(try await host.hub.makeScheduledTaskStore(for: .work)?.all().isEmpty == true)
        let window = mount(ScheduledTasksView(hub: host.hub, source: routed, observeHostServices: false).frame(width: 1120, height: 800), width: 1120, height: 800)
        defer { window.attachedSheet?.close(); window.close() }
        try await wait(window) { window.attachedSheet != nil }
        let editor = try #require(window.attachedSheet)
        _ = try await waitRendered(editor, containing: "UTC")
        _ = try await waitRendered(editor, containing: L.string("scheduled.draft.confirm"))
        try await pressButton(L.string(confirm ? "scheduled.draft.confirm" : "common.cancel"), in: editor)
        try await wait(window) { window.attachedSheet == nil }
        let stored = try await host.hub.makeScheduledTaskStore(for: .work)?.all() ?? []
        #expect(stored.count == (confirm ? 1 : 0))
        if confirm {
            #expect(stored.first?.id == draft.task.id && stored.first?.effectiveOptions.budget.maxTokens == 20_000)
            #expect(stored.first?.schedule.timeZoneIdentifier == "UTC")
        }
        #expect(try await host.hub.makeScheduledRunStore(for: .work)?.runs(taskID: draft.task.id).isEmpty == true)
    }

    @Test("A folder request card keeps its original answer and workspace boundary")
    func folderDraftCardBoundary() async throws {
        let host = try fixture()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let workspace = try #require(host.registry.defaultWorkspace(for: .work))
        let sessionID = UUID(), messageID = UUID(), runID = UUID(), receiptID = UUID()
        let receiptJSON = """
        {"id":"\(receiptID.uuidString)","version":1,"space":"work","workspaceID":"\(workspace.id.uuidString)","sessionID":"\(sessionID.uuidString)","reason":"A second folder may contain the source files."}
        """
        let trace = DispatcherTraceEntry(
            toolName: "workspace_folder_draft", argumentsPreview: "",
            resultPreview: receiptJSON, resultFull: receiptJSON, duration: 0, succeeded: true
        )
        let message = ChatMessage(id: messageID, role: .assistant, content: "Folder request",
            trace: [trace], runStatus: .succeeded, taskRun: ProductTaskIdentity(id: runID))
        var session = ChatSession(id: sessionID, workspaceId: workspace.id.uuidString)
        session.messages = [message]
        host.model.sessions = [session]
        host.model.activeSessionId = sessionID
        let policy = WorkspaceFolderDraftCardPolicy.self
        #expect(policy.receipts(in: message, space: .work, workspaceID: workspace.id, sessionID: sessionID).map(\.id) == [receiptID])
        var copied = message
        copied.taskRun = nil; copied.sourceTaskRunID = runID
        #expect(policy.receipts(in: copied, space: .work, workspaceID: workspace.id, sessionID: sessionID).isEmpty)
        var failed = message
        failed.trace = [.init(toolName: "workspace_folder_draft", argumentsPreview: "",
            resultPreview: receiptJSON, resultFull: receiptJSON, duration: 0, succeeded: false)]
        #expect(policy.receipts(in: failed, space: .work, workspaceID: workspace.id, sessionID: sessionID).isEmpty)

        let initial = policy.currentOrigin(receiptID: receiptID, sessionID: sessionID, messageID: messageID,
            space: .work, hub: host.hub, model: host.model)
        guard case .valid(let opened) = initial else {
            Issue.record("Original terminal answer should offer its own folder request")
            return
        }

        if let directory = ProcessInfo.processInfo.environment["AGROOM_FOLDER_DRAFT_SNAPSHOT_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let previous = LanguageManager.shared.currentLanguage
            defer { LanguageManager.shared.currentLanguage = previous }
            for language in [AppLanguage.simplifiedChinese, .traditionalChinese, .english] {
                LanguageManager.shared.currentLanguage = language
                let window = mount(WorkspaceFolderDraftCards(
                    message: message, session: session, hub: host.hub, model: host.model
                ).padding(), width: 480, height: 360)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView?.layoutSubtreeIfNeeded()
                try snapshot(window, to: output.appendingPathComponent("folder-draft-\(language.rawValue)-dark.png"))
                window.close()
            }
        }

        var picker = WorkspaceFolderDraftPickerState()
        let first = picker.begin()
        let firstTicket = try #require(first)
        let duplicate = picker.begin()
        #expect(duplicate == nil) // Double click cannot open another panel.
        let cancelled = picker.take(firstTicket)
        #expect(cancelled) // Cancel consumes this panel, but not the receipt.
        let second = picker.begin()
        let secondTicket = try #require(second)
        picker.invalidate()
        let stale = picker.take(secondTicket)
        #expect(!stale) // A late callback cannot register.
        let third = picker.begin()
        let thirdTicket = try #require(third)
        let accepted = picker.take(thirdTicket)
        #expect(accepted)
        picker.markApplied()
        let replay = picker.begin()
        #expect(replay == nil)

        host.model.activeSessionId = UUID()
        host.model.activeSessionId = sessionID
        let afterRoundTrip = policy.currentOrigin(receiptID: receiptID, sessionID: sessionID,
            messageID: messageID, space: .work, hub: host.hub, model: host.model)
        #expect(policy.completionDenial(opened, current: afterRoundTrip) == .leftContext)

        let afterReturn: WorkspaceFolderDraftCardPolicy.Origin
        if case .valid(let value) = afterRoundTrip { afterReturn = value }
        else { Issue.record("The original message should remain available after returning"); return }
        host.model.sessions[0].messages[0].activeVariationIndex = 1
        let switchedAnswer = policy.currentOrigin(receiptID: receiptID, sessionID: sessionID,
            messageID: messageID, space: .work, hub: host.hub, model: host.model)
        #expect(policy.completionDenial(afterReturn, current: switchedAnswer) == .changed)

        host.model.sessions[0].messages[0].activeVariationIndex = 0
        host.model.sessions[0].pendingConfirmation = PendingConfirmationSnapshot(
            messageId: messageID, toolName: "files_write", argumentsDisplay: "{}"
        )
        let blocked = policy.currentOrigin(receiptID: receiptID, sessionID: sessionID,
            messageID: messageID, space: .work, hub: host.hub, model: host.model)
        if case .denied(let reason) = blocked { #expect(reason == .blocked) }
        else { Issue.record("A waiting task must block changing folder references") }

        host.model.sessions[0].pendingConfirmation = nil
        host.model.sessions[0].messages.removeAll()
        let deleted = policy.currentOrigin(receiptID: receiptID, sessionID: sessionID,
            messageID: messageID, space: .work, hub: host.hub, model: host.model)
        if case .denied(let reason) = deleted { #expect(reason == .changed) }
        else { Issue.record("A removed source message must invalidate its picker") }
        #expect(host.registry.defaultWorkspace(for: .work)?.referencedFolders.isEmpty == true)
    }

    @Test("Archive rechecks persisted pending work when the confirmation view submits")
    func archiveRejectsRestoredPendingWork() throws {
        let host = try fixture()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let workspace = try #require(host.registry.defaultWorkspace(for: .work))
        var session = ChatSession(id: UUID(), workspaceId: workspace.id.uuidString)
        session.pendingConfirmation = PendingConfirmationSnapshot(
            messageId: UUID(), toolName: "files_write", argumentsDisplay: "{}"
        )
        host.model.sessions = [session]
        host.model.archiveSessionsIfSafe(session: session)
        #expect(host.model.sessions.first?.isArchived == false)
        #expect(host.model.errorMessage == L.string("workspace.archive.blocked"))

        // A workspace confirmation sheet can stay open while a task becomes pending.
        host.model.errorMessage = nil
        host.model.archiveSessions(in: workspace)
        #expect(host.model.sessions.first?.isArchived == false)
        #expect(host.model.errorMessage == L.string("workspace.archive.blocked"))

        host.model.sessions[0].pendingConfirmation = nil
        host.model.sessions[0].pendingQuestion = PendingQuestionSnapshot(
            messageId: UUID(), form: QuestionForm(
                title: "Question", prompt: "Choose", fields: [
                    QuestionField(id: "answer", label: "Answer", type: .text)
                ]
            )
        )
        host.model.errorMessage = nil
        host.model.archiveSessionsIfSafe(session: session)
        #expect(host.model.sessions.first?.isArchived == false)
        #expect(host.model.errorMessage == L.string("workspace.archive.blocked"))
    }

    @Test("Interrupted confirmation remains readable in a narrow dark native host",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] != nil))
    func interruptedConfirmationNarrowDarkSnapshot() async throws {
        let previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {} }
        let output = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let previousLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previousLanguage }

        LanguageManager.shared.currentLanguage = .simplifiedChinese
        let pending = PendingConfirmation(messageId: UUID(), toolName: "files_write",
            argumentsDisplay: "{\"path\":\"synthetic-note.txt\"}")
        let confirmation = mount(InterruptedConfirmationCard(pending: pending,
            hasSavedSteps: true, onViewSteps: {}, onEndWaiting: {}).padding(.vertical, 12),
            width: 480, height: 300)
        confirmation.appearance = NSAppearance(named: .darkAqua)
        defer { confirmation.close() }
        let confirmationText = try await waitRendered(confirmation,
            containing: L.string("chat.interrupted.end_waiting"))
        #expect(confirmationText.contains(L.string("chat.interrupted.title")))
        #expect(confirmationText.contains(L.string("chat.interrupted.view_steps")))
        try snapshot(confirmation, to: output.appendingPathComponent("interrupted-confirmation-zh-Hans-dark-480.png"))
    }

    @Test("Interrupted question remains readable in a narrow dark native host",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] != nil))
    func interruptedQuestionNarrowDarkSnapshot() async throws {
        let previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {} }
        let output = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let previousLanguage = LanguageManager.shared.currentLanguage
        defer { LanguageManager.shared.currentLanguage = previousLanguage }
        LanguageManager.shared.currentLanguage = .english
        let form = QuestionForm(title: "Synthetic review", prompt: "Choose after checking saved steps",
            fields: [QuestionField(id: "choice", label: "Synthetic choice", type: .text)])
        let question = mount(InterruptedQuestionCard(form: form, hasSavedSteps: true,
            onViewSteps: {}, onEndWaiting: {}).padding(.vertical, 12),
            width: 480, height: 320)
        question.appearance = NSAppearance(named: .darkAqua)
        defer { question.close() }
        let questionText = try await waitRendered(question,
            containing: L.string("chat.interrupted.end_waiting"))
        #expect(questionText.contains(L.string("chat.interrupted.title")))
        #expect(questionText.contains(L.string("chat.interrupted.view_steps")))
        try snapshot(question, to: output.appendingPathComponent("interrupted-question-en-dark-480.png"))
    }

    @Test("The native folder card registers only a fresh, explicitly selected directory")
    func nativeFolderDraftSelection() async throws {
        let host = try fixture()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        let bookmarks = WorkspaceAccessCoordinator.Bookmarks(
            create: { Data($0.path.utf8) },
            resolve: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) }
        )
        let registry = WorkspaceRegistry(
            fileURL: host.root.appendingPathComponent("folder-card-workspaces.json"),
            fileAreaService: FileAreaService(baseDirectory: host.root.appendingPathComponent("folder-card-files")),
            accessCoordinator: WorkspaceAccessCoordinator(root: host.root, bookmarks: bookmarks)
        )
        let model = ChatViewModel(hub: host.hub, workspaceRegistry: registry,
            observeHostServices: false, draftDefaults: nil)
        model.workspaces = registry.workspaces(for: .work)
        guard let workspace = registry.defaultWorkspace(for: .work) else {
            Issue.record("The synthetic registry did not initialize its work default workspace")
            return
        }
        let sessionID = UUID(), messageID = UUID(), runID = UUID(), receiptID = UUID()
        let receiptJSON = """
        {"id":"\(receiptID.uuidString)","version":1,"space":"work","workspaceID":"\(workspace.id.uuidString)","sessionID":"\(sessionID.uuidString)","reason":"Inspect the selected folder next time."}
        """
        let receipt = try WorkspaceFolderDraftReceipt.read(
            receiptJSON, space: .work, workspaceID: workspace.id, sessionID: sessionID
        )
        let message = ChatMessage(id: messageID, role: .assistant, content: "Folder request",
            trace: [.init(toolName: "workspace_folder_draft", argumentsPreview: "",
                resultPreview: receiptJSON, resultFull: receiptJSON, duration: 0, succeeded: true)],
            runStatus: .succeeded, taskRun: ProductTaskIdentity(id: runID))
        var session = ChatSession(id: sessionID, workspaceId: workspace.id.uuidString)
        session.messages = [message]
        model.sessions = [session]
        model.activeSessionId = sessionID

        let chosen = host.root.appendingPathComponent("folder-card-selected", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let probe = FolderPickerProbe()
        let card = mount(WorkspaceFolderDraftCard(
            receipt: receipt, sessionID: sessionID, messageID: messageID,
            answerVersion: 0, runID: runID, hub: host.hub, model: model,
            chooseFolder: { _ in await probe.choose() }
        ).padding(), width: 620, height: 340)
        defer { probe.complete(nil); card.close() }

        try await pressButton(L.string("workspace.folderDraft.choose"), in: card)
        try await wait(card) { probe.presentations == 1 }
        try await pressButton(L.string("workspace.folderDraft.choose"), in: card)
        #expect(probe.presentations == 1) // A pending panel is single-flight.
        probe.complete(nil)
        await Task.yield() // Let the injected chooser's cancellation reach the card.
        #expect(registry.workspaces(for: .work).first(where: { $0.id == workspace.id })?.referencedFolders.isEmpty == true)

        try await pressButton(L.string("workspace.folderDraft.choose"), in: card)
        try await wait(card) { probe.presentations == 2 }
        model.activeSessionId = UUID()
        model.activeSessionId = sessionID
        probe.complete(chosen)
        try await Task.sleep(for: .milliseconds(70))
        #expect(registry.workspaces(for: .work).first(where: { $0.id == workspace.id })?.referencedFolders.isEmpty == true)

        try await pressButton(L.string("workspace.folderDraft.choose"), in: card)
        try await wait(card) { probe.presentations == 3 }
        probe.complete(chosen)
        try await wait(card) {
            registry.workspaces(for: .work).first(where: { $0.id == workspace.id })?.referencedFolders.count == 1
        }
        #expect(registry.workspaces(for: .personal).allSatisfy { $0.referencedFolders.isEmpty })
        try await pressButton(L.string("workspace.folderDraft.choose"), in: card)
        #expect(probe.presentations == 3) // A completed receipt is disabled in this card.
    }

    @Test("Scheduled follow-up and report buttons create drafts, and a generated report still needs the ordinary file approval")
    func nativeScheduledFollowUpAndReport() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let runs = ScheduledRunStore(databaseQueue: host.queue)
        let record = ScheduledRun(taskID: UUID(), taskName: "Scheduled report source", trigger: .manual, scheduledFor: nil,
            status: .succeeded, startedAt: Date(), finishedAt: Date(), outputText: "NATIVE SCHEDULE RESULT 8056")
        try await runs.insert(record); let stored = try #require(try await runs.run(id: record.id))
        var prompt: String?
        let actions = mount(ScheduledResultActionsView(hub: host.hub, space: .work, run: stored) { prompt = $0 }.padding(), width: 760, height: 260)
        defer { actions.close() }
        try await pressButton(L.string("scheduled.result.follow"), in: actions)
        try await wait(actions) { prompt != nil }
        #expect(try #require(prompt).contains("> NATIVE SCHEDULE RESULT 8056"))
        prompt = nil
        try await pressButton(L.string("scheduled.result.report"), in: actions)
        try await wait(actions) { prompt != nil }
        let reportPrompt = try #require(prompt)
        #expect(reportPrompt.contains(L.string("scheduled.result.report.prompt")))
        let store = try #require(host.hub.makeArtifactStore(for: .work))
        let model = ChatViewModel(hub: host.hub, workspaceRegistry: host.registry, observeHostServices: false, draftDefaults: nil,
            makeEngine: { request in
                let root = URL(fileURLWithPath: request.settings.workspacePath)
                let files = FileAreaService(baseDirectory: host.root.appendingPathComponent("files"), scopedRoots: [root])
                let policy = FileAreaPolicy(service: files, space: .work, defaultWriteRoots: [root])
                return DispatcherEngine(provider: FirstTaskFixtureProvider.make(destination: root.appendingPathComponent("scheduled-report.md")),
                    tools: [FilesWriteTool(service: files, space: .work)], systemPrompt: "Write the report using the provided scheduled result.",
                    fileAreaPolicy: policy, executionContext: .init(space: .work, sessionID: request.sessionID, runID: request.runID,
                        permissionPolicy: PermissionPolicy(mode: request.settings.permissionMode, fileAreaPolicy: policy)), artifactStore: store)
            })
        await model.load(); model.preferredPermissionMode = .workspaceWrite
        model.inputText = "Preserve this pre-existing draft"
        #expect(await model.prepareProductDraft(reportPrompt))
        #expect(!model.isAnyRunning && model.inputText == reportPrompt)
        model.send()
        try await wait(actions) { model.pendingConfirmation != nil }
        let pending = try #require(model.pendingConfirmation), sessionID = try #require(model.activeSessionId)
        let workspace = try #require(model.taskWorkspace(id: model.session(id: sessionID)?.workspaceId))
        let output = workspace.url.appendingPathComponent("scheduled-report.md")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let approval = mount(ConfirmationCard(pending: pending) { decision in
            model.confirmPending(approved: decision.approved, alwaysAllow: decision.allowRound, persistRule: decision.persistRule)
        }.padding().frame(width: 700, height: 600, alignment: .top))
        defer { approval.close() }
        try await pressButton(L.string("chat.confirm.approve_once"), in: approval)
        try await wait(approval) { !model.isRunningHere && model.pendingConfirmation == nil }
        #expect(try String(contentsOf: output, encoding: .utf8) == FirstTaskFixtureProvider.report)
        let artifact = try #require(model.session(id: sessionID)?.messages.last?.trace?.flatMap(\.allArtifacts).first)
        #expect(artifact.versionID != nil && artifact.contentRetained == true)
        #expect(model.drafts.values.contains("Preserve this pre-existing draft"))
    }

    @Test("Saving a scheduled result opens an editable knowledge preview and writes only after Save")
    func nativeScheduledSaveKnowledge() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let runs = ScheduledRunStore(databaseQueue: host.queue), knowledge = KnowledgeService(databaseQueue: host.queue)
        let run = ScheduledRun(taskID: UUID(), taskName: "NATIVE SCHEDULE KNOWLEDGE 7024", trigger: .manual, scheduledFor: nil,
            status: .succeeded, finishedAt: Date(), outputText: "EXACT SCHEDULED CONTENT 7024")
        try await runs.insert(run); let stored = try #require(try await runs.run(id: run.id))
        let window = mount(ScheduledResultActionsView(hub: host.hub, space: .work, run: stored) { _ in }.padding(), width: 760, height: 260)
        defer { window.attachedSheet?.close(); window.close() }
        try await pressButton(L.string("scheduled.result.knowledge"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let editor = try #require(window.attachedSheet)
        _ = try await waitRendered(editor, containing: "EXACT SCHEDULED CONTENT 7024")
        #expect(try await knowledge.getAll().isEmpty)
        try await pressButton(L.string("common.save"), in: editor)
        try await wait(window) { window.attachedSheet == nil }
        let saved = try #require(try await knowledge.getAll().first)
        #expect(saved.title == run.taskName && saved.content.contains("EXACT SCHEDULED CONTENT 7024"))
        _ = try await waitRendered(window, containing: L.string("scheduled.result.knowledge.saved"))
    }

    @Test("Scheduled usage renders an actual zero estimate only with complete usage and a matching configured rate", arguments: [false,true])
    func nativeScheduledUsage(_ known: Bool) async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        let providerID = UUID(), preferences = ProductPreferencesService(databaseQueue: host.queue)
        try await preferences.save([ProductModelPrice(providerID: providerID, model: "fixture", currency: "USD", inputPerMillion: 12, outputPerMillion: 24)], key: "model-prices")
        var details = ScheduledRunExperience(budget: .init()); details.usageKnown = known; details.providerID = providerID; details.model = "fixture"
        details.budgetSpentTokens = known ? 0 : 500
        let run = ScheduledRun(taskID: UUID(), taskName: "Usage fixture", trigger: .manual, scheduledFor: nil, status: .succeeded, experience: details)
        let window = mount(ScheduledRunInfoView(hub: host.hub, space: .work, run: run).padding(), width: 760, height: 380)
        defer { window.close() }
        let expected = known ? "USD 0.0000" : L.string("scheduled.price.unknown")
        let rendered = try await waitRendered(window, containing: expected)
        #expect(known || rendered.contains(L.string("usage.unreported")))
    }

    @Test("Each first-result scenario reads its real selected sources before approval, retained preview and useful-result confirmation",
          arguments: ["organize", "compare", "mail"])
    func nativeFirstResultSources(_ scenario: String) async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        let preferences = ProductPreferencesService(databaseQueue: host.queue), mail = MailService(databaseQueue: host.queue)
        let accountService = MailAccountService(databaseQueue: host.queue, space: .work)
        let account = MailAccount(displayName: "Disposable source", emailAddress: "source@example.invalid", imapHost: "imap.example.invalid",
            smtpHost: "smtp.example.invalid", username: "source@example.invalid")
        try await accountService.save(account, password: nil)
        let folder = MailFolder(accountId: account.id, path: "INBOX", name: "INBOX", role: .inbox)
        try await mail.upsertFolders([folder])
        let mailMessage = MailMessage(accountId: account.id, folderId: folder.id, uid: 7, subject: "Synthetic decision request", bodyState: .ready)
        try await mail.upsertMessages([mailMessage])
        try await mail.saveBody(MailBody(messageId: mailMessage.id, textBody: "SYNTHETIC EVIDENCE MAIL: Please confirm the launch decision."))
        var sources: [URL] = []
        for (name, text) in [("source-A.txt", "SYNTHETIC EVIDENCE A: Launch Wednesday."), ("source-B.txt", "SYNTHETIC EVIDENCE B: Launch Friday.")] {
            let url = host.root.appendingPathComponent(name); try Data(text.utf8).write(to: url); sources.append(url)
        }
        if scenario == "organize" { sources.removeLast() }
        if scenario == "mail" { sources = [] }
        try await preferences.save(FirstResultSetupDraft(template: scenario, useSample: false), key: "first-result.setup")
        let config = LLMProviderConfig(name: "Disposable protocol fixture", endpoint: "https://first-scenario.invalid/v1", model: "fixture")
        let setup = FirstTaskSetupModel(space: .work, preferences: preferences, fetchProviders: { [config] }, probe: { _ in
            do { return .success(try await FirstResultScenarioProvider.make(scenario: scenario).generate(prompt: "ping", config: .init(maxTokens: 8, temperature: 0))) }
            catch { return .failure(error) }
        }, fetchMailSources: { try await mail.localSourceSummary() }, isCurrentSpace: { true })
        var requested: FirstTaskRequest?
        let setupWindow = mount(OnboardingView(hub: host.hub, setup: setup, onFinish: { requested = $0 }), width: 720, height: 720)
        defer { setupWindow.close() }
        try await wait(setupWindow) { setup.isLoaded && !setup.loadingMail }
        if scenario != "mail" { setup.selectFiles(sources) }
        try await pressButton(L.string("product.setup.test"), in: setupWindow)
        try await wait(setupWindow) { setup.connected && setup.sourcesReady }
        try await pressButton(L.string("product.setup.begin"), in: setupWindow)
        try await wait(setupWindow) { requested != nil }
        let request = try #require(requested)
        #expect(request.files == sources && request.template == scenario)
        setupWindow.close()
        let artifactStore = try #require(host.hub.makeArtifactStore(for: .work))
        let fileName = scenario == "mail" ? "mail-digest.md" : scenario == "compare" ? "comparison-report.md" : "source-report.md"
        let model = ChatViewModel(hub: host.hub, workspaceRegistry: host.registry, observeHostServices: false, draftDefaults: nil,
            makeEngine: { context in
                let root = URL(fileURLWithPath: context.settings.workspacePath)
                let files = FileAreaService(baseDirectory: host.root.appendingPathComponent("files"), scopedRoots: [root])
                let policy = FileAreaPolicy(service: files, space: .work, defaultWriteRoots: [root])
                let sync = MailSyncService(accountService: accountService, mail: mail, space: .work,
                    attachmentDirectory: host.root.appendingPathComponent("mail-attachments"), passwordProvider: { _ in nil })
                let readMail = MailToolFactory.build(accountService: accountService, mailService: mail, syncService: sync)
                    .filter { ["mail_list", "mail_read"].contains($0.definition.name) }
                let tools: [any DispatcherTool] = scenario == "mail" ? readMail : [FilesReadTool(service: files)]
                return DispatcherEngine(provider: FirstResultScenarioProvider.make(scenario: scenario, destination: policy.defaultWriteRoots[0].appendingPathComponent(fileName), mailID: mailMessage.id),
                    tools: tools + [FilesWriteTool(service: files, space: .work)], systemPrompt: "Read the supplied sources before writing the requested report.",
                    fileAreaPolicy: policy, executionContext: .init(space: .work, sessionID: context.sessionID, runID: context.runID,
                        permissionPolicy: PermissionPolicy(mode: context.settings.permissionMode, fileAreaPolicy: policy)), artifactStore: artifactStore)
            }, importAttachment: { url,_ in try AttachmentService.importFile(at: url, destinationDirectory: host.root.appendingPathComponent("attachments")) },
            selectProvider: { _ in })
        await model.load(); model.preferredPermissionMode = .workspaceWrite; model.inputText = "KEEP SCENARIO DRAFT"
        #expect(await model.startFirstTask(request))
        let sessionID = try #require(model.activeSessionId)
        let chat = mount(ChatView(hub: host.hub, viewModel: model), width: 1220, height: 800)
        defer { chat.close() }
        try await wait(chat) { model.pendingConfirmation != nil || (!model.isRunningHere && model.session(id: sessionID)?.messages.last?.runStatus == .failed) }
        let pending = try #require(model.pendingConfirmation, "\(model.session(id: sessionID)?.messages.last?.content ?? "No result")")
        let workspace = try #require(model.taskWorkspace(id: model.session(id: sessionID)?.workspaceId))
        let output = workspace.url.appendingPathComponent(fileName)
        #expect(pending.toolName == "files_write" && !FileManager.default.fileExists(atPath: output.path))
        let approval = mount(ConfirmationCard(pending: pending) { decision in
            model.confirmPending(approved: decision.approved, alwaysAllow: decision.allowRound, persistRule: decision.persistRule)
        }.padding().frame(width: 700, height: 600, alignment: .top))
        defer { approval.close() }
        try await pressButton(L.string("chat.confirm.approve_once"), in: approval)
        try await wait(chat) { !model.isRunningHere && model.pendingConfirmation == nil }
        let completed = try #require(model.session(id: sessionID)), answer = try #require(completed.messages.last)
        #expect(answer.runStatus == .succeeded)
        let report = try String(contentsOf: output, encoding: .utf8)
        #expect(report.contains("SYNTHETIC EVIDENCE " + (scenario == "mail" ? "MAIL" : "A")))
        if scenario == "compare" { #expect(report.contains("SYNTHETIC EVIDENCE B") && report.contains("Wednesday and Friday")) }
        if scenario == "mail" {
            #expect(report.contains("Local cached INBOX only") && report.contains(mailMessage.id.uuidString))
            #expect(try await mail.message(id: mailMessage.id)?.isRead == false)
        }
        let reads = answer.trace?.filter { $0.succeeded && $0.toolName == (scenario == "mail" ? "mail_read" : "files_read") } ?? []
        #expect(reads.count == (scenario == "compare" ? 2 : 1))
        let artifact = try #require(answer.trace?.flatMap(\.allArtifacts).first)
        try FileManager.default.removeItem(at: output)
        let progress = try #require(try await preferences.firstResultProgress())
        #expect(try await FirstResultReview.inspect(progress: progress, session: completed, roots: workspace.folderURLs, store: artifactStore) != nil)
        let retained = try await artifactStore.materialize(artifact)
        #expect(try String(contentsOf: retained, encoding: .utf8) == report)
        // Keep the actual chat mounted while the engine transitions from its
        // final message to idle; a separately mounted idle card misses that race.
        try await pressButton(L.string("product.setup.check.confirm"), in: chat)
        for _ in 0..<200 {
            if try await preferences.firstResultProgress()?.verifiedAt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await preferences.firstResultProgress()?.verifiedAt != nil)
        #expect(try await preferences.metrics().firstResultSeconds != nil)
        let previous = try #require(model.sessions.first { $0.id != sessionID })
        model.activeSessionId = previous.id
        #expect(model.inputText == "KEEP SCENARIO DRAFT")
    }

    @Test("A final saved answer is checked again when its still-running engine becomes idle")
    func nativeFirstResultIdleRecheck() async throws {
        let host = try fixture(); defer { try? FileManager.default.removeItem(at: host.root) }
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        let store = try #require(host.hub.makeArtifactStore(for: .work)), preferences = ProductPreferencesService(databaseQueue: host.queue)
        var session = ChatSession(), answer = ChatMessage(role: .assistant, content: "Retained first result", runStatus: .succeeded, taskRun: .init())
        let file = host.root.appendingPathComponent("first-result.md"); try Data("RETAINED FIRST RESULT 2468".utf8).write(to: file)
        let artifact = try await store.capture(file, root: host.root, logicalPath: nil,
            origin: .init(space: .work, sessionID: session.id, runID: answer.taskRun!.id, workspaceID: nil, operationID: "first-result", tool: "files_write"))
        answer.trace = [.init(toolName: "files_write", argumentsPreview: "", resultPreview: "", artifacts: [artifact], duration: 0, succeeded: true)]
        session.messages = [answer]; try await SessionService(databaseQueue: host.queue).save(session)
        let progress = FirstResultProgress(template: "organize", sessionID: session.id)
        try await preferences.beginFirstResult(progress)
        let state = FirstResultExecutionState()
        let window = mount(FirstResultLifecycleHost(state: state, progress: progress, session: session, store: store, preferences: preferences), width: 860, height: 180)
        defer { window.close() }
        try await wait(window) { state.inspections > 0 }
        #expect(!state.verified)
        let checkedWhileRunning = state.inspections
        state.running = false
        try await wait(window) { state.inspections > checkedWhileRunning }
        try await pressButton(L.string("product.setup.check.confirm"), in: window)
        try await wait(window) { state.verified }
        #expect(try await preferences.firstResultProgress()?.verifiedAt != nil)
    }

    @Test("Native metrics refresh from committed events and clearing leaves business data readable")
    func nativeProductMetrics() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let service = ProductPreferencesService(databaseQueue: host.queue)
        let session = ChatSession(title: "Retain business contents")
        try await SessionService(databaseQueue: host.queue).save(session)
        try await service.record(.manualIntervention)
        let window = mount(Form { ProductMetricsSection(service: service) }.formStyle(.grouped), width: 780, height: 700)
        defer { window.close() }
        _ = try await waitRendered(window, containing: L.string("product.metrics.interventions"))
        try await service.record(.manualIntervention)
        _ = try await waitRendered(window, containing: "2")
        #expect(try await service.metrics().manualInterventions == 2)
        // System alert actions are verified in the independently signed app host;
        // the headless test process does not own an application Scene presenter.
        try await service.clearMetrics()
        _ = try await waitRendered(window, containing: L.string("product.metrics.since"))
        #expect(try await service.metrics().manualInterventions == 0)
        #expect(try await SessionService(databaseQueue: host.queue).fetch(id: session.id)?.title == session.title)
    }

    @Test("Task mini app preview buttons calculate the documented sample without installation", arguments: [true, false])
    func nativeTaskTemplatePreview(_ quote: Bool) async throws {
        let definition = try quote ? NativeAppTemplates.quoteEstimate() : NativeAppTemplates.workHours()
        let model = NativeAppRuntime(definition: definition, space: .work, preview: true)
        let window = mount(NativeAppRenderer(model: model).padding(20).task { await model.activate() }, width: 680, height: 540)
        defer { model.suspend(); window.close() }
        let language = LanguageManager.shared.activeLanguageCode
        try await pressButton(definition.text("sample", language: language), in: window)
        try await pressButton(definition.text("calculate", language: language), in: window)
        #expect(model.values["result"] == .string(quote ? "396" : "13.5"))
        _ = try await waitRendered(window, containing: quote ? "396" : "13.5")
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("task-template-\(quote).png"))
        }
    }

    @Test("Skill task templates install only after the button and cancelling run confirmation executes nothing")
    func nativeSkillTaskTemplate() async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let store = SkillStore(directoryURL: host.root.appendingPathComponent("work/skills"))
        let model = SkillTaskTemplateModel(template: .csvQuality, store: store, space: .work, isCurrent: { true })
        let window = mount(SkillTaskTemplateView(model: model), width: 780, height: 730)
        defer { window.attachedSheet?.close(); window.close() }
        _ = try await waitRendered(window, containing: L.string("scenario.input"))
        #expect(await store.listSnapshot().isEmpty)
        #expect(model.canInstall)
        try await pressButton(L.string("scenario.skill.install"), in: window)
        do { try await wait(window) { (model.installedName != nil || model.error != nil) && !model.busy } }
        catch {
            if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
                try snapshot(window, to: URL(fileURLWithPath: directory).appendingPathComponent("skill-template-install-failure.png"))
            }
            Issue.record("Template state: install=\(model.canInstall), busy=\(model.busy), error=\(model.error ?? "none")")
            throw error
        }
        let name = try #require(model.installedName, "\(model.error ?? "No install result")")
        #expect(await store.listSnapshot().count == 1 && model.result == nil)
        try await pressButton(L.string("scenario.sample.run"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let confirmation = try #require(window.attachedSheet)
        _ = try await waitRendered(confirmation, containing: L.string("skills.validation.run.confirm.title"))
        try await pressButton(L.string("common.cancel"), in: confirmation)
        try await wait(window) { window.attachedSheet == nil }
        #expect(model.result == nil)
        #expect(!FileManager.default.fileExists(atPath: try store.folderURL(for: name).appendingPathComponent("scratch/report.json").path))
    }

    @Test("The actual composer opens project settings, saves or cancels the selected scope and preserves the unsent draft", arguments: [false, true])
    func nativeWorkspaceProject(_ confirm: Bool) async throws {
        let host = try fixture(), previousDelegate = NSApplication.shared.delegate, delegate = HostDelegate()
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate; withExtendedLifetime(delegate) {}; try? FileManager.default.removeItem(at: host.root) }
        let hub = Hub(spaceStore: SpaceStore(space: .work, databaseQueue: host.queue), skillDirectoryRoot: host.root.appendingPathComponent("isolated-skills"))
        let knowledge = try #require(hub.makeKnowledgeService(for: .work))
        let base = KnowledgeBase(name: "PROJECT EVIDENCE 7412")
        try await knowledge.saveBase(base)
        let model = ChatViewModel(hub: hub, workspaceRegistry: host.registry, observeHostServices: false, draftDefaults: nil)
        await model.load()
        let workspace = try #require(host.registry.defaultWorkspace(for: .work)), folders = workspace.folderURLs
        let attachment = host.root.appendingPathComponent("ORIGINAL-ATTACHMENT.txt")
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        try Data("Keep original input".utf8).write(to: attachment)
        model.inputText = "ORIGINAL UNSENT DRAFT 7412"; model.pendingAttachments = [attachment]
        let window = mount(ChatView(hub: hub, viewModel: model).frame(width: 1360, height: 930), width: 1360, height: 930)
        defer { window.attachedSheet?.close(); window.close() }
        try await pressButton(L.string("chat.composer.advanced"), in: window, identifier: "chat.composer.advanced")
        try await pressButton(L.string("project.memory.exclude"), in: window)
        try await wait(window) { model.excludesMemoryForNextTurn }
        try await pressButton(L.string("project.title"), in: window)
        try await wait(window) { window.attachedSheet != nil }
        let editor = try #require(window.attachedSheet)
        _ = try await waitRendered(editor, containing: L.string("project.knowledge.all"))
        func textEditor(_ view: NSView?) -> NSTextView? {
            guard let view else { return nil }
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textEditor($0) }.first
        }
        let field = try #require(textEditor(editor.contentView))
        field.string = "NATIVE PROJECT RULES 7412"; field.didChangeText()
        try await pressButton(L.string("project.knowledge.all"), in: editor)
        try await pressButton(base.name, in: editor)
        if let directory = ProcessInfo.processInfo.environment["AGROOM_PRODUCT_SNAPSHOT_DIR"] {
            try snapshot(editor, to: URL(fileURLWithPath: directory).appendingPathComponent("workspace-project-\(confirm).png"))
        }
        try await pressButton(L.string(confirm ? "common.save" : "common.cancel"), in: editor)
        try await wait(window) { window.attachedSheet == nil }
        let stored = try await hub.makeWorkspaceProjectStore(for: .work)?.project(workspaceID: workspace.id)
        if confirm {
            #expect(stored?.configuration.instructions == "NATIVE PROJECT RULES 7412")
            #expect(stored?.configuration.knowledgeBaseIDs == [base.id])
        } else { #expect(stored == nil) }
        #expect(model.excludesMemoryForNextTurn && model.inputText == "ORIGINAL UNSENT DRAFT 7412" && model.pendingAttachments == [attachment])
        #expect(host.registry.defaultWorkspace(for: .work)?.folderURLs == folders)
        #expect(try String(contentsOf: attachment, encoding: .utf8) == "Keep original input")
    }
}
