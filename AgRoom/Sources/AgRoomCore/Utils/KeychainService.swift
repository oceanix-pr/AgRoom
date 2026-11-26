import Foundation
import Security

// MARK: - Keychain Service

/// Keychain 存储服务：API Key 等敏感数据的唯一落盘位置。
/// 不存 UserDefaults / 数据库明文；accessibility 使用 afterFirstUnlock。
public enum KeychainService {

    public static let service = "com.agroom.app"

    public enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
                return "Keychain operation failed: \(message) (\(status))"
            }
        }
    }

    // MARK: - LLM Provider API Keys

    /// 保存 LLM 提供者的 API Key；空 key 视为删除
    public static func saveAPIKey(_ key: String, for providerId: UUID) throws {
        if key.isEmpty {
            try deleteAPIKey(for: providerId)
            return
        }
        try setString(key, account: apiKeyAccount(for: providerId))
    }

    public static func loadAPIKey(for providerId: UUID) -> String? {
        getString(account: apiKeyAccount(for: providerId))
    }

    public static func deleteAPIKey(for providerId: UUID) throws {
        try delete(account: apiKeyAccount(for: providerId))
    }

    private static func apiKeyAccount(for providerId: UUID) -> String {
        "llm.provider.apikey.\(providerId.uuidString)"
    }

    // MARK: - Mail Account Passwords

    /// 保存邮箱账号密码/授权码；空值视为删除。
    /// account 名带空间前缀（`mail.account.password.<space>.<id>`），
    /// 确保生活空间与工作空间同 UUID 也不撞键。
    public static func saveMailPassword(_ password: String, space: String, accountId: UUID) throws {
        if password.isEmpty {
            try deleteMailPassword(space: space, accountId: accountId)
            return
        }
        try setString(password, account: mailPasswordAccount(space: space, accountId: accountId))
    }

    public static func loadMailPassword(space: String, accountId: UUID) -> String? {
        getString(account: mailPasswordAccount(space: space, accountId: accountId))
    }

    public static func deleteMailPassword(space: String, accountId: UUID) throws {
        try delete(account: mailPasswordAccount(space: space, accountId: accountId))
    }

    private static func mailPasswordAccount(space: String, accountId: UUID) -> String {
        "mail.account.password.\(space).\(accountId.uuidString)"
    }

    // MARK: - Generic String Storage

    /// Creation is insert-only: an unavailable or concurrently created key must never be replaced.
    static func loadOrCreateSigningKey(account: String, createIfMissing: Bool = true) throws -> Data {
        func read() throws -> Data? {
            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
                throw KeychainError.unexpectedStatus(status == errSecSuccess ? errSecDecode : status)
            }
            return data
        }
        if let existing = try read() { return existing }
        guard createIfMissing else { throw KeychainError.unexpectedStatus(errSecItemNotFound) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(randomStatus) }
        let key = Data(bytes)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = key
        query[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read() { return existing }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return key
    }

    public static func setString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }

        // 先删旧条目再新建：条目的 ACL 绑定“创建它的代码签名”。
        // 旧条目可能由 ad-hoc 构建创建（CDHash 漂移），删旧建新后
        // 条目归属当前稳定签名，后续读取不再弹钥匙串密码框。
        let deleteStatus = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            HubLogger.shared.warning("Keychain delete old entry failed (\(deleteStatus)); will try update path")
        }

        var query = baseQuery(account: account)
        query[kSecValueData as String] = data

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // 旧条目删除受阻时退回更新路径（ACL 不变，读取时可能仍需一次授权）
            let attributes: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public static func getString(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecSuccess else {
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if status != errSecItemNotFound {
            // 常见于 ad-hoc 旧构建创建的条目：ACL 不匹配新签名 → 需要授权。
            // 明确记日志指引用户到设置页重新保存 API Key（重建条目归属新签名）
            HubLogger.shared.warning(
                "Keychain read failed (status \(status)). "
                + "The entry was likely created by an old ad-hoc build. "
                + "Please re-save the API key in Settings to recreate it under the current signature."
            )
        }
        return nil
    }

    public static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}
