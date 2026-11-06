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

    @Test func setRecordingPausedIntentPassesRequestedStateToHandler() async throws {
        var requested: [Bool] = []
        RecordingControlCommandCenter.shared.setPauseHandler { paused in
            requested.append(paused)
        }
        defer {
            RecordingControlCommandCenter.shared.clearPauseHandler()
        }

        _ = try await SetRecordingPausedIntent(paused: true).perform()
        _ = try await SetRecordingPausedIntent(paused: false).perform()

        #expect(requested == [true, false])
    }

    @Test func setRecordingPausedIntentDoesNothingWithoutHandler() async throws {
        RecordingControlCommandCenter.shared.clearPauseHandler()

        _ = try await SetRecordingPausedIntent(paused: true).perform()

        #expect(RecordingControlCommandCenter.shared.setPaused(true) == false)
    }

    private func clearPendingStartRecording() {
        while QuickAction.consumePendingStartRecording() {}
    }
}
