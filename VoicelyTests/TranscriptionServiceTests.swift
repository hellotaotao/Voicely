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
        #expect(note.transcriptionOwnerDeviceID == nil)
        #expect(note.transcriptionAttemptID == nil)
        #expect(note.transcriptionLeaseExpiresAt == nil)
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
