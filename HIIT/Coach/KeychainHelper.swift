import Foundation
import Security

/// Minimal Keychain wrapper for the (optional) AI-coach API keys — one entry
/// per provider, and a key never leaves the device except in requests the
/// user explicitly triggers. The account name is the provider's raw value,
/// so keys saved before multi-provider support (account "anthropic") keep
/// working unchanged.
enum KeychainHelper {
    private static let service = "com.scootsy.HIIT.apikey"

    private static func query(for provider: CoachProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }

    /// Returns false when the write failed, so the UI can say so instead of
    /// showing "Saved ✓" for a key that never landed. Updates in place rather
    /// than delete-then-add: the old version destroyed the existing key first,
    /// so a failed add left the user with no key at all.
    @discardableResult
    static func save(_ value: String, provider: CoachProvider) -> Bool {
        let query = query(for: provider)
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return true
        }
        let payload: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, payload as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // ThisDeviceOnly keeps the key out of device backups and migrations.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load(provider: CoachProvider) -> String? {
        var query = query(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
