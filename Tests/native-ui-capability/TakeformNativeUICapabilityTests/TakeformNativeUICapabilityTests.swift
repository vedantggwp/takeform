import XCTest

final class TakeformNativeUICapabilityTests: XCTestCase {
    func testCopiedF1WindowIsAccessibleAndCaptured() throws {
        let appURL = try copiedAppURL()
        let app = XCUIApplication(url: appURL)
        app.launchEnvironment = ["TAKEFORM_UI_CAPABILITY_PROBE": "1"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The copied F1 main window did not appear")

        let title = app.staticTexts["takeform-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "F1 title accessibility identifier was not exposed")
        XCTAssertEqual(title.label, "Takeform")

        XCTAssertTrue(
            app.staticTexts["Native development foundation"].waitForExistence(timeout: 5),
            "Known F1 foundation text was not exposed through accessibility"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "f1-main-window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func copiedAppURL() throws -> URL {
        guard let rawPath = ProcessInfo.processInfo.environment["TAKEFORM_UI_PROBE_APP"], !rawPath.isEmpty else {
            throw ProbeConfigurationError.missingCopiedAppPath
        }

        let url = URL(fileURLWithPath: rawPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProbeConfigurationError.copiedAppMissing(url.path)
        }
        return url
    }
}

private enum ProbeConfigurationError: LocalizedError {
    case missingCopiedAppPath
    case copiedAppMissing(String)

    var errorDescription: String? {
        switch self {
        case .missingCopiedAppPath:
            return "TAKEFORM_UI_PROBE_APP must name the copied F1 app bundle"
        case .copiedAppMissing(let path):
            return "Copied F1 app bundle is missing at \(path)"
        }
    }
}
