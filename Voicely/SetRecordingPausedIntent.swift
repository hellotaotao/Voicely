//
//  SetRecordingPausedIntent.swift
//  Voicely
//
//  Created by Codex on 5/31/2026.
//

import AppIntents
import Foundation

/// Pauses or resumes the recording from the Live Activity.
///
/// It carries the state the person asked for instead of toggling, so the
/// widget's `Toggle` can draw the new state the moment it is tapped, and a
/// repeated tap can never flip the recording the wrong way. As a
/// `LiveActivityIntent`, `perform()` runs in the app process; the widget
/// extension keeps a copy with the same shape only so its `Toggle` can name it.
struct SetRecordingPausedIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let description = IntentDescription(
        "Pauses or resumes the active Voicely recording from the Live Activity."
    )

    @Parameter(title: "Paused")
    var value: Bool

    init() {}

    init(paused: Bool) {
        value = paused
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingControlCommandCenter.shared.setPaused(value)
        return .result()
    }
}
