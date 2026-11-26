import Foundation

public struct MailTextStyle: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = Self(rawValue: 1)
    public static let italic = Self(rawValue: 2)
    public static let underline = Self(rawValue: 4)
}

/// Offsets are UTF-16, the same units as NSTextView selections.
public struct MailStyleSpan: Codable, Sendable, Equatable {
    public let range: NSRange
    public let style: MailTextStyle
    public init(range: NSRange, style: MailTextStyle) { self.range = range; self.style = style }

    static func validate(_ spans: [Self], text: String) throws {
        guard spans.count <= 16_384 else { throw MailFormattingError.invalid }
        let string = text as NSString
        func boundary(_ offset: Int) -> Bool {
            offset == string.length || !(0xDC00...0xDFFF).contains(string.character(at: offset))
        }
        var end = 0
        for span in spans {
            let range = span.range
            guard !span.style.isEmpty, span.style.rawValue <= 7,
                  range.location >= end, range.location <= string.length, range.length > 0,
                  range.length <= string.length - range.location,
                  boundary(range.location), boundary(NSMaxRange(range)) else { throw MailFormattingError.invalid }
            end = NSMaxRange(range)
        }
    }

    static func decode(_ data: Data?, text: String) throws -> [Self] {
        guard let data else { return [] }
        guard data.count <= 2 * 1024 * 1024 else { throw MailFormattingError.invalid }
        let spans = try JSONDecoder().decode([Self].self, from: data)
        try validate(spans, text: text)
        return spans
    }
}

public enum MailFormattingError: Error { case invalid }

extension MailDraft {
    /// Build the alternative exclusively from escaped authored text and supported styles.
    func formattedHTML() throws -> String? {
        guard !bodyStyles.isEmpty else { return nil }
        try MailStyleSpan.validate(bodyStyles, text: bodyText)
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        let text = bodyText as NSString
        var end = 0, html = "<div style=\"white-space:pre-wrap\">"
        for span in bodyStyles {
            html += escaped(text.substring(with: NSRange(location: end, length: span.range.location - end)))
            var part = escaped(text.substring(with: span.range))
            if span.style.contains(.bold) { part = "<strong>" + part + "</strong>" }
            if span.style.contains(.italic) { part = "<em>" + part + "</em>" }
            if span.style.contains(.underline) { part = "<u>" + part + "</u>" }
            html += part
            end = NSMaxRange(span.range)
        }
        html += escaped(text.substring(from: end))
        if !quotedText.isEmpty { html += "<br><br>" + escaped(quotedText) }
        return html + "</div>"
    }
}
