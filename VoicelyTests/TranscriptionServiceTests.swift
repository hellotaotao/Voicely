//
//  TranscriptionServiceTests.swift
//  VoicelyTests
//
//  Created by Codex on 1/22/2026.
//

import Foundation
import Testing
@testable import Voicely

struct TranscriptionServiceTests {
    @Test func ordinaryRepeatedChecklistIsPreserved() {
        let text = "When recording starts, check the recording status. When recording pauses, check the recording timer. When recording resumes, check the recording timer again. When recording stops, check the recording file. When the recording file opens, check the beginning and the end of the recording."
        if case .text(let result) = TranscriptionService.validatedWhisperOutput(text) {
            #expect(result == text)
        } else {
            Issue.record("A normal checklist must not be rejected for repeated terminology")
        }
    }

    @Test func repeatedWhisperOutputIsNotAcceptedAsSuccess() {
        let text = "First segment. " + String(repeating: "Claude Code, ", count: 80)
        if case .whisperError = TranscriptionService.validatedWhisperOutput(text) {} else {
            Issue.record("Degenerate decoder output must not replace the transcript")
        }
    }

    @Test func repeatedUnicodeWhisperOutputIsNotAcceptedAsSuccess() {
        let text = "First segment. " + String(repeating: "ḕ", count: 80)
        if case .whisperError = TranscriptionService.validatedWhisperOutput(text) {} else {
            Issue.record("Repeated Unicode output must be rejected")
        }
    }

    @Test func ordinaryWhisperOutputIsPreserved() {
        let text = "The first meeting starts at three. The second meeting starts at four."
        if case .text(let result) = TranscriptionService.validatedWhisperOutput(text) {
            #expect(result == text)
        } else {
            Issue.record("Ordinary speech must be preserved")
        }
    }

    actor TranscriptionGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var armedContinuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                armedContinuation?.resume()
                armedContinuation = nil
            }
        }

        func waitUntilArmed() async {
            if continuation != nil {
                return
            }

            await withCheckedContinuation { continuation in
                armedContinuation = continuation
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    final class UnloadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { false }
    }

    final class ToggleableModelManager: ModelManager {
        var loaded = false

        override func isModelLoaded() -> Bool { loaded }

        func setLoaded(_ value: Bool) {
            loaded = value
            modelState = value ? .loaded : .unloaded
        }
    }

    @Test @MainActor func transcribeAudioReturnsResultWhenModelLoaded() async {
        let service = makeService(deviceID: "device-a")
        service.transcribeImpl = { _, progress in
            progress(0.2)
            return "hello"
        }

        let result = await service.transcribeAudio(filePath: "file.m4a")

        #expect(result?.text == "hello")
        #expect((result?.duration ?? -1) >= 0)
        #expect(result?.modelIdentifier == "openai_whisper-small")
        #expect(service.isTranscribing == false)
        #expect(service.transcriptionProgress == 0.0)
    }

    @Test @MainActor func transcribeAudioRemovesNoSpeechMarkerLines() async {
        let service = makeService(deviceID: "device-a")
        service.transcribeImpl = { _, _ in
            "hello\n[BLANK_AUDIO]\n(humming)"
        }

        let result = await service.transcribeAudio(filePath: "file.m4a")

        #expect(result?.text == "hello")
    }

    @Test @MainActor func transcribeAudioKeepsNonSpeechMarkersVerbatim() async {
        let service = makeService(deviceID: "device-a")
        service.transcribeImpl = { _, _ in
            "[Silence]\n[BLANK_AUDIO]\n(humming)"
        }

        let result = await service.transcribeAudio(filePath: "file.m4a")

        // 整段非语音:如实保留 Whisper 原文,不抹成单一 [BLANK_AUDIO]。
        #expect(result?.text == "[Silence]\n[BLANK_AUDIO]\n(humming)")
    }

    @Test @MainActor func transcribeAudioReturnsNilWhenModelNotLoaded() async {
        let service = TranscriptionService()
        service.setModelManager(UnloadedModelManager())
        service.transcribeImpl = { _, _ in "hello" }

        let result = await service.transcribeAudio(filePath: "file.m4a")

        #expect(result == nil)
        #expect(service.isTranscribing == false)
    }

    @Test @MainActor func cancelRequestedBeforeTranscribeReturnsNilAndMarksCancelled() async {
        let service = makeService(deviceID: "device-a")

        service.cancelTranscription()
        let result = await service.transcribeAudio(filePath: "file.m4a")

        #expect(result == nil)
        #expect(service.wasTranscriptionCancelled() == true)
    }

    @Test @MainActor func originDeviceClaimsQueuedNoteImmediately() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "origin", now: now)
        service.transcribeImpl = { _, _ in "Transcribed text" }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "origin"
        note.queueTranscription(at: now)

        await service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription == "Transcribed text")
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionModelIdentifier == "openai_whisper-small")
        #expect(service.activeNoteID == nil)
    }

    @Test @MainActor func nonOriginDeviceDoesNotClaimQueuedNoteBeforeGracePeriod() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "desktop", now: now)
        service.transcribeImpl = { _, _ in "Should not run" }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)

        await service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription.isEmpty)
        #expect(note.transcriptionState == .queued)
        #expect(note.transcriptionOwnerDeviceID == nil)
    }

    @Test @MainActor func nonOriginDeviceClaimsQueuedNoteAfterGracePeriod() async {
        let queuedAt = Date(timeIntervalSince1970: 10_000)
        let service = makeService(
            deviceID: "desktop",
            now: queuedAt.addingTimeInterval(301)
        )
        service.transcribeImpl = { _, _ in "Desktop result" }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: queuedAt)

        await service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription == "Desktop result")
        #expect(note.transcriptionState == .completed)
    }

    @Test @MainActor func foreignOwnerWithActiveLeaseIsSkipped() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "desktop", now: now)
        service.transcribeImpl = { _, _ in "Should not run" }

        let note = VoiceNote(title: "Claimed", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.claimTranscription(
            ownerDeviceID: "phone",
            attemptID: "attempt-a",
            queuedAt: now,
            leaseExpiresAt: now.addingTimeInterval(300)
        )

        await service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription.isEmpty)
        #expect(note.transcriptionState == .claimed)
        #expect(note.transcriptionOwnerDeviceID == "phone")
    }

    @Test @MainActor func expiredForeignLeaseIsTakenOver() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "desktop", now: now)
        service.transcribeImpl = { _, _ in "Desktop takeover" }

        let note = VoiceNote(title: "Claimed", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.claimTranscription(
            ownerDeviceID: "phone",
            attemptID: "attempt-a",
            queuedAt: now.addingTimeInterval(-600),
            leaseExpiresAt: now.addingTimeInterval(-1)
        )

        await service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription == "Desktop takeover")
        #expect(note.transcriptionState == .completed)
    }

    @Test @MainActor func explicitTakeOverClaimsActiveRemoteTranscription() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "desktop", now: now)
        service.transcribeImpl = { _, _ in "Manual takeover" }

        let note = VoiceNote(title: "Claimed", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.claimTranscription(
            ownerDeviceID: "phone",
            attemptID: "attempt-a",
            queuedAt: now,
            leaseExpiresAt: now.addingTimeInterval(300)
        )

        let didStart = await service.requestTranscription(for: note, takeOver: true)

        #expect(didStart == true)
        #expect(note.transcription == "Manual takeover")
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOwnerDeviceID == nil)
    }

    @Test @MainActor func requestTranscriptionUsesLatestModelManagerState() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = TranscriptionService()
        let modelManager = ToggleableModelManager()
        modelManager.selectedModel = "openai_whisper-small"
        modelManager.setLoaded(false)
        service.setModelManager(modelManager)
        service.deviceIDProvider = { "phone" }
        service.nowProvider = { now }
        service.transcribeImpl = { _, _ in "Queued result" }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)

        modelManager.setLoaded(true)
        let didStart = await service.requestTranscription(for: note)

        #expect(didStart == true)
        #expect(note.transcription == "Queued result")
        #expect(note.transcriptionState == .completed)
    }

    @Test @MainActor func successfulTranscriptionPersistsTelemetrySummaryOnNote() async {
        var now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        service.nowProvider = { now }
        service.audioDurationProvider = { _ in 20 }
        service.transcribeImpl = { _, _ in
            now = now.addingTimeInterval(5)
            return "Telemetry result"
        }

        let note = VoiceNote(title: "Telemetry", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)

        let didStart = await service.requestTranscription(for: note)

        #expect(didStart == true)
        #expect(note.transcription == "Telemetry result")
        #expect(note.transcriptionTelemetrySampleCount == 1)
        #expect(note.averageProcessingTimeRatioLabel == "25% avg")
        #expect(note.averageTranscriptionSpeedLabel == "4.0× avg")
        #expect(note.transcriptionComputeBadgeLabel == "NPU")
    }

    @Test @MainActor func blankWhisperOutputRetriesThenMarksFailedAndClearsMetadata() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        var attempts = 0
        service.transcribeImpl = { _, _ in
            attempts += 1
            return "   \n"  // Whisper ran but produced nothing usable → a real error
        }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.lastTranscriptionDuration = 21.7
        note.transcriptionModelIdentifier = "openai_whisper-large-v3-turbo"
        note.queueTranscription(at: now)

        let didStart = await service.requestTranscription(for: note)

        #expect(didStart == true)
        #expect(attempts == 2)  // first try + one automatic retry
        #expect(note.transcription.isEmpty)
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.pendingTranscription == false)
        #expect(note.lastTranscriptionDuration == 0)
        #expect(note.transcriptionModelIdentifier == nil)
        // Real diagnostic is kept internally for us to investigate — not shown to the user.
        #expect(note.transcriptionLastErrorMessage == "blank output")
    }

    @Test @MainActor func realErrorRecoversOnAutomaticRetry() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        var attempts = 0
        service.transcribeImpl = { _, _ in
            attempts += 1
            return attempts == 1 ? .whisperError("transient") : .text("recovered")
        }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)

        let didStart = await service.requestTranscription(for: note)

        #expect(didStart == true)
        #expect(attempts == 2)
        #expect(note.transcription == "recovered")
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(note.transcriptionLastErrorMessage == nil)
    }

    @Test @MainActor func noSpeechCompletesNoteAsNoSpeechWithoutError() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        service.transcribeImpl = { _, _ in .noSpeech }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)

        let didStart = await service.requestTranscription(for: note)

        #expect(didStart == true)
        #expect(note.transcription.isEmpty)
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .noSpeech)
        #expect(note.pendingTranscription == false)
        #expect(note.isTranscribing == false)
        // No speech is a normal outcome, not an error.
        #expect(note.transcriptionLastErrorMessage == nil)
    }

    @Test @MainActor func failedSinglePassRecoveryKeepsPartialTextWithoutSuccessStatus() async {
        let outcomes: [RawTranscription] = [.noSpeech, .whisperError("recovery failed")]
        for outcome in outcomes {
            let service = makeService(deviceID: "phone")
            let note = VoiceNote(title: "Partial", audioFilePath: "partial.caf")
            note.transcription = "Previous partial text"
            note.transcriptionOriginDeviceID = "phone"
            note.queueTranscription(at: Date())
            service.transcribeImpl = { _, _ in outcome }
            await service.processPendingTranscriptions(notes: [note])
            #expect(note.transcription == "Previous partial text")
            #expect(note.transcriptionOutcome == .failed)
            #expect(note.transcriptionLastErrorMessage != nil)
        }
    }

    @Test @MainActor func failedImportKeepsAudioUntilExplicitRetrySucceeds() async throws {
        let service = makeService(deviceID: "phone")
        let note = VoiceNote(title: "Import", audioFilePath: "")
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = service.segmentProgressStore
        _ = try store.importWorkingCopy(from: url, for: note.id)
        service.transcribeImpl = { _, _ in .whisperError("failed import") }
        #expect(await service.requestTranscription(for: note))
        #expect(note.transcriptionOutcome == .failed)
        #expect(store.existingWorkingCopyURL(for: note.id) != nil)
        var calls = 0
        service.transcribeImpl = { _, _ in calls += 1; return "Recovered import" }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        await transcriber.resumePending(notes: [note])
        #expect(calls == 0)
        // A terminal checkpoint must not let explicit retry skip failed ranges.
        store.save(.init(lastFrame: 32_000, totalFrames: 32_000, accumulatedText: "old failed fragment",
            failedRanges: [.init(startFrame: 0, endFrame: 32_000)], updatedAt: Date()), for: note.id)
        #expect(await service.requestTranscription(for: note))
        #expect(calls == 1)
        #expect(note.transcription == "Recovered import")
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(store.existingWorkingCopyURL(for: note.id) == nil)
        #expect(store.load(for: note.id) == nil)
    }

    @Test @MainActor func modelUnavailableKeepsNoteQueuedWithoutFailure() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        service.transcribeImpl = { _, _ in .modelUnavailable }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)

        let didStart = await service.requestTranscription(for: note)

        #expect(didStart == true)
        // Model not ready yet: not a failure — requeue and wait for it to load.
        #expect(note.transcriptionState == .queued)
        #expect(note.pendingTranscription == true)
        #expect(note.transcriptionOutcome == nil)
        #expect(note.transcriptionLastErrorMessage == nil)
    }


    @Test @MainActor func nonSpeechOnlyTranscriptionCompletesAsBlankAudio() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        service.transcribeImpl = { _, _ in "[BLANK_AUDIO]" }

        let note = VoiceNote(title: "Blank", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.transcription = "[BLANK_AUDIO]"
        note.queueTranscription(at: now)

        let didStart = await service.requestTranscription(for: note)

        #expect(didStart == true)
        #expect(note.transcription == "[BLANK_AUDIO]")
        #expect(note.transcriptionState == .completed)
        #expect(note.pendingTranscription == false)
        #expect(note.isTranscribing == false)
        #expect(note.transcriptionLastErrorMessage == nil)
    }

    @Test @MainActor func staleAttemptDoesNotOverwriteCurrentOwner() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        let gate = TranscriptionGate()
        service.transcribeImpl = { _, _ in
            await gate.wait()
            return "stale result"
        }

        let note = VoiceNote(title: "Claimed", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.claimTranscription(
            ownerDeviceID: "phone",
            attemptID: "attempt-a",
            queuedAt: now,
            leaseExpiresAt: now.addingTimeInterval(300)
        )

        let task = Task {
            await service.processPendingTranscriptions(notes: [note])
        }

        while service.activeNoteID != note.id {
            await Task.yield()
        }
        await gate.waitUntilArmed()

        note.claimTranscription(
            ownerDeviceID: "desktop",
            attemptID: "attempt-b",
            queuedAt: now,
            leaseExpiresAt: now.addingTimeInterval(300)
        )

        await gate.resume()
        await task.value

        #expect(note.transcription.isEmpty)
        #expect(note.transcriptionState == .claimed)
        #expect(note.transcriptionOwnerDeviceID == "desktop")
        #expect(note.transcriptionAttemptID == "attempt-b")
    }

    @Test @MainActor func cancellationRequeuesNoteAndClearsOwner() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        let gate = TranscriptionGate()
        service.transcribeImpl = { _, _ in
            await gate.wait()
            return "should not finish"
        }

        let note = VoiceNote(title: "Queued", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)

        let task = Task {
            await service.processPendingTranscriptions(notes: [note])
        }

        while service.activeNoteID != note.id {
            await Task.yield()
        }
        await gate.waitUntilArmed()

        service.cancelTranscription(for: note)
        await gate.resume()
        await task.value

        #expect(note.transcriptionState == .queued)
        #expect(note.pendingTranscription == true)
        #expect(note.transcriptionOwnerDeviceID == nil)
        #expect(note.transcriptionAttemptID == nil)
        #expect(note.transcriptionLeaseExpiresAt == nil)
        #expect(note.transcriptionLastErrorMessage == nil)
    }

    @Test @MainActor func queuedNoteAddedDuringActiveProcessingIsDrainedBySameLoop() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        let gate = TranscriptionGate()
        service.transcribeImpl = { filePath, _ in
            if filePath == "first.m4a" {
                await gate.wait()
                return "first result"
            }
            return "second result"
        }

        let firstNote = VoiceNote(title: "First", audioFilePath: "first.m4a")
        firstNote.transcriptionOriginDeviceID = "phone"
        firstNote.queueTranscription(at: now)

        let secondNote = VoiceNote(title: "Second", audioFilePath: "second.m4a")
        secondNote.transcriptionOriginDeviceID = "phone"
        secondNote.queueTranscription(at: now)

        let processingTask = Task {
            await service.processPendingTranscriptions(notes: [firstNote])
        }

        while service.activeNoteID != firstNote.id {
            await Task.yield()
        }
        await gate.waitUntilArmed()

        let didStart = await service.requestTranscription(for: secondNote)
        #expect(didStart == true)
        #expect(secondNote.transcriptionState == .claimed)

        await gate.resume()
        await processingTask.value

        #expect(firstNote.transcription == "first result")
        #expect(firstNote.transcriptionState == .completed)
        #expect(secondNote.transcription == "second result")
        #expect(secondNote.transcriptionState == .completed)
    }

    @Test @MainActor func pendingQueueWaitsForExternalOwnerInsteadOfSkippingNote() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        let externalID = UUID()
        service.beginExternalTranscription(noteID: externalID)
        let note = VoiceNote(title: "Queued", audioFilePath: "queued.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.queueTranscription(at: now)
        var calls = 0
        service.transcribeImpl = { _, _ in
            calls += 1
            #expect(service.activeNoteID == note.id)
            return "Queued result"
        }
        var entered = false
        var returned = false
        let processing = Task { @MainActor in
            entered = true
            await service.processPendingTranscriptions(notes: [note])
            returned = true
        }
        while !entered { await Task.yield() }
        await Task.yield()
        #expect(calls == 0)
        #expect(!returned)
        #expect(service.activeNoteID == externalID)
        service.endExternalTranscription(noteID: externalID)
        await processing.value
        #expect(returned)
        #expect(calls == 1)
        #expect(note.transcription == "Queued result")
        #expect(note.transcriptionState == .completed)
    }

    @Test @MainActor func ownedClaimedNoteResumesOnCurrentDevice() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        service.transcribeImpl = { _, _ in "Recovered result" }

        let note = VoiceNote(title: "Claimed", audioFilePath: "file.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.claimTranscription(
            ownerDeviceID: "phone",
            attemptID: "attempt-a",
            queuedAt: now,
            leaseExpiresAt: now.addingTimeInterval(300)
        )

        await service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription == "Recovered result")
        #expect(note.transcriptionState == .completed)
    }

    @Test @MainActor func migrationRequeuesInterruptedLiveRecordingWithPartialTranscript() {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)

        let note = VoiceNote(title: "Interrupted", audioFilePath: "recording.m4a")
        note.transcriptionOriginDeviceID = "phone"
        note.transcription = "Partial live transcript"
        note.claimTranscription(
            ownerDeviceID: "phone",
            attemptID: "live-attempt",
            queuedAt: now.addingTimeInterval(-60),
            leaseExpiresAt: now.addingTimeInterval(240)
        )
        note.isTranscribing = true
        note.transcriptionProgress = 0.64

        service.migrateLegacyOwnershipIfNeeded(notes: [note])

        #expect(note.transcription == "Partial live transcript")
        #expect(note.transcriptionState == .queued)
        #expect(note.isTranscribing == false)
        #expect(note.pendingTranscription == true)
        #expect(note.transcriptionProgress == 0.0)
        #expect(note.transcriptionOwnerDeviceID == nil)
        #expect(note.transcriptionAttemptID == nil)
        #expect(note.transcriptionLeaseExpiresAt == nil)
    }

    @Test @MainActor func liveRecordingAndFinalizationAreExcludedFromQueueAndRecovery() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        let note = VoiceNote(title: "Live", audioFilePath: "live.caf")
        note.transcriptionOriginDeviceID = "phone"
        note.claimTranscription(ownerDeviceID: "phone", attemptID: "live",
            queuedAt: now, leaseExpiresAt: now.addingTimeInterval(300))
        note.isTranscribing = true
        service.beginLocalRecording(noteID: note.id)
        var calls = 0
        service.transcribeImpl = { _, _ in calls += 1; return "unexpected" }
        await service.processPendingTranscriptions(notes: [note])
        #expect(calls == 0)
        #expect(note.transcriptionAttemptID == "live")
        #expect(note.isTranscribing)
        #expect(await service.requestTranscription(for: note, force: true) == false)
        service.endLocalRecording(noteID: note.id)
        service.migrateLegacyOwnershipIfNeeded(notes: [note])
        #expect(note.transcriptionState == .queued)
    }

    @Test @MainActor func cancelledImportCanBeExplicitlyResumedFromWorkingCopy() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)
        let note = VoiceNote(title: "Import", audioFilePath: "")
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try service.segmentProgressStore.importWorkingCopy(from: url, for: note.id)
        service.beginExternalTranscription(noteID: note.id)
        service.cancelTranscription(for: note)
        service.endExternalTranscription(noteID: note.id)
        #expect(service.isUserPaused(noteID: note.id))
        service.transcribeImpl = { _, _ in "Recovered import" }
        let accepted = await service.requestTranscription(for: note)
        #expect(accepted)
        #expect(!service.isUserPaused(noteID: note.id))
        #expect(note.transcription == "Recovered import")
        #expect(note.transcriptionState == .completed)
        #expect(service.segmentProgressStore.existingWorkingCopyURL(for: note.id) == nil)
    }

    @Test @MainActor func migrationNormalizesLegacyFlags() {
        let now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(deviceID: "phone", now: now)

        let queuedNote = VoiceNote(title: "Legacy queued", audioFilePath: "file.m4a")
        queuedNote.pendingTranscription = true
        queuedNote.isTranscribing = true

        let completedNote = VoiceNote(title: "Legacy complete", audioFilePath: "file.m4a")
        completedNote.transcription = "done"

        service.migrateLegacyOwnershipIfNeeded(notes: [queuedNote, completedNote])

        #expect(queuedNote.transcriptionState == .queued)
        #expect(completedNote.transcriptionState == .completed)
        #expect(queuedNote.pendingTranscription == false)
        #expect(queuedNote.isTranscribing == false)
    }

    @Test @MainActor func annotatedTextUsesHeaderAndBody() {
        let service = makeService(deviceID: "device-a")
        let formatted = service.formatTranscriptionDuration(1.2)

        let withBody = service.annotatedText(text: "Hello", duration: 1.2)
        #expect(withBody == "Transcription completed in \(formatted).\n\nHello")

        let withoutBody = service.annotatedText(text: "", duration: 1.2)
        #expect(withoutBody == "Transcription completed in \(formatted).")
    }

    @Test @MainActor func formatTranscriptionDurationFormatsShortDurations() {
        let service = makeService(deviceID: "device-a")
        #expect(service.formatTranscriptionDuration(0.4) == "0.40 seconds")
        #expect(service.formatTranscriptionDuration(12.3) == "12.30 seconds")
    }

    @Test @MainActor func engineStatusMessagesReflectAvailability() {
        let service = TranscriptionService()

        service.setModelManager(UnloadedModelManager())
        #expect(service.getCurrentEngineDescription() == "No transcription available")
        #expect(service.getEngineStatusMessage() == "WhisperKit not loaded. Please load a model first.")

        service.setModelManager(LoadedModelManager())
        #expect(service.getCurrentEngineDescription() == "WhisperKit (Local AI)")
        #expect(service.getEngineStatusMessage() == "Using WhisperKit for high-quality offline transcription")
    }

    @Test @MainActor func serviceOwnsSegmentProgressStore() {
        let service = makeService(deviceID: "d")
        _ = service.segmentProgressStore
    }

    @Test @MainActor func shouldSegmentLongRecordingsWithAudio() {
        let service = makeService(deviceID: "d")
        let long = VoiceNote(title: "a", audioFilePath: "a.m4a"); long.duration = 1800
        let short = VoiceNote(title: "b", audioFilePath: "b.m4a"); short.duration = 12
        let noAudio = VoiceNote(title: "c", audioFilePath: ""); noAudio.duration = 1800
        #expect(service.shouldSegmentTranscription(long))
        #expect(!service.shouldSegmentTranscription(short))
        #expect(!service.shouldSegmentTranscription(noAudio))
    }

    @Test @MainActor func permanentlyMissingAudioStopsAutomaticRetries() async {
        for duration in [12.0, 1800.0] {
            let service = makeService(deviceID: "local")
            var attempts = 0
            service.prepareAudioFileForReading = { _ in attempts += 1; return nil }
            service.transcribeImpl = { _, _ in attempts += 1; return .audioUnavailable }
            service.isAudioPermanentlyMissing = { _ in true }
            let note = VoiceNote(title: "Missing", audioFilePath: "missing.m4a")
            note.duration = duration
            note.transcription = "Keep existing text"
            note.transcriptionOriginDeviceID = "local"
            note.queueTranscription(at: Date())

            await service.processPendingTranscriptions(notes: [note])
            await service.processPendingTranscriptions(notes: [note])

            #expect(attempts == 1)
            #expect(note.transcriptionState == .completed)
            #expect(note.transcriptionOutcome == .failed)
            #expect(note.transcription == "Keep existing text")
        }
    }

    @Test @MainActor func temporarilyUnavailableAudioStaysQueued() async {
        for duration in [12.0, 1800.0] {
            let service = makeService(deviceID: "local")
            var attempts = 0
            service.prepareAudioFileForReading = { _ in attempts += 1; return nil }
            service.transcribeImpl = { _, _ in attempts += 1; return .audioUnavailable }
            service.isAudioPermanentlyMissing = { _ in false }
            let note = VoiceNote(title: "Downloading", audioFilePath: "cloud.m4a")
            note.duration = duration
            note.transcriptionOriginDeviceID = "local"
            note.queueTranscription(at: Date())

            await service.processPendingTranscriptions(notes: [note])
            #expect(note.transcriptionState == .queued)
            await service.processPendingTranscriptions(notes: [note])
            #expect(note.transcriptionState == .queued)
            #expect(attempts == 2)
        }
    }

    @Test @MainActor func explicitRetryRefreshesExpiredAudioAvailabilityWindow() async {
        for duration in [12.0, 1800.0] {
            for takeOver in [false, true] {
                let now = Date(timeIntervalSince1970: 20_000)
                let service = makeService(deviceID: "local", now: now)
                service.prepareAudioFileForReading = { _ in nil }
                service.transcribeImpl = { _, _ in .audioUnavailable }
                service.isAudioPermanentlyMissing = { _ in false }
                let note = VoiceNote(title: "Retry", audioFilePath: "cloud.m4a")
                note.duration = duration
                note.transcription = "Keep existing text"
                note.transcriptionOriginDeviceID = "local"
                let oldQueueTime = now.addingTimeInterval(-service.audioAvailabilityRetryWindow - 60)
                if takeOver {
                    note.claimTranscription(ownerDeviceID: "remote", attemptID: "previous",
                        queuedAt: oldQueueTime, leaseExpiresAt: now.addingTimeInterval(300))
                } else {
                    note.queueTranscription(at: oldQueueTime)
                    note.completeTranscription()
                }

                let accepted = await service.requestTranscription(for: note, force: !takeOver, takeOver: takeOver)

                #expect(accepted)
                #expect(note.transcriptionState == .queued)
                #expect(note.transcriptionQueuedAt == now)
                #expect(note.transcriptionOutcome != .failed)
                #expect(note.transcription == "Keep existing text")
            }
        }
    }

    @Test @MainActor func unknownCloudAudioStopsRetryingAfterPersistedWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CloudStorageManager(testLocalContainerURL: local,
                                         testCloudContainerURL: cloud, testCloudEnabled: true)
        #expect(!storage.isAudioPermanentlyMissing(at: "recording.m4a"))
        for duration in [12.0, 1800.0] {
            let start = Date(timeIntervalSince1970: 10_000)
            var now = start
            let service = makeService(deviceID: "local", now: start)
            service.nowProvider = { now }
            var attempts = 0
            service.prepareAudioFileForReading = { _ in attempts += 1; return nil }
            service.transcribeImpl = { _, _ in attempts += 1; return .audioUnavailable }
            service.isAudioPermanentlyMissing = { storage.isAudioPermanentlyMissing(at: $0) }
            let note = VoiceNote(title: "Unavailable", audioFilePath: "recording.m4a")
            note.duration = duration
            note.transcription = "Keep existing text"
            note.transcriptionOriginDeviceID = "local"
            note.queueTranscription(at: start)

            await service.processPendingTranscriptions(notes: [note])
            #expect(note.transcriptionState == .queued)
            #expect(note.transcriptionQueuedAt == start)
            now = start.addingTimeInterval(service.audioAvailabilityRetryWindow - 1)
            await service.processPendingTranscriptions(notes: [note])
            #expect(note.transcriptionState == .queued)
            #expect(note.transcriptionQueuedAt == start)
            now = start.addingTimeInterval(service.audioAvailabilityRetryWindow)
            await service.processPendingTranscriptions(notes: [note])
            #expect(note.transcriptionState == .completed)
            #expect(note.transcriptionOutcome == .failed)
            #expect(note.transcriptionLastErrorMessage == "Audio is still unavailable. Automatic retries stopped. Check iCloud and retry.")
            #expect(note.transcription == "Keep existing text")
            await service.processPendingTranscriptions(notes: [note])
            #expect(attempts == 3)

            now = start.addingTimeInterval(service.audioAvailabilityRetryWindow + 60)
            let manualRetryTime = now
            let didRetry = await service.requestTranscription(for: note)
            #expect(didRetry)
            #expect(note.transcriptionState == .queued)
            #expect(note.transcriptionQueuedAt == manualRetryTime)
            #expect(attempts == 4)
            now = manualRetryTime.addingTimeInterval(1)
            await service.processPendingTranscriptions(notes: [note])
            #expect(note.transcriptionState == .queued)
            #expect(note.transcriptionQueuedAt == manualRetryTime)
            #expect(attempts == 5)
        }
    }

    @MainActor
    private func makeService(deviceID: String, now: Date = Date()) -> TranscriptionService {
        let service = TranscriptionService()
        let modelManager = LoadedModelManager()
        modelManager.selectedModel = "openai_whisper-small"
        service.setModelManager(modelManager)
        service.deviceIDProvider = { deviceID }
        service.nowProvider = { now }
        service.heartbeatInterval = 3600
        return service
    }
}
