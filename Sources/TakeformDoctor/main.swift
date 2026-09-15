import Foundation
import TakeformSupport
import Darwin

private func executablePath(named command: String, path: String) -> String? {
    if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
    return path.split(separator: ":").map(String.init).first { directory in
        FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: directory).appendingPathComponent(command).path)
    }.map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
}

private func swiftVersionOutput(at path: String) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
        process.waitUntilExit()
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    } catch {
        return nil
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

@main
enum TakeformDoctor {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments {
            case ["doctor"]:
                let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
                let report = ToolDoctor.evaluate { requirement in
                    let path = executablePath(named: requirement.command, path: searchPath)
                    return ToolProbe(path: path, versionOutput: path.flatMap { requirement.kind == .swiftVersion ? swiftVersionOutput(at: $0) : nil })
                }
                try printJSON(report)
                if !report.isReady { exit(1) }
            case ["identity"]:
                let identity = ProductIdentity.declared
                print("bundleIdentifier=\(identity.bundleIdentifier)")
                print("displayName=\(identity.displayName)")
                print("developmentVersion=\(identity.developmentVersion)")
                print("minimumSystemVersion=\(identity.minimumSystemVersion)")
            case let items where items.count == 2 && items[0] == "verify-identity":
                let plistPath = items[1]
                guard let dictionary = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
                    fputs("Could not read Info.plist at \(plistPath)\n", stderr)
                    exit(2)
                }
                let values = dictionary.compactMapValues { $0 as? String }
                let issues = BundleIdentity.validate(values)
                try printJSON(issues)
                if !issues.isEmpty { exit(1) }
            default:
                fputs("usage: TakeformDoctor doctor | identity | verify-identity <Info.plist>\n", stderr)
                exit(2)
            }
        } catch {
            fputs("TakeformDoctor: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
