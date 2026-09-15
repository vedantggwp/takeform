import AppKit
import XCTest

final class TakeformNativeUICapabilityTests: XCTestCase {
    private let copiedAppPathKey = "TAKEFORM_UI_PROBE_APP"
    private let titleIdentifier = "takeform-title"
    private let foundationText = "Native development foundation"

    func testBrandedLaunchIsAccessibleAndCaptured() throws {
        let app = try launchReady()
        defer { app.terminate() }

        let title = app.staticTexts[titleIdentifier]
        XCTAssertEqual(title.label, "Takeform")
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
        capture(app, named: "f1-01-branded-launch")
    }

    func testAboutIdentityUsesNativeMenu() throws {
        let app = try launchReady()
        defer { app.terminate() }

        let appMenu = app.menuBars.menuItems["Takeform"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(appMenu.isHittable)
        appMenu.click()

        let about = app.menuItems["About Takeform"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()

        let aboutWindow = app.windows.matching(NSPredicate(format: "title == %@", "About Takeform")).firstMatch
        XCTAssertTrue(aboutWindow.waitForExistence(timeout: 5), "Native About window did not appear")
        XCTAssertTrue(aboutWindow.staticTexts["Takeform"].exists)
        XCTAssertTrue(
            aboutWindow.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "0.1.0")).firstMatch.exists,
            "Native About window did not expose its version"
        )
        capture(app, named: "f1-04-about")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(of: aboutWindow, timeout: 5), "Native About window did not dismiss")
        XCTAssertTrue(app.windows.firstMatch.isHittable)
    }

    func testSettingsButtonAndKeyboardReturnToMainWindow() throws {
        let app = try launchReady()
        defer { app.terminate() }

        app.buttons["open-settings"].click()
        assertSettingsSurface(in: app)
        capture(app, named: "f1-05-settings-button")
        closeSettings(in: app)

        app.typeKey(",", modifierFlags: .command)
        assertSettingsSurface(in: app)
        capture(app, named: "f1-05-settings-keyboard")
        closeSettings(in: app)

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists)
        XCTAssertTrue(mainWindow.isHittable)
        XCTAssertTrue(app.staticTexts[foundationText].exists)
    }

    func testResizePreservesReachableNativeControls() throws {
        let app = try launchReady()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        let before = window.frame
        XCTAssertGreaterThanOrEqual(before.width, 1024)
        XCTAssertGreaterThanOrEqual(before.height, 700)

        let leftEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
        let narrower = leftEdge.withOffset(CGVector(dx: 180, dy: 0))
        leftEdge.press(forDuration: 0.2, thenDragTo: narrower)

        XCTAssertTrue(waitForNarrowerFrame(of: window, than: before, timeout: 5), "Window frame did not change after the native edge drag")
        let after = window.frame
        XCTAssertLessThan(after.width, before.width - 40)
        XCTAssertGreaterThanOrEqual(after.width, 720)
        XCTAssertGreaterThanOrEqual(after.height, 500)
        XCTAssertTrue(app.staticTexts[titleIdentifier].isHittable)
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
        XCTAssertTrue(app.staticTexts[foundationText].isHittable)
        capture(app, named: "f1-06-resized")
    }

    func testLightAndDarkAppearanceRemainLegible() throws {
        let light = try launchReady(arguments: ["-AppleInterfaceStyle", "Light"])
        let lightShot = capture(light, named: "f1-07-light")
        let lightLuminance = try sampledLuminance(lightShot)
        light.terminate()
        XCTAssertTrue(light.wait(for: .notRunning, timeout: 5))

        let dark = try launchReady(arguments: ["-AppleInterfaceStyle", "Dark"])
        defer { dark.terminate() }
        let darkShot = capture(dark, named: "f1-08-dark")
        let darkLuminance = try sampledLuminance(darkShot)

        XCTAssertGreaterThan(lightLuminance - darkLuminance, 0.2, "Process-local dark appearance did not produce a distinct readable surface")
        XCTAssertTrue(dark.staticTexts[titleIdentifier].isHittable)
        XCTAssertTrue(dark.staticTexts[foundationText].isHittable)
        XCTAssertTrue(dark.buttons["open-settings"].isHittable)
    }

    func testQuitRelaunchAndWarmReadyLatency() throws {
        let app = try launchReady()
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Copied app did not quit")

        let startedAt = ProcessInfo.processInfo.systemUptime
        app.launch()
        try assertReady(app)
        let readyAt = ProcessInfo.processInfo.systemUptime
        let elapsed = readyAt - startedAt
        attach("{\"warmLaunchStartedAt\":\(startedAt),\"visibleReadyAt\":\(readyAt),\"elapsedSeconds\":\(elapsed)}", named: "f1-10-warm-ready")
        XCTAssertLessThanOrEqual(elapsed, 3, "Warm copied-app visible-ready latency exceeded three seconds")
        capture(app, named: "f1-10-relaunch")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    private func launchReady(arguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication(url: try copiedAppURL())
        app.launchEnvironment = ["TAKEFORM_UI_CAPABILITY_PROBE": "1"]
        app.launchArguments = arguments
        app.launch()
        try assertReady(app)
        return app
    }

    private func assertReady(_ app: XCUIApplication) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The copied F1 main window did not appear")

        let title = app.staticTexts[titleIdentifier]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "F1 title accessibility identifier was not exposed")
        XCTAssertEqual(title.label, "Takeform")

        XCTAssertTrue(
            app.staticTexts[foundationText].waitForExistence(timeout: 5),
            "Known F1 foundation text was not exposed through accessibility"
        )
    }

    private func assertSettingsSurface(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["No application preferences are available in this development foundation."].waitForExistence(timeout: 5)
        )
    }

    private func closeSettings(in app: XCUIApplication) {
        let settingsMarker = app.staticTexts["No application preferences are available in this development foundation."]
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(of: settingsMarker, timeout: 5), "Settings surface did not close")
        XCTAssertTrue(app.staticTexts[foundationText].isHittable)
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
    }

    @discardableResult
    private func capture(_ app: XCUIApplication, named name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    private func attach(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sampledLuminance(_ screenshot: XCUIScreenshot) throws -> CGFloat {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
        let x = Int(CGFloat(bitmap.pixelsWide) * 0.85)
        let y = Int(CGFloat(bitmap.pixelsHigh) * 0.55)
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return (0.2126 * color.redComponent) + (0.7152 * color.greenComponent) + (0.0722 * color.blueComponent)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForNarrowerFrame(of window: XCUIElement, than before: CGRect, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in
            window.frame.width < before.width - 40
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: window)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func copiedAppURL() throws -> URL {
        guard let rawPath = ProcessInfo.processInfo.environment[copiedAppPathKey], !rawPath.isEmpty else {
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
