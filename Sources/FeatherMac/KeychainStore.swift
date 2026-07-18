import Foundation
import Security

/// p12 密码的存储位置。
///
/// 密码曾经和它保护的 p12 一起放在应用数据目录里——锁和钥匙挂在同一个钩子上，
/// PKCS#12 的加密形同虚设。改存钥匙串后，拿到 `cert.p12` 的人没有密码，
/// 面对的是一坨用随机强口令 AES-256 加密的数据。
///
/// 用的是 macOS 传统的文件钥匙串（不设 `kSecUseDataProtectionKeychain`）：
/// 数据保护钥匙串需要 keychain-access-group entitlement，而本应用没有签这类
/// entitlement。传统钥匙串按代码签名身份授权，正式签名的构建可以静默读写自己写入的条目。
enum KeychainStore {
    private static let service = "FeatherMac"

    enum KeychainError: LocalizedError {
        case operationFailed(action: String, status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .operationFailed(let action, let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return L10n.format("Keychain %@ failed: %@", action, detail)
            }
        }
    }

    /// 写入或更新某张证书的 p12 密码。
    static func save(password: String, for certificateID: UUID) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: certificateID.uuidString
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.operationFailed(action: "update", status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = "FeatherMac p12 password"
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.operationFailed(action: "add", status: addStatus)
        }
    }

    /// 读取密码。条目不存在返回 nil；其他失败抛错，不与"不存在"混为一谈。
    static func password(for certificateID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: certificateID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(action: "read", status: status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// 删除证书时一并清掉，避免钥匙串里堆积无主条目。
    static func delete(for certificateID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: certificateID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
