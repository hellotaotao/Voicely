//
//  NeuralSpeechAnalyzer.swift
//  Voicely
//

import AVFoundation
import Foundation

enum NeuralSpeechAnalyzer {
    /// EverLog-style conservative VAD gate: only skip audio when neural VAD is confidently silent.
    /// Any uncertain frame is treated as speech-present so Voicely does not silently drop user speech.
    private static let speechThreshold = 0.55
    private static let silenceThreshold = 0.40
    private static let minimumSpeechSeconds = 0.25

    static func safelyContainsProbableSpeech(at fileURL: URL) -> Bool {
        do {
            return try containsProbableSpeech(at: fileURL)
        } catch {
            debugLog("⚠️ [NeuralSpeechAnalyzer] Neural VAD preflight failed: \(error)")
            return true
        }
    }

    static func containsProbableSpeech(at fileURL: URL) throws -> Bool {
        let samples = try mono16kSamples(from: fileURL)
        let detector = try SileroNeuralVoiceActivityDetector()
        return try containsProbableSpeech(in: samples, detector: detector)
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

    private static func mono16kSamples(from fileURL: URL) throws -> [Float] {
        let sourceFile = try AVAudioFile(forReading: fileURL)
        let sourceFormat = sourceFile.processingFormat
        guard sourceFile.length > 0 else { return [] }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFile.length)
        ) else {
            return []
        }
        try sourceFile.read(into: inputBuffer)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(SileroNeuralVoiceActivityDetector.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            return []
        }

        let estimatedOutputFrames = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / sourceFormat.sampleRate)
        ) + AVAudioFrameCount(SileroNeuralVoiceActivityDetector.chunkSize)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(estimatedOutputFrames, AVAudioFrameCount(SileroNeuralVoiceActivityDetector.chunkSize))
        ) else {
            return []
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
