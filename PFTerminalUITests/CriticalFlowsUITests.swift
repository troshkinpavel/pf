import XCTest

/// Runs against throwaway state (`--ui-testing`) and the deterministic mock market.
final class CriticalFlowsUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--mock-market"] + extra
        app.launch()
        app.activate()
        return app
    }

    func testFirstLaunchOffersDemoAndEmpty() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 5))
    }

    func testPaletteTradeRequiresConfirmation() {
        let app = launch(["--demo"])
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 5))
        app.buttons["commands, ⌘K"].click()
        let input = app.textFields["palette-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.click()
        // Paste instead of typing: synthesized letter keys depend on the host's input layout.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("buy sol 3 @ 150", forType: .string)
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Paste"].click()
        input.typeKey(.return, modifierFlags: [])
        // A preview opens; nothing is committed until confirmed.
        XCTAssertTrue(app.staticTexts["BUY 3 SOL @ $150.00"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["97 → 100 SOL"].exists)
        app.buttons["[ confirm transaction ↵ ]"].click()
        XCTAssertTrue(app.staticTexts["100 SOL"].waitForExistence(timeout: 3), "asset detail shows the new holding")
    }

    func testQuickShareFromMenu() {
        let app = launch(["--demo"])
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Go"].click()
        app.menuItems["Quick Share"].click()
        XCTAssertTrue(app.staticTexts["QUICK SHARE"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["safe to share"].exists, "public is the default")
    }

    /// Picking custom privacy and more fields grows the options list; the window must not grow with it.
    func testShareOptionsNeverResizeTheWindow() {
        let app = launch(["--demo"])
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Go"].click()
        app.menuItems["Quick Share"].click()
        XCTAssertTrue(app.staticTexts["QUICK SHARE"].waitForExistence(timeout: 3))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["2 · WHO SEES WHAT"].waitForExistence(timeout: 3), "↵ opens the Share screen")
        let window = app.windows.firstMatch
        let before = window.frame
        func el(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        }
        el("custom").click()
        for f in ["portfolio name", "allocation", "positions · entries"] {
            let t = el(f)
            if t.waitForExistence(timeout: 2) { t.click() }
        }
        XCTAssertTrue(el("REVEALS POSITION DATA").waitForExistence(timeout: 2))
        XCTAssertEqual(window.frame, before, "the window keeps its size and position")
    }

    /// 0.7: four tabs, the g leader, What Changed and the new screens' empty states.
    func testTabsLeaderAndIntelScreens() {
        let app = launch(["--demo"])
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 5))
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        XCTAssertTrue(el("tab-1").exists && el("tab-4").exists, "four numbered tabs")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["WHAT CHANGED"].waitForExistence(timeout: 3))
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(el("watch-empty").waitForExistence(timeout: 3) || el("watch-table").exists)
        app.menuBars.menuBarItems["Go"].click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Alerts")).firstMatch.click()
        XCTAssertTrue(app.staticTexts["ALERTS"].waitForExistence(timeout: 3))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(el("settings-filter").waitForExistence(timeout: 3))
        XCTAssertTrue(el("settings-section-sync").exists, "settings sidebar")
    }
}
