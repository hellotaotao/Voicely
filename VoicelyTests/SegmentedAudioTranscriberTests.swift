import AVFoundation
import Foundation
import Testing
@testable import Voicely

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
    func incrementAndGet() -> Int { value += 1; return value }
}

actor ActiveProbe {
    private(set) var sawActive = false
    func record(_ active: Bool) { if active { sawActive = true } }
}

actor TranscriptCollector {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
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

    @Test @MainActor func segmentedRunUpdatesTranscriptIncrementally() async throws {
        // 70 s @ 16 kHz, target 29 s ⇒ 3 segments. Each segment callback fires
        // before that segment's text exists, so it observes the running total
        // of the *previous* segments — proving text is surfaced incrementally
        // rather than only after the whole file finishes.
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "imported", audioFilePath: "")
        let observed = TranscriptCollector()
        transcriber.transcribeSegmentOutcome = { _ in
            await observed.record(await MainActor.run { note.transcription })
            return .transcribed(.init(text: "seg", duration: 1, modelIdentifier: "m"))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await observed.values == ["", "seg", "seg\nseg"])
        #expect(note.transcription == "seg\nseg\nseg")
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

    @Test @MainActor func failedSegmentBisectsAndRescuesWhenHalvesSucceed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { segmentURL in
            // Segment 2 (extraction index 2) fails as a whole; its two bisected
            // halves (indices 3 & 4) transcribe fine, so nothing is lost.
            if SegmentedAudioTestSupport.extractionIndex(of: segmentURL) == 2 {
                return .whisperError("boom")
            }
            return .transcribed(.init(text: "ok", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .transcribed)              // fully recovered
        #expect(!note.transcription.contains("transcription unavailable"))
        // seg1 + two rescued halves of seg2 + seg3 = 4 pieces.
        #expect(note.transcription == "ok\nok\nok\nok")
    }

    @Test @MainActor func partialOutcomeWhenABisectedHalfStaysFailed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.minSalvageSeconds = 20   // one split only: 29s ⇒ two ~14.5s halves
        transcriber.transcribeSegmentOutcome = { segmentURL in
            // Segment 2 (index 2) fails; its left half (index 3) is rescued, but
            // its right half (index 4) still fails and is ≤ minSalvage, so it stays
            // a single placeholder — a partial success, not a failure.
            let i = SegmentedAudioTestSupport.extractionIndex(of: segmentURL)
            if i == 2 || i == 4 { return .whisperError("boom") }
            return .transcribed(.init(text: "ok", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .partial)
        #expect(note.transcription.contains("transcription unavailable"))
        #expect(note.transcription.hasPrefix("ok"))   // seg1 + rescued left half
        #expect(note.transcription.hasSuffix("ok"))   // seg3
    }

    @Test @MainActor func importWithNoUsableTextYieldsFailed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in .whisperError("boom") }  // nothing transcribes
        let note = VoiceNote(title: "imported", audioFilePath: "")            // no prior transcript

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .failed)   // produced nothing usable
        #expect(note.transcription.contains("transcription unavailable"))
    }

    @Test @MainActor func segmentedRunRecordsModelIdentifierAndDuration() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "x", duration: 2, modelIdentifier: "openai_whisper-small"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionModelIdentifier == "openai_whisper-small")
        #expect(note.lastTranscriptionDuration > 0)
    }

    @Test @MainActor func surfacesAsLocallyTranscribingDuringRun() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        let probe = ActiveProbe()
        transcriber.transcribeSegmentOutcome = { _ in
            await probe.record(service.activeNoteID != nil)
            return .transcribed(.init(text: "x", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await probe.sawActive)            // shown as transcribing while running
        #expect(service.activeNoteID == nil)      // cleared after the run (defer)
        #expect(service.progressByNoteID[note.id] == nil)
    }

    @Test @MainActor func externalTranscriptionMarkersSetAndClear() {
        let service = TranscriptionService()
        let id = UUID()
        service.beginExternalTranscription(noteID: id)
        #expect(service.activeNoteID == id)
        #expect(service.progressByNoteID[id] == 0)
        service.reportExternalProgress(0.5, for: id)
        #expect(service.progressByNoteID[id] == 0.5)
        service.endExternalTranscription(noteID: id)
        #expect(service.activeNoteID == nil)
        #expect(service.progressByNoteID[id] == nil)
    }

    @Test @MainActor func reTranscribeTotalFailureKeepsOldTranscript() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in .whisperError("boom") }   // every segment fails
        let note = VoiceNote(title: "rec", audioFilePath: "rec.m4a")
        note.transcription = "the original transcript"

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcription == "the original transcript")   // preserved, not overwritten
        #expect(note.transcriptionOutcome == .transcribed)         // not .failed
        #expect(note.transcriptionLastErrorMessage != nil)         // diagnostic kept
    }

    @Test @MainActor func reTranscribePartialSuccessUsesNewResult() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)   // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.minSalvageSeconds = 20   // one split only, so a gap survives
        transcriber.transcribeSegmentOutcome = { segmentURL in
            // Segment 2 fails; its right half (index 4) can't be salvaged.
            let i = SegmentedAudioTestSupport.extractionIndex(of: segmentURL)
            if i == 2 || i == 4 { return .whisperError("boom") }
            return .transcribed(.init(text: "new", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "rec", audioFilePath: "rec.m4a")
        note.transcription = "the original transcript"

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcription.hasPrefix("new"))                       // new result used
        #expect(note.transcription.contains("transcription unavailable"))  // surviving gap
        #expect(note.transcriptionOutcome == .partial)
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
