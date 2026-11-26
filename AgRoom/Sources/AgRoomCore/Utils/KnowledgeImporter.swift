import Foundation
import PDFKit

// MARK: - Knowledge Importer

/// 知识条目文件导入：md/txt 直读，PDF 提取文本层（网页正文抽取待内置浏览器上线后接入）
public enum KnowledgeImporter {

    public enum ImportError: LocalizedError {
        case unsupportedFormat(String)
        case pdfHasNoTextLayer
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "Unsupported file format: .\(ext). Supported: md, txt, pdf."
            case .pdfHasNoTextLayer:
                return "This PDF has no extractable text layer (scanned image?)."
            case .readFailed(let reason):
                return "Failed to read file: \(reason)"
            }
        }
    }

    /// 支持导入的扩展名
    public static let supportedExtensions = ["md", "txt", "pdf"]

    public static func item(from url: URL) throws -> KnowledgeItem {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent

        switch ext {
        case "md", "txt":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ImportError.readFailed(url.lastPathComponent)
            }
            return KnowledgeItem(title: title, content: text, kind: .document)

        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw ImportError.readFailed(url.lastPathComponent)
            }
            var pages: [String] = []
            for pageIndex in 0..<document.pageCount {
                if let pageText = document.page(at: pageIndex)?.string {
                    pages.append(pageText)
                }
            }
            let text = pages.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.pdfHasNoTextLayer
            }
            return KnowledgeItem(title: title, content: text, kind: .document)

        default:
            throw ImportError.unsupportedFormat(ext)
        }
    }
}
