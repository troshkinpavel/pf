import AppKit
import XCTest

/// Dock / menu bar lifecycle, version display and manual update check.
/// Dock presence is read from the app's real activation policy (.regular = in Dock).
final class LifecycleUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-market", "--demo"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 10))
        return app
    }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.troskinpavel.pf").max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }

    private func waitForPolicy(_ p: NSApplication.ActivationPolicy, _ why: String) {
        let deadline = Date().addingTimeInterval(5)
        while running?.activationPolicy != p, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(running?.activationPolicy, p, why)
    }

    private func el(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    private func closeMainWindow(_ app: XCUIApplication) {
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.staticTexts["DEMO"].waitForNonExistence(timeout: 5), "main window closed")
    }

    func testCloseHidesFromDockAndEveryReopenPathRestoresIt() {
        let app = launch()
        waitForPolicy(.regular, "launch: in Dock")

        closeMainWindow(app)
        waitForPolicy(.accessory, "closed: menu bar only, not in Dock")
        XCTAssertNotEqual(app.state, .notRunning, "close is not quit")

        // Menu bar item → open portfolio
        app.statusItems.firstMatch.click()
        let open = el(app, "open portfolio")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 5), "main window back")
        waitForPolicy(.regular, "reopened from menu bar: in Dock")
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title == 'PF Terminal'")).count <= 1, true, "no duplicate main windows")

        // Deep link (the path widget taps use) while menu-bar-only
        closeMainWindow(app)
        waitForPolicy(.accessory, "closed again")
        // Send it to the app under test: other local builds and /Applications also register the scheme.
        if let appURL = running?.bundleURL {
            NSWorkspace.shared.open([URL(string: "pfterminal://portfolio")!], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 10), "deep link opened the main window")
        waitForPolicy(.regular, "deep link: in Dock")

        // Finder/Dock reopen: opening the running app again sends the standard reopen event.
        closeMainWindow(app)
        waitForPolicy(.accessory, "closed a third time")
        if let url = running?.bundleURL {
            let done = expectation(description: "reopen")
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 10), "reopen event opened the main window")
        waitForPolicy(.regular, "Finder/Dock reopen: in Dock")
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.troskinpavel.pf").count, 1, "reopen reused the running app")

        // ⌘Q quits
        app.menuBars.menuBarItems["PF Terminal"].click()
        app.menuItems["Quit PF Terminal"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "quit terminates")
    }

    func testKeepInDockPreferenceAndVersionAndUpdateCheck() {
        let app = launch()
        // 0.7: Settings left the Go menu (tabs are 1–4); it stays in the app menu, ⌘,.
        app.menuBars.menuBarItems["PF Terminal"].click()
        app.menuItems["Settings…"].click()

        // Version comes from the running bundle's metadata.
        let info = running?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        XCTAssertTrue(el(app, "PF Terminal " + version).waitForExistence(timeout: 5), "Settings shows \(version)")

        // Manual update check against GitHub Releases (anonymous, read-only).
        el(app, "check for updates").click()
        let settled = NSPredicate(format: "label CONTAINS 'up to date' OR label CONTAINS 'available' OR label CONTAINS '✗'")
        let result = app.descendants(matching: .any).matching(settled).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "update check finished")
        print("UPDATE CHECK:", result.label)

        // Keep in Dock ON: closing the window keeps the Dock icon.
        el(app, "keep in Dock when closed").click()
        XCTAssertTrue(el(app, "‹ on ›").waitForExistence(timeout: 3))
        closeMainWindow(app)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(running?.activationPolicy, .regular, "keep in Dock: icon stays")
        app.terminate()
    }
}
