//
//  AudioInterruptionDecisionTests.swift
//  VoicelyTests
//
//  Created by Claude on 6/21/2026.
//

#if !os(macOS) || targetEnvironment(macCatalyst)
import AVFoundation
import Testing
@testable import Voicely

struct AudioInterruptionDecisionTests {
    @Test func beganInterruptionEndsRecording() {
        #expect(AudioInterruptionDecision.shouldEndRecording(
            typeRawValue: AVAudioSession.InterruptionType.began.rawValue
        ) == true)
    }

    @Test func endedInterruptionDoesNotEndRecording() {
        #expect(AudioInterruptionDecision.shouldEndRecording(
            typeRawValue: AVAudioSession.InterruptionType.ended.rawValue
        ) == false)
    }

    @Test func userInfoWithBeganTypeEndsRecording() {
        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ]

        #expect(AudioInterruptionDecision.shouldEndRecording(userInfo: userInfo) == true)
    }

    @Test func missingUserInfoDoesNotEndRecording() {
        #expect(AudioInterruptionDecision.shouldEndRecording(userInfo: nil) == false)
    }
}
#endif
