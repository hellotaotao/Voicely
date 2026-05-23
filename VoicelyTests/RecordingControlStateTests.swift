//
//  RecordingControlStateTests.swift
//  VoicelyTests
//
//  Created by Codex on 5/23/2026.
//

import Foundation
import Testing
@testable import Voicely

struct RecordingControlStateTests {
    @Test func startingPhaseShowsBeforeAudioServiceReportsRecording() {
        #expect(RecordingControlState.phase(isRecording: false, isStarting: true) == .starting)
        #expect(RecordingControlState.phase(isRecording: true, isStarting: true) == .recording)
        #expect(RecordingControlState.phase(isRecording: false, isStarting: false) == .idle)
    }

    @Test func immediateSecondTapCannotStopFreshRecording() {
        let startedAt = Date(timeIntervalSince1970: 1_000)

        #expect(RecordingControlState.shouldAcceptStopRequest(
            isStarting: true,
            recordingStartedAt: nil,
            now: startedAt.addingTimeInterval(10),
            recordingDuration: 10
        ) == false)

        #expect(RecordingControlState.shouldAcceptStopRequest(
            isStarting: false,
            recordingStartedAt: startedAt,
            now: startedAt.addingTimeInterval(0.2),
            recordingDuration: 0.2
        ) == false)

        #expect(RecordingControlState.shouldAcceptStopRequest(
            isStarting: false,
            recordingStartedAt: startedAt,
            now: startedAt.addingTimeInterval(1.2),
            recordingDuration: 1.2
        ) == true)
    }
}
