//
//  VoicelyDeepLinkTests.swift
//  VoicelyTests
//
//  Created by Codex on 5/28/2026.
//

import Foundation
import Testing
@testable import Voicely

struct VoicelyDeepLinkTests {
    @Test func recordDeepLinkParsesRecordHost() throws {
        let url = try #require(URL(string: "voicely://record"))

        #expect(VoicelyDeepLink(url: url) == .startRecording)
    }

    @Test func recordingTogglePauseDeepLinkParsesRecordingPath() throws {
        let url = try #require(URL(string: "voicely://recording/toggle-pause"))

        #expect(VoicelyDeepLink(url: url) == .toggleRecordingPause)
    }

    @Test func nonVoicelyURLIsNotADeepLink() throws {
        let url = try #require(URL(string: "file:///tmp/meeting.m4a"))

        #expect(VoicelyDeepLink(url: url) == nil)
    }
}
