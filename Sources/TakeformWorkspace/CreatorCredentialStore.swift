import Foundation
import Security

/// Native-app credential used only to authenticate the app's UDS creator session.
/// It is never a CLI pairing token and is never written into a project package.
public enum CreatorCredentialStore {
    private static let service = "com.takeform.app.creator-session"

    public static func loadOrCreate(account: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data, !data.isEmpty { return data }
        guard status == errSecItemNotFound else { throw WorkspaceFailure.creatorAuthorizationRequired }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WorkspaceFailure.creatorAuthorizationRequired }
        let credential = Data(bytes)
        let addition: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: credential,
            kSecAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw WorkspaceFailure.creatorAuthorizationRequired }
        return credential
    }

    public static func rotate(account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkspaceFailure.creatorAuthorizationRequired }
    }
}
