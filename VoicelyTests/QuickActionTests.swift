//
//  QuickActionTests.swift
//  VoicelyTests
//
//  Created by Codex on 5/29/2026.
//

import Testing
import UIKit
@testable import Voicely

@MainActor
struct QuickActionTests {
    @Test func startRecordingShortcutPerformedWhileRunningRequestsStartRecording() {
        clearPendingStartRecording()

        let shortcutItem = UIApplicationShortcutItem(
            type: QuickAction.startRecordingType,
            localizedTitle: "Start Recording"
        )
        var didRequestStartRecording = false

        let didHandle = AppDelegate().handleShortcutItem(shortcutItem) {
            didRequestStartRecording = true
        }

        #expect(didHandle == true)
        #expect(didRequestStartRecording == true)
    }

    @Test func unknownShortcutDoesNotMarkPendingStartRecordingRequest() {
        clearPendingStartRecording()

        let shortcutItem = UIApplicationShortcutItem(
            type: "au.taotao.voicely.unknown",
            localizedTitle: "Unknown"
        )
        var didRequestStartRecording = false

        let didHandle = AppDelegate().handleShortcutItem(shortcutItem) {
            didRequestStartRecording = true
        }

        #expect(didHandle == false)
        #expect(didRequestStartRecording == false)
        #expect(QuickAction.consumePendingStartRecording() == false)
    }

    @Test func startRecordingRequestMarksPendingBeforePostingNotification() {
        clearPendingStartRecording()
        var didPostNotification = false
        var wasPendingWhenNotificationPosted = false

        QuickAction.requestStartRecording {
            didPostNotification = true
            wasPendingWhenNotificationPosted = QuickAction.consumePendingStartRecording()
        }

        #expect(didPostNotification == true)
        #expect(wasPendingWhenNotificationPosted == true)
        #expect(QuickAction.consumePendingStartRecording() == false)
    }

    @Test func toggleRecordingPauseIntentRunsRegisteredHandler() async throws {
        var didTogglePause = false
        RecordingControlCommandCenter.shared.setTogglePauseHandler {
            didTogglePause = true
        }
        defer {
            RecordingControlCommandCenter.shared.clearTogglePauseHandler()
        }

        _ = try await ToggleRecordingPauseIntent().perform()

        #expect(didTogglePause == true)
    }

    @Test func toggleRecordingPauseIntentFallsBackToNotificationWithoutHandler() async throws {
        RecordingControlCommandCenter.shared.clearTogglePauseHandler()
        var didPostNotification = false
        let observer = NotificationCenter.default.addObserver(
            forName: .toggleRecordingPauseQuickAction,
            object: nil,
            queue: nil
        ) { _ in
            didPostNotification = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        _ = try await ToggleRecordingPauseIntent().perform()

        #expect(didPostNotification == true)
    }

    private func clearPendingStartRecording() {
        while QuickAction.consumePendingStartRecording() {}
    }
}
