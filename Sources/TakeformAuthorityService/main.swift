import Foundation
import Darwin
import TakeformAuthority
import TakeformCore

func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 5, arguments[0] == "execute", let grantID = UUID(uuidString: arguments[3]) else {
    fputs("usage: TakeformAuthorityService execute <package> <runtime> <grant-id> <request-json>\n", stderr)
    exit(2)
}

let authority = try ProjectAuthority(packageURL: URL(fileURLWithPath: arguments[1]), runtimeURL: URL(fileURLWithPath: arguments[2]))
let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: Data(arguments[4].utf8))
try output(authority.execute(envelope, grantID: grantID))
