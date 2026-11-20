#if DEBUG && targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Multi-speaker conversations with a speaker for every utterance (ASCEND,
/// stitched in speaking order). Local only: `build/speaker-live-replay/`.
private enum LiveSpeakerReplayFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/speaker-live-replay")
    static let names = ["test-1-persona", "test-2-sports", "validation-1-persona", "validation-2-education"]

    /// Measured with the shipping slice limits only; the fixture limits
    /// would cut differently. Run with `VOICELY_SLICE_LIMITS=production`.
    static var isConfigured: Bool {
        Qwen3SliceLimits.current == .production && names.allSatisfy { FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("\($0).caf").path) }
    }
}

private struct Utterance: Decodable {
    let start: Double
    let end: Double
    let speaker: Int
    let text: String
}

private actor PlaceholderText {
    private var count = 0
    func next() -> String {
        count += 1
        return "slice\(count)."
    }
}

/// Replays each conversation as a live recording: the coordinator is asked
/// once per second, as the recording timer does, with the real speaker model
/// and the real pause search. Text is a placeholder per slice, so this
/// measures where slices end and who they are given to, not transcription.
@Suite(.serialized, .enabled(if: LiveSpeakerReplayFixture.isConfigured))
struct LiveSpeakerReplayTests {
    struct Result {
        var tokens = 0
        var correct = 0
        var uncertain = 0
        var slices: [Double] = []
        var textDelays: [Double] = []
    }

    @Test @MainActor func liveSlicesGoToTheRightSpeaker() async throws {
        var withSpeakers = Result()
        var plain = Result()
        for name in LiveSpeakerReplayFixture.names {
            let url = LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).caf")
            let utterances = try JSONDecoder().decode([Utterance].self, from: Data(
                contentsOf: LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).utts.json")))
            let one = try await replay(url: url, utterances: utterances, tracksSpeakers: true)
            let base = try await replay(url: url, utterances: utterances, tracksSpeakers: false)
            print("📊 \(name): \(summary(one)) | without speakers: slices \(base.slices.count), text delay median \(median(base.textDelays)) s")
            withSpeakers.merge(one)
            plain.merge(base)
        }
        print("📊 all: \(summary(withSpeakers))")
        print("📊 all without speakers: slices \(plain.slices.count), text delay median \(median(plain.textDelays)) s, max \(plain.textDelays.max() ?? 0) s")
        let accuracy = Double(withSpeakers.correct) / Double(max(withSpeakers.tokens, 1))
        #expect(accuracy > 0.8)
    }

    @MainActor private func replay(url: URL, utterances: [Utterance], tracksSpeakers: Bool, pauseReach: Double? = nil) async throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(), recordingFileURL: url)
        if tracksSpeakers {
            coordinator.speakerTracker = try #require(NemotronLiveSpeakerTracker(fileURL: url))
            if let pauseReach { coordinator.snapTurnChange = Self.snap(reach: pauseReach) }
        }
        let placeholder = PlaceholderText()
        coordinator.transcribeOverride = { @Sendable _ in await placeholder.next() }

        var result = Result()
        var now = 0.0
        var seenSpans = 0
        coordinator.transcriptCallback = { [weak coordinator] _ in
            guard let spans = coordinator?.accumulatedSpans else { return }
            for span in spans.dropFirst(seenSpans) { result.textDelays.append(now - span.end) }
            seenSpans = spans.count
        }
        var frame = AVAudioFramePosition(rate)
        while frame < totalFrames {
            now = Double(frame) / rate
            await coordinator.transcribeSegment(upToFrame: frame)
            frame += AVAudioFramePosition(rate)
        }
        coordinator.transcriptCallback = nil
        _ = await coordinator.stop(currentFrame: totalFrames)

        let text = coordinator.accumulatedTranscript
        let spans = try #require(coordinator.accumulatedSpans)
        result.slices = spans.map { $0.end - $0.start }
        guard tracksSpeakers else { return result }
        let labels = try #require(SpeakerTranscriptBuilder.makeLive(
            text: text, spans: spans, audioPath: url.path, segments: coordinator.speakerRanges ?? []))
        // Placeholder text is one sentence per slice, so units and spans line up.
        let sliceLabels = labels.units.map(\.speaker)
        try #require(sliceLabels.count == spans.count)

        // As in the earlier measurement: each utterance belongs to the slice
        // it overlaps most; labels map to true speakers by shared seconds.
        func slice(for utterance: Utterance) -> Int {
            let overlaps = spans.map { max(0, min($0.end, utterance.end) - max($0.start, utterance.start)) }
            return overlaps.indices.max { overlaps[$0] < overlaps[$1] } ?? 0
        }
        var shared: [Int: [Int: Double]] = [:]
        for utterance in utterances {
            guard let label = sliceLabels[slice(for: utterance)] else { continue }
            shared[label, default: [:]][utterance.speaker, default: 0] += utterance.end - utterance.start
        }
        var mapping: [Int: Int] = [:]
        var used = Set<Int>()
        let pairs = shared.flatMap { label, speakers in speakers.map { (label, $0.key, $0.value) } }
        for (label, speaker, _) in pairs.sorted(by: { $0.2 > $1.2 }) where mapping[label] == nil && !used.contains(speaker) {
            mapping[label] = speaker
            used.insert(speaker)
        }
        for utterance in utterances {
            let count = Self.tokenCount(utterance.text)
            result.tokens += count
            guard let label = sliceLabels[slice(for: utterance)] else {
                result.uncertain += count
                continue
            }
            if mapping[label] == utterance.speaker { result.correct += count }
        }
        return result
    }

    /// Real Qwen3-ASR on the slices: cutting at every speaker change makes
    /// many short slices, and the app's speech gate must not drop them.
    @Test @MainActor func shortSpeakerSlicesKeepTheirText() async throws {
        let modelManager = ModelManager()
        await modelManager.loadModel()
        try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")
        let service = TranscriptionService(modelManager: modelManager)
        for name in ["test-2-sports", "validation-2-education"] {
            let url = LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).caf")
            let utterances = try JSONDecoder().decode([Utterance].self, from: Data(
                contentsOf: LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).utts.json")))
            let reference = utterances.flatMap { Self.tokens($0.text) }
            for tracksSpeakers in [true, false] {
                let started = Date()
                let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: url)
                if tracksSpeakers {
                    coordinator.speakerTracker = try #require(NemotronLiveSpeakerTracker(fileURL: url))
                }
                let total = try AVAudioFile(forReading: url).length
                var frame: AVAudioFramePosition = 16_000
                while frame < total {
                    await coordinator.transcribeSegment(upToFrame: frame)
                    frame += 16_000
                }
                let text = await coordinator.stop(currentFrame: total)
                let hypothesis = Self.tokens(text)
                let errors = Self.editDistance(reference, hypothesis)
                let slices = coordinator.accumulatedSpans?.count ?? 0
                print(String(format: "📊 qwen %@ %@: error %.2f%% (%d/%d), output tokens %d, slices with text %d, unavailable %d, %.0f s",
                             name, tracksSpeakers ? "speaker cuts" : "pause cuts",
                             Double(errors) / Double(reference.count) * 100, errors, reference.count,
                             hypothesis.count, slices, coordinator.unrecoveredSliceCount,
                             Date().timeIntervalSince(started)))
                #expect(coordinator.unrecoveredSliceCount == 0)
            }
        }
        await modelManager.unloadModel()
    }

    /// How far a speaker cut may move to reach a pause: 0, 0.5, 1 and 2 s,
    /// compared on who each slice goes to and on Qwen3-ASR's error rate.
    /// Slow (real Qwen on all four conversations per reach); opt in with
    /// `VOICELY_RUN_PAUSE_REACH=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICELY_RUN_PAUSE_REACH"] == "1"))
    @MainActor func pauseReachComparison() async throws {
        let reaches = [0.0, 0.5, 1.0, 2.0]
        for reach in reaches {
            var all = Result()
            for name in LiveSpeakerReplayFixture.names {
                let url = LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).caf")
                let utterances = try JSONDecoder().decode([Utterance].self, from: Data(
                    contentsOf: LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).utts.json")))
                let one = try await replay(url: url, utterances: utterances, tracksSpeakers: true, pauseReach: reach)
                print("📊 reach \(reach) s \(name): \(summary(one))")
                all.merge(one)
            }
            print("📊 reach \(reach) s all: \(summary(all))")
        }

        let modelManager = ModelManager()
        await modelManager.loadModel()
        try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")
        let service = TranscriptionService(modelManager: modelManager)
        for reach in reaches {
            var errors = 0
            var reference = 0
            for name in LiveSpeakerReplayFixture.names {
                let url = LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).caf")
                let utterances = try JSONDecoder().decode([Utterance].self, from: Data(
                    contentsOf: LiveSpeakerReplayFixture.directory.appendingPathComponent("\(name).utts.json")))
                let expected = utterances.flatMap { Self.tokens($0.text) }
                let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: url)
                coordinator.speakerTracker = try #require(NemotronLiveSpeakerTracker(fileURL: url))
                coordinator.snapTurnChange = Self.snap(reach: reach)
                let total = try AVAudioFile(forReading: url).length
                var frame: AVAudioFramePosition = 16_000
                while frame < total {
                    await coordinator.transcribeSegment(upToFrame: frame)
                    frame += 16_000
                }
                let text = await coordinator.stop(currentFrame: total)
                let distance = Self.editDistance(expected, Self.tokens(text))
                print(String(format: "📊 qwen reach %.1f s %@: error %.2f%% (%d/%d), slices %d, unavailable %d",
                             reach, name, Double(distance) / Double(expected.count) * 100, distance, expected.count,
                             coordinator.accumulatedSpans?.count ?? 0, coordinator.unrecoveredSliceCount))
                errors += distance
                reference += expected.count
            }
            print(String(format: "📊 qwen reach %.1f s all: error %.2f%% (%d/%d)",
                         reach, Double(errors) / Double(reference) * 100, errors, reference))
        }
        await modelManager.unloadModel()
    }

    private static func snap(reach: Double) -> (URL, AVAudioFramePosition, AVAudioFramePosition, AVAudioFramePosition) async -> AVAudioFramePosition {
        { url, frame, lower, upper in
            await Task.detached {
                IncrementalTranscriptionCoordinator.pauseNearest(
                    fileURL: url, frame: frame, lowerBound: lower, upperBound: upper, reachSeconds: reach)
            }.value
        }
    }

    /// Memory with the speaker model running next to Qwen3-ASR, one setup
    /// per test process so nothing earlier lingers in the footprint:
    /// `VOICELY_MEMORY_SCENARIO` is `qwen`, `speakers` or `both`. Run with
    /// `VOICELY_BACKEND=coreML` to measure the iPhone's path.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICELY_MEMORY_SCENARIO"] != nil))
    @MainActor func memoryWithSpeakerModel() async throws {
        let scenario = try #require(ProcessInfo.processInfo.environment["VOICELY_MEMORY_SCENARIO"])
        let usesQwen = scenario != "speakers"
        let tracksSpeakers = scenario != "qwen"
        func now() -> Int { MemoryFootprint.megabytes()?.current ?? -1 }
        let baseline = now()

        let modelManager = ModelManager()
        if usesQwen {
            await modelManager.loadModel()
            try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")
        }
        let afterQwen = now()
        let url = LiveSpeakerReplayFixture.directory.appendingPathComponent("validation-2-education.caf")
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(modelManager: modelManager), recordingFileURL: url)
        if tracksSpeakers {
            coordinator.speakerTracker = try #require(NemotronLiveSpeakerTracker(fileURL: url))
        }
        if !usesQwen {
            coordinator.transcribeOverride = { @Sendable _ in "slice." }
        }
        let total = try AVAudioFile(forReading: url).length
        var highest = afterQwen
        var afterFirstStep = 0
        var frame: AVAudioFramePosition = 16_000
        while frame < total {
            await coordinator.transcribeSegment(upToFrame: frame)
            if frame == 16_000 { afterFirstStep = now() }
            highest = max(highest, now())
            frame += 16_000
        }
        _ = await coordinator.stop(currentFrame: total)
        highest = max(highest, now())
        let lifetimePeak = MemoryFootprint.megabytes()?.peak ?? -1
        print("📊 memory \(scenario) backend=\(Qwen3Backend.current.rawValue): baseline \(baseline) MB, after Qwen load \(afterQwen) MB, after first second \(afterFirstStep) MB, highest sampled \(highest) MB, process peak \(lifetimePeak) MB, audio \(Double(total) / 16_000) s")
        if usesQwen { await modelManager.unloadModel() }
    }

    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { tokens.append(word) }
            word = ""
        }
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) {
                flush()
                tokens.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) || (scalar == "'" && !word.isEmpty) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            current[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return a.isEmpty ? b.count : previous[b.count]
    }

    /// Chinese characters and English words, as in the earlier measurement.
    static func tokenCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.lowercased().unicodeScalars {
            if (0x3400...0x9FFF).contains(scalar.value) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else if scalar != "'" {
                inWord = false
            }
        }
        return count
    }

    private func summary(_ result: Result) -> String {
        let accuracy = Double(result.correct) / Double(max(result.tokens, 1)) * 100
        let uncertain = Double(result.uncertain) / Double(max(result.tokens, 1)) * 100
        let short = Double(result.slices.filter { $0 < 3 }.count) / Double(max(result.slices.count, 1)) * 100
        return String(format: "right speaker %.1f%%, uncertain %.1f%%, slices %d (median %.1f s, under 3 s %.0f%%), text delay median %.1f s max %.1f s",
                      accuracy, uncertain, result.slices.count, median(result.slices), short,
                      median(result.textDelays), result.textDelays.max() ?? 0)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return (sorted[sorted.count / 2] * 10).rounded() / 10
    }
}

private extension LiveSpeakerReplayTests.Result {
    mutating func merge(_ other: Self) {
        tokens += other.tokens
        correct += other.correct
        uncertain += other.uncertain
        slices += other.slices
        textDelays += other.textDelays
    }
}
#endif
