//
//  SetRecordingPausedIntent.swift
//  VoicelyWidgets
//
//  Created by Codex on 5/31/2026.
//

import AppIntents
import Foundation

/// Widget-side twin of the app's intent. The system runs a `LiveActivityIntent`
/// in the app process, so this `perform()` is never the one that pauses.
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

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
