//
//  TimelineAccuracyReplayTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import AudioCommon
import Qwen3ASR
import Testing
@testable import Voicely

/// Input for measuring how far sentence start times estimated inside a slice
/// land from where the sentence is actually spoken. Off unless this directory
/// exists inside the test host's container:
///   audio/*.m4a   recordings to replay
///   aligner/      a Qwen3-ForcedAligner MLX model folder (the reference)
enum TimelineAccuracyInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-timeline-accuracy", isDirectory: true)
    static var isConfigured: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("aligner").path)
    }
}

/// Slices each recording the way the app does (29 s, VAD cuts), transcribes
/// with the bundled MLX model, and force-aligns each slice's text to its audio
/// as the reference. Compares four ways of placing a sentence inside its slice:
/// by character position over the whole slice (what ships), by estimated
/// syllables, over voiced time only, and both.
@Suite(.serialized, .enabled(if: TimelineAccuracyInput.isConfigured))
struct TimelineAccuracyReplayTests {
    enum Method: String, CaseIterable { case current, syllables, voiced, voicedSyllables, snapped, snappedWide }

    struct Row {
        var recording: String
        var sliceStart: Double
        var reference: Double
        var estimates: [Method: Double]
        var sentence: String
        /// Where a tap on this sentence would start playback, by strategy.
        var seeks: [String: Double] = [:]
    }

    static let seekStrategies = ["lead 1.0s", "lead 1.5s", "lead 2.0s",
                                 "pause back 3s", "pause back 2s", "pause nearest 2s"]

    @Test func measureSentenceStartErrors() async throws {
        let audioDirectory = TimelineAccuracyInput.directory.appendingPathComponent("audio")
        let recordings = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
            .filter { ["m4a", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!recordings.isEmpty)

        let modelDirectory = try #require(Qwen3ASRModelStore.defaultModelDirectory())
        let store = Qwen3ASRModelStore(backend: .mlx, modelDirectory: modelDirectory)
        try await store.prepareModel()
        let aligner = try await Qwen3ForcedAligner.fromPretrained(
            modelId: "aufklarer/Qwen3-ForcedAligner-0.6B-8bit",
            cacheDir: TimelineAccuracyInput.directory.appendingPathComponent("aligner"),
            offlineMode: true)
        let vad = try SileroNeuralVoiceActivityDetector()

        var rows: [Row] = []
        var skips: [String: [String: Int]] = [:]
        for recording in recordings {
            let (measured, skipped) = try await measure(recording, store: store, aligner: aligner, vad: vad)
            rows += measured
            skips[recording.lastPathComponent] = skipped
        }
        try #require(!rows.isEmpty)
        await store.unloadModel()

        var report = "recording\tunits\t" + Method.allCases.map { "\($0.rawValue): mean|med|p90|max|≤1s|≤2s|bias" }.joined(separator: "\t") + "\n"
        let names = recordings.map(\.lastPathComponent) + ["ALL"]
        for name in names {
            let subset = name == "ALL" ? rows : rows.filter { $0.recording == name }
            guard !subset.isEmpty else { continue }
            report += "\(name)\t\(subset.count)"
            for method in Method.allCases {
                let signed = subset.map { $0.estimates[method]! - $0.reference }
                let errors = signed.map(abs).sorted()
                func pct(_ p: Double) -> Double { errors[min(errors.count - 1, Int(Double(errors.count) * p))] }
                let within1 = Double(errors.filter { $0 <= 1 }.count) / Double(errors.count) * 100
                let within2 = Double(errors.filter { $0 <= 2 }.count) / Double(errors.count) * 100
                report += String(format: "\t%.2f|%.2f|%.2f|%.1f|%.0f%%|%.0f%%|%+.2f",
                                 errors.reduce(0, +) / Double(errors.count), pct(0.5), pct(0.9), errors.last!,
                                 within1, within2, signed.reduce(0, +) / Double(signed.count))
            }
            report += "\n"
        }
        report += "\nskipped sentences\n"
        for (name, counts) in skips.sorted(by: { $0.key < $1.key }) {
            report += "\(name)\t" + counts.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "\n"
        }
        // Tap: missing the head = playback starts after the sentence does; the
        // cost of starting early = how much comes before the head.
        report += "\ntap strategy\tmissed head\tmissed by (median)\theard before head median|p90|max\n"
        for strategy in Self.seekStrategies {
            let pairs = rows.map { ($0.seeks[strategy]!, $0.reference) }
            let late = pairs.filter { $0.0 > $0.1 + 0.15 }.map { $0.0 - $0.1 }.sorted()
            let before = pairs.filter { $0.0 <= $0.1 + 0.15 }.map { max(0, $0.1 - $0.0) }.sorted()
            func q(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count) * p))] }
            report += String(format: "%@\t%.1f%%\t%.2fs\t%.2f|%.2f|%.1f\n", strategy,
                             Double(late.count) / Double(pairs.count) * 100, q(late, 0.5),
                             q(before, 0.5), q(before, 0.9), before.last ?? 0)
        }
        var detail = "recording\tslice\treference\t" + Method.allCases.map(\.rawValue).joined(separator: "\t") + "\tsentence\n"
        for row in rows {
            detail += "\(row.recording)\t\(row.sliceStart)\t\(row.reference)\t"
                + Method.allCases.map { String(format: "%.2f", row.estimates[$0]!) }.joined(separator: "\t")
                + "\t\(row.sentence.replacingOccurrences(of: "\n", with: " "))\n"
        }
        try report.write(to: TimelineAccuracyInput.directory.appendingPathComponent("report.tsv"), atomically: true, encoding: .utf8)
        try detail.write(to: TimelineAccuracyInput.directory.appendingPathComponent("detail.tsv"), atomically: true, encoding: .utf8)
        print("TIMELINE-ACC\n\(report)TIMELINE-ACC end")
    }

    private func measure(_ recording: URL, store: Qwen3ASRModelStore, aligner: Qwen3ForcedAligner,
                         vad: SileroNeuralVoiceActivityDetector) async throws -> ([Row], [String: Int]) {
        var skipped: [String: Int] = [:]
        // A 16 kHz mono copy, so file frames and samples are the same unit.
        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: recording)
        let pcmURL = FileManager.default.temporaryDirectory.appendingPathComponent("acc_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: pcmURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }

        let limits = Qwen3SliceLimits.production
        let cutConfiguration = IncrementalVoiceActivityCutConfiguration(minimumCutSeconds: limits.minimumCutSeconds)
        let total = Int64(samples.count)
        let chunk = Int64(limits.chunkSeconds * 16_000)
        var rows: [Row] = []
        var start: Int64 = 0
        while start < total {
            let target = min(start + chunk, total)
            var end = target
            if target < total {
                let cut = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                    fileURL: pcmURL, startFrame: start, targetFrame: target,
                    targetSegmentSeconds: limits.chunkSeconds, configuration: cutConfiguration)
                if cut > start { end = cut }
            }
            let slice = Array(samples[Int(start)..<Int(end)])
            let sliceStart = Double(start) / 16_000
            let sliceEnd = Double(end) / 16_000
            start = end

            let raw = try await store.transcribe(samples: slice, languageHint: nil).text
            guard let text = IncrementalTranscriptionCoordinator.finalizedSegmentText(raw) else { continue }
            let language = Self.isMostlyCJK(text) ? "Chinese" : "English"
            let words = aligner.align(audio: slice, text: text, sampleRate: 16_000, language: language)
            let wordOffsets = Self.locate(words, in: text)

            // What ships: the production units over a one-slice timeline.
            let span = TranscriptSpan(length: text.utf16.count, start: sliceStart, end: sliceEnd)
            let units = TranscriptTimeline.units(text: text, spans: [span])
            skipped["total", default: 0] += units.count
            guard !wordOffsets.isEmpty else {
                skipped["slice not aligned", default: 0] += units.count
                continue
            }
            let voiced = Self.voicedIntervals(try vad.speechProbabilities(in: slice))
            let syllableWeights = Self.syllableWeights(text)
            let characterWeights = Array(repeating: 1.0, count: text.utf16.count)

            for unit in units {
                let location = unit.range.location
                // Reference: the first aligned word that starts inside this sentence.
                guard let first = wordOffsets.first(where: {
                    $0.offset >= location && $0.offset < location + unit.range.length
                }) else {
                    let sentence = (text as NSString).substring(with: unit.range)
                    let hasContent = sentence.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
                    skipped[hasContent ? "no aligned word in sentence" : "punctuation only", default: 0] += 1
                    continue
                }
                let reference = sliceStart + Double(first.word.startTime)
                let sentence = (text as NSString).substring(with: unit.range)
                func estimate(_ weights: [Double], voicedOnly: Bool) -> Double {
                    let before = weights[..<location].reduce(0, +)
                    let all = weights.reduce(0, +)
                    let fraction = all > 0 ? before / all : 0
                    guard voicedOnly, !voiced.isEmpty else { return sliceStart + fraction * (sliceEnd - sliceStart) }
                    return sliceStart + Self.time(atVoicedFraction: fraction, in: voiced)
                }
                rows.append(Row(
                    recording: recording.lastPathComponent, sliceStart: sliceStart, reference: reference,
                    estimates: [
                        .current: unit.start,
                        .syllables: estimate(syllableWeights, voicedOnly: false),
                        .voiced: estimate(characterWeights, voicedOnly: true),
                        .voicedSyllables: estimate(syllableWeights, voicedOnly: true),
                        .snapped: Self.snap(unit.start, toOnsetsIn: voiced, sliceStart: sliceStart, window: 1.5),
                        .snappedWide: Self.snap(unit.start, toOnsetsIn: voiced, sliceStart: sliceStart, window: 2.5)
                    ],
                    sentence: sentence,
                    seeks: try Self.tapSeeks(estimate: unit.start, slice: slice, sliceStart: sliceStart, vad: vad)))
            }
        }
        return (rows, skipped)
    }

    // MARK: Helpers

    static func isMostlyCJK(_ text: String) -> Bool {
        var cjk = 0, letters = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) { cjk += 1 } else if CharacterSet.letters.contains(scalar) { letters += 1 }
        }
        // A Chinese character carries about as much speech as a short English word.
        return cjk * 4 >= letters
    }

    /// UTF-16 offset of each aligned word, found in order in the slice text.
    static func locate(_ words: [AlignedWord], in text: String) -> [(word: AlignedWord, offset: Int)] {
        let nsText = text as NSString
        var cursor = 0
        var result: [(AlignedWord, Int)] = []
        for word in words where !word.text.isEmpty {
            let range = nsText.range(of: word.text, options: [.caseInsensitive],
                                     range: NSRange(location: cursor, length: nsText.length - cursor))
            guard range.location != NSNotFound else { continue }
            // The aligner glues punctuation onto the next word ("。Hello");
            // the word starts at its first letter or digit.
            var start = range.location
            while start < range.location + range.length,
                  let scalar = UnicodeScalar(nsText.character(at: start)),
                  !CharacterSet.alphanumerics.contains(scalar) { start += 1 }
            result.append((word, start))
            cursor = range.location + range.length
        }
        return result
    }

    /// Speech in seconds from the slice start: frames at or above 0.5,
    /// with gaps under 0.2 s bridged.
    static func voicedIntervals(_ frames: [NeuralVoiceActivityFrame]) -> [(Double, Double)] {
        var intervals: [(Double, Double)] = []
        for frame in frames where frame.speechProbability >= 0.5 {
            let s = Double(frame.startFrame) / 16_000, e = Double(frame.endFrame) / 16_000
            if let last = intervals.last, s - last.1 < 0.2 { intervals[intervals.count - 1].1 = e } else { intervals.append((s, e)) }
        }
        return intervals
    }

    /// Where a tap starts playback under each strategy. The pause strategies
    /// run the VAD on a few seconds around the estimate, as a tap would, and
    /// start just before speech resumes after a pause; a slice start counts as
    /// one (slices are cut in pauses). Without a pause in reach they fall back
    /// to a 1 s lead.
    static func tapSeeks(estimate: Double, slice: [Float], sliceStart: Double,
                         vad: SileroNeuralVoiceActivityDetector) throws -> [String: Double] {
        let sliceEnd = sliceStart + Double(slice.count) / 16_000
        var seeks: [String: Double] = [:]
        for lead in [1.0, 1.5, 2.0] {
            seeks[String(format: "lead %.1fs", lead)] = max(sliceStart, estimate - lead)
        }
        let windowStart = max(sliceStart, estimate - 3)
        let windowEnd = min(sliceEnd, estimate + 1)
        let from = max(0, Int((windowStart - sliceStart) * 16_000)), to = min(slice.count, Int((windowEnd - sliceStart) * 16_000))
        var onsets: [Double] = windowStart <= sliceStart + 0.01 ? [sliceStart] : []
        if to > from {
            let intervals = voicedIntervals(try vad.speechProbabilities(in: Array(slice[from..<to])))
            var previousEnd = 0.0
            for (s, e) in intervals {
                if s > 0.05, s - previousEnd >= 0.25 { onsets.append(windowStart + s) }
                previousEnd = e
            }
        }
        let fallback = max(sliceStart, estimate - 1)
        func cushion(_ onset: Double) -> Double { max(sliceStart, onset - 0.15) }
        for back in [3.0, 2.0] {
            let candidates = onsets.filter { $0 >= estimate - back && $0 <= estimate + 0.3 }
            seeks["pause back \(Int(back))s"] = candidates.max().map(cushion) ?? fallback
        }
        let near = onsets.filter { abs($0 - estimate) <= 2 }.min { abs($0 - estimate) < abs($1 - estimate) }
        seeks["pause nearest 2s"] = near.map(cushion) ?? fallback
        return seeks
    }

    /// Moves an estimate to the nearest point where speech resumes after a
    /// pause, if one lies within `window` seconds; sentences tend to start there.
    static func snap(_ estimate: Double, toOnsetsIn intervals: [(Double, Double)], sliceStart: Double, window: Double) -> Double {
        let onsets = intervals.map { sliceStart + $0.0 }
        guard let nearest = onsets.min(by: { abs($0 - estimate) < abs($1 - estimate) }),
              abs(nearest - estimate) <= window else { return estimate }
        return nearest
    }

    static func time(atVoicedFraction fraction: Double, in intervals: [(Double, Double)]) -> Double {
        let voiced = intervals.reduce(0) { $0 + ($1.1 - $1.0) }
        var remaining = fraction * voiced
        for (s, e) in intervals {
            if remaining <= e - s { return s + remaining }
            remaining -= e - s
        }
        return intervals.last!.1
    }

    /// Per UTF-16 unit: a CJK character counts one syllable, an English word its
    /// vowel groups spread over its letters, a digit one; the rest nothing.
    static func syllableWeights(_ text: String) -> [Double] {
        var weights: [Double] = []
        var word: [Character] = []
        func flushWord() {
            guard !word.isEmpty else { return }
            let lower = String(word).lowercased()
            var groups = 0, inVowel = false
            for c in lower {
                let vowel = "aeiouy".contains(c)
                if vowel && !inVowel { groups += 1 }
                inVowel = vowel
            }
            let syllables = Double(max(1, groups))
            let units = word.reduce(0) { $0 + String($1).utf16.count }
            weights += Array(repeating: syllables / Double(units), count: units)
            word.removeAll()
        }
        for character in text {
            let scalar = character.unicodeScalars.first!
            if character.isLetter, scalar.isASCII || !(0x4E00...0x9FFF).contains(scalar.value) && !(0x3040...0x30FF).contains(scalar.value) {
                word.append(character)
                continue
            }
            flushWord()
            let units = String(character).utf16.count
            let weight: Double = (character.isLetter || character.isNumber) ? 1 : 0
            weights += [weight] + Array(repeating: 0, count: units - 1)
        }
        flushWord()
        return weights
    }
}
