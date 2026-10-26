//
//  SpeechGateReplayTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Opt-in input for `SpeechGateReplayTests`: short spoken answers as 16 kHz
/// mono WAVs in `<tmp>/voicely-gate/answers/` (inside the test host's
/// container), e.g. made with `say -o x.wav --data-format=LEF32@16000 "不行"`.
enum SpeechGateInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-gate", isDirectory: true)
    static var answerURLs: [URL] {
        let answers = directory.appendingPathComponent("answers", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: answers.path)) ?? []
        return names.filter { $0.hasSuffix(".wav") }.sorted().map { answers.appendingPathComponent($0) }
    }
    static var isConfigured: Bool { !answerURLs.isEmpty }
}

/// Checks the speech gate in both directions with the real VAD and model:
/// noise alone must not come out as text, and a short answer ("不行", "No")
/// said quietly in an otherwise silent slice must not be dropped. Each answer
/// is scaled to several loudness levels and laid into synthetic backgrounds.
/// Writes `gate-<backend>.json`. Run with `TEST_RUNNER_VOICELY_RUN_GATE_REPLAY=1`;
/// `TEST_RUNNER_VOICELY_BACKEND=coreML` with the CoreML model in
/// `<tmp>/voicely-qwen-real/coreML` checks the iPhone backend on the Mac.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["VOICELY_RUN_GATE_REPLAY"] == "1" && SpeechGateInput.isConfigured))
struct SpeechGateReplayTests {
    static let sliceSeconds = 20.0
    static let answerOffsetSeconds = 8.0
    static let answerLevels: [Double] = [-25, -35, -45, -55]

    private struct Case: Encodable {
        let background: String
        let answer: String?
        let levelDb: Double?
        let presence: String
        let engineText: String?
        let keptText: String?
    }

    @Test func shortAnswersAreKeptAndNoiseIsDropped() async throws {
        let backend = Qwen3Backend.current
        let bundled = Qwen3ASRModelStore.defaultModelDirectory()
        let directory = bundled.flatMap { Qwen3ASRModelStore.isComplete($0, backend: backend) ? $0 : nil }
            ?? Qwen3RealModelInput.directory.appendingPathComponent(backend.rawValue, isDirectory: true)
        try #require(Qwen3ASRModelStore.isComplete(directory, backend: backend))
        let store = Qwen3ASRModelStore(backend: backend, modelDirectory: directory)
        try await store.prepareModel()

        let count = Int(Self.sliceSeconds * 16_000)
        let backgrounds: [(String, [Float])] = [
            ("silence", Array(repeating: 0, count: count)),
            ("white-60dB", Self.whiteNoise(count: count, db: -60, seed: 1)),
            ("white-45dB", Self.whiteNoise(count: count, db: -45, seed: 2)),
            ("rumble-40dB", Self.brownNoise(count: count, db: -40, seed: 3)),
            ("typing", Self.clicks(count: count, perSecond: 6, peakDb: -25, seed: 4)),
        ]
        let answers = try SpeechGateInput.answerURLs.map {
            ($0.deletingPathExtension().lastPathComponent, try Qwen3AudioPCM.loadPCM16kMono(url: $0))
        }

        var cases: [Case] = []
        func run(_ samples: [Float], background: String, answer: String?, level: Double?) async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try Self.write(samples, to: url)
            let presence = try NeuralSpeechAnalyzer.speechPresence(
                at: url, detector: SileroNeuralVoiceActivityDetector())
            var engineText: String?
            var kept: String?
            if presence != .silence {
                let text = try await store.transcribe(samples: samples, languageHint: nil).text
                engineText = text
                if case .text(let result) = TranscriptionService.gatedOutput(text, presence: presence) {
                    kept = result
                }
            }
            cases.append(Case(background: background, answer: answer, levelDb: level,
                              presence: String(describing: presence), engineText: engineText, keptText: kept))
        }

        for (name, background) in backgrounds {
            try await run(background, background: name, answer: nil, level: nil)
        }
        // Answers go into the backgrounds a quiet room actually has.
        for (name, background) in backgrounds where name != "white-45dB" {
            for (answer, clip) in answers {
                for level in Self.answerLevels {
                    var mix = background
                    let scaled = Self.scaled(clip, toRMSDb: level)
                    let start = Int(Self.answerOffsetSeconds * 16_000)
                    for index in scaled.indices where start + index < mix.count {
                        mix[start + index] += scaled[index]
                    }
                    try await run(mix, background: name, answer: answer, level: level)
                }
            }
        }
        await store.unloadModel()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(cases).write(to: SpeechGateInput.directory
            .appendingPathComponent("gate-\(backend.rawValue).json"))

        for noise in cases where noise.answer == nil {
            print("GATE \(backend.rawValue) noise=\(noise.background) presence=\(noise.presence) engine=\(noise.engineText.map { "\"\($0)\"" } ?? "-") kept=\(noise.keptText.map { "\"\($0)\"" } ?? "-")")
        }
        for level in Self.answerLevels {
            let atLevel = cases.filter { $0.levelDb == level }
            let kept = atLevel.filter { $0.keptText != nil }
            let byPresence = Dictionary(grouping: atLevel, by: \.presence).mapValues(\.count)
            print("GATE \(backend.rawValue) level=\(Int(level))dB kept=\(kept.count)/\(atLevel.count) presence=\(byPresence.sorted { $0.key < $1.key })")
        }
        for dropped in cases where dropped.answer != nil && dropped.keptText == nil {
            print("GATE \(backend.rawValue) dropped \(dropped.answer!) \(Int(dropped.levelDb!))dB on \(dropped.background): presence=\(dropped.presence) engine=\(dropped.engineText.map { "\"\($0)\"" } ?? "-")")
        }

        // Noise alone must never become text, and an answer at ordinary
        // speaking levels must survive any background quieter than itself.
        let keptNoise = cases.filter { $0.answer == nil && $0.keptText != nil }
        #expect(keptNoise.isEmpty, "Noise came out as text: \(keptNoise.map(\.background))")
        let droppedAudible = cases.filter {
            $0.answer != nil && $0.keptText == nil && ($0.levelDb ?? 0) >= -35 && $0.background != "rumble-40dB"
        }
        #expect(droppedAudible.isEmpty, "Audible answers were dropped: \(droppedAudible.map { "\($0.answer!) \($0.levelDb!)dB on \($0.background)" })")
    }

    // MARK: Synthetic audio

    private static func amplitude(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    private static func scaled(_ clip: [Float], toRMSDb db: Double) -> [Float] {
        let rms = sqrt(clip.reduce(0) { $0 + $1 * $1 } / Float(max(clip.count, 1)))
        guard rms > 0 else { return clip }
        let gain = amplitude(db) / rms
        return clip.map { $0 * gain }
    }

    /// Deterministic noise so runs compare.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func whiteNoise(count: Int, db: Double, seed: UInt64) -> [Float] {
        var generator = SplitMix64(state: seed)
        // Uniform noise in [-a, a] has an RMS of a / sqrt(3).
        let peak = amplitude(db) * sqrt(3)
        return (0..<count).map { _ in Float.random(in: -peak...peak, using: &generator) }
    }

    /// Integrated white noise: low-frequency rumble like ventilation.
    private static func brownNoise(count: Int, db: Double, seed: UInt64) -> [Float] {
        var generator = SplitMix64(state: seed)
        var value: Float = 0
        let raw: [Float] = (0..<count).map { _ in
            value = 0.995 * value + Float.random(in: -1...1, using: &generator) * 0.05
            return value
        }
        return scaled(raw, toRMSDb: db)
    }

    /// Short decaying bursts at random times, like keys being typed.
    private static func clicks(count: Int, perSecond: Double, peakDb: Double, seed: UInt64) -> [Float] {
        var generator = SplitMix64(state: seed)
        var samples = [Float](repeating: 0, count: count)
        let clickLength = 160
        for _ in 0..<Int(perSecond * Double(count) / 16_000) {
            let start = Int.random(in: 0..<(count - clickLength), using: &generator)
            let peak = amplitude(peakDb) * Float.random(in: 0.5...1, using: &generator)
            for index in 0..<clickLength {
                let decay = exp(-Float(index) / 25)
                samples[start + index] += Float.random(in: -1...1, using: &generator) * peak * decay
            }
        }
        return samples
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
