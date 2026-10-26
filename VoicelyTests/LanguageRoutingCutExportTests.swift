//
//  LanguageRoutingCutExportTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Opt-in, local-only input for `LanguageRoutingCutExportTests`: put 16 kHz mono
/// CAFs in `<tmp>/voicely-lid/` (inside the test host's container).
enum LanguageRoutingCutExportInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-lid", isDirectory: true)
    static var audioURLs: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".caf") }.sorted().map { directory.appendingPathComponent($0) }
    }
    static var isConfigured: Bool { !audioURLs.isEmpty }
}

/// Writes, for each recording, the production slices (the same walk as
/// `VADCutReplayTests`) and the neural VAD speech probability of every 36 ms
/// frame of each slice, so a language-routing experiment can slice audio and
/// tell silence from speech exactly as the app would.
@Suite(.serialized, .enabled(if: LanguageRoutingCutExportInput.isConfigured))
struct LanguageRoutingCutExportTests {
    private struct Slice: Encodable {
        let start: Double
        let end: Double
        /// Speech probability per 36 ms VAD frame across the whole slice, 3 decimals.
        let probabilities: [Double]
    }

    @Test func exportSlicesAndSpeechProbabilities() throws {
        let limits = Qwen3SliceLimits.production
        var configuration = IncrementalVoiceActivityCutConfiguration.default
        configuration.minimumCutSeconds = limits.minimumCutSeconds

        for url in LanguageRoutingCutExportInput.audioURLs {
            let outURL = url.deletingPathExtension().appendingPathExtension("slices.json")
            if FileManager.default.fileExists(atPath: outURL.path) { continue }
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            let totalFrames = file.length
            let batchFrames = Int64(limits.chunkSeconds * sampleRate)
            let detector = try SileroNeuralVoiceActivityDetector()
            var slices: [Slice] = []
            var start: Int64 = 0
            while start < totalFrames {
                let target = min(start + batchFrames, totalFrames)
                var end = target
                if target < totalFrames {
                    let cut = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                        fileURL: url, startFrame: start, targetFrame: target,
                        targetSegmentSeconds: limits.chunkSeconds, configuration: configuration)
                    if cut > start { end = cut }
                }
                file.framePosition = start
                let count = AVAudioFrameCount(end - start)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
                try file.read(into: buffer, frameCount: count)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                let probabilities = try detector.speechProbabilities(in: samples)
                    .map { ($0.speechProbability * 1000).rounded() / 1000 }
                slices.append(Slice(start: Double(start) / sampleRate, end: Double(end) / sampleRate,
                                    probabilities: probabilities))
                start = end
            }
            try JSONEncoder().encode(slices).write(to: outURL)
            print("✅ [LanguageRoutingCutExport] \(url.lastPathComponent): \(slices.count) slices")
        }
    }
}
