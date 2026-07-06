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

actor DurationCollector {
    private(set) var durations: [Double?] = []
    private(set) var allActive = true
    func record(active: Bool, duration: Double?) {
        durations.append(duration)
        if !active { allActive = false }
    }
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
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            await observed.record(await MainActor.run { note.transcription })
            let n = await calls.incrementAndGet()
            return .transcribed(.init(text: "seg\(n)", duration: 1, modelIdentifier: "m"))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await observed.values == ["", "seg1", "seg1\nseg2"])
        #expect(note.transcription == "seg1\nseg2\nseg3")
    }

    @Test @MainActor func segmentedRunDrivesWholeFileTelemetry() async throws {
        // Re-transcribe / import (the segmented path) must drive ONE telemetry
        // session pinned to the WHOLE-FILE duration for the entire run, so the
        // detail card shows a real, growing time-ratio/speed. Regression for the
        // "stuck on Measuring" bug: telemetry used to be driven per ~29 s slice
        // (reset each segment) rather than once for the whole file.
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        let note = VoiceNote(title: "imported", audioFilePath: "")
        let observed = DurationCollector()
        transcriber.transcribeSegmentOutcome = { _ in
            let snapshot = await MainActor.run { service.transcriptionTelemetry }
            await observed.record(active: snapshot.isActive,
                                  duration: snapshot.metrics.audioDurationSeconds)
            return .transcribed(.init(text: "seg", duration: 1, modelIdentifier: "m"))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        // Each slice should have seen the live telemetry active and pinned to the
        // whole-file ~70 s (not a per-slice ~29 s value, and not nil → "Measuring").
        let durations = await observed.durations
        #expect(!durations.isEmpty)
        #expect(await observed.allActive)
        for duration in durations {
            #expect(duration != nil)
            if let duration { #expect(abs(duration - 70) < 2) }
        }
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
            let n = await calls.incrementAndGet()
            return .transcribed(.init(text: "seg\(n)", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 3)
        #expect(note.transcription == "seg1\nseg2\nseg3")
        #expect(note.transcriptionOutcome == .transcribed)
    }

    @Test @MainActor func adjacentIdenticalSlicesAreDeduplicatedWithTheirWords() async throws {
        // A cross-window decode loop repeating the previous slice verbatim (the
        // classic whisper hallucination) collapses to one piece — text and word
        // timings together, so the tappable transcript matches the plain text.
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "same words", duration: 1, modelIdentifier: "m",
                               words: [WordToken(word: " same", start: 0.0, end: 0.4),
                                       WordToken(word: " words", start: 0.4, end: 0.8)]))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcription == "same words")
        #expect(note.wordTimings.count == 2)
        #expect(note.transcription == note.wordTimings.map(\.word).joined())
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
            let n = await calls.incrementAndGet()
            return .transcribed(.init(text: "more\(n)", duration: 1, modelIdentifier: "m"))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 2)               // only the remaining 2 segments
        #expect(note.transcription == "first\nmore1\nmore2")
    }

    @Test @MainActor func resumedRunKeepsPersistedWordTimings() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let note = VoiceNote(title: "imported", audioFilePath: "")
        // Segment 1 already finished, with its word saved in the sidecar.
        store.save(.init(lastFrame: Int64(29 * 16_000), totalFrames: Int64(70 * 16_000),
                         accumulatedText: "first", failedRanges: [], updatedAt: Date(),
                         accumulatedWords: [WordToken(word: "first", start: 0.0, end: 0.5)]),
                   for: note.id)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            let n = await calls.incrementAndGet()
            return .transcribed(.init(text: "more\(n)", duration: 1, modelIdentifier: "m",
                                      words: [WordToken(word: "more\(n)", start: 0.0, end: 0.5)]))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        // Pre-resume word + the two remaining segments = a complete timeline. The
        // old resume path dropped its pre-resume words and stored nothing, which
        // left a finished re-transcribe showing the previous run's transcript.
        #expect(note.wordTimings.count == 3)
        // The first token carries the piece separator ("first\n") by design.
        #expect(note.wordTimings.first?.word.hasPrefix("first") == true)
        let starts = note.wordTimings.map(\.start)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 })   // re-based, increasing
    }

    /// End-to-end acceptance for "an interrupted run keeps its word timings":
    /// run 1 is backgrounded after the first segment (the production loop must
    /// write that segment's words into the sidecar itself), run 2 resumes from
    /// the sidecar and finishes with one complete, increasing timeline.
    @Test @MainActor func interruptedRunPersistsWordsAndResumesToCompleteTimeline() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let note = VoiceNote(title: "interrupted", audioFilePath: "")

        var completedSegments = 0
        let segmentStub: (URL) async -> TranscriptionOutcome = { _ in
            completedSegments += 1
            return .transcribed(.init(text: "seg\(completedSegments)", duration: 1, modelIdentifier: "m",
                                      words: [WordToken(word: "seg\(completedSegments)", start: 0.0, end: 0.5)]))
        }

        // Run 1: killed/backgrounded right after the first segment lands.
        let first = SegmentedAudioTestSupport.makeTranscriber(store: store)
        first.transcribeSegmentOutcome = segmentStub
        first.shouldStopForBackground = { completedSegments >= 1 }
        await first.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionState != .completed)
        #expect(store.load(for: note.id)?.accumulatedWords?.isEmpty == false)

        // Run 2 (app relaunch): a fresh transcriber resumes and finishes.
        let second = SegmentedAudioTestSupport.makeTranscriber(store: store)
        second.transcribeSegmentOutcome = segmentStub
        await second.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionState == .completed)
        #expect(note.transcription.contains("seg1"))          // pre-interrupt text kept
        let fullStarts = note.wordTimings.map(\.start)
        #expect(note.wordTimings.first?.start == 0.0)         // timeline starts at the top
        #expect(zip(fullStarts, fullStarts.dropFirst()).allSatisfy { $0 < $1 })
        #expect((note.wordTimings.last?.start ?? 0) > 20.0)   // resumed part re-based past the cut
    }

    @Test @MainActor func legacyResumeWithoutSavedWordsClearsStaleTimings() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let note = VoiceNote(title: "imported", audioFilePath: "")
        note.wordTimings = [WordToken(word: "stale", start: 0.0, end: 0.5)]   // a previous run's timings
        // A sidecar written before words were persisted (accumulatedWords == nil).
        store.save(.init(lastFrame: Int64(29 * 16_000), totalFrames: Int64(70 * 16_000),
                         accumulatedText: "first", failedRanges: [], updatedAt: Date()),
                   for: note.id)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            let n = await calls.incrementAndGet()
            return .transcribed(.init(text: "more\(n)", duration: 1, modelIdentifier: "m",
                                      words: [WordToken(word: "more\(n)", start: 0.0, end: 0.5)]))
        }

        await transcriber.transcribe(note: note, sourceURL: url)

        // A legacy sidecar can't rebuild a complete timeline, so the stale
        // previous-run timings are cleared (the view falls back to the new text)
        // rather than left to mask the re-transcribed result.
        #expect(note.wordTimings.isEmpty)
        #expect(note.transcription == "first\nmore1\nmore2")
    }

    // MARK: Task 6 — retry, failed-range placeholder, noSpeech

    @Test @MainActor func failedSegmentBisectsAndRescuesWhenHalvesSucceed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { segmentURL in
            // Segment 2 (extraction index 2) fails as a whole; its two bisected
            // halves (indices 3 & 4) transcribe fine, so nothing is lost.
            let i = SegmentedAudioTestSupport.extractionIndex(of: segmentURL)
            if i == 2 {
                return .whisperError("boom", retryable: false)
            }
            return .transcribed(.init(text: "ok\(i)", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .transcribed)              // fully recovered
        #expect(!note.transcription.contains("transcription unavailable"))
        // seg1 + two rescued halves of seg2 (indices 3 & 4) + seg3 (index 5).
        #expect(note.transcription == "ok1\nok3\nok4\nok5")
    }

    @Test @MainActor func rescuedHalvesContributeRebasedWordTimings() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        // Every transcribed slice carries one word at slice-local 0.0–0.5; the
        // transcriber must re-base each to the slice's offset in the recording.
        transcriber.transcribeSegmentOutcome = { segmentURL in
            let i = SegmentedAudioTestSupport.extractionIndex(of: segmentURL)
            if i == 2 {
                return .whisperError("boom", retryable: false)   // seg2 fails ⇒ bisected into halves 3 & 4
            }
            return .transcribed(.init(text: "ok\(i)", duration: 1, modelIdentifier: "m",
                                      words: [WordToken(word: "ok\(i)", start: 0.0, end: 0.5)]))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        // seg1 + two rescued halves of seg2 + seg3 = 4 words. Before the fix the
        // two rescued halves dropped their timings, leaving only 2.
        #expect(note.wordTimings.count == 4)
        let starts = note.wordTimings.map(\.start)
        // Each piece re-based to its own offset ⇒ strictly increasing global times.
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 })
        #expect(starts.first == 0.0)        // seg1 sits at the recording start
        #expect(starts.last! > 50.0)        // seg3 starts ~58 s in
    }

    @Test @MainActor func nonRetryableErrorSkipsSameWindowRetryAndBisects() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let seg2Calls = Counter()
        transcriber.transcribeSegmentOutcome = { segmentURL in
            let i = SegmentedAudioTestSupport.extractionIndex(of: segmentURL)
            if i == 2 {
                await seg2Calls.increment()
                return .whisperError("blank", retryable: false)   // deterministic
            }
            return .transcribed(.init(text: "ok\(i)", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        // A deterministic failure must NOT re-run the identical window — it goes
        // straight to bisection. (The old loop ran it 3× before bisecting.)
        #expect(await seg2Calls.value == 1)
        #expect(note.transcription == "ok1\nok3\nok4\nok5")   // halves still salvaged
        #expect(note.transcriptionOutcome == .transcribed)
    }

    @Test @MainActor func retryableErrorRetriesSameWindowBeforeBisecting() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)  // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let seg2Calls = Counter()
        transcriber.transcribeSegmentOutcome = { segmentURL in
            let i = SegmentedAudioTestSupport.extractionIndex(of: segmentURL)
            if i == 2 {
                await seg2Calls.increment()
                return .whisperError("transient", retryable: true)   // worth retrying
            }
            return .transcribed(.init(text: "ok\(i)", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        // A transient error re-runs the same window twice (3 total) before falling
        // back to bisection, which then salvages the halves.
        #expect(await seg2Calls.value == 3)
        #expect(note.transcription == "ok1\nok3\nok4\nok5")
        #expect(note.transcriptionOutcome == .transcribed)
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
            if i == 2 || i == 4 { return .whisperError("boom", retryable: false) }
            return .transcribed(.init(text: "ok\(i)", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .partial)
        #expect(note.transcription.contains("transcription unavailable"))
        #expect(note.transcription.hasPrefix("ok1"))   // seg1 + rescued left half
        #expect(note.transcription.hasSuffix("ok5"))   // seg3
    }

    @Test @MainActor func importWithNoUsableTextYieldsFailed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in .whisperError("boom", retryable: false) }  // nothing transcribes
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
        transcriber.transcribeSegmentOutcome = { _ in .whisperError("boom", retryable: false) }   // every segment fails
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
            if i == 2 || i == 4 { return .whisperError("boom", retryable: false) }
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
