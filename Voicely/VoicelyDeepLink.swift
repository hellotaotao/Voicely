//
//  VoicelyDeepLink.swift
//  Voicely
//
//  Created by Codex on 5/28/2026.
//

import Foundation

enum VoicelyDeepLink: Equatable {
    case startRecording

    init?(url: URL) {
        guard url.scheme?.localizedCaseInsensitiveCompare("voicely") == .orderedSame else {
            return nil
        }

        let host = url.host()?.lowercased()
        let pathComponents = url.pathComponents
            .map { $0.lowercased() }
            .filter { $0 != "/" }

        if host == "record" || pathComponents.first == "record" {
            self = .startRecording
            return
        }

        return nil
    }
}
