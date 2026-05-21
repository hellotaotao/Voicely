//
//  VoicelyUITests.swift
//  VoicelyUITests
//
//  Created by Tao Wang on 1/6/2025.
//

import XCTest

final class VoicelyUITests: XCTestCase {
    fileprivate enum ID {
        static let libraryScreen = "LibraryScreen"
        static let noteLibraryList = "NoteLibraryList"
        static let emptyState = "EmptyLibraryCard"
        static let recordingControls = "RecordingControls"
        static let recordingModelPickerButton = "RecordingModelPickerButton"
        static let recordButton = "RecordButton"
        static let settingsButton = "SettingsButton"
        static let settingsScreen = "SettingsScreen"
        static let settingsDoneButton = "SettingsDoneButton"
        static let activeModelCard = "ActiveModelCard"
        static let transcriptionSettingsSection = "TranscriptionSettingsSection"
        static let noteRow = "VoiceNoteRow"
        static let noteDetailScreen = "NoteDetailScreen"
        static let noteDetailTitle = "NoteDetailTitle"
        static let noteDetailMetadata = "NoteDetailMetadata"
        static let transcriptionCard = "TranscriptionCard"
        static let transcriptionBody = "TranscriptionBody"
        static let transcribeButton = "TranscribeButton"
        static let retranscribeButton = "RetranscribeButton"
        static let copyTranscriptionButton = "CopyTranscriptionButton"
        static let shareTranscriptionButton = "ShareTranscriptionButton"
    }

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

    private func launchApp(
        seedNoteTitle: String? = nil,
        seedNoteAudioPath: String? = nil,
        seedNoteDuration: TimeInterval? = nil,
        seedNoteTranscription: String? = nil,
        seedNoteTranscriptionModelIdentifier: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        let shouldSeedNote = seedNoteTitle != nil
            || seedNoteAudioPath != nil
            || seedNoteDuration != nil
            || seedNoteTranscription != nil
            || seedNoteTranscriptionModelIdentifier != nil

        if shouldSeedNote {
            app.launchEnvironment["VOICELY_UI_TEST_SEED_NOTE"] = "1"
        }
        if let seedNoteTitle {
            app.launchEnvironment["VOICELY_UI_TEST_NOTE_TITLE"] = seedNoteTitle
        }
        if let seedNoteAudioPath {
            app.launchEnvironment["VOICELY_UI_TEST_NOTE_AUDIO_PATH"] = seedNoteAudioPath
        }
        if let seedNoteDuration {
            app.launchEnvironment["VOICELY_UI_TEST_NOTE_DURATION"] = String(seedNoteDuration)
        }
        if let seedNoteTranscription {
            app.launchEnvironment["VOICELY_UI_TEST_NOTE_TRANSCRIPTION"] = seedNoteTranscription
        }
        if let seedNoteTranscriptionModelIdentifier {
            app.launchEnvironment["VOICELY_UI_TEST_NOTE_TRANSCRIPTION_MODEL_IDENTIFIER"] = seedNoteTranscriptionModelIdentifier
        }
        app.launch()
        app.tap()
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchShowsLibraryShell() throws {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Voicely"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.libraryScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.noteLibraryList).exists)
    }

    @MainActor
    func testEmptyLibraryShellShowsPrimaryRecordingPath() throws {
        let app = launchApp()

        XCTAssertTrue(app.element(id: ID.libraryScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.noteLibraryList).exists)
        XCTAssertTrue(app.element(id: ID.emptyState).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Recordings Yet"].exists)
        XCTAssertTrue(app.element(id: ID.recordingControls).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.recordingModelPickerButton).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.recordButton).waitForExistence(timeout: 5))

        attachScreenshot(named: "Library Empty Shell", app: app)
    }

    @MainActor
    func testOpenSettingsShowsSettingsScreen() throws {
        let app = launchApp()
        app.buttons[ID.settingsButton].firstMatch.tap()
        XCTAssertTrue(app.element(id: ID.settingsScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.activeModelCard).exists)
        XCTAssertTrue(app.element(id: ID.transcriptionSettingsSection).exists)
        attachScreenshot(named: "Settings Screen", app: app)

        app.buttons[ID.settingsDoneButton].firstMatch.tap()
        XCTAssertTrue(app.element(id: ID.libraryScreen).waitForExistence(timeout: 5))
    }

    @MainActor
    func testSelectingNoteShowsDetailScreen() throws {
        let noteTitle = "UI Test Note"
        let app = launchApp(seedNoteTitle: noteTitle)

        let noteTitleText = app.staticTexts[noteTitle].firstMatch
        XCTAssertTrue(noteTitleText.waitForExistence(timeout: 5))

        noteTitleText.tap()

        XCTAssertTrue(app.element(id: ID.noteDetailScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.noteDetailTitle).exists)
        XCTAssertTrue(app.element(id: ID.transcriptionCard).exists)
        let transcribeButton = app.transcribeControl
        app.scrollToElement(transcribeButton)
        XCTAssertTrue(transcribeButton.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSeededCompletedTranscriptShowsDetailSmoke() throws {
        let noteTitle = "Completed Transcript Smoke"
        let transcript = "This is a completed transcript seeded for the simulator smoke test."
        let app = launchApp(
            seedNoteTitle: noteTitle,
            seedNoteDuration: 83,
            seedNoteTranscription: transcript,
            seedNoteTranscriptionModelIdentifier: "openai_whisper-small"
        )

        let noteTitleText = app.staticTexts[noteTitle].firstMatch
        XCTAssertTrue(noteTitleText.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[transcript].exists)
        XCTAssertTrue(app.staticTexts["1m 23s"].exists)

        noteTitleText.tap()

        XCTAssertTrue(app.element(id: ID.noteDetailScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[noteTitle].exists)
        XCTAssertTrue(app.element(id: ID.noteDetailTitle).exists)
        XCTAssertTrue(app.element(id: ID.noteDetailMetadata).exists)
        XCTAssertTrue(app.staticTexts["1m 23s"].exists)
        XCTAssertTrue(app.staticTexts["Transcript"].exists)
        XCTAssertTrue(app.staticTexts["Small"].exists)
        XCTAssertTrue(app.element(id: ID.transcriptionCard).exists)
        XCTAssertTrue(app.element(id: ID.transcriptionBody).exists)
        XCTAssertTrue(app.staticTexts[transcript].exists)
        XCTAssertTrue(app.buttons[ID.retranscribeButton].exists)
        XCTAssertTrue(app.buttons[ID.copyTranscriptionButton].exists)
        XCTAssertTrue(app.buttons[ID.shareTranscriptionButton].exists)

        attachScreenshot(named: "Completed Transcript Detail", app: app)
    }

    @MainActor
    func testSeededRecordingTranscribePromptRoutesToSettings() throws {
        let noteTitle = "Seeded Recording"
        let app = launchApp(
            seedNoteTitle: noteTitle,
            seedNoteAudioPath: "ui-test-seeded-recording.m4a"
        )

        XCTAssertTrue(app.element(id: ID.noteLibraryList).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[ID.noteRow].firstMatch.waitForExistence(timeout: 5))
        app.buttons[ID.noteRow].firstMatch.tap()

        XCTAssertTrue(app.element(id: ID.noteDetailScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[noteTitle].exists)
        let transcribeButton = app.transcribeControl
        app.scrollToElement(transcribeButton)
        XCTAssertTrue(transcribeButton.waitForExistence(timeout: 5))
        transcribeButton.tap()

        let modelAlert = app.alerts["Model Not Loaded"]
        XCTAssertTrue(modelAlert.waitForExistence(timeout: 5))
        modelAlert.buttons["Open Settings"].tap()

        XCTAssertTrue(app.element(id: ID.settingsScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.activeModelCard).exists)
        XCTAssertTrue(app.element(id: ID.transcriptionSettingsSection).exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

private extension XCUIApplication {
    func element(id: String) -> XCUIElement {
        descendants(matching: .any)[id].firstMatch
    }

    var transcribeControl: XCUIElement {
        let identifiedControl = element(id: VoicelyUITests.ID.transcribeButton)
        if identifiedControl.exists {
            return identifiedControl
        }
        return buttons["Transcribe"].firstMatch
    }

    func scrollToElement(_ element: XCUIElement, maxSwipes: Int = 4) {
        guard !element.exists || !element.isHittable else { return }

        let scrollView = scrollViews.firstMatch
        guard scrollView.exists else { return }

        for _ in 0..<maxSwipes where !element.isHittable {
            scrollView.swipeUp()
        }
    }
}
