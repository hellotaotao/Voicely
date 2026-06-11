//
//  RecordingControlCommandCenter.swift
//  Voicely
//
//  Created by Codex on 5/31/2026.
//

import Foundation

@MainActor
final class RecordingControlCommandCenter {
    static let shared = RecordingControlCommandCenter()

    private var togglePauseHandler: (() -> Void)?

    private init() {}

    func setTogglePauseHandler(_ handler: @escaping () -> Void) {
        togglePauseHandler = handler
    }

    func clearTogglePauseHandler() {
        togglePauseHandler = nil
    }

    @discardableResult
    func togglePauseResume() -> Bool {
        guard let togglePauseHandler else { return false }
        togglePauseHandler()
        return true
    }
}
