import Foundation
import Darwin
import LocalAuthentication
import Security
import TakeformAppAuthorityWire
import TakeformCore

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

private enum ExecuteFailurePhase: String, Error {
    case servicePeer = "service-peer"
    case credentialRead = "credential-read"
    case requestConnect = "request-connect"
    case requestPeer = "request-peer"
    case requestSend = "request-send"
    case response = "response"
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

func nonInteractiveContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
}

func bundledAppService() -> URL? {
    let executable = CommandLine.arguments[0]
    let executableURL = executable.hasPrefix("/")
        ? URL(fileURLWithPath: executable)
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(executable)
    let service = executableURL.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("TakeformAuthorityAppService")
    return FileManager.default.isExecutableFile(atPath: service.path) ? service : nil
}

switch arguments.first {
case "import-paired-credential":
    guard arguments.count == 2, let grantID = UUID(uuidString: arguments[1]), let token = readLine(), !token.isEmpty else {
        fputs("usage: takeform import-paired-credential <grant-id> < token-on-stdin\n", stderr)
        exit(2)
    }
    let query = credentialQuery(for: grantID)
    var addition = query
    let authenticationContext = nonInteractiveContext()
    addition[kSecUseAuthenticationContext] = authenticationContext
    var deletion = query
    deletion[kSecUseAuthenticationContext] = authenticationContext
    addition[kSecValueData] = Data(token.utf8)
    guard storeCredential(query: deletion, addition: addition) == errSecSuccess else {
        fputs("takeform: could not store paired session credential\n", stderr)
        exit(3)
    }
    print("takeform: paired session credential stored")
case "forget-paired-credential":
    guard arguments.count == 2, let grantID = UUID(uuidString: arguments[1]) else {
        fputs("usage: takeform forget-paired-credential <grant-id>\n", stderr)
        exit(2)
    }
    var query = credentialQuery(for: grantID)
    query[kSecUseAuthenticationContext] = nonInteractiveContext()
    _ = removeCredential(query: query)
    print("takeform: paired session credential removed")
case "execute":
    guard arguments.count == 4, let service = bundledAppService(), let grantID = UUID(uuidString: arguments[2]) else {
        fputs("usage: takeform execute <package> <grant-id> <request-json>\n", stderr)
        exit(1)
    }
    do {
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: Data(arguments[3].utf8))
        // Do not wake Keychain or expose a paired token until the fixed bundled
        // service is present and its peer identity has been verified.
        do { try AppAuthoritySocket.verifyService(expectedService: service) }
        catch { throw ExecuteFailurePhase.servicePeer }
        var query = credentialQuery(for: grantID)
        query[kSecReturnData] = true
        // A paired generic-password item must never trigger UI from the shipping
        // CLI. This is intentionally separate from the app's creator credential.
        query[kSecUseAuthenticationContext] = nonInteractiveContext()
        guard let tokenData = readCredential(query: query), let token = String(data: tokenData, encoding: .utf8), !token.isEmpty else { throw ExecuteFailurePhase.credentialRead }
        // Re-verify on the request connection so a peer replacement between the
        // availability check and token read cannot receive the token.
        let descriptor: Int32
        do { descriptor = try AppAuthoritySocket.connect() }
        catch { throw ExecuteFailurePhase.requestConnect }
        defer { Darwin.close(descriptor) }
        guard let requirement = AppAuthorityPeer.requirement(for: service), AppAuthorityPeer.matches(fd: descriptor, requirement: requirement) else {
            throw ExecuteFailurePhase.requestPeer
        }
        do { try AppAuthoritySocket.send(AppAuthorityRequest.pairedExecute(URL(fileURLWithPath: arguments[1]), envelope, grantID, token), descriptor) }
        catch { throw ExecuteFailurePhase.requestSend }
        let response: AppAuthorityResponse
        do { response = try AppAuthoritySocket.receive(AppAuthorityResponse.self, descriptor) }
        catch { throw ExecuteFailurePhase.response }
        guard case let .result(result) = response else {
            if case let .failure(failure) = response {
                fputs("takeform: authority response [\(failure)]\n", stderr)
            }
            throw ExecuteFailurePhase.response
        }
        let output = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch let phase as ExecuteFailurePhase {
        fputs("takeform: project authority is unavailable [\(phase.rawValue)]; open Takeform, then try again\n", stderr)
        exit(3)
    } catch {
        fputs("takeform: project authority is unavailable [response]; open Takeform, then try again\n", stderr)
        exit(3)
    }
case "import":
    guard arguments.count >= 4, let service = bundledAppService(), let grantID = UUID(uuidString: arguments[2]) else {
        fputs("usage: takeform import <package> <grant-id> <source>...\n", stderr)
        exit(1)
    }
    do {
        try AppAuthoritySocket.verifyService(expectedService: service)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var query = credentialQuery(for: grantID)
        query[kSecReturnData] = true
        query[kSecUseAuthenticationContext] = authenticationContext
        guard let tokenData = readCredential(query: query), let token = String(data: tokenData, encoding: .utf8), !token.isEmpty else {
            throw NSError(domain: "TakeformCLI", code: 2)
        }
        let sources = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
        guard case let .importOutcomes(outcomes) = try AppAuthoritySocket.verifiedRequest(.pairedImport(URL(fileURLWithPath: arguments[1]), sources, grantID, token), expectedService: service) else { throw NSError(domain: "TakeformCLI", code: 3) }
        FileHandle.standardOutput.write(try JSONEncoder().encode(outcomes))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fputs("takeform: project authority is unavailable; open Takeform, then try again\n", stderr)
        exit(3)
    }
default:
    fputs("usage: takeform <import-paired-credential|forget-paired-credential|execute|import> ...\n", stderr)
    exit(2)
}
