import Foundation
import Security

/// One JSON value kept in the keychain as a generic password, under the app's
/// bundle identifier, so each app keeps its own.
nonisolated struct KeychainItem<Value: Codable>: Sendable {
    let account: String

    private var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "Cohesion",
            kSecAttrAccount: account,
        ]
    }

    func load() -> Value? {
        var query = query
        query[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        remove()
        var item = query
        item[kSecValueData] = try? JSONEncoder().encode(value)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
