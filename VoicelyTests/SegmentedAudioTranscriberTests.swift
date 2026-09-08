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
        #expect(note.transcriptionOutcome == .failed)         // The latest attempt failed despite preserving text.
        #expect(note.transcriptionLastErrorMessage != nil)         // diagnostic kept
    }

    @Test @MainActor func reTranscribePartialSuccessKeepsCompleteOriginal() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)   // 3 segments
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            let n = await calls.incrementAndGet()
            if (2...4).contains(n) { return .whisperError("boom") }   // segment 2 fails
            return .transcribed(.init(text: "new", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "rec", audioFilePath: "rec.m4a")
        note.transcription = "the original transcript"

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await calls.value == 5)  // All three segments attempted, with two retries.
        #expect(note.transcription == "the original transcript")
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage != nil)
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
        let note = VoiceNote(title: "imported", audioFilePath: "")
        var observedClaim = false
        transcriber.transcribeSegmentOutcome = { _ in
            #expect(note.transcriptionState == .claimed)
            #expect(note.transcriptionOwnerDeviceID == "device-X")
            #expect((note.transcriptionLeaseExpiresAt ?? .distantPast) > Date())
            observedClaim = true
            return .transcribed(.init(text: "x", duration: 1, modelIdentifier: "m"))
        }
        // Freeze mid-run, after the first segment is persisted.
        transcriber.shouldStopForBackground = { (store.load(for: note.id)?.lastFrame ?? 0) > 0 }

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(observedClaim)
        #expect(note.transcriptionState == .queued)
        #expect(note.transcriptionOwnerDeviceID == nil)
        #expect(note.transcriptionLeaseExpiresAt == nil)
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
        #expect(note.transcriptionState == .queued)           // ready to resume
        #expect((store.load(for: note.id)?.lastFrame ?? 0) > 0) // sidecar kept for resume
    }
    @Test @MainActor func cancellationStopsBeforeCheckpointAdvances() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService(segmentProgressStore: store)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        let note = VoiceNote(title: "Existing", audioFilePath: url.path)
        note.transcription = "Old complete transcript"
        var calls = 0
        transcriber.transcribeSegmentOutcome = { _ in
            calls += 1
            if calls == 2 {
                #expect(service.transcriptionPreview(for: note.id) == "new first")
                #expect(note.transcription == "Old complete transcript")
                service.cancelTranscription(for: note)
            }
            return .transcribed(.init(text: "new first", duration: 1, modelIdentifier: "m"))
        }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(calls == 2)
        let checkpoint = try #require(store.load(for: note.id))
        #expect(checkpoint.lastFrame == Int64(29 * 16_000))
        #expect(note.transcription == "Old complete transcript")
        #expect(note.transcriptionState == .queued)
        #expect(service.transcriptionPreview(for: note.id) == nil)
    }

    @Test @MainActor func unavailableSegmentRemainsResumableWithoutSkippedRange() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Import", audioFilePath: "")
        let copy = try store.importWorkingCopy(from: url, for: note.id)
        var calls = 0
        transcriber.transcribeSegmentOutcome = { _ in
            calls += 1
            return calls == 1 ? .transcribed(.init(text: "first", duration: 1, modelIdentifier: "m")) : .modelUnavailable
        }
        await transcriber.transcribe(note: note, sourceURL: copy)
        #expect(calls == 2)
        let checkpoint = try #require(store.load(for: note.id))
        #expect(checkpoint.lastFrame == Int64(29 * 16_000))
        #expect(store.load(for: note.id)?.failedRanges.isEmpty == true)
        #expect(store.existingWorkingCopyURL(for: note.id) != nil)
        #expect(note.transcriptionState == .queued)
    }

    @Test @MainActor func shortUnavailableImportKeepsWorkingCopyForResume() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Import", audioFilePath: "")
        let copy = try store.importWorkingCopy(from: url, for: note.id)
        transcriber.transcribeSegmentOutcome = { _ in .audioUnavailable }
        await transcriber.transcribe(note: note, sourceURL: copy)
        #expect(store.existingWorkingCopyURL(for: note.id) != nil)
        #expect(store.listPendingNoteIDs().contains(note.id))
        #expect(note.transcriptionState == .queued)
        transcriber.transcribeSegmentOutcome = { _ in .transcribed(.init(text: "recovered", duration: 1, modelIdentifier: "m")) }
        await transcriber.resumePending(notes: [note])
        #expect(note.transcription == "recovered")
        #expect(store.existingWorkingCopyURL(for: note.id) == nil)
    }

    @Test @MainActor func importRecoveryDoesNotDeleteRecordingCheckpoint() async {
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Recording", audioFilePath: "recording.caf")
        let checkpoint = SegmentedTranscriptionProgress(lastFrame: 100, totalFrames: 500,
            accumulatedText: "first", failedRanges: [], updatedAt: Date())
        store.save(checkpoint, for: note.id)
        await transcriber.resumePending(notes: [note])
        #expect(store.load(for: note.id) == checkpoint)
    }

    @Test @MainActor func partialFailedRetranscriptionPreservesCompleteOriginal() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 35)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Existing", audioFilePath: url.path)
        note.transcription = "Old complete transcript"
        var calls = 0
        transcriber.transcribeSegmentOutcome = { _ in
            calls += 1
            return calls == 1 ? .transcribed(.init(text: "new fragment", duration: 1, modelIdentifier: "m")) : .whisperError("failure")
        }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcription == "Old complete transcript")
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage != nil)
        let snapshots = store.listRetainedAttempts(for: note.id)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.text.contains("new fragment") == true)
        try store.resetProgressPreservingAttempt(for: note.id)
        #expect(note.transcription == "Old complete transcript")
        #expect(store.listRetainedAttempts(for: note.id) == snapshots)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "Successful replacement", duration: 1, modelIdentifier: "m"))
        }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(note.transcription.contains("Successful replacement"))
        #expect(store.load(for: note.id) == nil)
        #expect(store.listRetainedAttempts(for: note.id) == snapshots)
    }

    @Test @MainActor func failedAttemptArchiveErrorKeepsOriginalAndCheckpoint() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 35)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try Data([1]).write(to: store.directory.appendingPathComponent("retained-attempts"))
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Existing", audioFilePath: url.path)
        note.transcription = "Original text"
        var calls = 0
        transcriber.transcribeSegmentOutcome = { _ in
            calls += 1
            return calls == 1 ? .transcribed(.init(text: "New fragment", duration: 1, modelIdentifier: "m")) : .whisperError("failure")
        }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcription == "Original text")
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage?.contains("recovery checkpoint has been kept") == true)
        #expect(store.load(for: note.id)?.accumulatedText.contains("New fragment") == true)
        #expect(throws: (any Error).self) { try store.resetProgressPreservingAttempt(for: note.id) }
        #expect(store.load(for: note.id)?.accumulatedText.contains("New fragment") == true)
    }

    @Test @MainActor func discardedRunDoesNotWriteLateResult() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService(segmentProgressStore: store)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        let note = VoiceNote(title: "Deleted", audioFilePath: url.path)
        transcriber.transcribeSegmentOutcome = { _ in
            service.discardTranscription(for: note)
            return .transcribed(.init(text: "late text", duration: 1, modelIdentifier: "m"))
        }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcription.isEmpty)
        #expect(service.activeNoteID == nil)
        #expect(service.transcriptionPreview(for: note.id) == nil)
    }

    @Test @MainActor func userCancelledImportIsNotAutomaticallyResumed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 35)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService(segmentProgressStore: store)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        let note = VoiceNote(title: "Import", audioFilePath: "")
        let copy = try store.importWorkingCopy(from: url, for: note.id)
        var calls = 0
        transcriber.transcribeSegmentOutcome = { _ in
            calls += 1
            service.cancelTranscription(for: note)
            return .cancelled
        }
        await transcriber.transcribe(note: note, sourceURL: copy)
        #expect(calls == 1)
        #expect(note.transcriptionState == .queued)
        #expect(service.isUserPaused(noteID: note.id))
        #expect(store.existingWorkingCopyURL(for: note.id) != nil)
        await transcriber.resumePending(notes: [note])
        #expect(calls == 1)
        #expect(service.activeNoteID == nil)
        #expect(store.existingWorkingCopyURL(for: note.id) != nil)
    }

    @Test @MainActor func unreadableAudioPreservesTextButMarksAttemptFailed() async {
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Partial", audioFilePath: "missing.caf")
        note.transcription = "Previous partial text"
        await transcriber.transcribe(note: note, sourceURL: store.directory.appendingPathComponent("missing.caf"))
        #expect(note.transcription == "Previous partial text")
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage != nil)
    }

    @Test @MainActor func emptyRetranscriptionNeverConfirmsExistingPartialText() async throws {
        for seconds in [2.0, 35.0] {
            let outcomes: [TranscriptionOutcome] = [.noSpeech, .whisperError("decode failed")]
            for outcome in outcomes {
                let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: seconds)
                defer { try? FileManager.default.removeItem(at: url) }
                let store = SegmentedAudioTestSupport.makeStore()
                let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
                let note = VoiceNote(title: "Partial", audioFilePath: url.path)
                note.transcription = "Previous partial text"
                transcriber.transcribeSegmentOutcome = { _ in outcome }
                await transcriber.transcribe(note: note, sourceURL: url)
                #expect(note.transcription == "Previous partial text")
                #expect(note.transcriptionOutcome == .failed)
                #expect(note.transcriptionLastErrorMessage != nil)
            }
        }
    }

    @Test @MainActor func livePartialThenFailedRecoveryIsNeverMarkedTranscribed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = RecordingSessionTests.MockRecordingAudio()
        audio.currentPCMFileURL = url
        audio.startFilename = url.path
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService(segmentProgressStore: store)
        let session = RecordingSession(audioService: audio, transcriptionService: service)
        let collector = RecordingSessionTests.NoteCollector()
        session.onRecordingComplete = { collector.append($0) }
        let sequence = IncrementalTranscriptionCoordinatorTests.TranscriptSequence(["first slice"])
        session.coordinatorFactory = { source in
            let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: source)
            coordinator.transcribeOverride = { @Sendable _ in await sequence.next() }
            return coordinator
        }
        session.startRecording()
        let startDeadline = Date().addingTimeInterval(2)
        while session.currentRecordingNote == nil, Date() < startDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let note = try #require(collector.notes.first)
        audio.recordingDuration = 40
        audio.currentFramePosition = 40 * 16_000
        session.stopRecording()
        let stopDeadline = Date().addingTimeInterval(2)
        while note.transcriptionState != .queued || session.isRecording(note), Date() < stopDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(note.transcriptionState == .queued)
        #expect(!session.isRecording(note))
        #expect(note.transcription == "first slice")
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        transcriber.transcribeSegmentOutcome = { _ in .whisperError("recovery failed") }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcription == "first slice")
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage != nil)
    }

}
