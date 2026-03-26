import Foundation
import Security

final class EntitlementCache {
    private static let account = "subscription-entitlement-cache"

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jboive.quickpreview") {
        self.service = "\(bundleIdentifier).commerce"
    }

    func load() -> EntitlementSnapshot? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let snapshot = try? decoder.decode(EntitlementSnapshot.self, from: data) else {
            return nil
        }

        return snapshot
    }

    @discardableResult
    func save(_ snapshot: EntitlementSnapshot) -> Bool {
        guard let data = try? encoder.encode(snapshot) else {
            return false
        }

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return true
        }

        guard addStatus == errSecDuplicateItem else {
            return false
        }

        let updateAttributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updateAttributes as CFDictionary)
        return updateStatus == errSecSuccess
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
    }
}
