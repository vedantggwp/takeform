import XCTest
@testable import TakeformSupport

final class TakeformSupportTests: XCTestCase {
    func testRequiredSwiftAcceptsCompatibleVersion() {
        let report = ToolDoctor.evaluate([
            ToolRequirement(command: "swift", kind: .swiftVersion, minimumVersion: SemanticVersion(6, 3))
        ]) { _ in ToolProbe(path: "/usr/bin/swift", versionOutput: "Apple Swift version 6.3.0 (swiftlang-6.3.0)") }

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.checks.first?.version, SemanticVersion(6, 3, 0))
    }

    func testMissingRequiredToolFailsWithActionableRemedy() {
        let report = ToolDoctor.evaluate([ToolRequirement(command: "codesign")]) { _ in ToolProbe(path: nil) }

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.checks.first?.state, .missing)
        XCTAssertTrue(report.checks.first?.remedy.contains("codesign") == true)
    }

    func testMalformedSwiftVersionIsRejected() {
        let report = ToolDoctor.evaluate([
            ToolRequirement(command: "swift", kind: .swiftVersion, minimumVersion: SemanticVersion(6, 3))
        ]) { _ in ToolProbe(path: "/usr/bin/swift", versionOutput: "Swift nightly") }

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.checks.first?.state, .malformedVersion)
    }

    func testIncompatibleSwiftVersionIsRejected() {
        let report = ToolDoctor.evaluate([
            ToolRequirement(command: "swift", kind: .swiftVersion, minimumVersion: SemanticVersion(6, 3))
        ]) { _ in ToolProbe(path: "/usr/bin/swift", versionOutput: "Swift version 6.2.4") }

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.checks.first?.state, .incompatible)
        XCTAssertEqual(report.checks.first?.version, SemanticVersion(6, 2, 4))
    }

    func testOptionalMediaToolDoesNotBlockBuildReadiness() {
        let report = ToolDoctor.evaluate([ToolRequirement(command: "ffmpeg", optional: true)]) { _ in ToolProbe(path: nil) }

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.checks.first?.state, .missing)
        XCTAssertTrue(report.checks.first?.remedy.contains("later media work") == true)
    }

    func testBundleIdentityReportsActualDisagreements() {
        let values = [
            "CFBundleIdentifier": "com.example.other",
            "CFBundleDisplayName": "Takeform",
            "TakeformDevelopmentVersion": "0.1.0-dev",
            "LSMinimumSystemVersion": "13.0"
        ]

        let issues = BundleIdentity.validate(values)

        XCTAssertEqual(issues, [
            BundleIdentityIssue(key: "CFBundleIdentifier", expected: "com.takeform.app", actual: "com.example.other"),
            BundleIdentityIssue(key: "LSMinimumSystemVersion", expected: "14.0", actual: "13.0")
        ])
    }
}
