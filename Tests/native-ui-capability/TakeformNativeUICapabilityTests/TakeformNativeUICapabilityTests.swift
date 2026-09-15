import AppKit
import XCTest

@MainActor
final class TakeformNativeUICapabilityTests: XCTestCase {
    private let copiedAppPathKey = "TAKEFORM_UI_PROBE_APP"
    private let titleIdentifier = "takeform-title"
    private let foundationText = "Native development foundation"
    private let settingsStatusText = "Appearance is the only application preference available in this development foundation."
    private let appearanceLabelText = "Appearance"

    func testBrandedLaunchIsAccessibleAndCaptured() throws {
        let app = try launchReady()
        defer { finishCase(app, named: "f1-01-branded-launch-final") }

        let title = app.staticTexts[titleIdentifier]
        assertAccessibleTitle(title)
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
        capture(app, named: "f1-01-branded-launch")
    }

    func testAboutIdentityUsesNativeMenu() throws {
        let app = try launchReady()
        defer { finishCase(app, named: "f1-04-about-final") }

        let appMenu = app.menuBars.menuBarItems["Takeform"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(appMenu.isHittable)
        appMenu.click()

        let about = app.menuItems["About Takeform"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()

        let aboutDialog = aboutDialog(in: app)
        XCTAssertTrue(aboutDialog.waitForExistence(timeout: 5), "Native About dialog did not appear")
        XCTAssertTrue(
            aboutDialog.staticTexts.matching(NSPredicate(format: "value == %@", "Takeform")).firstMatch.exists
        )
        XCTAssertTrue(
            aboutDialog.staticTexts.matching(NSPredicate(format: "value == %@", "Version 0.1.0 (1)")).firstMatch.exists,
            "Native About dialog did not expose its version"
        )
        capture(app, named: "f1-04-about")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(of: aboutDialog, timeout: 5), "Native About dialog did not dismiss")
        XCTAssertTrue(app.windows.firstMatch.isHittable)
    }

    func testKeyboardMenuTraversalOpensNativeAbout() throws {
        let app = try launchReady()
        defer { finishCase(app, named: "f1-09-keyboard-menu-final") }

        app.typeKey(.F2, modifierFlags: .control)
        app.typeKey(.rightArrow, modifierFlags: [])
        let appMenu = app.menuBars.menuBarItems["Takeform"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        attach(app.debugDescription, named: "f1-09-menu-bar-focus-ax")

        app.typeKey(.return, modifierFlags: [])
        let about = app.menuItems["About Takeform"]
        XCTAssertTrue(about.waitForExistence(timeout: 5), "Keyboard activation did not open the Takeform menu")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(about.isHittable, "Down Arrow did not leave About Takeform available for keyboard activation")
        attach(app.debugDescription, named: "f1-09-about-menu-open-ax")
        capture(app, named: "f1-09-keyboard-menu")

        app.typeKey(.return, modifierFlags: [])
        let aboutDialog = aboutDialog(in: app)
        XCTAssertTrue(aboutDialog.waitForExistence(timeout: 5), "Keyboard menu activation did not open the native About dialog")
        capture(app, named: "f1-09-keyboard-about")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(of: aboutDialog, timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.isHittable)
    }

    func testSettingsButtonAndKeyboardReturnToMainWindow() throws {
        let app = try launchReady()
        defer { finishCase(app, named: "f1-05-settings-final") }

        app.buttons["open-settings"].click()
        assertSettingsSurface(in: app)
        selectAppearance("System", in: app)
        capture(app, named: "f1-05-settings-button")
        closeSettings(in: app)

        app.typeKey(",", modifierFlags: .command)
        assertSettingsSurface(in: app)
        selectAppearance("System", in: app)
        capture(app, named: "f1-05-settings-keyboard")
        closeSettings(in: app)

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists)
        XCTAssertTrue(mainWindow.isHittable)
        XCTAssertTrue(app.staticTexts[foundationText].exists)
    }

    func testResizePreservesReachableNativeControls() throws {
        let app = try launchReady()
        defer { finishCase(app, named: "f1-06-resized-final") }

        let window = app.windows.firstMatch
        let before = window.frame
        attachWindowGeometry(before, named: "f1-06-window-before")
        XCTAssertGreaterThanOrEqual(before.width, 1024)

        let outerBefore = try copiedAppOuterWindowBounds(for: try copiedAppURL())
        XCTAssertEqual(outerBefore.width, 1024, "The copied app outer window width must be 1024 points before resize")
        XCTAssertEqual(outerBefore.height, 700, "The copied app outer window height must be 700 points before resize")

        let leftEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
        let narrower = leftEdge.withOffset(CGVector(dx: 180, dy: 0))
        leftEdge.press(forDuration: 0.2, thenDragTo: narrower)

        XCTAssertTrue(waitForNarrowerFrame(of: window, than: before, timeout: 5), "Window frame did not change after the native edge drag")
        let after = window.frame
        attachWindowGeometry(after, named: "f1-06-window-after")
        XCTAssertLessThan(after.width, before.width - 40)
        XCTAssertGreaterThanOrEqual(after.width, 720)
        XCTAssertGreaterThanOrEqual(after.height, 500)
        XCTAssertTrue(app.staticTexts[titleIdentifier].isHittable)
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
        XCTAssertTrue(app.staticTexts[foundationText].isHittable)
        capture(app, named: "f1-06-resized")
    }

    func testLightAndDarkAppearanceRemainLegible() throws {
        let app = try launchReady()
        defer { finishCase(app, named: "f1-08-appearance-final") }

        app.buttons["open-settings"].click()
        assertSettingsSurface(in: app)
        let appearanceLabel = app.staticTexts[appearanceLabelText]
        XCTAssertTrue(appearanceLabel.waitForExistence(timeout: 5), "Appearance label was not exposed")
        selectAppearance("Light", in: app)
        let lightShot = capture(app, named: "f1-07-light")
        let lightContrast = try appearanceLabelContrast(
            in: app,
            in: lightShot,
            label: appearanceLabel,
            mode: "Light"
        )

        selectAppearance("Dark", in: app)
        let darkShot = capture(app, named: "f1-08-dark")
        let darkContrast = try appearanceLabelContrast(
            in: app,
            in: darkShot,
            label: appearanceLabel,
            mode: "Dark"
        )

        XCTAssertGreaterThanOrEqual(lightContrast, 4.5, "Light Appearance label contrast is below 4.5:1")
        XCTAssertGreaterThanOrEqual(darkContrast, 4.5, "Dark Appearance label contrast is below 4.5:1")
        XCTAssertTrue(app.staticTexts[titleIdentifier].isHittable)
        XCTAssertTrue(app.staticTexts[foundationText].isHittable)
        selectAppearance("System", in: app)
        closeSettings(in: app)
    }

    func testQuitRelaunchAndWarmReadyLatency() throws {
        let app = try launchReady()
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Copied app did not quit")

        let startedAt = ProcessInfo.processInfo.systemUptime
        app.launch()
        let launchReturnedAt = ProcessInfo.processInfo.systemUptime

        let readyWindow = app.windows
            .containing(.staticText, identifier: titleIdentifier)
            .containing(.staticText, identifier: foundationText)
            .firstMatch
        let readinessQueryStartedAt = ProcessInfo.processInfo.systemUptime
        let remainingReadyBudget = max(0, 3 - (readinessQueryStartedAt - startedAt))
        let readyWindowExists = readyWindow.waitForExistence(timeout: remainingReadyBudget)
        let readinessQueryReturnedAt = ProcessInfo.processInfo.systemUptime

        let title = app.staticTexts[titleIdentifier]
        let titleExistsAfterGate = title.exists
        let foundation = app.staticTexts[foundationText]
        let foundationExistsAfterGate = foundation.exists
        attachWarmReadyTiming(
            startedAt: startedAt,
            launchReturnedAt: launchReturnedAt,
            readinessQueryStartedAt: readinessQueryStartedAt,
            readinessQueryReturnedAt: readinessQueryReturnedAt,
            remainingReadyBudget: remainingReadyBudget,
            readyWindowExists: readyWindowExists,
            titleExistsAfterGate: titleExistsAfterGate,
            foundationExistsAfterGate: foundationExistsAfterGate
        )
        XCTAssertTrue(readyWindowExists, "The copied F1 main window did not expose both required accessibility sentinels within three seconds")
        XCTAssertTrue(titleExistsAfterGate, "F1 title accessibility identifier was not exposed after relaunch")
        assertAccessibleTitle(title)
        XCTAssertTrue(foundationExistsAfterGate, "Known F1 foundation text was not exposed after relaunch")
        XCTAssertLessThanOrEqual(readinessQueryReturnedAt - startedAt, 3, "Warm copied-app visible-ready latency exceeded three seconds")
        capture(app, named: "f1-10-relaunch")
        recordCaseEvidence(app, named: "f1-10-relaunch-final")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    private func launchReady() throws -> XCUIApplication {
        let app = XCUIApplication(url: try copiedAppURL())
        app.launchEnvironment = ["TAKEFORM_UI_CAPABILITY_PROBE": "1"]
        app.launch()
        try assertReady(app)
        return app
    }

    private func assertReady(_ app: XCUIApplication) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The copied F1 main window did not appear")

        let title = app.staticTexts[titleIdentifier]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "F1 title accessibility identifier was not exposed")
        assertAccessibleTitle(title)

        XCTAssertTrue(
            app.staticTexts[foundationText].waitForExistence(timeout: 5),
            "Known F1 foundation text was not exposed through accessibility"
        )
    }

    private func aboutDialog(in app: XCUIApplication) -> XCUIElement {
        app.dialogs
            .containing(NSPredicate(format: "elementType == %ld AND value == %@", XCUIElement.ElementType.staticText.rawValue, "Takeform"))
            .containing(NSPredicate(format: "elementType == %ld AND value == %@", XCUIElement.ElementType.staticText.rawValue, "Version 0.1.0 (1)"))
            .firstMatch
    }

    private func finishCase(_ app: XCUIApplication, named name: String) {
        recordCaseEvidence(app, named: name)
        app.terminate()
    }

    private func recordCaseEvidence(_ app: XCUIApplication, named name: String) {
        capture(app, named: name)
        attachTitleEvidence(in: app, named: "\(name)-accessibility")
    }

    private func assertAccessibleTitle(_ title: XCUIElement) {
        XCTAssertEqual(title.elementType, .staticText)
        XCTAssertEqual(title.value as? String, "Takeform")
    }

    private func attachTitleEvidence(in app: XCUIApplication, named name: String) {
        let title = app.staticTexts[titleIdentifier]
        let window = app.windows.firstMatch
        let evidence = """
        titleExists: \(title.exists)
        titleElementType: \(title.elementType.rawValue)
        titleIdentifier: \(title.identifier)
        titleLabel: \(title.label)
        titleValue: \(String(describing: title.value))
        xcuiWindowFrame: \(window.frame)
        titleDebugDescription:
        \(title.debugDescription)
        applicationDebugDescription:
        \(app.debugDescription)
        """
        attach(evidence, named: name)
    }

    private func attachWindowGeometry(_ frame: CGRect, named name: String) {
        attach("xcuiWindowFrame: \(frame)", named: name)
    }

    private func copiedAppOuterWindowBounds(for copiedBundleURL: URL) throws -> CGRect {
        let normalizedBundleURL = copiedBundleURL.standardizedFileURL
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.takeform.app")
            .first(where: { $0.bundleURL?.standardizedFileURL == normalizedBundleURL }) else {
            throw ProbeConfigurationError.copiedAppNotRunning(normalizedBundleURL.path)
        }

        let pid = runningApp.processIdentifier
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let candidates = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { entry -> WindowServerCandidate? in
                guard
                    let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                    ownerPID == pid,
                    let layer = entry[kCGWindowLayer as String] as? Int,
                    layer == normalLayer,
                    let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                    let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
                else {
                    return nil
                }

                let number = entry[kCGWindowNumber as String] as? Int ?? -1
                let alpha = entry[kCGWindowAlpha as String] as? Double ?? 0
                return WindowServerCandidate(number: number, layer: layer, alpha: alpha, bounds: bounds)
            }

        attach(
            """
            copiedBundleURL: \(normalizedBundleURL.path)
            copiedAppPID: \(pid)
            normalWindowLayer: \(normalLayer)
            candidates:
            \(candidates.map(\.description).joined(separator: "\n"))
            """,
            named: "f1-06-outer-window-candidates"
        )

        guard let largest = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            throw ProbeConfigurationError.copiedAppWindowNotFound(pid)
        }
        return largest.bounds
    }

    private func attachWarmReadyTiming(
        startedAt: TimeInterval,
        launchReturnedAt: TimeInterval,
        readinessQueryStartedAt: TimeInterval,
        readinessQueryReturnedAt: TimeInterval,
        remainingReadyBudget: TimeInterval,
        readyWindowExists: Bool,
        titleExistsAfterGate: Bool,
        foundationExistsAfterGate: Bool
    ) {
        let evidence = """
        warmLaunchStartedAt: \(startedAt)
        launchReturnedAt: \(launchReturnedAt)
        readinessQueryStartedAt: \(readinessQueryStartedAt)
        readinessQueryReturnedAt: \(readinessQueryReturnedAt)
        remainingReadyBudgetSeconds: \(remainingReadyBudget)
        singleQueryVisibleReadySeconds: \(readinessQueryReturnedAt - startedAt)
        singleQueryRoundTripSeconds: \(readinessQueryReturnedAt - readinessQueryStartedAt)
        readyWindowContainsBothSentinels: \(readyWindowExists)
        titleExistsAfterGate: \(titleExistsAfterGate)
        foundationExistsAfterGate: \(foundationExistsAfterGate)
        """
        attach(evidence, named: "f1-10-warm-ready")
    }

    private func assertSettingsSurface(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[settingsStatusText].waitForExistence(timeout: 5))
        XCTAssertTrue(app.popUpButtons["appearance-preference"].waitForExistence(timeout: 5))
    }

    private func closeSettings(in app: XCUIApplication) {
        let settingsMarker = app.staticTexts[settingsStatusText]
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(of: settingsMarker, timeout: 5), "Settings surface did not close")
        XCTAssertTrue(app.staticTexts[foundationText].isHittable)
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
    }

    private func selectAppearance(_ name: String, in app: XCUIApplication) {
        let picker = app.popUpButtons["appearance-preference"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Appearance picker was not exposed")
        picker.click()
        let option = app.menuItems[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Appearance option \(name) was not exposed")
        option.click()
        XCTAssertEqual(picker.value as? String, name, "Appearance picker did not select \(name)")
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

    func testScreenshotCoordinateTransformPreservesOriginAndScale() {
        let pixels = screenshotPixels(
            for: CGRect(x: 150, y: 350, width: 50, height: 25),
            captureFrame: CGRect(x: 100, y: 200, width: 400, height: 300),
            bitmapSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(pixels, CGRect(x: 100, y: 250, width: 100, height: 50))
    }

    private func appearanceLabelContrast(
        in app: XCUIApplication,
        in screenshot: XCUIScreenshot,
        label: XCUIElement,
        mode: String
    ) throws -> CGFloat {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
        let labelFrame = label.frame
        let captureFrame = app.frame
        let settingsWindowFrame = app.windows.allElementsBoundByIndex
            .map(\.frame)
            .first(where: { $0.contains(labelFrame) })
        let labelPixels = screenshotPixels(
            for: labelFrame,
            captureFrame: captureFrame,
            bitmapSize: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        )
        let foreground = try extremeColor(in: labelPixels, bitmap: bitmap, preferLight: mode == "Dark")
        let backgroundScreenRect = CGRect(x: labelFrame.minX + 4, y: labelFrame.minY - 18, width: 12, height: 12)
        XCTAssertFalse(backgroundScreenRect.intersects(labelFrame), "Panel background sample overlaps the Appearance label frame")
        let panelPixels = screenshotPixels(
            for: backgroundScreenRect,
            captureFrame: captureFrame,
            bitmapSize: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        )
        let background = try averageColor(in: panelPixels, bitmap: bitmap)
        let ratio = contrastRatio(foreground, background)
        attach(
            """
            mode: \(mode)
            screenshotPixels: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)
            appCaptureFrameAX: \(captureFrame)
            settingsWindowFrameAX: \(String(describing: settingsWindowFrame))
            foregroundRegionAX: \(labelFrame)
            foregroundRegionPixels: \(labelPixels)
            backgroundRegionAX: \(backgroundScreenRect)
            backgroundRegionPixels: \(panelPixels)
            backgroundOutsideLabelFrame: \(!backgroundScreenRect.intersects(labelFrame))
            foregroundSRGB: \(foreground)
            backgroundSRGB: \(background)
            contrastRatio: \(ratio)
            """,
            named: "f1-\(mode.lowercased())-appearance-contrast"
        )
        return ratio
    }

    private func screenshotPixels(for screenRect: CGRect, captureFrame: CGRect, bitmapSize: CGSize) -> CGRect {
        guard captureFrame.width > 0, captureFrame.height > 0 else { return .null }
        let xScale = bitmapSize.width / captureFrame.width
        let yScale = bitmapSize.height / captureFrame.height
        return CGRect(
            x: (screenRect.minX - captureFrame.minX) * xScale,
            y: (captureFrame.maxY - screenRect.maxY) * yScale,
            width: screenRect.width * xScale,
            height: screenRect.height * yScale
        ).integral.intersection(CGRect(origin: .zero, size: bitmapSize))
    }

    private func extremeColor(in rect: CGRect, bitmap: NSBitmapImageRep, preferLight: Bool) throws -> NSColor {
        let colors = try colors(in: rect, bitmap: bitmap)
        return try XCTUnwrap(colors.max { lhs, rhs in
            let left = relativeLuminance(lhs)
            let right = relativeLuminance(rhs)
            return preferLight ? left < right : left > right
        })
    }

    private func averageColor(in rect: CGRect, bitmap: NSBitmapImageRep) throws -> NSColor {
        let colors = try colors(in: rect, bitmap: bitmap)
        let count = CGFloat(colors.count)
        return NSColor(
            red: colors.map(\.redComponent).reduce(0, +) / count,
            green: colors.map(\.greenComponent).reduce(0, +) / count,
            blue: colors.map(\.blueComponent).reduce(0, +) / count,
            alpha: 1
        )
    }

    private func colors(in rect: CGRect, bitmap: NSBitmapImageRep) throws -> [NSColor] {
        guard !rect.isEmpty else { throw ProbeConfigurationError.invalidContrastRegion }
        return try rect.pixelCoordinates.map { point in
            try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
        }
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    private func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        let first = relativeLuminance(foreground)
        let second = relativeLuminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
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
    case copiedAppNotRunning(String)
    case copiedAppWindowNotFound(pid_t)
    case invalidContrastRegion

    var errorDescription: String? {
        switch self {
        case .missingCopiedAppPath:
            return "TAKEFORM_UI_PROBE_APP must name the copied F1 app bundle"
        case .copiedAppMissing(let path):
            return "Copied F1 app bundle is missing at \(path)"
        case .copiedAppNotRunning(let path):
            return "Copied F1 app is not running from \(path)"
        case .copiedAppWindowNotFound(let pid):
            return "Copied F1 app has no onscreen normal-layer window for PID \(pid)"
        case .invalidContrastRegion:
            return "Appearance contrast sample region is outside the screenshot"
        }
    }
}

private extension CGRect {
    var pixelCoordinates: [CGPoint] {
        let xValues = Int(minX)..<Int(maxX)
        let yValues = Int(minY)..<Int(maxY)
        return xValues.flatMap { x in yValues.map { y in CGPoint(x: x, y: y) } }
    }
}

private struct WindowServerCandidate {
    let number: Int
    let layer: Int
    let alpha: Double
    let bounds: CGRect

    var description: String {
        "number=\(number) layer=\(layer) alpha=\(alpha) bounds=\(bounds)"
    }
}
