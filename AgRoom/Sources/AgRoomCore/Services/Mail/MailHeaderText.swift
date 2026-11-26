import Foundation
import MimeFoundation

extension MailAddress {
    public var composeText: String {
        guard !name.isEmpty else { return address }
        return MailboxAddress(name: name, address: address).description
    }

    /// Paste from a mail client or a Chinese address list. Preserve invalid entries for correction.
    public static func parseComposeList(_ text: String) -> [MailAddress] {
        var tokens: [String] = [], token = "", quoted = false, escaped = false
        for character in text {
            if character.isNewline || (!quoted && ",;，；、".contains(character)) {
                tokens.append(token); token = ""; quoted = false; escaped = false
                continue
            }
            token.append(character)
            if escaped { escaped = false }
            else if quoted && character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
        }
        tokens.append(token)
        return tokens.compactMap {
            let raw = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if let box = (try? InternetAddress.parsed(from: raw)) as? MailboxAddress {
                return MailAddress(name: box.name ?? "", address: box.address)
            }
            return MailAddress(name: "", address: raw)
        }
    }
}

// MARK: - Mail Header Text

/// 邮件头部文本解码（RFC 2047 编码字）。
///
/// IMAP `ENVELOPE` 返回的 `Subject` 与地址显示名是**原始值**，可能含
/// `=?UTF-8?B?...?=` / `=?GBK?Q?...?=` 形式的编码字，直接展示就是乱码。
/// 上游 `ImapEnvelope` / `ImapAddress` 不做解码，因此在本域内统一处理：
/// 协议适配层写入时解码一次；读取映射（`MailMessageRow.toMessage`）再解码一次，
/// 把修复前已按原始值入库的历史行也一并纠正。解码是幂等的——非编码文本原样
/// 返回——所以重复调用安全。
///
/// 本文件与 `MailFoundationAdapter` 是邮件域内仅有的两处 MimeFoundation 使用点。
enum MailHeaderText {

    /// 解码 RFC 2047 编码字，并展开折行的头部；非编码文本原样返回。
    ///
    /// `MimeFoundation.Header.value` 会按 RFC 2047 解码，`setRawValue` 写入原始字节。
    /// 上游 `setRawValue` 要求以换行结尾（原始头部行的约定），故补一个 `\n`。
    static func decoded(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        let header = Header(.subject, value: "")
        do { try header.setRawValue(Array((raw + "\n").utf8)) } catch { return raw }
        return header.value
    }

    /// 解码地址列表中的显示名（主题与显示名同规则）。
    static func decoded(_ addresses: [MailAddress]) -> [MailAddress] {
        addresses.map { MailAddress(name: decoded($0.name), address: $0.address) }
    }
}
