import Foundation
import Security

public enum AutomationCredential {
    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "local-connection"]
    }
    public static func loadOrCreate(service: String = "app.jingxu.desktop.mcp") throws -> String {
        var lookup = query(service)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), value.count >= 32 { return value }
        guard status == errSecItemNotFound else { throw error(status) }
        return try reset(service: service)
    }
    public static func reset(service: String = "app.jingxu.desktop.mcp") throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw error(status) }
        let value = Data(bytes).base64EncodedString(), data = Data(value.utf8)
        let update = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query(service)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw error(added) }
        } else if update != errSecSuccess { throw error(update) }
        return value
    }
    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法访问 AI 连接密钥（Keychain \(status)）"])
    }
}
