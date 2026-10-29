//
//  NeuralSpeechAnalyzer.swift
//  Voicely
//

import AVFoundation
import Foundation
import os

enum NeuralSpeechAnalyzerError: Error {
    case audioConversionUnavailable
}

/// How sure the VAD is that a slice holds speech.
enum SpeechPresence: Equatable {
    case speech
    /// Some activity, but below the speech rule. The slice is transcribed, and
    /// only output that is more than a fragment is kept.
    case uncertain
    /// Confident silence; the slice is not transcribed.
    case silence
}

enum NeuralSpeechAnalyzer {
    /// Logged in release builds too: whether the sound classifier runs on a
    /// locked iPhone is only known from the field.
    private static let gateLog = Logger(subsystem: "com.hellotaotao.Voicely", category: "SpeechGate")
    /// EverLog-style conservative VAD gate: only skip audio when neural VAD is confidently silent.
    /// Confirmed speech passes immediately; uncertain activity must persist briefly.
    private static let speechThreshold = 0.55
    private static let silenceThreshold = 0.40
    private static let minimumSpeechSeconds = 0.25
    /// Below this peak probability a slice is confident silence. Calibrated on
    /// three meeting recordings: every slice with speech peaked at 0.43 or more
    /// (far-field speech sits at 0.43–0.50, under the speech rule), while digital
    /// silence and white noise peaked at 0.04–0.08 and the quietest real gap at 0.35.
    static let uncertainSpeechThreshold = 0.30
    /// Source-side read size for the streaming scan. Peak memory stays constant
    /// for any file length instead of loading the whole recording at once.
    private static let streamingChunkSeconds = 10.0

    /// A failed scan counts as speech: dropping audio is worse than decoding it.
    static func safelySpeechPresence(
        at fileURL: URL,
        secondOpinion: SpeechSecondOpinion = SoundClassifierSpeechCheck()
    ) -> SpeechPresence {
        let presence: SpeechPresence
        do {
            presence = try speechPresence(at: fileURL, detector: SileroNeuralVoiceActivityDetector())
        } catch {
            debugLog("⚠️ [NeuralSpeechAnalyzer] Neural VAD preflight failed: \(error)")
            return .speech
        }
        return reviewedPresence(presence, at: fileURL, secondOpinion: secondOpinion)
    }

    /// Silence is the one verdict that drops audio, and Silero can be deaf to
    /// a whole voice, so a second judge reviews it. When that judge hears
    /// speech the slice is decoded as uncertain, which still drops fragments.
    /// A failed review keeps the silence: that is how the gate behaves without it.
    static func reviewedPresence(
        _ presence: SpeechPresence,
        at fileURL: URL,
        secondOpinion: SpeechSecondOpinion
    ) -> SpeechPresence {
        guard presence == .silence else { return presence }
        do {
            if try secondOpinion.containsSpeech(at: fileURL) {
                gateLog.notice("VAD heard silence, sound classifier heard speech: decoding")
                return .uncertain
            }
        } catch {
            gateLog.error("Sound classifier review failed: \(String(describing: error), privacy: .public)")
        }
        return .silence
    }

    static func containsProbableSpeech(
        at fileURL: URL,
        detector: NeuralVoiceActivityDetecting
    ) throws -> Bool {
        try speechPresence(at: fileURL, detector: detector) == .speech
    }

    /// Streams the file chunk by chunk — convert to 16 kHz mono, score with the
    /// detector, stop at the first probable-speech frame — so a full scan only
    /// happens when the recording contains no confirmed speech.
    static func speechPresence(
        at fileURL: URL,
        detector: NeuralVoiceActivityDetecting
    ) throws -> SpeechPresence {
        let sourceFile = try AVAudioFile(forReading: fileURL)
        guard sourceFile.length > 0 else { return .silence }

        let sourceFormat = sourceFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(SileroNeuralVoiceActivityDetector.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw NeuralSpeechAnalyzerError.audioConversionUnavailable
        }

        let windowSize = SileroNeuralVoiceActivityDetector.chunkSize
        let chunkFrames = AVAudioFrameCount(streamingChunkSeconds * sourceFormat.sampleRate)
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(chunkFrames) * outputFormat.sampleRate / sourceFormat.sampleRate)
        ) + AVAudioFrameCount(windowSize)

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw NeuralSpeechAnalyzerError.audioConversionUnavailable
        }

        // Samples that don't fill a whole VAD window carry over to the next
        // chunk, so zero-padding happens at most once — at the end of the file.
        var pendingSamples: [Float] = []
        var uncertainSpeechSeconds: TimeInterval = 0
        var peakProbability = 0.0

        while sourceFile.framePosition < sourceFile.length {
            inputBuffer.frameLength = 0
            try sourceFile.read(into: inputBuffer, frameCount: chunkFrames)
            guard inputBuffer.frameLength > 0 else { break }

            outputBuffer.frameLength = 0
            var conversionError: NSError?
            var didProvideInput = false
            converter.convert(to: outputBuffer, error: &conversionError) { _, status in
                if didProvideInput {
                    status.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                status.pointee = .haveData
                return inputBuffer
            }
            if let conversionError {
                throw conversionError
            }

            if let channelData = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                pendingSamples.append(contentsOf: UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(outputBuffer.frameLength)
                ))
            }

            let usableCount = pendingSamples.count - pendingSamples.count % windowSize
            if usableCount > 0 {
                let windowedSamples = Array(pendingSamples.prefix(usableCount))
                pendingSamples.removeFirst(usableCount)
                if try containsProbableSpeech(in: windowedSamples, detector: detector,
                    uncertainSpeechSeconds: &uncertainSpeechSeconds, peakProbability: &peakProbability) {
                    return .speech
                }
            }
        }

        if !pendingSamples.isEmpty, try containsProbableSpeech(in: pendingSamples, detector: detector,
            uncertainSpeechSeconds: &uncertainSpeechSeconds, peakProbability: &peakProbability) {
            return .speech
        }
        return peakProbability >= uncertainSpeechThreshold ? .uncertain : .silence
    }

    static func containsProbableSpeech(
        in samples: [Float],
        detector: NeuralVoiceActivityDetecting,
        speechThreshold: Double = Self.speechThreshold,
        silenceThreshold: Double = Self.silenceThreshold,
        minimumSpeechSeconds: TimeInterval = Self.minimumSpeechSeconds
    ) throws -> Bool {
        var uncertainSpeechSeconds: TimeInterval = 0
        var peakProbability = 0.0
        return try containsProbableSpeech(in: samples, detector: detector,
            speechThreshold: speechThreshold, silenceThreshold: silenceThreshold,
            minimumSpeechSeconds: minimumSpeechSeconds,
            uncertainSpeechSeconds: &uncertainSpeechSeconds, peakProbability: &peakProbability)
    }

    private static func containsProbableSpeech(
        in samples: [Float],
        detector: NeuralVoiceActivityDetecting,
        speechThreshold: Double = Self.speechThreshold,
        silenceThreshold: Double = Self.silenceThreshold,
        minimumSpeechSeconds: TimeInterval = Self.minimumSpeechSeconds,
        uncertainSpeechSeconds: inout TimeInterval,
        peakProbability: inout Double
    ) throws -> Bool {
        guard !samples.isEmpty else { return false }

        let vadFrames = try detector.speechProbabilities(in: samples)
        guard !vadFrames.isEmpty else { return false }

        let secondsPerSample = 1.0 / Double(SileroNeuralVoiceActivityDetector.sampleRate)

        for frame in vadFrames {
            peakProbability = max(peakProbability, frame.speechProbability)
            if frame.speechProbability >= speechThreshold {
                return true
            }

            // Isolated uncertain spikes must not admit an otherwise silent chunk.
            // Carry the duration across streaming reads so boundaries do not drop speech.
            if frame.speechProbability > silenceThreshold {
                uncertainSpeechSeconds += Double(frame.endFrame - frame.startFrame) * secondsPerSample
                if uncertainSpeechSeconds >= minimumSpeechSeconds { return true }
            } else {
                uncertainSpeechSeconds = 0
            }
        }

        return false
    }

}
