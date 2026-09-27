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
        NSPasteboard.general.setString("buy tel 500000 @ .001805", forType: .string)
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Paste"].click()
        input.typeKey(.return, modifierFlags: [])
        // A preview opens; nothing is committed until confirmed.
        XCTAssertTrue(app.staticTexts["BUY 500,000 TEL @ $0.001805"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["3,435,000 → 3,935,000 TEL"].exists)
        app.buttons["[ confirm transaction ↵ ]"].click()
        XCTAssertTrue(app.staticTexts["3,935,000 TEL"].waitForExistence(timeout: 3), "asset detail shows the new holding")
    }

    func testQuickShareFromMenu() {
        let app = launch(["--demo"])
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Go"].click()
        app.menuItems["Quick Share"].click()
        XCTAssertTrue(app.staticTexts["QUICK SHARE"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["safe to share"].exists, "public is the default")
    }
}
