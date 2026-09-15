import Foundation
import Darwin
import LocalAuthentication
import Security

let arguments = Array(CommandLine.arguments.dropFirst())

private final class KeychainResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private let completed = DispatchSemaphore(value: 0)

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
        completed.signal()
    }

    func wait() -> Value? {
        guard completed.wait(timeout: .now() + 3) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CredentialStoreRequest: @unchecked Sendable {
    let query: CFDictionary
    let addition: CFDictionary

    init(query: [CFString: Any], addition: [CFString: Any]) {
        self.query = query as CFDictionary
        self.addition = addition as CFDictionary
    }
}

private final class CredentialReadRequest: @unchecked Sendable {
    let query: CFDictionary

    init(query: [CFString: Any]) {
        self.query = query as CFDictionary
    }
}

func storeCredential(query: [CFString: Any], addition: [CFString: Any]) -> OSStatus? {
    let request = CredentialStoreRequest(query: query, addition: addition)
    let result = KeychainResult<OSStatus>()
    DispatchQueue.global(qos: .userInitiated).async {
        SecItemDelete(request.query)
        result.set(SecItemAdd(request.addition, nil))
    }
    return result.wait()
}

func removeCredential(query: [CFString: Any]) -> OSStatus? {
    let request = CredentialReadRequest(query: query)
    let result = KeychainResult<OSStatus>()
    DispatchQueue.global(qos: .userInitiated).async {
        result.set(SecItemDelete(request.query))
    }
    return result.wait()
}

func readCredential(query: [CFString: Any]) -> Data? {
    let request = CredentialReadRequest(query: query)
    let result = KeychainResult<Data?>()
    DispatchQueue.global(qos: .userInitiated).async {
        var value: CFTypeRef?
        guard SecItemCopyMatching(request.query, &value) == errSecSuccess else {
            result.set(nil)
            return
        }
        result.set(value as? Data)
    }
    return result.wait() ?? nil
}

func credentialQuery(for grantID: UUID) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.takeform.authority.cli", kSecAttrAccount: grantID.uuidString]
}

func bundledService() -> String? {
    let executable = CommandLine.arguments[0]
    let executableURL = executable.hasPrefix("/")
        ? URL(fileURLWithPath: executable)
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(executable)
    let service = executableURL.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("TakeformAuthorityService").path
    return FileManager.default.isExecutableFile(atPath: service) ? service : nil
}

switch arguments.first {
case "import-paired-credential":
    guard arguments.count == 2, let grantID = UUID(uuidString: arguments[1]), let token = readLine(), !token.isEmpty else {
        fputs("usage: takeform import-paired-credential <grant-id> < token-on-stdin\n", stderr)
        exit(2)
    }
    let query = credentialQuery(for: grantID)
    var addition = query
    addition[kSecValueData] = Data(token.utf8)
    guard storeCredential(query: query, addition: addition) == errSecSuccess else {
        fputs("takeform: could not store paired session credential\n", stderr)
        exit(3)
    }
    print("takeform: paired session credential stored")
case "forget-paired-credential":
    guard arguments.count == 2, let grantID = UUID(uuidString: arguments[1]) else {
        fputs("usage: takeform forget-paired-credential <grant-id>\n", stderr)
        exit(2)
    }
    _ = removeCredential(query: credentialQuery(for: grantID))
    print("takeform: paired session credential removed")
case "execute":
    guard arguments.count == 4, let service = bundledService() else {
        fputs("takeform: bundled authority service is unavailable\n", stderr)
        exit(1)
    }
    guard let grantID = UUID(uuidString: arguments[2]) else {
        fputs("usage: takeform execute <package> <grant-id> <request-json>\n", stderr)
        exit(2)
    }
    let authenticationContext = LAContext()
    authenticationContext.interactionNotAllowed = true
    var query = credentialQuery(for: grantID)
    query[kSecReturnData] = true
    query[kSecUseAuthenticationContext] = authenticationContext
    let credential = readCredential(query: query)
    guard let tokenData = credential else {
        fputs("takeform: paired session credential is unavailable\n", stderr)
        exit(3)
    }
    let process = Process()
    let input = Pipe()
    process.executableURL = URL(fileURLWithPath: service)
    process.arguments = arguments
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(tokenData)
    input.fileHandleForWriting.write(Data("\n".utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    exit(process.terminationStatus)
default:
    fputs("usage: takeform <import-paired-credential|forget-paired-credential|execute> ...\n", stderr)
    exit(2)
}
