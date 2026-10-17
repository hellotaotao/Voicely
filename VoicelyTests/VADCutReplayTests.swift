//
//  VADCutReplayTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Opt-in, local-only input for `VADCutReplayTests`: copy one or more 16 kHz
/// mono CAFs named `cuts-<name>.caf` to `<tmp>/voicely-replay/` (inside the test
/// host's container).
enum VADCutReplayInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-replay", isDirectory: true)
    static var audioURLs: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("cuts-") && $0.hasSuffix(".caf") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
    static var isConfigured: Bool { !audioURLs.isEmpty }
}

/// Walks a real recording with the production slice limits the way
/// `SegmentedAudioTranscriber` does and writes every cut the neural VAD picks
/// to `cuts-<name>.json`, so cut placement can be judged offline (word
/// boundaries, pause depth) without decoding.
@Suite(.serialized, .enabled(if: VADCutReplayInput.isConfigured))
struct VADCutReplayTests {
    private struct Slice: Encodable {
        let start: Double
        let end: Double
        /// The cut fell on the batch end: no pause was chosen.
        let atBatchEnd: Bool
        /// Speech probability of each 36 ms VAD frame over the window the cut
        /// was searched in, rounded to 3 decimals. Empty for the final slice.
        let windowProbabilities: [Double]
    }

    @Test func recordCutsForEachRecording() throws {
        let limits = Qwen3SliceLimits.production
        var configuration = IncrementalVoiceActivityCutConfiguration.default
        configuration.minimumCutSeconds = limits.minimumCutSeconds

        for url in VADCutReplayInput.audioURLs {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            let totalFrames = file.length
            let batchFrames = Int64(limits.chunkSeconds * sampleRate)
            var slices: [Slice] = []
            let detector = try SileroNeuralVoiceActivityDetector()
            let minimumCutFrames = Int64(limits.minimumCutSeconds * sampleRate)
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
                var probabilities: [Double] = []
                if target < totalFrames {
                    let windowStart = start + minimumCutFrames
                    file.framePosition = windowStart
                    let count = AVAudioFrameCount(target - windowStart)
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
                    try file.read(into: buffer, frameCount: count)
                    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                    probabilities = try detector.speechProbabilities(in: samples)
                        .map { ($0.speechProbability * 1000).rounded() / 1000 }
                }
                slices.append(Slice(start: Double(start) / sampleRate, end: Double(end) / sampleRate,
                                    atBatchEnd: end == start + batchFrames && target < totalFrames,
                                    windowProbabilities: probabilities))
                start = end
            }
            let outURL = url.deletingPathExtension().appendingPathExtension("json")
            try JSONEncoder().encode(slices).write(to: outURL)
            let batchEndCuts = slices.filter(\.atBatchEnd).count
            print("✅ [VADCutReplay] \(url.lastPathComponent): \(slices.count) slices, \(batchEndCuts) cut at batch end")
        }
    }
}
