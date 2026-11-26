import AppKit

/// Reuses the reader's Markdown parser and prose styles, with paginated TextKit output.
@MainActor
enum NotePrintDocument {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize: 12),.foregroundColor:NSColor.black]
        for segment in MarkdownSegment.segments(from: MarkdownParser.parse(markdown).blocks) {
            switch segment {
            case .prose(let prose): result.append(prose.attributedString)
            case .codeBlock(let code, _):
                result.append(NSAttributedString(string: code.code + "\n\n",attributes: [.font:NSFont.monospacedSystemFont(ofSize: 10,weight: .regular),.foregroundColor:NSColor.black,.backgroundColor:NSColor(white: 0.95,alpha: 1)]))
            case .table(let table, _, _):
                let layout = NSTextTable(); layout.numberOfColumns = max(1,table.header.count)
                for (row,cells) in ([table.header] + table.rows).enumerated() {
                    for (column,cell) in cells.prefix(layout.numberOfColumns).enumerated() {
                        let block = NSTextTableBlock(table: layout,startingRow: row,rowSpan: 1,startingColumn: column,columnSpan: 1)
                        block.setWidth(0.5,type: .absoluteValueType,for: .border)
                        block.setWidth(5,type: .absoluteValueType,for: .padding)
                        block.setBorderColor(.lightGray)
                        if row == 0 { block.backgroundColor = NSColor(white: 0.94,alpha: 1) }
                        let style = NSMutableParagraphStyle(); style.textBlocks = [block]
                        let value = NSMutableAttributedString(string: cell.map(\.plainText).joined() + "\n",attributes: attributes)
                        value.addAttribute(.paragraphStyle,value: style,range: NSRange(location: 0,length: value.length))
                        if row == 0 { value.addAttribute(.font,value: NSFont.boldSystemFont(ofSize: 12),range: NSRange(location: 0,length: value.length)) }
                        result.append(value)
                    }
                }
                result.append(NSAttributedString(string: "\n",attributes: attributes))
            case .math(let math, _): result.append(NSAttributedString(string: math.source + "\n\n",attributes: attributes))
            case .image(_, let alt, _): result.append(NSAttributedString(string: alt + "\n\n",attributes: attributes))
            case .media(let source, let name, _): result.append(NSAttributedString(string: name + " (" + source + ")\n\n",attributes: attributes))
            case .divider: result.append(NSAttributedString(string: "────────────────────────\n\n",attributes: attributes))
            }
        }
        result.addAttribute(.foregroundColor,value: NSColor.black,range: NSRange(location: 0,length: result.length))
        return result
    }
    static func print(_ markdown: String) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic; info.isVerticallyCentered = false
        info.leftMargin = 36; info.rightMargin = 36; info.topMargin = 36; info.bottomMargin = 36
        let width = max(200,info.paperSize.width - info.leftMargin - info.rightMargin)
        let text = NSTextView(frame: NSRect(x: 0,y: 0,width: width,height: 720))
        text.isRichText = true; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width: width,height: .greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(attributed(markdown)); text.sizeToFit()
        let operation = NSPrintOperation(view: text,printInfo: info)
        operation.showsPrintPanel = true; operation.run()
    }
}
