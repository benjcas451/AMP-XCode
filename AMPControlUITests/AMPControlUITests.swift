import XCTest

/// Drives the real app against `MockAMPServer`.
final class AMPControlUITests: XCTestCase {
    private var server: MockAMPServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try MockAMPServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    @MainActor
    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetSettings"]
        app.launch()
        return app
    }

    @MainActor
    private func attachScreenshot(_ name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertExists(
        _ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "\(what) not found", file: file, line: line)
    }

    /// Any element whose label contains `fragment`.
    @MainActor
    private func element(labelled fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// iOS offers to save the password some time after the login form is
    /// gone. Its sheet covers the app, so it has to be answered.
    @MainActor
    private func dismissSavePasswordPrompt(in app: XCUIApplication, timeout: TimeInterval = 0) {
        let labels = NSPredicate(format: "label IN %@", ["Not Now", "Jetzt nicht"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for host in [app, springboard] {
                let notNow = host.buttons.matching(labels).firstMatch
                if notNow.exists {
                    notNow.tap()
                    _ = notNow.waitForNonExistence(timeout: 5)
                    return
                }
            }
        } while Date() < deadline
    }

    /// Taps `element` once nothing from the system is in the way.
    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        dismissSavePasswordPrompt(in: app)
        element.tap()
    }

    /// Fills in the first-run form and saves it.
    @MainActor
    private func connect(_ app: XCUIApplication) {
        let url = app.textFields["settings-url"]
        assertExists(url, "URL field")
        url.tap()
        url.typeText("127.0.0.1:\(server.port)")

        let username = app.textFields["settings-username"]
        username.tap()
        username.typeText("admin")

        let password = app.secureTextFields["settings-password"]
        password.tap()
        // Return submits the form.
        password.typeText("secret\n")
    }

    @MainActor
    private func selectTab(_ id: String, in app: XCUIApplication) {
        let tab = app.buttons["tab-\(id)"]
        assertExists(tab, "Tab \(id)")
        dismissSavePasswordPrompt(in: app)
        for _ in 0..<4 where !tab.isHittable {
            app.scrollViews["detail-tabs"].swipeLeft()
        }
        tab.tap()
    }

    @MainActor
    func testFolderNavigation() {
        let app = launchFresh()
        connect(app)
        assertExists(app.navigationBars["Instanzen"], "Instance list")
        dismissSavePasswordPrompt(in: app, timeout: 10)
        tap(app.buttons["manage-mc"], in: app)
        selectTab("files", in: app)
        assertExists(app.staticTexts["server.properties"], "Root file")
        tap(app.buttons["open-folder-world"], in: app)
        assertExists(app.staticTexts["level.dat"], "File in subdirectory")
        XCTAssertEqual(app.staticTexts["files-path"].label, "/world")
        tap(app.buttons["files-parent"], in: app)
        assertExists(app.staticTexts["server.properties"], "File after returning to root")
        XCTAssertFalse(app.buttons["files-parent"].exists)
    }

    // MARK: - Tests

    @MainActor
    func testFirstRunValidatesTheForm() {
        let app = launchFresh()
        assertExists(app.navigationBars["AMP Control einrichten"], "Setup screen")

        app.buttons["settings-save"].tap()
        assertExists(app.staticTexts["Bitte Server-URL eingeben"], "URL validation message")
        XCTAssertTrue(app.staticTexts["Bitte Benutzer eingeben"].exists)
        XCTAssertTrue(app.staticTexts["Bitte Passwort eingeben"].exists)
        attachScreenshot("01 Setup validation", of: app)
    }

    @MainActor
    func testSetupBrowseAndControlInstances() {
        let app = launchFresh()
        assertExists(app.navigationBars["AMP Control einrichten"], "Setup screen")
        connect(app)

        // Instance list
        assertExists(app.navigationBars["Instanzen"], "Instance list")
        dismissSavePasswordPrompt(in: app, timeout: 10)
        assertExists(app.staticTexts["Survival"], "Running instance")
        XCTAssertTrue(app.staticTexts["AMP-Instanz: Läuft"].exists)
        XCTAssertTrue(app.staticTexts["AMP-Instanz: Gestoppt"].exists)
        XCTAssertTrue(app.staticTexts["CPU: 12 %"].exists)
        XCTAssertFalse(app.buttons["manage-valheim"].exists)
        attachScreenshot("02 Instances", of: app)

        // Start and stop the instance that is not running
        tap(app.buttons["toggle-valheim"], in: app)
        assertExists(app.buttons["manage-valheim"], "Controls of the started instance")
        attachScreenshot("03 Instance started", of: app)

        tap(app.buttons["toggle-valheim"], in: app)
        let stopAlert = app.alerts["Instanz stoppen?"]
        assertExists(stopAlert, "Stop confirmation")
        attachScreenshot("04 Stop confirmation", of: app)
        stopAlert.buttons["Instanz stoppen"].tap()
        XCTAssertTrue(app.buttons["manage-valheim"].waitForNonExistence(timeout: 15))

        // Instance details
        tap(app.buttons["manage-mc"], in: app)
        assertExists(app.navigationBars["Survival"], "Detail screen")
        assertExists(app.staticTexts["Laufzeit: 0:01:23:45"], "Uptime")
        XCTAssertTrue(app.staticTexts["1536 / 4096 MB"].exists)
        attachScreenshot("05 Overview", of: app)

        selectTab("console", in: app)
        assertExists(element(labelled: "Done (3.2s)!", in: app), "Console output")
        let input = app.textFields["console-input"]
        tap(input, in: app)
        input.typeText("say hello\n")
        assertExists(element(labelled: "[Server] say hello", in: app), "Echo of the command")
        attachScreenshot("06 Console", of: app)

        selectTab("users", in: app)
        assertExists(app.staticTexts["Alex"], "Player")
        XCTAssertTrue(app.staticTexts["Steve"].exists)

        selectTab("backups", in: app)
        assertExists(app.staticTexts["world-2024-06-01"], "Backup")
        attachScreenshot("07 Backups", of: app)

        selectTab("files", in: app)
        assertExists(app.staticTexts["server.properties"], "File")

        selectTab("settings", in: app)
        assertExists(app.staticTexts["Max Players"], "Setting")
        attachScreenshot("08 Settings", of: app)

        selectTab("tasks", in: app)
        assertExists(element(labelled: "Nightly Backup", in: app), "Scheduled task")

        selectTab("events", in: app)
        assertExists(app.staticTexts["Backup completed"], "Audit log entry")

        selectTab("updates", in: app)
        assertExists(app.staticTexts["Status: Läuft"], "Update status")
        XCTAssertFalse(app.buttons["Update starten"].isEnabled)
        attachScreenshot("09 Updates", of: app)

        // Settings keep the saved values; deleting them leads back to the setup
        tap(app.navigationBars.buttons.firstMatch, in: app)
        assertExists(app.navigationBars["Instanzen"], "Instance list after going back")
        tap(app.navigationBars["Instanzen"].buttons["Einstellungen"], in: app)
        assertExists(app.navigationBars["Einstellungen"], "Settings screen")
        XCTAssertEqual(
            app.textFields["settings-url"].value as? String, "http://127.0.0.1:\(server.port)")
        XCTAssertEqual(app.textFields["settings-username"].value as? String, "admin")
        // The saved password is filled in, shown as one bullet per character.
        XCTAssertEqual((app.secureTextFields["settings-password"].value as? String)?.count, 6)
        attachScreenshot("10 Connection settings", of: app)

        tap(app.buttons["Zugangsdaten löschen"], in: app)
        let deleteAlert = app.alerts["Zugangsdaten löschen?"]
        assertExists(deleteAlert, "Delete confirmation")
        deleteAlert.buttons["Löschen"].tap()
        assertExists(app.navigationBars["AMP Control einrichten"], "Setup screen after deleting")
    }
}
