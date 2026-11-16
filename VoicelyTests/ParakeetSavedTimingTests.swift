import Foundation
import Testing
@testable import Voicely

@MainActor
struct ParakeetSavedTimingTests {
    @Test func englishImportStoresLocalCharacterOffsetsAndAbsoluteTimes() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        let transcriber = Self.transcriber(service: service)
        transcriber.storeImportedAudio = { _ in "listening-copy.m4a" }
        transcriber.transcribeEnglish = { _, _, _ in
            [TimedWord(text: "Hello,", start: 2, end: 3), TimedWord(text: "world.", start: 4, end: 5)]
        }
        let note = VoiceNote(title: "Import", audioFilePath: "")
        service.setLanguageKey("english", for: note.id)

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcription == "Hello, world.")
        #expect(note.audioFilePath == "listening-copy.m4a")
        let span = try #require(note.transcriptSpans?.first)
        #expect(span.wordTimings == [
            .init(offset: 0, length: 6, start: 2, end: 3),
            .init(offset: 7, length: 6, start: 4, end: 5)
        ])
    }

    @Test func longEnglishImportResumesWithItsTimedWordsAtTheRightAudioPositions() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 42)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = Self.transcriber(service: service, store: store)
        let note = VoiceNote(title: "Import", audioFilePath: "saved.m4a")
        service.setLanguageKey("english", for: note.id)
        var starts: [Int64] = []
        transcriber.transcribeEnglish = { _, start, _ in
            starts.append(start)
            if start == 0 { return [TimedWord(text: "First.", start: 4, end: 5)] }
            return [TimedWord(text: "Second.", start: 18, end: 19), TimedWord(text: "Third.", start: 30, end: 31)]
        }
        transcriber.shouldStopForBackground = { store.load(for: note.id) != nil }
        await transcriber.transcribe(note: note, sourceURL: url)

        let checkpoint = try #require(store.load(for: note.id))
        #expect(checkpoint.lastFrame == 14 * 16_000)
        #expect(checkpoint.spans?.first?.wordTimings == [.init(offset: 0, length: 6, start: 4, end: 5)])

        transcriber.shouldStopForBackground = { false }
        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(starts == [0, 14 * 16_000])
        #expect(note.transcription == "First.\nSecond.\nThird.")
        #expect(note.transcriptSpans?.map { $0.wordTimings ?? [] } == [
            [.init(offset: 0, length: 6, start: 4, end: 5)],
            [.init(offset: 0, length: 7, start: 18, end: 19)],
            [.init(offset: 0, length: 6, start: 30, end: 31)]
        ])
        #expect(store.load(for: note.id) == nil)
    }

    @Test func englishRetranscriptionGetsTimingsAndQwenFallbackDoesNotReuseThem() async throws {
        let parakeet = try await EnglishStretchTranscriptionTests.retranscribeShortNote(
            qwen: "fallback", languageKey: "english"
        ) { _, _, _ in
            [TimedWord(text: "Before.", start: 2, end: 3), TimedWord(text: "After.", start: 4, end: 5)]
        }
        #expect(parakeet.qwenCalls == 0)
        #expect(parakeet.note.transcriptSpans?.first?.wordTimings == [
            .init(offset: 0, length: 7, start: 2, end: 3),
            .init(offset: 8, length: 6, start: 4, end: 5)
        ])

        let fallback = try await EnglishStretchTranscriptionTests.retranscribeShortNote(
            qwen: "fallback", languageKey: "english"
        ) { _, _, _ in [] }
        #expect(fallback.qwenCalls == 1)
        #expect(fallback.note.transcription == "fallback")
        #expect(fallback.note.transcriptSpans?.count == 1)
        #expect(fallback.note.transcriptSpans?.first?.wordTimings == nil)
    }

    private static func transcriber(service: TranscriptionService, store: SegmentProgressStore? = nil)
        -> SegmentedAudioTranscriber {
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(
            store: store ?? SegmentedAudioTestSupport.makeStore(), service: service)
        transcriber.nextCutFrame = { _, start, _ in start + 14 * 16_000 }
        transcriber.transcribeSegmentOutcome = { _ in
            Issue.record("English import unexpectedly fell back to Qwen3-ASR")
            return .noSpeech
        }
        transcriber.releaseEnglishEngine = {}
        return transcriber
    }
}
