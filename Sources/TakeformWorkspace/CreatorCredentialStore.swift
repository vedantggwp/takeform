import Foundation
import Security

/// Native-app credential used only to authenticate the app's UDS creator session.
/// It is never a CLI pairing token and is never written into a project package.
///
/// The developer build uses the macOS file-keychain ACL model. It deliberately does
/// not claim a data-protection keychain access group, which would require a provisioned
/// signing profile. The UDS service verifies the peer's code identity separately.
public enum CreatorCredentialStore {
    public static let service = "com.takeform.app.creator-session"
    public static let account = "creator-session-v1"

    private static var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]
    }

    private static func creatorAccess() throws -> SecAccess {
        guard let executable = Bundle.main.executablePath else { throw WorkspaceFailure.creatorAuthorizationRequired }
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(executable, &trusted) == errSecSuccess, let trusted else {
            throw WorkspaceFailure.creatorAuthorizationRequired
        }
        var access: SecAccess?
        guard SecAccessCreate("Takeform creator session" as CFString, [trusted] as CFArray, &access) == errSecSuccess, let access else {
            throw WorkspaceFailure.creatorAuthorizationRequired
        }
        return access
    }

    public static func loadOrCreate() throws -> Data {
        var readQuery = query; readQuery[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data, !data.isEmpty { return data }
        guard status == errSecItemNotFound else { throw WorkspaceFailure.creatorAuthorizationRequired }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WorkspaceFailure.creatorAuthorizationRequired }
        var addition = query
        addition[kSecValueData] = Data(bytes)
        addition[kSecAttrAccess] = try creatorAccess()
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw WorkspaceFailure.creatorAuthorizationRequired }
        return Data(bytes)
    }

    public static func rotate() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkspaceFailure.creatorAuthorizationRequired }
    }
}
