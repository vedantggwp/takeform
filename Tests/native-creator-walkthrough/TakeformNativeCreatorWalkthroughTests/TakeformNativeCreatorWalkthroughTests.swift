import AppKit
import XCTest

/// Exercises only the copied app's public creator controls. Test input files
/// live in the runner temp root; projects are created by the app's Save panel.
@MainActor
final class TakeformNativeCreatorWalkthroughTests: XCTestCase {
    private let appPathKey = "TAKEFORM_CREATOR_WALKTHROUGH_APP"
    private let rootPathKey = "TAKEFORM_CREATOR_WALKTHROUGH_ROOT"

    func testCreateImportInspectComposeSaveAndReopen() throws {
        let fixture = try makePNG(named: "source.png")
        let projectURL = try runnerRoot().appendingPathComponent("happy.takeform", isDirectory: true)
        let app = try launchApp()
        defer { finish(app, named: "creator-happy-final") }

        try createChannel(in: app, named: "Harbor", projectURL: projectURL)
        XCTAssertTrue(app.staticTexts["Harbor"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Revision ")).firstMatch.exists)
        record(app, named: "creator-created")

        try importMedia(fixture, in: app)
        XCTAssertTrue(app.otherElements["managed-import-outcomes"].waitForExistence(timeout: 15))
        let asset = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "managed-asset-")).firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.click()
        XCTAssertTrue(app.otherElements["managed-asset-inspector"].waitForExistence(timeout: 10))
        record(app, named: "creator-managed-inspector")

        let episodeName = app.textFields["workspace-episode-name"]
        XCTAssertTrue(episodeName.waitForExistence(timeout: 5))
        episodeName.click()
        episodeName.typeText("Assembly")
        app.buttons["workspace-create-episode"].click()
        XCTAssertTrue(app.staticTexts["Assembly"].waitForExistence(timeout: 10))

        let clipMenu = app.buttons["composition-asset-picker"]
        XCTAssertTrue(clipMenu.waitForExistence(timeout: 5))
        clipMenu.click()
        XCTAssertTrue(app.menuItems["source.png"].waitForExistence(timeout: 5))
        app.menuItems["source.png"].click()
        XCTAssertTrue(app.otherElements["composition-editor"].waitForExistence(timeout: 5))
        app.buttons["composition-add-caption"].click()
        let caption = app.textFields.matching(NSPredicate(format: "identifier CONTAINS %@", "-text")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        caption.click()
        caption.typeText("Harbor cut")
        app.buttons["composition-save"].click()
        XCTAssertTrue(app.staticTexts["Composition saved at revision 4."].waitForExistence(timeout: 15))
        record(app, named: "creator-composition-saved")

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        try openProject(projectURL, in: app)
        XCTAssertTrue(app.staticTexts["Harbor"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Assembly"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["composition-editor"].waitForExistence(timeout: 10))
        record(app, named: "creator-reopened")
    }

    func testPairCLIRejectsStaleRevisionAndRevocation() throws {
        let projectURL = try runnerRoot().appendingPathComponent("cli.takeform", isDirectory: true)
        let app = try launchApp()
        defer { finish(app, named: "creator-cli-final") }
        try createChannel(in: app, named: "CLI channel", projectURL: projectURL)

        app.buttons["workspace-pair-cli"].click()
        XCTAssertTrue(app.buttons["workspace-confirm-pair-cli"].waitForExistence(timeout: 5))
        app.buttons["workspace-confirm-pair-cli"].click()
        let grant = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-cli-grant-")).firstMatch
        XCTAssertTrue(grant.waitForExistence(timeout: 15))
        let grantID = try XCTUnwrap(UUID(uuidString: String(grant.identifier.dropFirst("workspace-cli-grant-".count))))
        record(app, named: "creator-cli-paired")

        let rename = commandJSON(expectedRevision: 1, name: "CLI committed")
        let accepted = try runCopiedCLI(arguments: ["execute", projectURL.path, grantID.uuidString, rename])
        XCTAssertEqual(accepted.status, 0, accepted.stderr)
        XCTAssertTrue(accepted.stdout.contains("applied"), accepted.stdout)

        let stale = try runCopiedCLI(arguments: ["execute", projectURL.path, grantID.uuidString, commandJSON(expectedRevision: 1, name: "stale")])
        XCTAssertEqual(stale.status, 0, stale.stderr)
        XCTAssertTrue(stale.stdout.contains("conflict"), stale.stdout)

        try openProject(projectURL, in: app)
        XCTAssertTrue(app.staticTexts["CLI committed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["stale"].exists)

        let selection = app.buttons["workspace-cli-grant-select-\(grantID.uuidString)"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        selection.click()
        app.buttons["workspace-revoke-cli"].click()
        XCTAssertTrue(app.staticTexts["CLI access revoked."].waitForExistence(timeout: 10))
        let denied = try runCopiedCLI(arguments: ["execute", projectURL.path, grantID.uuidString, commandJSON(expectedRevision: 2, name: "denied")])
        XCTAssertNotEqual(denied.status, 0)
        XCTAssertTrue(denied.stderr.contains("open Takeform"), denied.stderr)
        record(app, named: "creator-cli-revoked")
    }

    func testCopiedProjectRequiresNativeRebindAndCorruptionDoesNotOpen() throws {
        let projectURL = try runnerRoot().appendingPathComponent("original.takeform", isDirectory: true)
        let copiedURL = try runnerRoot().appendingPathComponent("copied.takeform", isDirectory: true)
        let app = try launchApp()
        defer { finish(app, named: "creator-rebind-final") }
        try createChannel(in: app, named: "Move me", projectURL: projectURL)
        try FileManager.default.copyItem(at: projectURL, to: copiedURL)

        try openProject(copiedURL, in: app)
        let alert = app.dialogs["Project needs attention"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Rebind moved project"].isHittable)
        record(app, named: "creator-copy-decision")
        app.buttons["Rebind moved project"].click()
        XCTAssertTrue(app.staticTexts["Move me"].waitForExistence(timeout: 10))

        let manifest = copiedURL.appendingPathComponent("manifest.json")
        try Data("not a takeform manifest".utf8).write(to: manifest, options: .atomic)
        try openProject(copiedURL, in: app)
        XCTAssertTrue(app.dialogs["Project needs attention"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "corrupt")).firstMatch.exists)
        record(app, named: "creator-corrupt-project")
    }

    private func runnerRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[rootPathKey], !path.isEmpty else {
            throw XCTSkip("The opt-in workflow did not provide a runner-owned creator test root.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func launchApp() throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment[appPathKey], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("The opt-in workflow did not provide a copied Takeform app bundle.")
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["takeform-title"].waitForExistence(timeout: 10))
        return app
    }

    private func createChannel(in app: XCUIApplication, named name: String, projectURL: URL) throws {
        app.buttons["workspace-new-channel"].click()
        let nameField = app.textFields["new-channel-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText(name)
        app.buttons["new-channel-create"].click()
        try acceptSystemPanel(path: projectURL.deletingLastPathComponent(), confirmation: "Create Project", app: app, named: "creator-create-panel")
    }

    private func importMedia(_ source: URL, in app: XCUIApplication) throws {
        app.buttons["workspace-import-footage"].click()
        try acceptSystemPanel(path: source, confirmation: "Import footage", app: app, named: "creator-import-panel")
    }

    private func openProject(_ projectURL: URL, in app: XCUIApplication) throws {
        app.buttons["workspace-open-project"].click()
        try acceptSystemPanel(path: projectURL, confirmation: "Open Project", app: app, named: "creator-open-panel")
    }

    /// Open and Save panels are system UI. This intentionally records the
    /// panel AX tree before interacting with it; a changed system hierarchy is
    /// a test failure with evidence, never a product-route fallback.
    private func acceptSystemPanel(path: URL, confirmation: String, app: XCUIApplication, named: String) throws {
        let system = XCUIApplication()
        let panel = system.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The separate system Open/Save panel did not appear")
        attach(system.debugDescription, named: "\(named)-ax")
        capture(panel, named: named)
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let folderField = system.textFields.firstMatch
        XCTAssertTrue(folderField.waitForExistence(timeout: 5), "System panel did not expose its Go to Folder field")
        folderField.click()
        folderField.typeText(path.path)
        panel.typeKey(.return, modifierFlags: [])
        let confirmationButton = system.buttons[confirmation]
        XCTAssertTrue(confirmationButton.waitForExistence(timeout: 5), "System panel did not expose \(confirmation)")
        confirmationButton.click()
    }

    private func makePNG(named name: String) throws -> URL {
        let url = try runnerRoot().appendingPathComponent(name)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { throw NSError(domain: "TakeformCreatorWalkthrough", code: 1) }
        rep.setColor(NSColor.systemTeal)
        rep.fill()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "TakeformCreatorWalkthrough", code: 2) }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func commandJSON(expectedRevision: Int, name: String) -> String {
        let id = UUID().uuidString
        return #"{"id":{"value":"\#(id)"},"expectedRevision":{"value":\#(expectedRevision)},"command":{"renameChannel":{"name":"\#(name)"}}}"#
    }

    private func runCopiedCLI(arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let executable = try copiedAppURL().appendingPathComponent("Contents/MacOS/takeform")
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func copiedAppURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[appPathKey] else { throw NSError(domain: "TakeformCreatorWalkthrough", code: 3) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func finish(_ app: XCUIApplication, named: String) {
        record(app, named: named)
        app.terminate()
    }

    private func record(_ app: XCUIApplication, named: String) {
        capture(app, named: named)
        attach(app.debugDescription, named: "\(named)-ax")
    }

    private func capture(_ object: some XCUIScreenshotProviding, named: String) {
        let attachment = XCTAttachment(screenshot: object.screenshot())
        attachment.name = named
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ value: String, named: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = named
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
