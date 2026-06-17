//
//  NeuralSpeechAnalyzer.swift
//  Voicely
//

import AVFoundation
import Foundation

enum NeuralSpeechAnalyzerError: Error {
    case audioConversionUnavailable
}

enum NeuralSpeechAnalyzer {
    /// EverLog-style conservative VAD gate: only skip audio when neural VAD is confidently silent.
    /// Any uncertain frame is treated as speech-present so Voicely does not silently drop user speech.
    private static let speechThreshold = 0.55
    private static let silenceThreshold = 0.40
    private static let minimumSpeechSeconds = 0.25
    /// Source-side read size for the streaming scan. Peak memory stays constant
    /// for any file length instead of loading the whole recording at once.
    private static let streamingChunkSeconds = 10.0

    static func safelyContainsProbableSpeech(at fileURL: URL) -> Bool {
        do {
            return try containsProbableSpeech(at: fileURL)
        } catch {
            debugLog("⚠️ [NeuralSpeechAnalyzer] Neural VAD preflight failed: \(error)")
            return true
        }
    }

    static func containsProbableSpeech(at fileURL: URL) throws -> Bool {
        try containsProbableSpeech(at: fileURL, detector: SileroNeuralVoiceActivityDetector())
    }

    /// Streams the file chunk by chunk — convert to 16 kHz mono, score with the
    /// detector, stop at the first probable-speech frame — so a full scan only
    /// happens when the recording truly contains no speech.
    static func containsProbableSpeech(
        at fileURL: URL,
        detector: NeuralVoiceActivityDetecting
    ) throws -> Bool {
        let sourceFile = try AVAudioFile(forReading: fileURL)
        guard sourceFile.length > 0 else { return false }

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
                if try containsProbableSpeech(in: windowedSamples, detector: detector) {
                    return true
                }
            }
        }

        guard !pendingSamples.isEmpty else { return false }
        return try containsProbableSpeech(in: pendingSamples, detector: detector)
    }

    static func containsProbableSpeech(
        in samples: [Float],
        detector: NeuralVoiceActivityDetecting,
        speechThreshold: Double = Self.speechThreshold,
        silenceThreshold: Double = Self.silenceThreshold,
        minimumSpeechSeconds: TimeInterval = Self.minimumSpeechSeconds
    ) throws -> Bool {
        guard !samples.isEmpty else { return false }

        let vadFrames = try detector.speechProbabilities(in: samples)
        guard !vadFrames.isEmpty else { return false }

        var confirmedSpeechSeconds: TimeInterval = 0
        let secondsPerSample = 1.0 / Double(SileroNeuralVoiceActivityDetector.sampleRate)

        for frame in vadFrames {
            if frame.speechProbability >= speechThreshold {
                confirmedSpeechSeconds += Double(frame.endFrame - frame.startFrame) * secondsPerSample
                if confirmedSpeechSeconds >= minimumSpeechSeconds {
                    return true
                }
            } else {
                confirmedSpeechSeconds = 0
            }

            // Conservative skip policy: uncertain frames are not silence, so transcribe them.
            if frame.speechProbability > silenceThreshold {
                return true
            }
        }

        return false
    }

}
