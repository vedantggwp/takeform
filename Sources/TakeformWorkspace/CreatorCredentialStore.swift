import Foundation
import Security

/// Native-app credential used only to authenticate the app's UDS creator session.
/// It is never a CLI pairing token and is never written into a project package.
public enum CreatorCredentialStore {
    public static let service = "com.takeform.app.creator-session"
    public static let account = "creator-session-v1"
    public static let accessGroup = "com.takeform.app.creator"

    private static func query(returnData: Bool) throws -> [CFString: Any] {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
              groups.contains(accessGroup) else {
            throw WorkspaceFailure.creatorAuthorizationRequired
        }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: accessGroup,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]
        if returnData { query[kSecReturnData] = true }
        return query
    }

    public static func loadOrCreate() throws -> Data {
        let readQuery = try query(returnData: true)
        var value: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data, !data.isEmpty { return data }
        guard status == errSecItemNotFound else { throw WorkspaceFailure.creatorAuthorizationRequired }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WorkspaceFailure.creatorAuthorizationRequired }
        let credential = Data(bytes)
        var addition = try query(returnData: false)
        addition[kSecValueData] = credential
        addition[kSecAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw WorkspaceFailure.creatorAuthorizationRequired }
        return credential
    }

    public static func rotate() throws {
        let status = SecItemDelete(try query(returnData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkspaceFailure.creatorAuthorizationRequired }
    }
}
