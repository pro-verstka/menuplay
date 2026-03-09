import Foundation
import LocalAuthentication
import Security

enum KeychainStore {
    private static let service = "com.menuplay.app.spotify"

    static func string(for account: String, allowPrompt: Bool = true) -> String? {
        guard let data = data(for: account, allowPrompt: allowPrompt) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func data(for account: String, allowPrompt: Bool = true) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return data
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        set(Data(value.utf8), for: account)
    }

    @discardableResult
    static func set(_ value: Data, for account: String) -> Bool {
        var query = baseQuery(account: account)
        let attributes = [
            kSecValueData as String: value,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus != errSecItemNotFound {
            return false
        }

        query[kSecValueData as String] = value
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
