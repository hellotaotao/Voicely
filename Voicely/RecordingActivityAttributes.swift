//
//  RecordingActivityAttributes.swift
//  Voicely
//
//  Created by Codex on 5/28/2026.
//

import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

struct RecordingActivityAttributes {
    struct ContentState: Codable, Hashable {
        var recordingState: RecordingState
        var timerBaseDate: Date
        var elapsedDuration: TimeInterval
        var scheduledEndDate: Date?

        static func active(
            elapsedDuration: TimeInterval = 0,
            now: Date = Date(),
            scheduledEndDate: Date? = nil
        ) -> ContentState {
            ContentState(
                recordingState: .recording,
                timerBaseDate: now.addingTimeInterval(-elapsedDuration),
                elapsedDuration: elapsedDuration,
                scheduledEndDate: scheduledEndDate
            )
        }
    }

    enum RecordingState: String, Codable, Hashable {
        case recording
        case paused
        case stopping

        var displayName: String {
            switch self {
            case .recording: return "Recording"
            case .paused: return "Paused"
            case .stopping: return "Stopping"
            }
        }
    }

    var recordingID: UUID
    var title: String
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
extension RecordingActivityAttributes: ActivityAttributes {}
#endif
