import AppKit
import XCTest

/// Exercises only the copied app's public creator controls. Test input files
/// live in the runner temp root; projects are created by the app's Save panel.
@MainActor
final class TakeformNativeCreatorWalkthroughTests: XCTestCase {
    private let appPathKey = "TAKEFORM_CREATOR_WALKTHROUGH_APP"
    private let outputPathKey = "TAKEFORM_CREATOR_WALKTHROUGH_OUTPUT"
    private let rootPathKey = "TAKEFORM_CREATOR_WALKTHROUGH_ROOT"

    func testCreateImportInspectComposeSaveAndReopen() async throws {
        let fixtures = try SyntheticMediaFixtures()
        defer { fixtures.cleanup() }
        let fixture = try fixtures.png(named: "source.png")
        let video = try await fixtures.video(named: "source.mov")
        let audio = try fixtures.monoAIFF(named: "source.aiff")
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

        try importMedia(video, in: app)
        try inspectManagedAsset(named: "source.mov", expectedPlaybackLabel: "Managed video playback", in: app)
        try importMedia(audio, in: app)
        try inspectManagedAsset(named: "source.aiff", expectedPlaybackLabel: "Managed audio playback", in: app)

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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Composition saved at revision ")).firstMatch.waitForExistence(timeout: 15))
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

        let manifest = copiedURL.appendingPathComponent(".takeform/manifest.json")
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
        record(app, named: "creator-launch")
        return app
    }

    private func createChannel(in app: XCUIApplication, named name: String, projectURL: URL) throws {
        app.buttons["workspace-new-channel"].click()
        let nameField = app.textFields["new-channel-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText(name)
        let recipeKey = app.textFields["new-channel-recipe-key"]
        recipeKey.click()
        recipeKey.typeText("title")
        let recipeValue = app.textFields["new-channel-recipe-value"]
        recipeValue.click()
        recipeValue.typeText("Creator cut")
        record(app, named: "creator-new-channel")
        app.buttons["new-channel-create"].click()
        try acceptSystemPanel(path: projectURL.deletingLastPathComponent(), confirmation: "Create Project", app: app, named: "creator-create-panel")
    }

    private func importMedia(_ source: URL, in app: XCUIApplication) throws {
        app.buttons["workspace-import-footage"].click()
        try acceptSystemPanel(path: source, confirmation: "Import footage", app: app, named: "creator-import-panel")
    }

    private func inspectManagedAsset(named name: String, expectedPlaybackLabel: String, in app: XCUIApplication) throws {
        let asset = app.buttons[name]
        XCTAssertTrue(asset.waitForExistence(timeout: 10), "Imported \(name) did not appear as a selectable managed asset")
        asset.click()
        XCTAssertTrue(app.otherElements["managed-asset-inspector"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements[expectedPlaybackLabel].waitForExistence(timeout: 10), "Selected \(name) did not expose its native playback control")
        record(app, named: "creator-inspector-\(name)")
    }

    private func openProject(_ projectURL: URL, in app: XCUIApplication) throws {
        app.buttons["workspace-open-project"].click()
        try acceptSystemPanel(path: projectURL, confirmation: "Open Project", app: app, named: "creator-open-panel")
    }

    /// Open and Save panels are system UI. This intentionally records the
    /// panel AX tree before interacting with it; a changed system hierarchy is
    /// a test failure with evidence, never a product-route fallback.
    private func acceptSystemPanel(path: URL, confirmation: String, app: XCUIApplication, named: String) throws {
        let panel = try presentedSystemPanel(in: app, named: named)
        attach(app.debugDescription, named: "\(named)-ax")
        capture(panel, named: named)
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let folderField = panel.textFields.firstMatch
        XCTAssertTrue(folderField.waitForExistence(timeout: 5), "System panel did not expose its Go to Folder field")
        folderField.click()
        folderField.typeText(path.path)
        panel.typeKey(.return, modifierFlags: [])
        let confirmationButton = panel.buttons[confirmation]
        XCTAssertTrue(confirmationButton.waitForExistence(timeout: 5), "System panel did not expose \(confirmation)")
        confirmationButton.click()
    }

    /// This test target intentionally has no configured Target Application: it
    /// launches the copied bundle by URL. NSOpenPanel/NSSavePanel presentation
    /// therefore remains a descendant of that explicit app proxy instead of
    /// creating XCUIApplication(), which would require a Target Application.
    private func presentedSystemPanel(in app: XCUIApplication, named: String) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let sheet = app.sheets.firstMatch
            if sheet.exists { return sheet }
            let dialog = app.dialogs.firstMatch
            if dialog.exists { return dialog }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        attach(app.debugDescription, named: "\(named)-missing-panel-ax")
        capture(app, named: "\(named)-missing-panel")
        XCTFail("The app-owned system Open/Save panel did not appear")
        throw NSError(domain: "TakeformCreatorWalkthrough", code: 4)
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
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
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
        let screenshot = object.screenshot()
        persist(screenshot, named: named)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = named
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func persist(_ screenshot: XCUIScreenshot, named: String) {
        guard let outputPath = ProcessInfo.processInfo.environment[outputPathKey], !outputPath.isEmpty else {
            XCTFail("The opt-in workflow did not provide a runner-owned evidence output path.")
            return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        let safeName = named.replacingOccurrences(of: "/", with: "-")
        let file = output.appendingPathComponent("\(safeName)-\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: file, options: .atomic)
        } catch {
            XCTFail("Could not retain \(named) screenshot: \(error.localizedDescription)")
        }
    }

    private func attach(_ value: String, named: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = named
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
