import Foundation

public struct SemanticVersion: Codable, Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public static func parseSwiftVersion(_ output: String) -> SemanticVersion? {
        guard let range = output.range(of: "Swift version ") else { return nil }
        let token = output[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first ?? ""
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3,
              let major = Int(parts[0]), let minor = Int(parts[1]),
              parts.count == 2 || Int(parts[2]) != nil else { return nil }
        return SemanticVersion(major, minor, parts.count == 3 ? Int(parts[2])! : 0)
    }
}

public enum ToolRequirementKind: String, Codable, Sendable {
    case executable
    case swiftVersion
}

public struct ToolRequirement: Codable, Equatable, Sendable {
    public let command: String
    public let kind: ToolRequirementKind
    public let minimumVersion: SemanticVersion?
    public let optional: Bool

    public init(command: String, kind: ToolRequirementKind = .executable, minimumVersion: SemanticVersion? = nil, optional: Bool = false) {
        self.command = command
        self.kind = kind
        self.minimumVersion = minimumVersion
        self.optional = optional
    }
}

public struct ToolProbe: Equatable, Sendable {
    public let path: String?
    public let versionOutput: String?

    public init(path: String?, versionOutput: String? = nil) {
        self.path = path
        self.versionOutput = versionOutput
    }
}

public enum ToolState: String, Codable, Sendable {
    case available
    case incompatible
    case malformedVersion
    case missing
}

public struct ToolCheck: Codable, Equatable, Sendable {
    public let command: String
    public let optional: Bool
    public let path: String?
    public let state: ToolState
    public let version: SemanticVersion?
    public let remedy: String
}

public struct DoctorReport: Codable, Sendable {
    public let checks: [ToolCheck]

    public var isReady: Bool {
        checks.allSatisfy { $0.optional || $0.state == .available }
    }
}

public enum ToolDoctor {
    public static let requirements = [
        ToolRequirement(command: "swift", kind: .swiftVersion, minimumVersion: SemanticVersion(6, 3)),
        ToolRequirement(command: "codesign"),
        ToolRequirement(command: "plutil"),
        ToolRequirement(command: "ditto"),
        ToolRequirement(command: "ffmpeg", optional: true)
    ]

    public static func evaluate(_ requirements: [ToolRequirement] = ToolDoctor.requirements, probe: (ToolRequirement) -> ToolProbe) -> DoctorReport {
        DoctorReport(checks: requirements.map { requirement in
            let result = probe(requirement)
            guard result.path != nil else {
                let remedy = requirement.optional
                    ? "\(requirement.command) is optional for this foundation and required only by later media work."
                    : "Install or select \(requirement.command) before building Takeform."
                return ToolCheck(command: requirement.command, optional: requirement.optional, path: nil, state: .missing, version: nil, remedy: remedy)
            }
            guard requirement.kind == .swiftVersion else {
                return ToolCheck(command: requirement.command, optional: requirement.optional, path: result.path, state: .available, version: nil, remedy: "")
            }
            guard let output = result.versionOutput, let version = SemanticVersion.parseSwiftVersion(output) else {
                return ToolCheck(command: requirement.command, optional: requirement.optional, path: result.path, state: .malformedVersion, version: nil, remedy: "Use a Swift 6.3 toolchain; the selected swift executable did not report a parseable version.")
            }
            guard let minimum = requirement.minimumVersion else {
                return ToolCheck(command: requirement.command, optional: requirement.optional, path: result.path, state: .malformedVersion, version: version, remedy: "The Swift requirement is missing its minimum version.")
            }
            guard version >= minimum else {
                return ToolCheck(command: requirement.command, optional: requirement.optional, path: result.path, state: .incompatible, version: version, remedy: "Use Swift \(minimum.major).\(minimum.minor) or newer for this checkout.")
            }
            return ToolCheck(command: requirement.command, optional: requirement.optional, path: result.path, state: .available, version: version, remedy: "")
        })
    }
}
