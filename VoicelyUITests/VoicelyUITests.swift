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

    private func launchApp(seedNoteTitle: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let seedNoteTitle {
            app.launchEnvironment["VOICELY_UI_TEST_SEED_NOTE"] = "1"
            app.launchEnvironment["VOICELY_UI_TEST_NOTE_TITLE"] = seedNoteTitle
        }
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
    func testSelectingNoteShowsDetailScreen() throws {
        let noteTitle = "UI Test Note"
        let app = launchApp(seedNoteTitle: noteTitle)

        let noteTitleText = app.staticTexts[noteTitle].firstMatch
        XCTAssertTrue(noteTitleText.waitForExistence(timeout: 5))

        noteTitleText.tap()

        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
