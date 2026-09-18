//
//  RecordingNotePhase.swift
//  Voicely
//

import Foundation

/// Where a locally recorded note is in its lifecycle, derived from note fields.
/// A recording has no duration until it stops, so duration alone separates
/// "still recording" from "stopped, finishing the transcript". Live text that is
/// already visible must not keep a stopped recording labelled as recording.
enum RecordingNotePhase: Equatable {
    case none
    case recording(hasLiveText: Bool)
    case finalizing

    init(
        isTranscribing: Bool,
        duration: TimeInterval,
        hasVisibleTranscript: Bool,
        isOwnedByTranscriptionJob: Bool
    ) {
        guard isTranscribing, !isOwnedByTranscriptionJob else {
            self = .none
            return
        }
        self = duration > 0 ? .finalizing : .recording(hasLiveText: hasVisibleTranscript)
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isLiveUpdatingTranscript: Bool {
        self == .recording(hasLiveText: true)
    }

    var isFinalizing: Bool {
        self == .finalizing
    }
}
