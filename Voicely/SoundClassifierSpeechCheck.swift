//
//  SoundClassifierSpeechCheck.swift
//  Voicely
//

import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis

/// A second judge of whether a slice holds speech, asked only when the VAD
/// is about to drop the slice as silence.
protocol SpeechSecondOpinion {
    /// Throws when the check cannot run; the caller then keeps the VAD's verdict.
    func containsSpeech(at fileURL: URL) throws -> Bool
}

/// Apple's built-in sound classifier (SoundAnalysis, version 1).
///
/// Silero scores some voices near zero: in a 30-minute English lecture the
/// presenter's dry, phone-like voice scored 0.01 while being plainly audible,
/// so whole slices of real speech were dropped. This classifier relies on
/// different cues and scored the same voice 0.77–0.82. On three meeting
/// recordings (386 slices) every slice with speech peaked at 0.70 or more,
/// while digital silence, white noise, rumble, typing and synthetic music
/// stayed at or below 0.01.
///
/// Its windows are at least 0.5 s, too coarse to place cuts, so Silero keeps
/// that job and this check only overrides a "silence" verdict.
final class SoundClassifierSpeechCheck: SpeechSecondOpinion {
    static let speechConfidenceThreshold = 0.5
    static let windowSeconds = 1.5
    /// The shortest window the classifier accepts.
    static let minimumWindowSeconds = 0.5
    static let overlapFactor = 0.5

    /// A file shorter than the window yields no result at all, so a short
    /// tail slice or a one-word note gets a window as long as the file:
    /// 0.6–0.9 s answers then score 0.62–0.99, and noise of that length
    /// stays at or below 0.11.
    static func windowSeconds(forFileSeconds fileSeconds: Double) -> Double {
        min(windowSeconds, max(minimumWindowSeconds, fileSeconds))
    }

    func containsSpeech(at fileURL: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: fileURL)
        let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(
            seconds: Self.windowSeconds(forFileSeconds: fileSeconds),
            preferredTimescale: 1_000
        )
        request.overlapFactor = Self.overlapFactor

        let analyzer = try SNAudioFileAnalyzer(url: fileURL)
        let observer = Observer(threshold: Self.speechConfidenceThreshold)
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()

        if let error = observer.failure { throw error }
        return observer.foundSpeech
    }

    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let threshold: Double
        private let lock = NSLock()
        private var speech = false
        private var error: Error?

        init(threshold: Double) {
            self.threshold = threshold
        }

        var foundSpeech: Bool { lock.withLock { speech } }
        var failure: Error? { lock.withLock { error } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult,
                  let confidence = classification.classification(forIdentifier: "speech")?.confidence,
                  confidence >= threshold else { return }
            lock.withLock { speech = true }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.withLock { self.error = error }
        }
    }
}
