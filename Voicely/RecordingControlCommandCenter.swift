//
//  RecordingControlCommandCenter.swift
//  Voicely
//
//  Created by Codex on 5/31/2026.
//

import Foundation

/// Hands the Live Activity's pause control to the recording session that owns
/// the current recording. With no session registered nothing is recording, so
/// there is nothing to pause.
@MainActor
final class RecordingControlCommandCenter {
    static let shared = RecordingControlCommandCenter()

    private var pauseHandler: ((_ paused: Bool) -> Void)?

    private init() {}

    func setPauseHandler(_ handler: @escaping (_ paused: Bool) -> Void) {
        pauseHandler = handler
    }

    func clearPauseHandler() {
        pauseHandler = nil
    }

    @discardableResult
    func setPaused(_ paused: Bool) -> Bool {
        guard let pauseHandler else { return false }
        pauseHandler(paused)
        return true
    }
}
