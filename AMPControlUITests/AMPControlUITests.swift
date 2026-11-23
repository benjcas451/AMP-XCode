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

    @MainActor
    private func text(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
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
        for _ in 0..<4 where !tab.isHittable {
            app.scrollViews["detail-tabs"].swipeLeft()
        }
        tab.tap()
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
        assertExists(app.staticTexts["Survival"], "Running instance")
        XCTAssertTrue(app.staticTexts["AMP-Instanz: Läuft"].exists)
        XCTAssertTrue(app.staticTexts["AMP-Instanz: Gestoppt"].exists)
        XCTAssertTrue(app.staticTexts["CPU: 12 %"].exists)
        XCTAssertFalse(app.buttons["manage-valheim"].exists)
        attachScreenshot("02 Instances", of: app)

        // Start and stop the instance that is not running
        app.buttons["toggle-valheim"].tap()
        assertExists(app.buttons["manage-valheim"], "Controls of the started instance")
        attachScreenshot("03 Instance started", of: app)

        app.buttons["toggle-valheim"].tap()
        let stopAlert = app.alerts["Instanz stoppen?"]
        assertExists(stopAlert, "Stop confirmation")
        attachScreenshot("04 Stop confirmation", of: app)
        stopAlert.buttons["Instanz stoppen"].tap()
        XCTAssertTrue(app.buttons["manage-valheim"].waitForNonExistence(timeout: 15))

        // Instance details
        app.buttons["manage-mc"].tap()
        assertExists(app.navigationBars["Survival"], "Detail screen")
        assertExists(app.staticTexts["Laufzeit: 0:01:23:45"], "Uptime")
        XCTAssertTrue(app.staticTexts["1536 / 4096 MB"].exists)
        attachScreenshot("05 Overview", of: app)

        selectTab("console", in: app)
        assertExists(text(containing: "Done (3.2s)!", in: app), "Console output")
        let input = app.textFields["console-input"]
        input.tap()
        input.typeText("say hello\n")
        assertExists(text(containing: "[Server] say hello", in: app), "Echo of the command")
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
        assertExists(app.staticTexts["Nightly Backup"], "Scheduled task")

        selectTab("events", in: app)
        assertExists(app.staticTexts["Backup completed"], "Audit log entry")

        selectTab("updates", in: app)
        assertExists(app.staticTexts["Status: Läuft"], "Update status")
        XCTAssertFalse(app.buttons["Update starten"].isEnabled)
        attachScreenshot("09 Updates", of: app)

        // Settings keep the saved values; deleting them leads back to the setup
        app.navigationBars.buttons.firstMatch.tap()
        assertExists(app.navigationBars["Instanzen"], "Instance list after going back")
        app.navigationBars["Instanzen"].buttons["Einstellungen"].tap()
        assertExists(app.navigationBars["Einstellungen"], "Settings screen")
        XCTAssertEqual(
            app.textFields["settings-url"].value as? String, "http://127.0.0.1:\(server.port)")
        attachScreenshot("10 Connection settings", of: app)

        app.buttons["Zugangsdaten löschen"].tap()
        let deleteAlert = app.alerts["Zugangsdaten löschen?"]
        assertExists(deleteAlert, "Delete confirmation")
        deleteAlert.buttons["Löschen"].tap()
        assertExists(app.navigationBars["AMP Control einrichten"], "Setup screen after deleting")
    }
}
