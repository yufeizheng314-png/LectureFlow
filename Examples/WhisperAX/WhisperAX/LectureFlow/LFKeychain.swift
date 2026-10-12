import Foundation
#if canImport(Security)
import Security
#endif

enum LFKeychain {
    private static let service = "LectureFlow.personal-cloud-key.v1"
    private static let account = "personal-api-key"

    private struct BoundCredential: Codable {
        let endpoint: String
        let key: String
    }

    static func credentialData(_ key: String, for endpoint: URL) throws -> Data {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 8192, !clean.contains("\n"), !clean.contains("\r") else {
            throw LFError.invalid("API Key 不能为空或包含换行。")
        }
        try LFCloudConfiguration(endpoint: endpoint, model: "credential-validation").validate()
        return try JSONEncoder().encode(BoundCredential(endpoint: endpoint.absoluteString, key: clean))
    }

    static func matchingKey(in data: Data, for endpoint: URL) -> String? {
        guard let record = try? JSONDecoder().decode(BoundCredential.self, from: data),
              record.endpoint == endpoint.absoluteString else { return nil }
        return record.key
    }

    static func save(_ key: String, for endpoint: URL) throws {
        let data = try credentialData(key, for: endpoint)
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
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

    static func read(for endpoint: URL) throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LFError.invalid("无法读取系统钥匙串中的 API Key（\(status)）。")
        }
        return matchingKey(in: data, for: endpoint)
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
