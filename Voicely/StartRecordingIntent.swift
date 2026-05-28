//
//  StartRecordingIntent.swift
//  Voicely
//
//  Created by Codex on 5/28/2026.
//

import AppIntents
import Foundation

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Voicely Recording"
    static let description = IntentDescription(
        "Opens Voicely and starts the visible recording flow."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickAction.markPendingStartRecording()
        QuickAction.postStartRecordingRequest()
        return .result()
    }
}

struct VoicelyAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start a \(.applicationName) recording",
                "Record a meeting in \(.applicationName)",
                "Record a sensitive meeting in \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
    }
}
