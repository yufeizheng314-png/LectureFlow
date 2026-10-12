import Foundation
#if canImport(Security)
import Security
#endif

enum LFKeychain {
    private static let service = "LectureFlow.personal-cloud-key.v1"
    private static let account = "personal-api-key"

    static func save(_ key: String) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 8192, !clean.contains("\n"), !clean.contains("\r") else {
            throw LFError.invalid("API Key 不能为空或包含换行。")
        }
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(clean.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LFError.invalid("无法将 API Key 保存到钥匙串（\(status)）。") }
        #else
        throw LFError.invalid("此平台没有系统钥匙串。")
        #endif
    }

    static func read() throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw LFError.invalid("无法读取系统钥匙串中的 API Key（\(status)）。")
        }
        return key
        #else
        return nil
        #endif
    }

    static func delete() throws {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LFError.invalid("无法删除钥匙串中的 API Key（\(status)）。")
        }
        #endif
    }
}
