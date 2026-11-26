import AppKit
import ImageIO
import AgRoomCore
import SwiftUI
import Testing
@testable import AgRoomUI

@Suite("Markdown grammar regressions")
struct MarkdownGrammarTests {
    @Test("Setext、闭合井号与带空格分隔线")
    func headingsAndThematicBreaks() {
        let blocks = MarkdownParser.parse("标题\n===\n\n## 次标题 ##\n\n* * *").blocks
        #expect(blocks.count == 3)
        guard case .heading(let level, let title) = blocks[0].content,
              case .heading(let secondLevel, let secondTitle) = blocks[1].content,
              case .divider = blocks[2].content else {
            Issue.record("应解析为两个标题和分隔线")
            return
        }
        #expect(level == 1)
        #expect(title.map(\.plainText).joined() == "标题")
        #expect(secondLevel == 2)
        #expect(secondTitle.map(\.plainText).joined() == "次标题")
    }

    @Test("密集软硬换行保留段落语义与两侧节点的 UTF-8 源码范围")
    func multilineSourceRanges() throws {
        let line = "中文 😀 **重点** 和 `code`"
        let separators = ["\n", "  \r\n"]
        let source = (0..<400).map { line + ($0 == 399 ? "" : separators[$0 % 2]) }.joined()
        let document = MarkdownParser.parse(source)
        guard case .paragraph(let nodes) = document.blocks.first?.content else { Issue.record("应为同一段"); return }
        let bytes = Array(source.utf8)
        var breaks = 0, emphasis = 0
        for node in nodes {
            switch node.content {
            case .softBreak: #expect(breaks.isMultiple(of: 2)); breaks += 1
            case .hardBreak: #expect(!breaks.isMultiple(of: 2)); breaks += 1
            case .strong:
                let range = try #require(node.sourceRange)
                #expect(String(decoding: bytes[range], as: UTF8.self).contains("重点"))
                emphasis += 1
            default: continue
            }
        }
        #expect(breaks == 399 && emphasis == 400)
    }

    @Test("围栏长度匹配、波浪号和缩进代码")
    func allCodeBlockForms() {
        let sources = [
            "````markdown\n```swift\nlet a = 1\n```\n````",
            "~~~swift\nlet a = 1\n~~~",
            "    let a = 1"
        ]
        for source in sources {
            let blocks = MarkdownParser.parse(source).blocks
            #expect(blocks.count == 1)
            guard case .code(let code) = blocks[0].content else {
                Issue.record("代码块不应拆成普通段落")
                continue
            }
            #expect(code.code.contains("let a = 1"))
        }
        guard case .code(let outer) = MarkdownParser.parse(sources[0]).blocks[0].content else { return }
        #expect(outer.code.hasPrefix("```swift\n"))
        #expect(outer.code.hasSuffix("```\n"))
        #expect(outer.language == "markdown")
    }

    @Test("保留硬换行、反斜杠转义和中文软换行")
    func lineBreaksAndEscapes() {
        let slash = String(UnicodeScalar(92))
        #expect(MarkdownParser.parse("第一行  \n第二行").plainText == "第一行\n第二行")
        #expect(MarkdownParser.parse("第一行" + slash + "\n第二行").plainText == "第一行\n第二行")
        #expect(MarkdownParser.parse("第一行" + slash + slash + "\n第二行").plainText == "第一行" + slash + " 第二行")
        #expect(MarkdownParser.parse("末尾" + slash).plainText == "末尾" + slash)
        #expect(MarkdownParser.parse("中文\nEnglish").plainText == "中文 English")
    }

    @Test("表格允许省略外侧竖线，保留转义竖线与对齐")
    func tableGrammarAndPlainText() {
        let source = "**名称** | [值](https://example.com)\n:---: | ---:\nx\\|y | `z`"
        let document = MarkdownParser.parse(source)
        guard case .table(let table) = document.blocks.first?.content else {
            Issue.record("应识别为 GFM 表格")
            return
        }
        #expect(table.alignments == [.center, .trailing])
        #expect(table.rows[0].count == 2)
        #expect(table.rows[0][0].map(\.plainText).joined() == "x|y")
        #expect(document.plainText == "名称\t值\nx|y\tz")
    }

    @Test("引用式链接使用整篇文档的定义")
    func lateReferenceDefinition() {
        let document = MarkdownParser.parse("[来源][ref]\n\n其他段落\n\n[ref]: https://example.com \"标题\"")
        guard case .paragraph(let inline) = document.blocks[0].content,
              case .link(let destination, let title, _) = inline[0].content else {
            Issue.record("后到定义应关联到前文链接")
            return
        }
        #expect(destination == "https://example.com")
        #expect(title == "标题")
        #expect(document.plainText == "来源\n\n其他段落")
    }

    @Test("任务状态、列表续行与嵌套树保持归属")
    func listStructure() {
        let source = "- [ ] 第一行\n  续行\n  - 内层\n- [x] 完成"
        guard case .list(_, let items) = MarkdownParser.parse(source).blocks.first?.content else {
            Issue.record("应识别列表")
            return
        }
        #expect(items.map(\.checked) == [false, true])
        #expect(items[0].blocks.count == 2)
        #expect(items[0].blocks[0].plainText == "第一行 续行")
        guard case .list(_, let nested) = items[0].blocks[1].content else {
            Issue.record("子列表不能被压成同级")
            return
        }
        #expect(nested[0].blocks[0].plainText == "内层")
    }

    @Test("源码范围使用原始 UTF-8，覆盖中文、emoji 与 CRLF")
    func sourceRanges() throws {
        let source = "首行\r\n\r\n## 标题🙂\r\n\r\n<details>原文</details>"
        let blocks = MarkdownParser.parse(source).blocks
        let range = try #require(blocks[1].sourceRange)
        let original = String(decoding: Array(source.utf8)[range], as: UTF8.self)
        #expect(original == "## 标题🙂")
        #expect(blocks.last?.plainText.contains("<details>原文</details>") == true)
    }

    @Test("frontmatter 仅在完整闭合时剥离")
    func frontmatter() {
        #expect(MarkdownParser.bodyWithoutFrontmatter("---\nname: demo\n---\n# 正文") == "# 正文")
        let incomplete = "---\nname: demo\n# 正文"
        #expect(MarkdownParser.bodyWithoutFrontmatter(incomplete) == incomplete)
        #expect(MarkdownParser.parse("---\n\n正文").blocks.count == 2)
    }

    @Test("技能正文源码范围仍指向含 frontmatter 的原始文件")
    func frontmatterSourceRanges() throws {
        let source = "---\r\nname: 示例\r\n---\r\n## 正文🙂"
        let document = MarkdownParser.parse(source, strippingFrontmatter: true)
        #expect(document.source == source)
        #expect(document.plainText == "正文🙂")
        let range = try #require(document.blocks.first?.sourceRange)
        #expect(String(decoding: Array(source.utf8)[range], as: UTF8.self) == "## 正文🙂")
    }
}

@Suite("Markdown native rendering regressions")
@MainActor
struct MarkdownNativeRenderingTests {
    private func prose(_ source: String) -> NSAttributedString {
        let segments = MarkdownSegment.segments(from: MarkdownParser.parse(source).blocks)
        let result = NSMutableAttributedString()
        for segment in segments {
            if case .prose(let prose) = segment { result.append(prose.attributedString) }
        }
        return result
    }

    @Test("删除线、粗斜体、行内代码和链接属性不丢失")
    func inlineAttributes() throws {
        let text = prose("~~删除~~ ***粗斜体*** `代码` [链接](https://example.com)")
        let string = text.string as NSString
        let strike = string.range(of: "删除")
        #expect(text.attribute(.strikethroughStyle, at: strike.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let emphasis = string.range(of: "粗斜体")
        let font = try #require(text.attribute(.font, at: emphasis.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains([.bold, .italic]))
        let code = string.range(of: "代码")
        #expect(text.attribute(.backgroundColor, at: code.location, effectiveRange: nil) != nil)
        let link = string.range(of: "链接")
        #expect((text.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com")
    }

    @Test("嵌套列表与引用中的代码保留容器缩进")
    func nestedCodeContext() throws {
        let source = "- 父项\n  - 子项\n    > 引用\n    >\n    > ~~~swift\n    > let a = 1\n    > ~~~"
        let segments = MarkdownSegment.segments(from: MarkdownParser.parse(source).blocks)
        let pair = try #require(segments.compactMap { segment -> (MarkdownCode, MarkdownBlockContext)? in
            if case .codeBlock(let code, let context) = segment { return (code, context) }
            return nil
        }.first)
        #expect(pair.0.language == "swift")
        #expect(pair.1.indent >= 40)
        #expect(pair.1.quoteIndents.count == 1)
        let text = prose(source)
        let child = (text.string as NSString).range(of: "子项")
        let parent = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let nested = try #require(text.attribute(.paragraphStyle, at: child.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(nested.headIndent > parent.headIndent)
    }

    @Test("嵌套引用的左缘标记与正文保持同一行")
    func quoteMarkerSharesFirstLine() throws {
        let text = prose("- 父项\n  - 子项\n    > 引用中的 **强调** 与换行\n    > 第二行")
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 268, height: 900))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let marker = (text.string as NSString).range(of: "▎")
        let body = (text.string as NSString).range(of: "引用")
        try #require(marker.location != NSNotFound && body.location != NSNotFound)
        let markerLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: marker.location), effectiveRange: nil)
        let bodyLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: body.location), effectiveRange: nil)
        #expect(markerLine.minY == bodyLine.minY)
    }

    @Test("不同文档的富文本缓存互不共享")
    func cacheOwnership() throws {
        let first = MarkdownRenderCache()
        let second = MarkdownRenderCache()
        let document = MarkdownParser.parse("相同正文")
        guard case .prose(let a) = first.segments(for: document)[0],
              case .prose(let b) = second.segments(for: document)[0] else { return }
        #expect(a !== b)
    }

    @Test("同一源码切换 frontmatter 配置不复用错误渲染")
    func cacheConfiguration() {
        let cache = MarkdownRenderCache()
        let source = "---\nname: 示例\n---\n正文"
        _ = cache.segments(for: MarkdownParser.parse(source))
        let stripped = cache.segments(for: MarkdownParser.parse(source, strippingFrontmatter: true))
        guard case .prose(let text) = stripped.first else { Issue.record("应显示技能正文"); return }
        #expect(text.attributedString.string == "正文")
    }

    @Test("同一文档切换阅读字号会更新流式与终态缓存")
    func readingSizeInvalidatesCaches() throws {
        let cache = MarkdownRenderCache()
        let document = MarkdownParser.parse("#### 标题\n\n正文与 [来源](https://example.com)")
        for streaming in [true, false] {
            guard case .prose(let smallRun) = cache.segments(for: document, streaming: streaming, typography: ReadingTypography(pointSize: 14)).first,
                  case .prose(let largeRun) = cache.segments(for: document, streaming: streaming, typography: ReadingTypography(pointSize: 17)).first,
                  case .prose(let restored) = cache.segments(for: document, streaming: streaming, typography: ReadingTypography(pointSize: 14)).first else {
                Issue.record("字号切换后仍应保留正文")
                return
            }
            let small = smallRun.attributedString, large = largeRun.attributedString
            let body = (small.string as NSString).range(of: "正文")
            let smallFont = try #require(small.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)
            let largeFont = try #require(large.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)
            let headingFont = try #require(large.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(largeFont.pointSize > smallFont.pointSize)
            #expect(headingFont.pointSize >= largeFont.pointSize)
            #expect(restored.attributedString.isEqual(to: small))
            let link = (large.string as NSString).range(of: "来源")
            #expect(large.attribute(.link, at: link.location, effectiveRange: nil) != nil)
        }
    }

    @Test("只更改字号也会重排同一消息，并失效原生高度缓存")
    func readingSizeReflowsExistingMessage() async throws {
        let model = MarkdownRenderModel()
        let source = "> - " + String(repeating: "中文与 English 混排正文🙂，", count: 18) + "末尾标记"
        await model.update(source, documentID: "reading-size", streaming: false, typography: ReadingTypography(pointSize: 14))
        guard case .prose(let small) = model.segments.first else { Issue.record("应渲染正文"); return }
        let view = SelectableTextView.make(prose: small)
        let width = 268.0
        let smallHeight = view.heightForWidth(width)

        await model.update(source, documentID: "reading-size", streaming: false, typography: ReadingTypography(pointSize: 30))
        guard case .prose(let large) = model.segments.first else { Issue.record("应重新渲染正文"); return }
        #expect(!small.attributedString.isEqual(to: large.attributedString))
        #expect(large.attributedString.string.contains("末尾标记"))
        view.setProse(large)
        let largeHeight = view.heightForWidth(width)
        #expect(largeHeight > smallHeight)
        view.setFrameSize(NSSize(width: width, height: largeHeight))
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        #expect(layout.usedRect(for: container).maxY <= largeHeight)
    }

    @Test("逐字符流式快照保留代码空行与后到链接定义")
    func streamingSnapshots() async throws {
        let source = "```swift\nlet a = 1\n\nlet b = 2\n```\n\n[来源][ref]\n\n[ref]: https://example.com"
        let model = MarkdownRenderModel()
        var prefix = ""
        for character in source {
            prefix.append(character)
            await model.update(prefix, documentID: "message", streaming: true)
            if prefix == "```swift\nlet a = 1\n\nlet b = 2" {
                #expect(model.segments.count == 1)
                guard case .codeBlock(let code, _) = model.segments[0] else {
                    Issue.record("空行之后的代码不应落入普通文本")
                    return
                }
                #expect(code.code.contains("let b = 2"))
            }
        }
        await model.update(source, documentID: "message", streaming: false)
        let final = MarkdownSegment.segments(from: MarkdownParser.parse(source).blocks)
        #expect(model.segments.count == final.count)
        guard case .prose(let actual) = model.segments.last,
              case .prose(let expected) = final.last else {
            Issue.record("最终快照应包含链接文本")
            return
        }
        #expect(actual.attributedString.isEqual(to: expected.attributedString))
        #expect(actual.attributedString.attribute(.link, at: 0, effectiveRange: nil) != nil)
    }

    @Test("取消的解析不能覆盖切换后的文档")
    func cancelledDocumentUpdate() async {
        let model = MarkdownRenderModel()
        let old = Task { await model.update(String(repeating: "旧内容\n\n", count: 1_000), documentID: "old", streaming: true) }
        old.cancel()
        await model.update("新正文", documentID: "new", streaming: false)
        await old.value
        #expect(model.documentID == "new")
        guard case .prose(let text) = model.segments.first else {
            Issue.record("新文档正文必须保留")
            return
        }
        #expect(text.attributedString.string == "新正文")
    }

    @Test("只有引用定义或 frontmatter 的文档渲染为空，不退回显示元数据")
    func emptyRenderedDocument() async {
        let model = MarkdownRenderModel()
        await model.update("[ref]: https://example.com", documentID: "reference-only", streaming: false)
        #expect(model.hasRenderedSnapshot)
        #expect(model.segments.isEmpty)
        await model.update("---\nname: 示例\n---", documentID: "metadata-only", streaming: false, strippingFrontmatter: true)
        #expect(model.hasRenderedSnapshot)
        #expect(model.segments.isEmpty)
    }

    @Test("共享预览在原生宿主中完成后台渲染，窄宽布局不裁切末段")
    func hostedPreview() async throws {
        let source = #"""
        # Markdown 渲染

        **粗体**、*斜体*、~~删除线~~、`行内代码` 与 [链接](https://example.com)。

        - [x] 已完成
          - 嵌套列表
            > 引用中的 **强调** 与换行
            > 第二行

        ~~~swift
        let value = 1

        let next = value + 1
        ~~~

        名称 | 数值 | 说明
        :--- | ---: | :---:
        **示例** | 42 | x\|y

        最后一段：正文完整显示。
        """#
        for (width, dark, pointSize) in [(300.0, 15), (680.0, 15), (300.0, 30)].flatMap({ width, size in [false, true].map { (width, $0, size) } }) {
            let suite = "markdown-reading-preview-\(UUID())"
            let preferences = try #require(UserDefaults(suiteName: suite))
            preferences.set(pointSize, forKey: ReadingTypography.preferenceKey)
            defer { preferences.removePersistentDomain(forName: suite) }
            let hosting = NSHostingView(rootView: MarkdownView(text: source, documentID: "hosted-\(width)-\(dark)-\(pointSize)")
                .padding(16).environment(\.colorScheme, dark ? .dark : .light).defaultAppStorage(preferences))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            defer { window.close() }

            func textViews(_ view: NSView) -> [SelectableTextView] {
                if let text = view as? SelectableTextView { return [text] }
                return view.subviews.flatMap(textViews)
            }
            var rendered: [SelectableTextView] = []
            for _ in 0..<100 {
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                rendered = textViews(hosting)
                if rendered.contains(where: { $0.string.contains("最后一段") }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(rendered.count >= 2)
            #expect(rendered.last?.string.contains("最后一段") == true)
            if let last = rendered.last, let attributed = last.currentAttributed {
                let range = (attributed.string as NSString).range(of: "最后一段")
                let font = try #require(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                #expect(font.pointSize == CGFloat(pointSize))
            }
            for text in rendered {
                #expect(text.frame.width <= width)
                #expect(text.frame.height >= text.heightForWidth(text.frame.width) - 0.5)
            }
            if let directory = ProcessInfo.processInfo.environment["AGROOM_MARKDOWN_SNAPSHOT_DIR"],
               let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let preview = NSImage(size: hosting.bounds.size)
                preview.lockFocus()
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.textBackgroundColor.setFill()
                    hosting.bounds.fill()
                }
                if let cgImage = bitmap.cgImage {
                    NSImage(cgImage: cgImage, size: hosting.bounds.size).draw(
                        in: hosting.bounds, from: .zero, operation: .sourceOver, fraction: 1
                    )
                }
                preview.unlockFocus()
                let tiff = try #require(preview.tiffRepresentation)
                let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("markdown-\(dark ? "dark" : "light")-\(Int(width))-\(pointSize).png"), options: .atomic)
            }
        }
    }
}

@Suite("Markdown performance regressions", .serialized)
@MainActor
struct MarkdownPerformanceRegressionTests {
    @Test func attachmentThumbnailsShareDecodesAndRespectFileReplacementSpaceAndScale() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: path) }
        func write(_ width: Int, _ height: Int) throws {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: path, options: .atomic)
        }
        try write(300, 100)
        let loader = AttachmentThumbnailLoader()
        let request = AttachmentThumbnailLoader.Request(space: .personal, path: path.path, pixels: 64)
        async let a = loader.image(for: request)
        async let b = loader.image(for: request)
        let images = await [a, b]
        #expect(images.allSatisfy { $0?.width == 64 })
        #expect(await loader.decodeCount == 1)
        _ = await loader.image(for: .init(space: .work, path: path.path, pixels: 64))
        #expect(await loader.image(for: .init(space: .personal, path: path.path, pixels: 128))?.width == 128)
        let watch = await loader.watch(path.path)
        defer { watch.cancel() }
        try write(100, 300)
        var iterator = watch.events.makeAsyncIterator()
        let timer = Task { try await Task.sleep(for: .seconds(3)); watch.cancel() }
        defer { timer.cancel() }
        #expect(await iterator.next() != nil)
        let replaced = await loader.image(for: request)
        #expect(replaced?.height == 64 && replaced?.width != 64)
        #expect(await loader.decodeCount == 4)
    }

    @Test("流式解析未结束时仍交付有效前缀，只消费最后一次追加")
    func slowStreamingUpdates() async throws {
        let first = MarkdownResourceTestGate(), last = MarkdownResourceTestGate()
        let model = MarkdownRenderModel(parse: { text, strip, _ in
            if text == "A" { await first.wait() }
            if text == "ABC" { await last.wait() }
            return MarkdownParser.parse(text, strippingFrontmatter: strip)
        })
        func append(_ text: String) async {
            await model.present(.init(text: text, streaming: true, documentID: "stream"))
        }
        await append("A")
        try #require(await first.didStart())
        await append("AB")
        await append("ABC")
        await first.release()
        try #require(await last.didStart())
        guard case .prose(let intermediate) = model.segments.first else { Issue.record("缺少中间快照"); return }
        #expect(intermediate.attributedString.string == "A")
        // Change scope while an older append is still inside the parser.
        await model.present(.init(text: "终态", documentID: "next"))
        await last.release()
        #expect(model.documentID == "next")
        guard case .prose(let final) = model.segments.first else { Issue.record("缺少终态"); return }
        #expect(final.attributedString.string == "终态")
    }

    @Test("连续正文按块提供后缀，跳过中间修订后仍保留选区、属性与测量高度")
    func proseSkipsUnchangedBlocks() throws {
        let cache = MarkdownBlockRenderCache()
        let head = "# 标题🙂\n\n" + String(repeating: "稳定 **正文**\n\n", count: 60)
        func run(_ tail: String) throws -> MarkdownProse {
            let segments = cache.segments(MarkdownParser.parse(head + tail).blocks, resources: [:], failed: [], typography: .init())
            return try #require(segments.compactMap { if case .prose(let prose) = $0 { prose } else { nil } }.first)
        }
        let first = try run("尾段 e")
        let view = SelectableTextView.make(prose: first)
        view.setSelectedRange(NSRange(location: 0, length: 2))
        let skipped = try run("尾段 é")
        let latest = try run("尾段 é 和 [链接](https://example.com)")
        #expect(latest.prefix(sharedWith: skipped).count == 61)
        #expect(latest.prefix(sharedWith: first).count == 61)
        for prose in [latest, try run("尾段 **新样式**"), try run("")] {
            view.setProse(prose)
            #expect(view.lastEditedRange.location >= first.parts[0].length)
            #expect(view.selectedRange() == NSRange(location: 0, length: 2))
            let fresh = SelectableTextView.make(prose: prose)
            let current = try #require(view.textStorage), expected = try #require(fresh.textStorage)
            #expect(current.string == expected.string)
            // TextKit synthesizes private original-font metadata during font
            // fallback. Compare the visible fonts and Markdown attributes.
            for i in 0..<expected.length {
                let font = current.attribute(.font, at: i, effectiveRange: nil) as? NSFont
                let target = expected.attribute(.font, at: i, effectiveRange: nil) as? NSFont
                #expect(font?.fontName == target?.fontName && font?.pointSize == target?.pointSize)
                for key in [NSAttributedString.Key.paragraphStyle, .link, .foregroundColor] {
                    let actual = current.attribute(key, at: i, effectiveRange: nil) as? NSObject
                    let wanted = expected.attribute(key, at: i, effectiveRange: nil) as? NSObject
                    #expect(actual == wanted)
                }
            }
            #expect(view.heightForWidth(267) == fresh.heightForWidth(267))
        }
    }

    @Test("新公式进入资源计划时保留在途公式，移除或换文档会丢弃迟到结果")
    func resourcesAcrossPlanChanges() async throws {
        let gate = MarkdownResourceTestGate()
        let x = MarkdownResourceKey.math(.init(source: "x", display: false))
        let y = MarkdownResourceKey.math(.init(source: "y", display: false))
        var loads: [MarkdownResourceKey] = []
        let model = MarkdownRenderModel(resourceLoader: { key, _, _ in
            loads.append(key)
            if key == x { await gate.wait() }
            return MarkdownRenderedResource(image: NSImage(size: NSSize(width: 4, height: 4)), pixelCount: 16)
        })
        await model.update("$x$", documentID: "one", streaming: false, loadingResources: false)
        let loading = Task { await model.loadResources() }
        try #require(await gate.didStart())
        let revision = model.resourceRequestID
        await model.update("$x$ 和 $y$", documentID: "one", streaming: false, loadingResources: false)
        #expect(model.resourceRequestID == revision)
        await gate.release()
        await loading.value
        #expect(loads == [x, y])
        #expect(model.resources.count == 2)

        let removed = MarkdownResourceTestGate()
        var cancelled = false
        let other = MarkdownRenderModel(resourceLoader: { key, _, _ in
            if key == x { await removed.wait(); cancelled = Task.isCancelled }
            return MarkdownRenderedResource(image: NSImage(size: NSSize(width: 4, height: 4)), pixelCount: 16)
        })
        await other.update("$x$", documentID: "two", streaming: false, loadingResources: false)
        let obsolete = Task { await other.loadResources() }
        try #require(await removed.didStart())
        await other.update("$y$", documentID: "two", streaming: false)
        await removed.release()
        await obsolete.value
        #expect(cancelled && other.resources[x] == nil && other.resources[y] != nil && other.failedResources.isEmpty)
    }

    @Test("大表只布局当前页，翻页按需加载并复用资源，整篇预算及导出保持完整")
    func tablePagesAndResources() async throws {
        let rows = (0..<70).map { "| $f\($0)$ |" }.joined(separator: "\n")
        let source = "> | 小表 |\n> |---|\n> | 1 |\n\n| 主表 |\n|---|\n" + rows
        var loaded: [MarkdownResourceKey] = []
        let model = MarkdownRenderModel(resourceLoader: { key, _, _ in
            loaded.append(key)
            return MarkdownRenderedResource(image: NSImage(size: NSSize(width: 4, height: 4)), pixelCount: 16)
        })
        await model.update(source, documentID: "tables", streaming: false)
        let table = try #require(model.segments.compactMap { segment -> MarkdownTable? in
            if case .table(let table, _, 1) = segment { return table }; return nil
        }.first)
        let cache = MarkdownTableLayoutCache()
        let first = cache.layout(table, resources: [:], failed: [], typography: .init())
        #expect(first.cells.count == table.rowsPerPage + 1 && loaded.count == table.rowsPerPage)
        model.setTablePage(1, for: 1)
        await model.loadResources()
        let second = cache.layout(table, page: 1, resources: [:], failed: [], typography: .init())
        #expect(first.cells[0][0] === second.cells[0][0])
        #expect(second.cells[1][0].string == "f\(table.rowsPerPage)")
        #expect(loaded.count == 2 * table.rowsPerPage)
        model.setTablePage(0, for: 1)
        await model.loadResources()
        #expect(loaded.count == 2 * table.rowsPerPage)
        model.setTablePage(Int.max, for: 1)
        await model.loadResources()
        #expect(model.tablePages[1] == table.pageCount - 1)
        #expect(loaded.count == 64 && table.plainText.contains("f69"))
        #expect(NotePrintDocument.attributed(source).string.contains("f69"))
        let replaced = source.replacingOccurrences(of: "| 主表 |", with: "| 另一张表 |")
        await model.update(replaced, documentID: "tables", streaming: false, loadingResources: false)
        #expect(model.tablePages.isEmpty)
        await model.update("| 小表 |\n|---|\n| 1 |", documentID: "tables", streaming: false)
        #expect(model.tablePages.isEmpty && model.resources.isEmpty)
    }

    @Test("原生表格首次挂载和翻页只创建本页文本视图")
    func hostedTablePagination() async throws {
        let source = "A | B\n--- | ---\n" + (1...65).map { "row-\($0) | value" }.joined(separator: "\n")
        let model = MarkdownRenderModel()
        let host = NSHostingView(rootView: ScrollView {
            MarkdownView(text: source, documentID: "paged", model: model)
        }.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func cells(_ view: NSView) -> [String] {
            if let text = view as? SelectableTextView { return [text.string] }
            return view.subviews.flatMap(cells)
        }
        func page(containing marker: String) async throws -> [String] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while .now < deadline {
                host.layoutSubtreeIfNeeded()
                let values = cells(host)
                if values.contains(marker) { return values }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CocoaError(.coderValueNotFound)
        }
        let first = try await page(containing: "row-24")
        #expect(first.count == 50 && !first.contains("row-25"))
        model.setTablePage(1, for: 0)
        let next = try await page(containing: "row-48")
        #expect(next.count == 50 && next.contains("A") && !next.contains("row-24"))
    }

    @Test("Opt-in TextKit streaming benchmark")
    func textKitBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["AGROOM_MARKDOWN_BENCHMARK"] else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let prefix = String(repeating: "中文 English 😀 paragraph with a stable prefix.\n", count: 600)
        let initial = NSAttributedString(string: prefix, attributes: attributes)
        let baseline = SelectableTextView.make(attributed: initial)
        let optimized = SelectableTextView.make(attributed: initial)
        let storage = NSTextStorage(attributedString: initial)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 550, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.usesFontLeading = true; manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        _ = optimized.heightForWidth(550)
        var full: [Double] = [], incremental: [Double] = []
        for index in 1...20 {
            let text = NSAttributedString(string: prefix + String(repeating: "tail ", count: index), attributes: attributes)
            var start = ContinuousClock.now
            baseline.textStorage?.setAttributedString(text)
            storage.setAttributedString(text)
            manager.ensureLayout(for: container)
            let fullHeight = ceil(manager.usedRect(for: container).maxY)
            full.append(milliseconds(start.duration(to: .now)))
            start = .now
            optimized.setText(text)
            let height = optimized.heightForWidth(550)
            incremental.append(milliseconds(start.duration(to: .now)))
            #expect(abs(fullHeight - height) < 0.1)
        }
        func stats(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            return ["p50_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)]]
        }
        let result = ["full_replacement": stats(full), "suffix_replacement": stats(incremental)]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test("Unchanged block cache hits retain the merged attributed-string identity")
    func mergedCacheIdentity() {
        let blocks = MarkdownParser.parse(String(repeating: "Paragraph **bold**.\n\n", count: 200)).blocks
        let cache = MarkdownBlockRenderCache()
        let first = cache.segments(blocks, resources: [:], failed: [], typography: ReadingTypography())
        let rebuilt = cache.rebuildCount
        let second = cache.segments(blocks, resources: [:], failed: [], typography: ReadingTypography())
        guard case .prose(let a) = first.first, case .prose(let b) = second.first else { Issue.record("Missing prose"); return }
        #expect(a === b)
        #expect(cache.rebuildCount == rebuilt)
    }

    @Test("TextKit edits only changed suffixes and still invalidates changed formatting")
    func incrementalTextStorage() {
        let prefix = String(repeating: "中文 😀 é paragraph.\n", count: 300)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let first = NSAttributedString(string: prefix + "tail", attributes: attributes)
        let view = SelectableTextView.make(attributed: first)
        let second = NSAttributedString(string: prefix + "tail extended", attributes: attributes)
        view.setText(second)
        #expect(view.lastEditedRange.location == first.length)
        #expect(view.lastEditedRange.length == 0)
        #expect(view.string == second.string)
        let expected = SelectableTextView.make(attributed: second)
        #expect(abs(view.heightForWidth(350) - expected.heightForWidth(350)) < 0.1)
        let restyled = NSMutableAttributedString(attributedString: second)
        restyled.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 23), range: NSRange(location: 0, length: 2))
        view.setText(restyled)
        #expect(view.lastEditedRange.location == 0)
        #expect(view.textStorage!.isEqual(to: SelectableTextView.make(attributed: restyled).textStorage!))
        view.setText(NSAttributedString(string: "😀!", attributes: attributes))
        view.setText(NSAttributedString(string: "😁!", attributes: attributes))
        #expect(view.lastEditedRange.location == 0)
        #expect(view.string == "😁!")
    }

    @Test("Table tail changes reuse existing cells and oversized tables have a total view budget")
    func tableReuseAndBudget() {
        func cell(_ text: String) -> [MarkdownInline] { [.init(content: .text(text), sourceRange: nil)] }
        let first = MarkdownTable(header: [cell("header")], rows: [cell("old")].map { [$0] }, alignments: [.leading])
        let cache = MarkdownTableLayoutCache()
        let a = cache.layout(first, resources: [:], failed: [], typography: ReadingTypography())
        let count = cache.rebuildCount
        let second = MarkdownTable(header: first.header, rows: first.rows + [[cell("new")]], alignments: first.alignments)
        let b = cache.layout(second, resources: [:], failed: [], typography: ReadingTypography())
        #expect(cache.rebuildCount == count + 1)
        #expect(a.cells[0][0] === b.cells[0][0] && a.cells[1][0] === b.cells[1][0])
        let wide = MarkdownTable(header: Array(repeating: cell("h"), count: 100), rows: Array(repeating: Array(repeating: cell("x"), count: 100), count: 600), alignments: [])
        let preview = cache.layout(wide, resources: [:], failed: [], typography: ReadingTypography())
        #expect(preview.widths.count == MarkdownTable.maximumPreviewColumns)
        #expect(preview.cells.count * preview.widths.count <= MarkdownTable.maximumPreviewCells)
        #expect(wide.previewTruncated)
        #expect(wide.rows.count == 600 && wide.header.count == 100)
    }

    @Test("Text deltas keep the current resource task and commit against the latest document")
    func resourceSurvivesTextDeltas() async throws {
        let gate = MarkdownResourceTestGate()
        var loads = 0
        let model = MarkdownRenderModel(resourceLoader: { _, _, _ in
            loads += 1
            await gate.wait()
            return MarkdownRenderedResource(image: NSImage(size: NSSize(width: 10, height: 10)), pixelCount: 100)
        })
        await model.update("$x$\n\nold", documentID: "stream", streaming: false, loadingResources: false)
        let revision = model.resourceRequestID
        let loading = Task { await model.loadResources() }
        while !(await gate.started) { await Task.yield() }
        await model.update("$x$\n\nnew tail", documentID: "stream", streaming: false, loadingResources: false)
        #expect(model.resourceRequestID == revision)
        await gate.release()
        await loading.value
        #expect(loads == 1 && model.resources.count == 1)
        guard case .prose(let text) = model.segments.first else { Issue.record("Missing prose"); return }
        #expect(text.attributedString.string.contains("new tail") && !text.attributedString.string.contains("old"))
        await model.update("$x$", documentID: "other", streaming: false, loadingResources: false)
        #expect(model.resourceRequestID != revision && model.resources.isEmpty)
    }
}

private actor MarkdownResourceTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; started = true }
    }
    func didStart() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !started, .now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return started
    }
    func release() { continuation?.resume(); continuation = nil }
}
