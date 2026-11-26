import AppKit
import Foundation
import GRDB
import SwiftUI
import Testing
@testable import AgRoomCore
@testable import AgRoomUI

@Suite("Knowledge browser visual checks")
struct KnowledgeBrowserSnapshotTests {
    private func jobs() -> JobCenter {
        JobCenter(historyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-render-jobs-" + UUID().uuidString).appendingPathComponent("history.json"))
    }
    @MainActor @Test("Opening a knowledge reader from saved navigation completes its initial load")
    func coldPageMount() async throws {
        _ = NSApplication.shared
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = KnowledgeService(databaseQueue: queue)
        let article = KnowledgeItem(title: "Opening knowledge", content: "The reader is ready.")
        try await service.save(article)
        let suite = "knowledge-mount-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let previous = KnowledgeBrowserModel(service: service, space: .work, preferences: preferences)
        await previous.reload()
        previous.selection = .item(article.id)
        let model = KnowledgeBrowserModel(service: service, space: .work, preferences: preferences)
        let hosting = NSHostingView(rootView: KnowledgeView(model: model, jobCenter: jobs()).frame(width: 740, height: 640))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        for _ in 0..<100 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if !model.isLoading, model.selectedItem?.id == article.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading && !model.loadFailed)
        #expect(model.selectedItem?.content == article.content)
    }

    @Test("Native tree and reader layouts at narrow and wide sizes",
          .enabled(if: ProcessInfo.processInfo.environment["AGROOM_KNOWLEDGE_SNAPSHOT_DIR"] != nil))
    @MainActor func nativeLayouts() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGROOM_KNOWLEDGE_SNAPSHOT_DIR"])
        _ = NSApplication.shared
        let queue = try DatabaseQueue()
        try DatabaseBootstrap.prepareSpace(queue)
        let service = KnowledgeService(databaseQueue: queue)
        let base = KnowledgeBase(name: "产品知识库 · Product")
        let parent = KnowledgeFolder(baseId: base.id, name: "阿吉屋")
        let child = KnowledgeFolder(baseId: base.id, parentId: parent.id, name: "需求设计与长期使用经验")
        try await service.saveBase(base); try await service.saveFolder(parent); try await service.saveFolder(child)
        let article = KnowledgeItem(title: "知识库树状层级与范围检索设计", content: """
            ## 知识如何组织

            当前空间内，知识库包含多级目录；文档和 Wiki 作为条目保存在目录中。

            - 左侧查看完整目录树。
            - 点击目录浏览其下的知识，点击条目阅读正文。
            - 通过路径导航返回任意上级目录。

            ### 检索范围

            搜索默认包含子目录，也可以仅查看本层。移动条目后，引用仍使用稳定身份定位。

            正文末尾：阅读字号遵循应用的全局阅读设置。
            """, kind: .wiki, tags: ["产品", "知识管理"], baseId: base.id, folderId: child.id)
        try await service.save(article)
        try await service.save(KnowledgeItem(title: "用户访谈记录 · Interview notes", content: "收集真实使用场景和整理需求。", baseId: base.id, folderId: parent.id))
        try await service.save(KnowledgeItem(title: "很长的文档标题用于检查侧栏缩进和标题截断是否清晰", content: "长标题应当保留可阅读空间并支持悬停查看。", baseId: base.id, folderId: child.id))
        let suite = "knowledge-snapshot-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        for width in [740.0, 1100.0] {
            for dark in [false, true] {
                for reading in [false, true] {
                    let model = KnowledgeBrowserModel(service: service, space: .work, preferences: preferences)
                    await model.reload()
                    model.selection = reading ? .item(article.id) : .folder(parent.id)
                    model.expanded.insert(.folder(child.id))
                    if reading { await model.loadSelectedItem() }
                    let hosting = NSHostingView(rootView: KnowledgeView(model: model, jobCenter: jobs())
                        .frame(width: width, height: 640)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = hosting
                    defer { window.close() }
                    for _ in 0..<30 {
                        hosting.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    #expect(abs(hosting.frame.width - width) < 0.5)
                    if reading { #expect(model.selectedItem?.content.contains("正文末尾") == true) }
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let image = NSImage(size: hosting.bounds.size)
                    image.lockFocus()
                    window.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.textBackgroundColor.setFill()
                        hosting.bounds.fill()
                    }
                    if let cgImage = bitmap.cgImage {
                        NSImage(cgImage: cgImage, size: hosting.bounds.size).draw(in: hosting.bounds)
                    }
                    image.unlockFocus()
                    let data = try #require(image.tiffRepresentation)
                    let png = try #require(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
                    let name = "knowledge-\(reading ? "reader" : "tree")-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
                }
            }
        }
    }
}
