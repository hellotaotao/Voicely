//
//  SileroVariantReplayTests.swift
//  VoicelyTests
//

import AVFoundation
import CoreML
import Foundation
import Testing
@testable import Voicely

/// Feeds a CoreML Silero model the way it was exported: the previous step's
/// last 64 samples as context plus 512 new samples, one 32 ms frame per step.
final class ContextSileroDetector: NeuralVoiceActivityDetecting {
    enum Flavor { case bundled, v621 }

    private let model: MLModel
    private let flavor: Flavor
    private var hidden: MLMultiArray
    private var cell: MLMultiArray

    init(flavor: Flavor, modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.flavor = flavor
        (hidden, cell) = try Self.zeroState(flavor)
    }

    private static func zeroState(_ flavor: Flavor) throws -> (MLMultiArray, MLMultiArray) {
        switch flavor {
        case .bundled:
            return (try MLMultiArray(shape: [1, 128], dataType: .float32), try MLMultiArray(shape: [1, 128], dataType: .float32))
        case .v621:
            let h = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
            let c = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
            for i in 0..<128 { h[i] = 0; c[i] = 0 }
            return (h, c)
        }
    }

    func speechProbabilities(in samples: [Float]) throws -> [NeuralVoiceActivityFrame] {
        (hidden, cell) = try Self.zeroState(flavor)
        var context = [Float](repeating: 0, count: 64)
        var frames: [NeuralVoiceActivityFrame] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 512, samples.count)
            var chunk = Array(samples[offset..<end])
            if chunk.count < 512 { chunk += [Float](repeating: 0, count: 512 - chunk.count) }
            let probability = try run(context + chunk)
            context = Array(chunk.suffix(64))
            frames.append(NeuralVoiceActivityFrame(startFrame: offset, endFrame: end, speechProbability: Double(probability)))
            offset += 512
        }
        return frames
    }

    private func run(_ input: [Float]) throws -> Float {
        switch flavor {
        case .bundled:
            let audio = try MLMultiArray(shape: [1, 576], dataType: .float32)
            for i in 0..<576 { audio[i] = NSNumber(value: input[i]) }
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "audio_input": audio, "hidden_state": hidden, "cell_state": cell]))
            hidden = result.featureValue(for: "new_hidden_state")!.multiArrayValue!
            cell = result.featureValue(for: "new_cell_state")!.multiArrayValue!
            return result.featureValue(for: "vad_output")!.multiArrayValue![0].floatValue
        case .v621:
            let audio = try MLMultiArray(shape: [1, 1, 576], dataType: .float16)
            let pointer = audio.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<576 { pointer[i] = Float16(input[i]) }
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "audio": audio, "h": hidden, "c": cell]))
            hidden = result.featureValue(for: "h_out")!.multiArrayValue!
            cell = result.featureValue(for: "c_out")!.multiArrayValue!
            return result.featureValue(for: "probability")!.multiArrayValue![0].floatValue
        }
    }
}

/// Off unless `VOICELY_RUN_SILERO_CALIBRATION=1` (pass it to xcodebuild as
/// `TEST_RUNNER_VOICELY_RUN_SILERO_CALIBRATION=1`, with
/// `-only-testing:VoicelyTests/SileroVariantReplayTests`): the full scan takes
/// minutes. Inputs live in the replay directory: `cuts-<name>.caf` 16 kHz
/// recordings, their `cuts-<name>.json` from VADCutReplayTests, the v6.2.1 model
/// at `silero-v621/silero_vad.mlmodelc` (aufklarer/Silero-VAD-v6.2.1-CoreML),
/// optional `gate-probe.json` and `calib-negatives.json`.
enum SileroCalibrationInput {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VOICELY_RUN_SILERO_CALIBRATION"] == "1" && VADCutReplayInput.isConfigured
    }
}

/// Calibration experiment: for every `cuts-<name>.caf` in the replay directory and
/// each Silero variant (A = current app detector, B = bundled model fed 64+512,
/// C = v6.2.1 fed 64+512, model at `silero-v621/silero_vad.mlmodelc`), writes
/// the cut list, a 32 ms speech-probability track, and the speech-gate verdict
/// for each slice of variant A's cut list.
@Suite(.serialized, .enabled(if: SileroCalibrationInput.isEnabled))
struct SileroVariantReplayTests {
    private struct Slice: Encodable { let start: Double; let end: Double; let atBatchEnd: Bool }
    private struct Output: Encodable {
        let slices: [Slice]
        let track: [Double]
        let gate: [String]
    }

    private static func detector(_ name: String) throws -> NeuralVoiceActivityDetecting {
        switch name {
        case "A": return try SileroNeuralVoiceActivityDetector()
        case "B":
            let url = try #require(Bundle.allBundles.lazy.compactMap { $0.url(forResource: "silero_vad", withExtension: "mlmodelc") }.first)
            return try ContextSileroDetector(flavor: .bundled, modelURL: url)
        default:
            return try ContextSileroDetector(flavor: .v621, modelURL: VADCutReplayInput.directory
                .appendingPathComponent("silero-v621/silero_vad.mlmodelc"))
        }
    }

    @Test func compareVariants() throws {
        let limits = Qwen3SliceLimits.production
        var configuration = IncrementalVoiceActivityCutConfiguration.default
        configuration.minimumCutSeconds = limits.minimumCutSeconds

        for url in VADCutReplayInput.audioURLs {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            try #require(sampleRate == 16_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let all = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let batchFrames = Int64(limits.chunkSeconds * sampleRate)
            var referenceSlices: [Slice] = []

            for name in ["A", "B", "C"] {
                let vad = try Self.detector(name)
                var slices: [Slice] = []
                var start: Int64 = 0
                while start < file.length {
                    let target = min(start + batchFrames, file.length)
                    var end = target
                    if target < file.length {
                        let cut = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                            fileURL: url, startFrame: start, targetFrame: target,
                            targetSegmentSeconds: limits.chunkSeconds, configuration: configuration,
                            neuralVoiceActivityDetector: vad)
                        if cut > start { end = cut }
                    }
                    slices.append(Slice(start: Double(start) / sampleRate, end: Double(end) / sampleRate,
                                        atBatchEnd: end == start + batchFrames && target < file.length))
                    start = end
                }
                if name == "A" { referenceSlices = slices }

                // Probability on a common 32 ms grid, analysed in 30 s windows
                // with a fresh state each, as the cut search does.
                var track: [Double] = []
                let window = 30 * 16_000
                var offset = 0
                while offset < all.count {
                    let piece = Array(all[offset..<min(offset + window, all.count)])
                    let frames = try vad.speechProbabilities(in: piece)
                    var gridTime = 0
                    var index = 0
                    while gridTime < piece.count {
                        while index + 1 < frames.count && frames[index].endFrame <= gridTime { index += 1 }
                        track.append((frames[index].speechProbability * 1000).rounded() / 1000)
                        gridTime += 512
                    }
                    offset += window
                }

                // Speech gate on the same slices for every variant.
                var gate: [String] = []
                for slice in referenceSlices {
                    let lo = Int(slice.start * sampleRate), hi = min(all.count, Int(slice.end * sampleRate))
                    let sliceURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("silero-gate-\(UUID().uuidString).caf")
                    let out = try AVAudioFile(forWriting: sliceURL, settings: file.processingFormat.settings)
                    let sliceBuffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(hi - lo)))
                    sliceBuffer.frameLength = AVAudioFrameCount(hi - lo)
                    all.withUnsafeBufferPointer { source in
                        sliceBuffer.floatChannelData![0].update(from: source.baseAddress! + lo, count: hi - lo)
                    }
                    try out.write(from: sliceBuffer)
                    gate.append(String(describing: try NeuralSpeechAnalyzer.speechPresence(at: sliceURL, detector: vad)))
                    try? FileManager.default.removeItem(at: sliceURL)
                }

                let outURL = VADCutReplayInput.directory.appendingPathComponent(
                    "silero-\(url.deletingPathExtension().lastPathComponent)-\(name).json")
                try JSONEncoder().encode(Output(slices: slices, track: track, gate: gate)).write(to: outURL)
                print("✅ [SileroVariant] \(url.lastPathComponent) \(name): \(slices.count) slices, \(slices.filter(\.atBatchEnd).count) at batch end, gate over \(gate.count) slices: \(gate.filter { $0 == "silence" }.count) silence, \(gate.filter { $0 == "uncertain" }.count) uncertain")
            }
        }
    }

    /// Wraps a detector and keeps every frame it returns, per call.
    final class RecordingDetector: NeuralVoiceActivityDetecting {
        let inner: NeuralVoiceActivityDetecting
        private(set) var calls: [[NeuralVoiceActivityFrame]] = []
        init(_ inner: NeuralVoiceActivityDetecting) { self.inner = inner }
        func speechProbabilities(in samples: [Float]) throws -> [NeuralVoiceActivityFrame] {
            let frames = try inner.speechProbabilities(in: samples)
            calls.append(frames)
            return frames
        }
    }

    /// For each `[recording, start, end]` in `gate-probe.json`, prints what the
    /// speech gate saw (per streaming call) and what one pass over the whole
    /// slice gives, for every variant.
    @Test func probeGateSlices() throws {
        let probeURL = VADCutReplayInput.directory.appendingPathComponent("gate-probe.json")
        guard let data = try? Data(contentsOf: probeURL) else { return }
        let probes = try JSONSerialization.jsonObject(with: data) as! [[Any]]
        for probe in probes {
            let url = VADCutReplayInput.directory.appendingPathComponent("cuts-\(probe[0] as! String).caf")
            let start = probe[1] as! Double, end = probe[2] as! Double
            let file = try AVAudioFile(forReading: url)
            file.framePosition = AVAudioFramePosition(start * 16_000)
            let count = AVAudioFrameCount((end - start) * 16_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            try file.read(into: buffer, frameCount: count)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let sliceURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).caf")
            let out = try AVAudioFile(forWriting: sliceURL, settings: file.processingFormat.settings)
            try out.write(from: buffer)
            defer { try? FileManager.default.removeItem(at: sliceURL) }
            for name in ["A", "B", "C"] {
                let recorder = RecordingDetector(try Self.detector(name))
                let presence = try NeuralSpeechAnalyzer.speechPresence(at: sliceURL, detector: recorder)
                let gateFrames = recorder.calls.flatMap { $0 }
                let whole = try Self.detector(name).speechProbabilities(in: samples)
                func summary(_ frames: [NeuralVoiceActivityFrame]) -> String {
                    let p = frames.map(\.speechProbability)
                    let above40 = frames.filter { $0.speechProbability > 0.40 }
                        .reduce(0.0) { $0 + Double($1.endFrame - $1.startFrame) / 16_000 }
                    return String(format: "max=%.3f framesAbove0.55=%d secondsAbove0.40=%.2f", p.max() ?? 0,
                                  p.filter { $0 >= 0.55 }.count, above40)
                }
                print("🔍 [GateProbe] \(probe[0]) \(start)-\(end) \(name): presence=\(presence) calls=\(recorder.calls.count) gate[\(summary(gateFrames))] wholeSlice[\(summary(whole))]")
            }
        }
    }

    /// Per slice of the current cut list (`cuts-<name>.json` from VADCutReplayTests):
    /// max speech probability and seconds above 0.40 / 0.30 / 0.20, variant A.
    @Test func gateStatistics() throws {
        for url in VADCutReplayInput.audioURLs {
            let cutsURL = url.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: cutsURL),
                  let slices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let all = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let vad = try Self.detector("A")
            var rows: [[String: Double]] = []
            for slice in slices {
                let lo = Int((slice["start"] as! Double) * 16_000), hi = min(all.count, Int((slice["end"] as! Double) * 16_000))
                let frames = try vad.speechProbabilities(in: Array(all[lo..<hi]))
                func seconds(above t: Double) -> Double {
                    frames.filter { $0.speechProbability > t }.reduce(0.0) { $0 + Double($1.endFrame - $1.startFrame) / 16_000 }
                }
                rows.append(["start": slice["start"] as! Double, "end": slice["end"] as! Double,
                             "max": frames.map(\.speechProbability).max() ?? 0,
                             "s40": seconds(above: 0.40), "s30": seconds(above: 0.30), "s20": seconds(above: 0.20)])
            }
            let outURL = VADCutReplayInput.directory.appendingPathComponent("gate-\(url.deletingPathExtension().lastPathComponent).json")
            try JSONSerialization.data(withJSONObject: rows).write(to: outURL)
            print("✅ [GateStats] \(url.lastPathComponent): \(rows.count) slices")
        }
    }

    /// Gate-path statistics for calibration: every slice of the current cut
    /// lists (positives) and every entry of `calib-negatives.json`, per variant.
    @Test func gateCalibration() throws {
        struct Sample { let file: String; let start: Double; let end: Double; let label: String }
        var samples: [Sample] = []
        for url in VADCutReplayInput.audioURLs {
            let cutsURL = url.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: cutsURL),
                  let slices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for (i, slice) in slices.enumerated() {
                samples.append(Sample(file: url.lastPathComponent, start: slice["start"] as! Double,
                                      end: slice["end"] as! Double, label: "slice-\(i)"))
            }
        }
        let negativesURL = VADCutReplayInput.directory.appendingPathComponent("calib-negatives.json")
        if let data = try? Data(contentsOf: negativesURL),
           let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for row in rows {
                samples.append(Sample(file: row["file"] as! String, start: row["start"] as! Double,
                                      end: row["end"] as! Double, label: row["label"] as! String))
            }
        }
        var cache: [String: (AVAudioFormat, [Float])] = [:]
        var results: [[String: Any]] = []
        let detectors = try ["A", "B", "C"].map { ($0, RecordingDetector(try Self.detector($0))) }
        for sample in samples {
            if cache[sample.file] == nil {
                let file = try AVAudioFile(forReading: VADCutReplayInput.directory.appendingPathComponent(sample.file))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                cache[sample.file] = (file.processingFormat,
                                      Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
            }
            let (format, all) = cache[sample.file]!
            let lo = Int(sample.start * 16_000), hi = min(all.count, Int(sample.end * 16_000))
            let sliceURL = FileManager.default.temporaryDirectory.appendingPathComponent("calib-\(UUID().uuidString).caf")
            let out = try AVAudioFile(forWriting: sliceURL, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hi - lo)))
            buffer.frameLength = AVAudioFrameCount(hi - lo)
            all.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + lo, count: hi - lo) }
            try out.write(from: buffer)
            var row: [String: Any] = ["file": sample.file, "start": sample.start, "end": sample.end, "label": sample.label]
            for (name, recorder) in detectors {
                let before = recorder.calls.count
                // A full scan is needed for the statistics, so the early exit is
                // bypassed by reading the frames of every call, not the verdict alone.
                let presence = try NeuralSpeechAnalyzer.speechPresence(at: sliceURL, detector: recorder)
                var frames = recorder.calls[before...].flatMap { $0 }
                if presence == .speech {
                    // The gate stops at the first speech frame; finish the scan.
                    frames = try Self.detector(name).speechProbabilities(in: Array(all[lo..<hi]))
                }
                let p = frames.map(\.speechProbability)
                func seconds(above t: Double) -> Double {
                    frames.filter { $0.speechProbability > t }.reduce(0.0) { $0 + Double($1.endFrame - $1.startFrame) / 16_000 }
                }
                row[name] = ["presence": String(describing: presence), "max": p.max() ?? 0,
                             "s40": seconds(above: 0.40), "s30": seconds(above: 0.30), "s20": seconds(above: 0.20)]
            }
            try? FileManager.default.removeItem(at: sliceURL)
            results.append(row)
        }
        try JSONSerialization.data(withJSONObject: results).write(
            to: VADCutReplayInput.directory.appendingPathComponent("calib-results.json"))
        print("✅ [GateCalibration] \(results.count) samples")
    }
}
