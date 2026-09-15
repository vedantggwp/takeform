import Foundation

public struct ProductIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let developmentVersion: String
    public let displayName: String
    public let minimumSystemVersion: String

    public init(bundleIdentifier: String, developmentVersion: String, displayName: String, minimumSystemVersion: String) {
        self.bundleIdentifier = bundleIdentifier
        self.developmentVersion = developmentVersion
        self.displayName = displayName
        self.minimumSystemVersion = minimumSystemVersion
    }

    public static let declared = ProductIdentity(
        bundleIdentifier: "com.takeform.app",
        developmentVersion: "0.1.0-dev",
        displayName: "Takeform",
        minimumSystemVersion: "14.0"
    )
}

public struct BundleIdentityIssue: Codable, Equatable, Sendable {
    public let key: String
    public let expected: String
    public let actual: String?

    public init(key: String, expected: String, actual: String?) {
        self.key = key
        self.expected = expected
        self.actual = actual
    }
}

public enum BundleIdentity {
    public static func values(from bundle: Bundle) -> [String: String] {
        bundle.infoDictionary?.compactMapValues { $0 as? String } ?? [:]
    }

    public static func validate(_ values: [String: String], against expected: ProductIdentity = .declared) -> [BundleIdentityIssue] {
        [
            ("CFBundleIdentifier", expected.bundleIdentifier),
            ("CFBundleDisplayName", expected.displayName),
            ("TakeformDevelopmentVersion", expected.developmentVersion),
            ("LSMinimumSystemVersion", expected.minimumSystemVersion)
        ].compactMap { key, expectedValue in
            let actual = values[key]
            return actual == expectedValue ? nil : BundleIdentityIssue(key: key, expected: expectedValue, actual: actual)
        }
    }
}
