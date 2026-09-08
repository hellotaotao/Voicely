//
//  VoicelyUITests.swift
//  VoicelyUITests
//
//  Created by Tao Wang on 1/6/2025.
//

import XCTest

final class VoicelyUITests: XCTestCase {
    fileprivate enum ID {
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
        static let audioPlayerCard = "AudioPlayerCard"
        static let playButton = "PlayButton"
        static let transcriptionCard = "TranscriptionCard"
        static let transcriptionBody = "TranscriptionBody"
        static let transcribeButton = "TranscribeButton"
        static let transcribeNowButton = "TranscribeNowButton"
        static let retranscribeButton = "RetranscribeButton"
        static let copyTranscriptionButton = "CopyTranscriptionButton"
        static let shareTranscriptionButton = "ShareTranscriptionButton"
        static let playbackRateButton = "PlaybackRateButton"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
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
        seedNoteTranscriptionModelIdentifier: String? = nil,
        seedNoteQueuedForTranscription: Bool = false,
        transcriptPreview: String? = nil,
        failedImport: Bool = false,
        retainedAttempt: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        let shouldSeedNote = seedNoteTitle != nil
            || seedNoteAudioPath != nil
            || seedNoteDuration != nil
            || seedNoteTranscription != nil
            || seedNoteTranscriptionModelIdentifier != nil
            || seedNoteQueuedForTranscription

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
        if seedNoteQueuedForTranscription {
            app.launchEnvironment["VOICELY_UI_TEST_NOTE_TRANSCRIPTION_STATE"] = "queued"
        }
        if let transcriptPreview {
            app.launchEnvironment["VOICELY_UI_TEST_TRANSCRIPT_PREVIEW"] = transcriptPreview
        }
        if failedImport {
            app.launchEnvironment["VOICELY_UI_TEST_IMPORT_RETRY"] = "1"
        }
        if let retainedAttempt {
            app.launchEnvironment["VOICELY_UI_TEST_RETAINED_ATTEMPT"] = retainedAttempt
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
        XCTAssertTrue(app.buttons[ID.settingsButton].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyLibraryShellShowsPrimaryRecordingPath() throws {
        let app = launchApp()

        XCTAssertTrue(app.buttons[ID.settingsButton].waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.emptyState).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Recordings Yet"].exists)
        // Assert actionable controls rather than an ancestor container identifier.
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
        XCTAssertTrue(app.buttons[ID.settingsButton].waitForExistence(timeout: 5))
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
    func testLandscapeLibraryPreservesControlIdentifiers() throws {
        let app = launchApp(seedNoteTitle: "Landscape Note")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons[ID.settingsButton].waitForExistence(timeout: 5))
        XCTAssertTrue(app.element(id: ID.noteRow).waitForExistence(timeout: 5))
        app.buttons[ID.settingsButton].tap()
        XCTAssertTrue(app.element(id: ID.settingsScreen).waitForExistence(timeout: 5))
    }

    @MainActor
    func testEarlierAttemptCanBeReadWithoutReplacingCurrentTranscript() throws {
        let original = "The original complete transcript."
        let retained = "Useful new words from the failed attempt."
        let app = launchApp(seedNoteTitle: "Saved Attempt", seedNoteTranscription: original,
                            retainedAttempt: retained)
        let row = app.element(id: ID.noteRow)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let disclosure = app.buttons["Saved results from earlier attempts"]
        app.scrollToElement(disclosure)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
        let savedText = app.staticTexts["RetainedAttemptText"]
        app.scrollToElement(savedText)
        attachScreenshot(named: "Saved Attempt Expanded", app: app)
        XCTAssertTrue(savedText.waitForExistence(timeout: 5))
        XCTAssertEqual(savedText.label, retained)
        XCTAssertTrue(app.staticTexts[original].exists)
        XCTAssertTrue(app.buttons["CopyRetainedAttempt"].exists)
        attachScreenshot(named: "Saved Failed Attempt", app: app)
    }

    @MainActor
    func testFailedImportRetryReachesModelPromptWithoutAudioPath() throws {
        let app = launchApp(seedNoteTitle: "Retry Import", failedImport: true)
        let row = app.element(id: ID.noteRow)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let retry = app.buttons[ID.transcribeNowButton]
        app.scrollToElement(retry)
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Please load a model in Settings first to transcribe this recording."].exists)
        attachScreenshot(named: "Failed Import Retry Model Prompt", app: app)
    }

    @MainActor
    func testSegmentPreviewIsReadOnlyAndKeepsCopyAction() throws {
        let title = "Segment Preview"
        let original = "Original complete transcript remains available."
        let preview = "The first completed segment appears before the rest."
        let app = launchApp(seedNoteTitle: title, seedNoteDuration: 83,
                            seedNoteTranscription: original, transcriptPreview: preview)
        let row = app.element(id: ID.noteRow)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let previewText = app.staticTexts["TranscriptionPreview"]
        app.scrollToElement(previewText)
        XCTAssertTrue(previewText.waitForExistence(timeout: 5))
        XCTAssertEqual(previewText.label, preview)
        XCTAssertTrue(app.staticTexts["Partial transcript — transcription in progress"].exists)
        XCTAssertFalse(app.textViews["TranscriptEditor"].exists)
        XCTAssertTrue(app.buttons[ID.copyTranscriptionButton].exists)
        attachScreenshot(named: "Read Only Segment Preview", app: app)
    }

    @MainActor
    func testDetailPlaybackControlsStayVisuallyBalancedOnCompactWidth() throws {
        let noteTitle = "Balanced Playback Controls"
        let transcript = "A compact detail screen should keep playback and transcription controls readable."
        let app = launchApp(
            seedNoteTitle: noteTitle,
            seedNoteAudioPath: "ui-test-balanced-playback.m4a",
            seedNoteDuration: 125,
            seedNoteTranscription: transcript,
            seedNoteTranscriptionModelIdentifier: "openai_whisper-small"
        )

        XCTAssertTrue(app.staticTexts[noteTitle].waitForExistence(timeout: 5))
        app.staticTexts[noteTitle].firstMatch.tap()

        let detail = app.element(id: ID.noteDetailScreen)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let audioCard = app.element(id: ID.audioPlayerCard)
        XCTAssertTrue(audioCard.waitForExistence(timeout: 5))

        let playButton = app.playControl
        XCTAssertTrue(playButton.exists)
        XCTAssertEqual(playButton.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 6)

        let playbackRateButton = app.playbackRateControl
        XCTAssertTrue(playbackRateButton.exists)
        XCTAssertLessThanOrEqual(playbackRateButton.frame.width, 46)

        let retranscribeButton = app.buttons[ID.retranscribeButton].firstMatch
        XCTAssertTrue(retranscribeButton.exists)
        XCTAssertGreaterThan(retranscribeButton.frame.width, retranscribeButton.frame.height)
    }

    @MainActor
    func testSeededRecordingTranscribePromptRoutesToSettings() throws {
        let noteTitle = "Seeded Recording"
        let app = launchApp(
            seedNoteTitle: noteTitle,
            seedNoteAudioPath: "ui-test-seeded-recording.m4a"
        )

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
    func testQueuedRecordingAllowsManualTranscribePrompt() throws {
        let noteTitle = "Queued Recording"
        let app = launchApp(
            seedNoteTitle: noteTitle,
            seedNoteAudioPath: "ui-test-queued-recording.m4a",
            seedNoteDuration: 12,
            seedNoteQueuedForTranscription: true
        )

        XCTAssertTrue(app.buttons[ID.noteRow].firstMatch.waitForExistence(timeout: 5))
        app.buttons[ID.noteRow].firstMatch.tap()

        XCTAssertTrue(app.element(id: ID.noteDetailScreen).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[noteTitle].exists)
        XCTAssertTrue(app.staticTexts["Queued for transcription"].exists)

        // A queued note offers "Transcribe Now" (its own identifier), not the
        // detail view's generic Transcribe control.
        let transcribeNow = app.element(id: ID.transcribeNowButton)
        app.scrollToElement(transcribeNow)
        XCTAssertTrue(transcribeNow.waitForExistence(timeout: 5))
        XCTAssertTrue(transcribeNow.isEnabled)
        transcribeNow.tap()

        let modelAlert = app.alerts["Model Not Loaded"]
        XCTAssertTrue(modelAlert.waitForExistence(timeout: 5))
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

    var playControl: XCUIElement {
        let identifiedControl = element(id: VoicelyUITests.ID.playButton)
        if identifiedControl.exists {
            return identifiedControl
        }
        return buttons["Play"].firstMatch
    }

    var playbackRateControl: XCUIElement {
        let identifiedControl = element(id: VoicelyUITests.ID.playbackRateButton)
        if identifiedControl.exists {
            return identifiedControl
        }
        return buttons["Playback Speed"].firstMatch
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
