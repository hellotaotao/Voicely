import AVFoundation
import Foundation
import Testing
@testable import Voicely

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
    func incrementAndGet() -> Int { value += 1; return value }
}

@Suite(.serialized)
struct SegmentedAudioTranscriberTests {
    // MARK: Task 3 — short single pass

    @Test @MainActor func shortFileSinglePassWritesTextAndNoSidecar() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "hello world", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcription == "hello world")
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(store.load(for: note.id) == nil)   // ≤30s never writes a sidecar
    }

    @Test func timestampFormatsMinutesAndHours() {
        #expect(SegmentedAudioTranscriber.formatTimestamp(75) == "1:15")
        #expect(SegmentedAudioTranscriber.formatTimestamp(3_661) == "1:01:01")
    }

    // MARK: Task 4 — long-file segmentation

    @Test @MainActor func longFileSlicesAndJoinsWithSidecar() async throws {
        // 70 s @ 16 kHz, target 29 s ⇒ 3 segments (29 + 29 + 12).
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            await calls.increment()
            return .transcribed(.init(text: "seg", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 3)
        #expect(note.transcription == "seg\nseg\nseg")
        #expect(note.transcriptionOutcome == .transcribed)
    }

    // MARK: Task 5 — resume from sidecar

    @Test @MainActor func resumeStartsFromSavedFrame() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let note = VoiceNote(title: "imported", audioFilePath: "")
        // Pretend segment 1 already finished: lastFrame at 29 s, one piece saved.
        store.save(.init(lastFrame: Int64(29 * 16_000), totalFrames: Int64(70 * 16_000),
                         accumulatedText: "first", failedRanges: [], updatedAt: Date()),
                   for: note.id)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            await calls.increment()
            return .transcribed(.init(text: "more", duration: 1, modelIdentifier: "m"))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 2)               // only the remaining 2 segments
        #expect(note.transcription == "first\nmore\nmore")
    }

    // MARK: Task 6 — retry, failed-range placeholder, noSpeech

    @Test @MainActor func failedSegmentRetriesThenSkipsWithPlaceholder() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            let n = await calls.incrementAndGet()
            // Segment 2 = calls 2,3,4 (initial + 2 retries) all fail; others succeed.
            if (2...4).contains(n) { return .whisperError("boom") }
            return .transcribed(.init(text: "ok", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 5)               // seg1(1) + seg2(3) + seg3(1)
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcription.contains("transcription unavailable"))
        #expect(note.transcription.hasPrefix("ok"))
        #expect(note.transcription.hasSuffix("ok"))
    }

    @Test @MainActor func allNoSpeechYieldsNoSpeechOutcome() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in .noSpeech }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .noSpeech)
        #expect(note.transcription.isEmpty)
    }

    // MARK: Task 7 — claim + lease

    @Test @MainActor func claimsNoteForThisDeviceWhileWorking() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        service.deviceIDProvider = { "device-X" }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "x", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        // Freeze mid-run, after the first segment is persisted.
        transcriber.shouldStopForBackground = { (store.load(for: note.id)?.lastFrame ?? 0) > 0 }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionState == .claimed)               // still owned, not finalized
        #expect(note.transcriptionOwnerDeviceID == "device-X")
        #expect((note.transcriptionLeaseExpiresAt ?? .distantPast) > Date())
    }

    // MARK: Task 8 — background stop at boundary

    @Test @MainActor func stopsAtBoundaryWhenBackgroundExpires() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            _ = await calls.incrementAndGet()
            return .transcribed(.init(text: "seg", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        // Stop once the first segment has been persisted.
        transcriber.shouldStopForBackground = { (store.load(for: note.id)?.lastFrame ?? 0) > 0 }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 1)                       // stopped after segment 1
        #expect(note.transcriptionState == .claimed)          // not finalized
        #expect((store.load(for: note.id)?.lastFrame ?? 0) > 0) // sidecar kept for resume
    }
}
