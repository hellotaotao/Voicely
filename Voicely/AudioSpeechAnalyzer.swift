//
//  AudioSpeechAnalyzer.swift
//  Voicely
//

import AVFoundation
import Foundation

enum AudioSpeechAnalyzer {
    private static let chunkSeconds = 0.2
    private static let rmsSpeechThreshold: Float = 0.0035
    private static let peakSpeechThreshold: Float = 0.025
    private static let minimumActiveSpeechSeconds = 0.12

    static func safelyContainsProbableSpeech(at fileURL: URL) -> Bool {
        do {
            return try containsProbableSpeech(at: fileURL)
        } catch {
            return true
        }
    }

    static func containsProbableSpeech(at fileURL: URL) throws -> Bool {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return true }

        let framesPerChunk = AVAudioFrameCount(max(1, Int(sampleRate * chunkSeconds)))
        var activeSpeechSeconds = 0.0

        while audioFile.framePosition < audioFile.length {
            let remainingFrames = audioFile.length - audioFile.framePosition
            guard remainingFrames > 0 else { break }

            let framesToRead = min(framesPerChunk, AVAudioFrameCount(remainingFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                return true
            }

            try audioFile.read(into: buffer, frameCount: framesToRead)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }

            guard let energy = energy(in: buffer) else {
                return true
            }

            if energy.rms >= rmsSpeechThreshold || energy.peak >= peakSpeechThreshold {
                activeSpeechSeconds += Double(frameLength) / sampleRate
                if activeSpeechSeconds >= minimumActiveSpeechSeconds {
                    return true
                }
            }
        }

        return false
    }

    private static func energy(in buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float)? {
        guard let channelData = buffer.floatChannelData else { return nil }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return nil }

        var sumSquares = 0.0
        var peak: Float = 0.0

        for frame in 0..<frameLength {
            var sample: Float = 0.0
            for channel in 0..<channelCount {
                sample += channelData[channel][frame] / Float(channelCount)
            }

            let absoluteSample = Swift.abs(sample)
            peak = max(peak, absoluteSample)
            sumSquares += Double(sample) * Double(sample)
        }

        let rms = Float(sqrt(sumSquares / Double(frameLength)))
        return (rms, peak)
    }
}
