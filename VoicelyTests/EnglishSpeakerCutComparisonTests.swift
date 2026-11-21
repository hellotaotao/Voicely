#if DEBUG && targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// AMI meetings with the human word transcript, for asking whether Parakeet
/// is more accurate when each speaker's turn is transcribed on its own.
/// Local only: `build/speaker-cut-english/` holds `<meeting>.array.wav` (one
/// far-field microphone), `<meeting>.headset.wav` for some, and
/// `<meeting>.json` with the reference words and speaker changes. Run with
/// `VOICELY_RUN_ENGLISH_CUTS=1`.
private enum EnglishCutFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/speaker-cut-english")

    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment["VOICELY_RUN_ENGLISH_CUTS"] == "1"
            && FileManager.default.fileExists(atPath: directory.path)
    }

    struct Reference: Decodable {
        /// start, end, speaker letter, word
        let words: [[Value]]
        let referenceTurnChanges: [Double]

        enum Value: Decodable {
            case number(Double)
            case text(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) {
                    self = .number(number)
                } else {
                    self = .text(try container.decode(String.self))
                }
            }

            var text: String? { if case .text(let value) = self { value } else { nil } }
            var number: Double? { if case .number(let value) = self { value } else { nil } }
        }

        /// The transcript in time order, one word per entry.
        var text: [String] {
            words.compactMap { $0.count == 4 ? $0[3].text : nil }
        }
    }
}

@Suite(.serialized, .enabled(if: EnglishCutFixture.isConfigured))
struct EnglishSpeakerCutComparisonTests {
    private struct Score {
        var errors = 0
        var referenceWords = 0
        var hypothesisWords = 0
        var segments = 0
        var seconds = 0.0

        mutating func add(_ other: Score) {
            errors += other.errors
            referenceWords += other.referenceWords
            hypothesisWords += other.hypothesisWords
            segments += other.segments
            seconds += other.seconds
        }

        var rate: Double { Double(errors) / Double(max(referenceWords, 1)) * 100 }
    }

    @Test func wholeFileAgainstCuttingAtSpeakerChanges() async throws {
        let recordings = try FileManager.default.contentsOfDirectory(atPath: EnglishCutFixture.directory.path)
            .filter { $0.hasSuffix(".wav") }.sorted()
        var pooled: [String: [String: Score]] = [:]
        for name in recordings {
            let url = EnglishCutFixture.directory.appendingPathComponent(name)
            let meeting = String(name.prefix { $0 != "." })
            let microphone = name.split(separator: ".")[1]
            let reference = try JSONDecoder().decode(EnglishCutFixture.Reference.self, from: Data(
                contentsOf: EnglishCutFixture.directory.appendingPathComponent("\(meeting).json")))
            let referenceTokens = Self.tokens(reference.text.joined(separator: " "))
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate

            let nemotron = try await SpeakerDiarizationEngine.turns(for: url).turnChanges
            let conditions: [(String, [Double]?)] = [
                ("whole", nil), ("nemotron", nemotron), ("reference", reference.referenceTurnChanges),
            ]
            var line = "📊 \(meeting) \(microphone)"
            for (condition, changes) in conditions {
                let started = ProcessInfo.processInfo.systemUptime
                let segments = Self.segments(changes: changes ?? [], totalFrames: file.length, sampleRate: rate)
                var words: [TimedWord] = []
                for (start, end) in segments {
                    words += try await ParakeetEnglishEngine.shared.transcribe(fileURL: url, startFrame: start, endFrame: end)
                }
                words.sort { $0.start < $1.start }
                let hypothesis = Self.tokens(words.map(\.text).joined(separator: " "))
                var score = Score()
                score.errors = Self.editDistance(referenceTokens, hypothesis)
                score.referenceWords = referenceTokens.count
                score.hypothesisWords = hypothesis.count
                score.segments = segments.count
                score.seconds = ProcessInfo.processInfo.systemUptime - started
                pooled[String(microphone), default: [:]][condition, default: Score()].add(score)
                line += String(format: " | %@ %.2f%% (%d segments, %.0f s)", condition, score.rate, score.segments, score.seconds)
                try? Self.save(words, to: "\(meeting).\(microphone).\(condition).txt")
            }
            print(line + " | reference words \(referenceTokens.count)")
        }
        for (microphone, scores) in pooled.sorted(by: { $0.key < $1.key }) {
            let parts = ["whole", "nemotron", "reference"].compactMap { condition in
                scores[condition].map { String(format: "%@ %.2f%% (%d/%d, %d segments)", condition, $0.rate, $0.errors, $0.referenceWords, $0.segments) }
            }
            print("📊 all \(microphone): " + parts.joined(separator: " | "))
        }
        await ParakeetEnglishEngine.shared.unload()
    }

    /// Stretches between speaker changes, each at least the app's shortest
    /// speaker slice, in frames of the file.
    static func segments(changes: [Double], totalFrames: AVAudioFramePosition,
                         sampleRate: Double) -> [(AVAudioFramePosition, AVAudioFramePosition)] {
        var result: [(AVAudioFramePosition, AVAudioFramePosition)] = []
        var start: AVAudioFramePosition = 0
        let minimum = IncrementalTranscriptionCoordinator.minimumSpeakerSliceSeconds
        for change in changes.sorted() {
            let frame = AVAudioFramePosition((change * sampleRate).rounded())
            guard frame < totalFrames, Double(frame - start) / sampleRate >= minimum else { continue }
            result.append((start, frame))
            start = frame
        }
        result.append((start, totalFrames))
        return result
    }

    /// Lowercase words without punctuation or hesitations, which AMI writes
    /// out and Parakeet mostly leaves out.
    static func tokens(_ text: String) -> [String] {
        let fillers: Set<String> = ["um", "uh", "hmm", "hm", "mm", "mhm", "mmm", "er", "erm", "ah", "eh", "uhhuh", "mmhmm"]
        var tokens: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty, !fillers.contains(word) { tokens.append(word) }
            word = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || (scalar == "'" && !word.isEmpty) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var ids: [String: Int32] = [:]
        let left = a.map { word in ids[word] ?? { let id = Int32(ids.count); ids[word] = id; return id }() }
        let right = b.map { word in ids[word] ?? { let id = Int32(ids.count); ids[word] = id; return id }() }
        var previous = [Int32](0...Int32(right.count))
        var current = [Int32](repeating: 0, count: right.count + 1)
        previous.withUnsafeMutableBufferPointer { previousBuffer in
            current.withUnsafeMutableBufferPointer { currentBuffer in
                var p = previousBuffer
                var c = currentBuffer
                right.withUnsafeBufferPointer { r in
                    for i in 0..<left.count {
                        c[0] = Int32(i + 1)
                        let word = left[i]
                        for j in 0..<r.count {
                            let substitution = p[j] + (word == r[j] ? 0 : 1)
                            c[j + 1] = min(substitution, min(p[j + 1], c[j]) + 1)
                        }
                        swap(&p, &c)
                    }
                }
                if left.count % 2 == 1 {
                    // The last row was written to the buffer now named `p`,
                    // which is the original `current`.
                    previousBuffer[right.count] = currentBuffer[right.count]
                }
            }
        }
        return Int(previous[right.count])
    }

    static func save(_ words: [TimedWord], to name: String) throws {
        // The test host may read the repository but writes only to its own container.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-cut-english", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = words.map { String(format: "%.2f\t%.2f\t%@", $0.start, $0.end, $0.text) }
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

struct EnglishSpeakerCutScoringTests {
    @Test func editDistanceCountsWordErrors() {
        typealias T = EnglishSpeakerCutComparisonTests
        #expect(T.editDistance(["a", "b", "c"], ["a", "c"]) == 1)
        #expect(T.editDistance(["a", "b"], ["a", "x", "b", "y"]) == 2)
        #expect(T.editDistance(["a", "b", "c", "d"], ["b", "a", "c", "d"]) == 2)
        #expect(T.tokens("Mm-hmm, okay. Don't um go!") == ["okay", "don't", "go"])
        let segments = T.segments(changes: [0.5, 3, 3.5, 6], totalFrames: 8 * 16_000, sampleRate: 16_000)
        #expect(segments.map { $0.0 / 16_000 } == [0, 3, 6])
    }
}
#endif
