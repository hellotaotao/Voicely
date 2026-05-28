//
//  RecordingActivityAttributes.swift
//  VoicelyWidgets
//
//  Created by Codex on 5/28/2026.
//

import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var recordingState: RecordingState
        var timerBaseDate: Date
        var elapsedDuration: TimeInterval
        var scheduledEndDate: Date?
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
