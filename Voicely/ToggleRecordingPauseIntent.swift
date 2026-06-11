//
//  ToggleRecordingPauseIntent.swift
//  Voicely
//
//  Created by Codex on 5/31/2026.
//

import AppIntents
import Foundation

struct ToggleRecordingPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Recording Pause"
    static let description = IntentDescription(
        "Pauses or resumes the active Voicely recording from the Live Activity."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        if !RecordingControlCommandCenter.shared.togglePauseResume() {
            NotificationCenter.default.post(name: .toggleRecordingPauseQuickAction, object: nil)
        }
        return .result()
    }
}
