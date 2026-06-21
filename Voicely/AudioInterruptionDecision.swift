//
//  AudioInterruptionDecision.swift
//  Voicely
//
//  Created by Claude on 6/21/2026.
//

#if !os(macOS) || targetEnvironment(macCatalyst)
import AVFoundation

/// Pure decision logic for how to react to an `AVAudioSession` interruption.
///
/// Policy: an interruption (incoming call, another app taking the audio
/// session, etc.) ends the in-progress recording. iOS forbids restarting
/// input IO from the background, so attempting to resume across an
/// interruption is unreliable; ending cleanly keeps the UI honest.
enum AudioInterruptionDecision {
    /// Whether the interruption of the given raw type should finalize the
    /// active recording. Only `.began` ends it; `.ended` is ignored.
    static func shouldEndRecording(typeRawValue: UInt) -> Bool {
        AVAudioSession.InterruptionType(rawValue: typeRawValue) == .began
    }

    /// Convenience over a notification's `userInfo` payload.
    static func shouldEndRecording(userInfo: [AnyHashable: Any]?) -> Bool {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
            return false
        }
        return shouldEndRecording(typeRawValue: raw)
    }
}
#endif
