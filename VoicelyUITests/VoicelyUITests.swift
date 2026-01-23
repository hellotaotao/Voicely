//
//  VoicelyUITests.swift
//  VoicelyUITests
//
//  Created by Tao Wang on 1/6/2025.
//

import XCTest

final class VoicelyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System Alerts") { alert in
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return true
            }
            if alert.buttons["OK"].exists {
                alert.buttons["OK"].tap()
                return true
            }
            return false
        }
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        app.tap()
        return app
    }

    @MainActor
    func testLaunchShowsVoiceNotesTitle() throws {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Voice Notes"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOpenSettingsShowsSettingsScreen() throws {
        let app = launchApp()
        app.buttons["SettingsButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Model Management"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
