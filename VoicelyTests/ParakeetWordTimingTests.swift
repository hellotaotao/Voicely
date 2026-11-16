import Foundation
import Testing
@testable import Voicely

struct ParakeetWordTimingTests {
    @Test func renderKeepsExactFinalTextAndUTF16OffsetsForRepeatedWords() throws {
        let words = [
            TimedWord(text: "  Hi🙂", start: 12, end: 12.4),
            TimedWord(text: " Hi🙂", start: 12.5, end: 13),
            TimedWord(text: "there.  ", start: 13, end: 13.5)
        ]
        let output = try #require(EnglishStretchRouting.render(words))
        #expect(output.text == "Hi🙂  Hi🙂 there.")
        let timings = try #require(output.wordTimings)
        #expect(timings.map(\.offset) == [0, 6, 11])
        #expect(timings.map(\.length) == [4, 4, 6])
        #expect(timings.map(\.start) == [12, 12.5, 13])
    }

    @Test func invalidTimingDoesNotChangeTheWrittenWords() throws {
        let output = try #require(EnglishStretchRouting.render([
            .init(text: "Always", start: .nan, end: 1),
            .init(text: "keep text.", start: 1, end: 2),
        ]))
        #expect(output.text == "Always keep text.")
        #expect(output.wordTimings == [.init(offset: 7, length: 10, start: 1, end: 2)])
    }

    @Test func ambiguousTextNormalizationNeverInventsWordOffsets() throws {
        let output = try #require(EnglishStretchRouting.render([
            .init(text: "first  \n  second", start: 1, end: 2)
        ]))
        #expect(output.text == "first\nsecond")
        #expect(output.wordTimings == nil)
    }

    @Test func routedWordsCarryTheirOwnTimesWhileOtherSpansStayUntimed() async throws {
        let slices: [LanguageTaggedSlice] = [
            .init(start: 0, end: 3, text: "Before", language: nil),
            .init(start: 3, end: 7, text: "Replace", language: "English"),
            .init(start: 7, end: 10, text: "Replace", language: "English"),
        ]
        let routed = await EnglishStretchRouting.transcribeStretches(
            [1...2], in: slices, fileURL: URL(fileURLWithPath: "/tmp/fixture"), sampleRate: 1
        ) { _, _, _ in
            [.init(text: "Hello.", start: 5, end: 6), .init(text: "Again.", start: 7, end: 8)]
        }
        let transcript = EnglishStretchRouting.transcript(of: routed.slices)
        #expect(transcript.text == "Before\nHello.\nAgain.")
        let spans = try #require(transcript.spans)
        #expect(spans.map(\.length) == [7, 7, 6])
        #expect(spans[0].wordTimings == nil)
        #expect(spans[1].wordTimings == [.init(offset: 0, length: 6, start: 5, end: 6)])
        #expect(spans[2].wordTimings == [.init(offset: 0, length: 6, start: 7, end: 8)])
    }

    @Test @MainActor func persistedTimesAreBoundToTheTextAndAudioAndSurviveLabelWrites() throws {
        let note = VoiceNote(title: "Test")
        let word = TranscriptWordTiming(offset: 0, length: 3, start: 1, end: 2)
        let spans = [TranscriptSpan(length: 4, start: 0, end: 3, wordTimings: [word])]
        note.setTranscript("Say.", spans: spans)
        note.attachImportedAudio("original.m4a")
        #expect(note.transcriptSpans == spans)
        let wire = try #require(note.transcriptSpansData)
        let legacy = try JSONDecoder().decode(LegacyTimeline.self, from: wire)
        #expect(legacy.spans.first?.length == 4)
        #expect(note.setSpeakerTranscript(.init(
            audioPath: "original.m4a", units: [.init(length: 4, start: 1, speaker: 1)]
        )))
        #expect(note.transcriptSpans == spans)

        note.audioFilePath = "replacement.m4a"
        #expect(note.transcriptSpans?.first?.wordTimings == nil)
        #expect(note.transcriptSpans?.first?.length == 4)
        note.audioFilePath = "original.m4a"
        note.applyEditedTranscript("Said.")
        #expect(note.transcriptSpans?.first?.wordTimings == nil)
    }

    @Test func wordTimesUseCompactJSONForLongRecordings() throws {
        let timing = TranscriptWordTiming(offset: 17, length: 5, start: 3600.25, end: 3601)
        let data = try JSONEncoder().encode(timing)
        #expect(String(decoding: data, as: UTF8.self) == "[17,5,3600.25,3601]")
        #expect(try JSONDecoder().decode(TranscriptWordTiming.self, from: data) == timing)
    }

    @Test func legacyTimelineDecodesWithoutWordTimes() throws {
        let old = """
        {"spans":[{"length":4,"start":0,"end":3}],"textDigest":"unused"}
        """
        let decoded = try JSONDecoder().decode(StoredTranscriptTimeline.self, from: Data(old.utf8))
        #expect(decoded.spans.first?.wordTimings == nil)
    }

    private struct LegacyTimeline: Decodable {
        struct Span: Decodable { var length: Int }
        var spans: [Span]
    }
}
