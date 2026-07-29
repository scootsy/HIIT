import Foundation
import Security

/// Minimal Keychain wrapper for the (optional) Anthropic API key — the key
/// never leaves the device except in requests the user explicitly triggers.
enum KeychainHelper {
    private static let service = "com.scootsy.HIIT.apikey"
    private static let account = "anthropic"

    /// Returns false when the write failed, so the UI can say so instead of
    /// showing "Saved ✓" for a key that never landed.
    @discardableResult
    static func save(_ value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // ThisDeviceOnly keeps the key out of device backups and migrations.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
