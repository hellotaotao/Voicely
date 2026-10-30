import AVFoundation
import Foundation
import Testing
@testable import Voicely

struct EnglishStretchRoutingTests {
    /// 60 s slices tagged in order; "-" is a slice without a tag.
    static func slices(_ tags: [String], seconds: Double = 60) -> [LanguageTaggedSlice] {
        tags.enumerated().map { index, tag in
            LanguageTaggedSlice(start: Double(index) * seconds, end: Double(index + 1) * seconds,
                                text: tag == "-" ? nil : "q\(index)", language: tag == "-" ? nil : tag)
        }
    }

    @Test func englishStretchesNeedThreeMinutesFromFirstToLastEnglishSlice() {
        // 3 English minutes count; 2 do not.
        #expect(EnglishStretchRouting.stretches(in: Self.slices(["English", "English", "English", "Chinese"]),
                                                mode: .automatic) == [0...2])
        #expect(EnglishStretchRouting.stretches(in: Self.slices(["English", "English", "Chinese"]), mode: .automatic).isEmpty)
    }

    @Test func englishOnlyRecordingsNeedNoMinimum() {
        let short = Self.slices(["-", "English", "None"], seconds: 10)
        #expect(EnglishStretchRouting.stretches(in: short, mode: .automatic) == [1...1])
        // Han characters in Qwen3-ASR's text mean the slice mixed in Chinese.
        var mixed = short
        mixed[1].text = "可不可以帮我去做个化验？ Yeah, a patient had"
        #expect(EnglishStretchRouting.stretches(in: mixed, mode: .automatic).isEmpty)
    }

    @Test func anyOtherLanguageEndsTheStretchAndEnglishAfterItStartsAgain() {
        let tags = ["English", "English", "English", "Chinese", "English", "English", "French",
                    "English", "English", "English", "English"]
        #expect(EnglishStretchRouting.stretches(in: Self.slices(tags), mode: .automatic) == [0...2, 7...10])
    }

    @Test func untaggedAndNoneSlicesStayInsideAStretchButNeverAtItsEdges() {
        let tags = ["-", "None", "English", "-", "None", "English", "English", "-", "None"]
        #expect(EnglishStretchRouting.stretches(in: Self.slices(tags), mode: .automatic) == [2...6])
        // Untagged slices do not count towards the three minutes on their own.
        #expect(EnglishStretchRouting.stretches(in: Self.slices(["English", "-", "-", "-", "Chinese"]), mode: .automatic).isEmpty)
    }

    @Test func chosenLanguageDecidesAlone() {
        let tags = ["Chinese", "-"]
        #expect(EnglishStretchRouting.stretches(in: Self.slices(tags), mode: .english) == [0...1])
        #expect(EnglishStretchRouting.stretches(in: Self.slices(["English", "English", "English", "English"]),
                                                mode: .otherLanguage).isEmpty)
        #expect(EnglishStretchRouting.Mode(languageHint: nil) == .automatic)
        #expect(EnglishStretchRouting.Mode(languageHint: "English") == .english)
        #expect(EnglishStretchRouting.Mode(languageHint: "Chinese") == .otherLanguage)
    }

    @Test func wordsGoToTheSliceTheirMiddleFallsIn() {
        let slices = Self.slices(["English", "-", "English"], seconds: 10)
        let words = [
            TimedWord(text: "Hello,", start: 1, end: 2),
            TimedWord(text: "world.", start: 2, end: 3),
            // Straddles the first cut, mostly after it.
            TimedWord(text: "Next", start: 9.5, end: 21),
            TimedWord(text: "one.", start: 22, end: 23),
            // Past the last slice.
            TimedWord(text: "Bye.", start: 31, end: 32),
        ]
        #expect(EnglishStretchRouting.distribute(words, over: slices) == ["Hello, world.", "Next", "one. Bye."])
        #expect(EnglishStretchRouting.distribute([], over: slices) == [nil, nil, nil])
    }

    @Test func transcriptKeepsOneLinePerSliceWithItsTimes() {
        var slices = Self.slices(["English", "-", "English"], seconds: 10)
        slices[2].text = "Two"
        let transcript = EnglishStretchRouting.transcript(of: slices)
        #expect(transcript.text == "q0\nTwo")
        #expect(transcript.spans == [TranscriptSpan(length: 3, start: 0, end: 10),
                                     TranscriptSpan(length: 3, start: 20, end: 30)])
    }

    @Test func aFailedStretchKeepsQwenText() async {
        struct Failure: Error {}
        let slices = Self.slices(["English", "English", "English", "Chinese", "English", "English", "English"])
        var calls = 0
        let routed = await EnglishStretchRouting.transcribeStretches(
            in: slices, mode: .automatic, fileURL: URL(fileURLWithPath: "/dev/null"), sampleRate: 16_000
        ) { _, start, end in
            calls += 1
            if calls == 1 { throw Failure() }
            #expect(start == 240 * 16_000 && end == 420 * 16_000)
            return [TimedWord(text: "Parakeet.", start: 250, end: 251)]
        }
        #expect(routed.replaced == [4, 5, 6])
        #expect(routed.slices.map(\.text) == ["q0", "q1", "q2", "q3", "Parakeet.", nil, nil])
    }

    @Test @MainActor func noteSwitchesBetweenVersionsUntilItsTextChanges() {
        let note = VoiceNote(title: "Meeting")
        let qwenSpans = [TranscriptSpan(length: 4, start: 0, end: 30)]
        note.setTranscript("Parakeet text", spans: nil,
                           alternate: AlternateTranscript(engine: .qwen3, text: "qwen", spans: qwenSpans))
        #expect(note.alternateTranscript?.engine == .qwen3)

        note.switchToAlternateTranscript()
        #expect(note.transcription == "qwen")
        #expect(note.transcriptSpans == qwenSpans)
        #expect(note.alternateTranscript?.engine == .parakeet)
        #expect(note.alternateTranscript?.text == "Parakeet text")

        note.switchToAlternateTranscript()
        #expect(note.transcription == "Parakeet text")

        note.applyEditedTranscript("Parakeet text, edited")
        #expect(note.alternateTranscript == nil)
    }
}

/// The Parakeet pass on a live recording and on saved audio, with a fake
/// Parakeet. Test fixtures cut 14 s slices.
@Suite(.serialized)
struct EnglishStretchTranscriptionTests {
    final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    /// One word in the middle of each 14 s slice in `range`, named after the slice.
    static func words(for range: ClosedRange<Int>, start: Int64, end: Int64) -> [TimedWord] {
        #expect(start == Int64(range.lowerBound * 14 * 16_000))
        return range.map { TimedWord(text: "en\($0)", start: Double($0 * 14) + 6, end: Double($0 * 14) + 7) }
    }

    @Test @MainActor func liveRecordingReplacesOnlyTheLongEnglishStretch() async throws {
        // Slice 0 Chinese, 1–13 English (182 s), 14 Chinese, 15–16 English (too short).
        let languages = ["Chinese"] + Array(repeating: "English", count: 13) + ["Chinese", "English", "English"]
        let pcmURL = try SegmentedAudioTestSupport.makeSilentCAF(seconds: Double(languages.count * 14))
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager(backend: .coreML))
        var decoded = 0
        service.transcribeImpl = { [unowned service] _, _ in
            service.decodedLanguage = languages[decoded]
            defer { decoded += 1 }
            return .text("q\(decoded)")
        }
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        var stretches: [(Int64, Int64)] = []
        coordinator.transcribeEnglish = { _, start, end, progress in
            stretches.append((start, end))
            progress(0.5)
            return Self.words(for: 1...13, start: start, end: end)
        }
        var released = false
        coordinator.releaseEnglishEngine = { released = true }

        for slice in 0..<(languages.count - 1) {
            await coordinator.transcribeSegment(upToFrame: Int64(slice * 14 + 15) * 16_000)
        }
        let qwenTranscript = await coordinator.stop(currentFrame: Int64(languages.count * 14) * 16_000)
        let qwenSpans = coordinator.accumulatedSpans
        let workBefore = service.decodeWorkCount

        let qwenVersion = await coordinator.transcribeEnglishStretches(mode: .automatic)

        #expect(stretches.count == 1 && stretches[0] == (14 * 16_000, 14 * 14 * 16_000))
        #expect(service.decodeWorkCount > workBefore)
        #expect(released)
        #expect(qwenVersion == AlternateTranscript(engine: .qwen3, text: qwenTranscript, spans: qwenSpans))
        let expected = ["q0"] + (1...13).map { "en\($0)" } + ["q14", "q15", "q16"]
        #expect(coordinator.accumulatedTranscript == expected.joined(separator: "\n"))
        #expect(coordinator.accumulatedSpans?.map(\.start) == qwenSpans?.map(\.start))

        // Another language chosen: nothing goes to Parakeet.
        stretches = []
        #expect(await coordinator.transcribeEnglishStretches(mode: .otherLanguage) == nil)
        #expect(stretches.isEmpty)
    }

    @Test @MainActor func savedAudioKeepsQwenVersionNextToParakeetText() async throws {
        let languages = Array(repeating: "English", count: 13) + ["Chinese"]
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: Double(languages.count * 14))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        transcriber.nextCutFrame = { _, start, _ in start + 14 * 16_000 }
        var decoded = 0
        transcriber.transcribeSegmentOutcome = { _ in
            defer { decoded += 1 }
            return .transcribed(.init(text: "q\(decoded)", duration: 1, modelIdentifier: "m",
                                      language: languages[decoded]))
        }
        transcriber.transcribeEnglish = { _, start, end in Self.words(for: 0...12, start: start, end: end) }
        transcriber.releaseEnglishEngine = {}
        let note = VoiceNote(title: "Import", audioFilePath: "")
        service.setLanguageKey("auto", for: note.id)

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(decoded == languages.count)
        #expect(note.transcription == ((0...12).map { "en\($0)" } + ["q13"]).joined(separator: "\n"))
        #expect(note.transcriptSpans?.count == languages.count)
        #expect(note.transcriptionOutcome == .transcribed)
        let alternate = try #require(note.alternateTranscript)
        #expect(alternate.engine == .qwen3)
        #expect(alternate.text == (0..<languages.count).map { "q\($0)" }.joined(separator: "\n"))
    }
}
