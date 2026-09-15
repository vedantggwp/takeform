import AppKit
import Darwin
import XCTest

/// Exercises only the copied app's public creator controls. Test input files
/// live in the runner temp root; projects are created by the app's Save panel.
@MainActor
final class TakeformNativeCreatorWalkthroughTests: XCTestCase {
    private let appPathKey = "TAKEFORM_CREATOR_WALKTHROUGH_APP"
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

    func testCopiedProjectRequiresNativeRebindAndCorruptionDoesNotOpen() async throws {
        let projectURL = try runnerRoot().appendingPathComponent("original.takeform", isDirectory: true)
        let copiedURL = try runnerRoot().appendingPathComponent("copied.takeform", isDirectory: true)
        await recordCopiedExecutableDiagnosticControl()
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

    /// This is a CI-only process control. It intentionally does not make any
    /// UI claim: the following `XCUIApplication(url:)` launch remains the
    /// only native acceptance route. Its purpose is to distinguish a copied
    /// executable that exits immediately from an XCUI launch failure that
    /// never yields an observable application process.
    private func recordCopiedExecutableDiagnosticControl() async {
        let appURL: URL
        do {
            appURL = try copiedAppURL()
        } catch {
            attach("configurationError: \(error)", named: "creator-direct-executable-control")
            return
        }

        let executable = appURL.appendingPathComponent("Contents/MacOS/Takeform")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            attach("configurationError: copied executable is not executable\nexecutable: \(executable.path)", named: "creator-direct-executable-control")
            return
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutCollector = BoundedProcessOutputCollector(limit: 32 * 1024)
        let stderrCollector = BoundedProcessOutputCollector(limit: 32 * 1024)
        stdoutCollector.read(from: stdout.fileHandleForReading)
        stderrCollector.read(from: stderr.fileHandleForReading)

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.environment = diagnosticChildEnvironment()
        process.standardOutput = stdout
        process.standardError = stderr

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            stdoutCollector.finish(stdout.fileHandleForReading)
            stderrCollector.finish(stderr.fileHandleForReading)
            attach(
                """
                childSpawnError: \(error)
                copiedBundle: \(appURL.path)
                executable: \(executable.path)
                workingDirectory: \(executable.deletingLastPathComponent().path)
                environmentKeys: \(diagnosticChildEnvironment().keys.sorted().joined(separator: ","))
                """,
                named: "creator-direct-executable-control"
            )
            attach(stdoutCollector.rendered(), named: "creator-direct-executable-stdout")
            attach(stderrCollector.rendered(), named: "creator-direct-executable-stderr")
            return
        }

        let processID = process.processIdentifier
        let observationDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < observationDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let observedAliveAtFiveSeconds = process.isRunning
        var sentTERM = false
        var sentKILL = false
        if process.isRunning {
            sentTERM = true
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminationDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                sentKILL = Darwin.kill(processID, SIGKILL) == 0
            }
        }
        process.waitUntilExit()
        stdoutCollector.finish(stdout.fileHandleForReading)
        stderrCollector.finish(stderr.fileHandleForReading)

        let endedAt = Date()
        let result = """
        diagnosticOnly: true
        copiedBundle: \(appURL.path)
        executable: \(executable.path)
        workingDirectory: \(executable.deletingLastPathComponent().path)
        environmentKeys: \(diagnosticChildEnvironment().keys.sorted().joined(separator: ","))
        pid: \(processID)
        startedAt: \(startedAt.timeIntervalSince1970)
        observedAliveAtFiveSeconds: \(observedAliveAtFiveSeconds)
        sentTERM: \(sentTERM)
        sentKILL: \(sentKILL)
        endedAt: \(endedAt.timeIntervalSince1970)
        terminationReason: \(process.terminationReason.rawValue)
        terminationStatus: \(process.terminationStatus)
        stdoutRetainedBytes: \(stdoutCollector.snapshot.retained.count)
        stdoutDiscardedBytes: \(stdoutCollector.snapshot.discardedByteCount)
        stderrRetainedBytes: \(stderrCollector.snapshot.retained.count)
        stderrDiscardedBytes: \(stderrCollector.snapshot.discardedByteCount)
        """
        attach(result, named: "creator-direct-executable-control")
        attach(stdoutCollector.rendered(), named: "creator-direct-executable-stdout")
        attach(stderrCollector.rendered(), named: "creator-direct-executable-stderr")
    }

    private func diagnosticChildEnvironment() -> [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName()
        ]
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

private final class BoundedProcessOutputCollector: @unchecked Sendable {
    struct Snapshot: Sendable {
        let retained: Data
        let discardedByteCount: Int
    }

    private let limit: Int
    private let lock = NSLock()
    private var retained = Data()
    private var discardedByteCount = 0

    init(limit: Int) {
        self.limit = limit
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(retained: retained, discardedByteCount: discardedByteCount)
    }

    func read(from handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data)
        }
    }

    func finish(_ handle: FileHandle) {
        handle.readabilityHandler = nil
        append(handle.readDataToEndOfFile())
        try? handle.close()
    }

    func rendered() -> String {
        let snapshot = snapshot
        let payload = String(data: snapshot.retained, encoding: .utf8) ?? snapshot.retained.base64EncodedString()
        return "retainedBytes: \(snapshot.retained.count)\ndiscardedBytes: \(snapshot.discardedByteCount)\n\(payload)"
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let capacity = max(0, limit - retained.count)
        let retainedCount = min(capacity, data.count)
        retained.append(data.prefix(retainedCount))
        discardedByteCount += data.count - retainedCount
    }
}
