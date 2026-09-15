import Foundation
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
guard let service = ProcessInfo.processInfo.environment["TAKEFORM_AUTHORITY_SERVICE"], arguments.count == 5, arguments[0] == "execute" else {
    fputs("usage: TAKEFORM_AUTHORITY_SERVICE=/path/TakeformAuthorityService takeform execute <package> <runtime> <grant-id> <request-json>\n", stderr)
    exit(2)
}

var argv = ([service] + arguments).map { strdup($0) } + [nil]
defer { argv.forEach { free($0) } }
execv(service, &argv)
fputs("takeform: could not start authority service\n", stderr)
exit(1)
