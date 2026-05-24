//
//  RecordingControlState.swift
//  Voicely
//
//  Created by Codex on 5/23/2026.
//

import Foundation

enum RecordingControlPhase: Equatable {
    case idle
    case starting
    case recording
}

enum RecordingControlState {
    static let accidentalStopProtectionInterval: TimeInterval = 1.0

    static func phase(isRecording: Bool, isStarting: Bool) -> RecordingControlPhase {
        if isRecording {
            return .recording
        }

        if isStarting {
            return .starting
        }

        return .idle
    }

    static func shouldAcceptStopRequest(
        isStarting: Bool,
        recordingStartedAt: Date?,
        now: Date,
        recordingDuration: TimeInterval
    ) -> Bool {
        guard !isStarting else {
            return false
        }

        guard let recordingStartedAt else {
            return true
        }

        let elapsedSinceStart = now.timeIntervalSince(recordingStartedAt)
        let elapsed = max(elapsedSinceStart, recordingDuration)
        return elapsed >= accidentalStopProtectionInterval
    }
}

enum RecordingSessionPrewarmState {
    static func shouldStartPrewarm(
        hasPermission: Bool,
        isRecording: Bool,
        isPrewarming: Bool,
        isPrewarmed: Bool
    ) -> Bool {
        hasPermission && !isRecording && !isPrewarming && !isPrewarmed
    }
}
