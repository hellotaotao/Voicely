//
//  AudioSessionActivation.swift
//  Voicely
//

import AVFoundation

#if !os(macOS) || targetEnvironment(macCatalyst)
/// Activating or deactivating the shared audio session is an IPC round trip to
/// the audio server that can block for a long time, so it must stay off the main
/// thread (the asynchronous activation API needs iOS 27). One serial queue keeps
/// every change, from recording and playback alike, in the order it was requested,
/// so a queued deactivation can never land after a later activation.
enum AudioSessionActivation {
    private static let queue = DispatchQueue(label: "com.hellotaotao.Voicely.audio-session", qos: .userInitiated)

    /// Runs `change` on the session queue and waits for it to finish.
    static func perform(_ change: @escaping @Sendable (AVAudioSession) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try change(AVAudioSession.sharedInstance())
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Queues `change` behind pending session changes without waiting for it.
    static func enqueue(_ change: @escaping @Sendable (AVAudioSession) throws -> Void) {
        queue.async {
            do {
                try change(AVAudioSession.sharedInstance())
            } catch {
                debugLog("⚠️ [AudioSessionActivation] Session change failed: \(error)")
            }
        }
    }
}
#endif
