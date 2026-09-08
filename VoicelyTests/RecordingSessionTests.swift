//
//  RecordingSessionTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
import UIKit
@testable import Voicely

@MainActor
struct RecordingSessionTests {

    @Test func finalizationBackgroundBudgetEndsOnceOnCompletion() {
        let taskID = UIBackgroundTaskIdentifier(rawValue: 42)
        var ended: [UIBackgroundTaskIdentifier] = []
        let budget = RecordingFinalizationBackgroundTask(
            begin: { _ in taskID }, end: { ended.append($0) })

        budget.end()
        budget.end()

        #expect(ended == [taskID])
    }

    @Test func finalizationBackgroundBudgetEndsOnceOnExpiration() async {
        let taskID = UIBackgroundTaskIdentifier(rawValue: 43)
        var expiration: (@Sendable () -> Void)?
        var ended: [UIBackgroundTaskIdentifier] = []
        let budget = RecordingFinalizationBackgroundTask(
            begin: { expiration = $0; return taskID }, end: { ended.append($0) })

        expiration?()
        for _ in 0..<100 where ended.isEmpty { await Task.yield() }
        #expect(ended == [taskID])
        budget.end()
        #expect(ended == [taskID])
    }

    @Test func invalidFinalizationBackgroundBudgetIsNotEnded() {
        var endCount = 0
        let budget = RecordingFinalizationBackgroundTask(
            begin: { _ in .invalid }, end: { _ in endCount += 1 })

        budget.end()

        #expect(endCount == 0)
    }

    /// Stand-in recorder so the session's control flow can run without a real
    /// `AVAudioEngine`. Mirrors the public surface `RecordingSession` relies on.
    final class MockRecordingAudio: RecordingAudioControlling {
        var isRecording = false
        var isPaused = false
        var recordingDuration: TimeInterval = 0
        var hasPermission = true
        var currentPCMFileURL: URL?
        var currentFramePosition: AVAudioFramePosition = 0

        var stopResultOverride: RecordingStopResult?
        var startFilename: String? = "recording.m4a"
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func startRecording() -> String? {
            startCount += 1
            isRecording = true
            isPaused = false
            return startFilename
        }

        func stopRecording() -> RecordingStopResult {
            stopCount += 1
            let filename = isRecording ? startFilename : nil
            isRecording = false
            isPaused = false
            return stopResultOverride ?? RecordingStopResult(filePath: filename, duration: recordingDuration)
        }

        func pauseRecording() { isPaused = true }

        @discardableResult
        func resumeRecording() -> Bool {
            isPaused = false
            return true
        }
    }

    final class NoteCollector {
        private(set) var notes: [VoiceNote] = []
        var count: Int { notes.count }
        func append(_ note: VoiceNote) { notes.append(note) }
    }

    private func makeSession() -> (RecordingSession, MockRecordingAudio, NoteCollector) {
        let audio = MockRecordingAudio()
        audio.currentPCMFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely_test_\(UUID().uuidString).caf")
        // No model manager set → isModelLoaded == false, so finalize takes the
        // "queue for later" branch and never kicks off real transcription work.
        let transcription = TranscriptionService()
        let session = RecordingSession(audioService: audio, transcriptionService: transcription)
        let collector = NoteCollector()
        session.onRecordingComplete = { collector.append($0) }
        return (session, audio, collector)
    }

    @Test func defensiveStopNoteHasLocalOriginAndIsImmediatelyEligible() async {
        let audio = MockRecordingAudio()
        audio.isRecording = true
        audio.recordingDuration = 8
        let transcription = TranscriptionService()
        transcription.deviceIDProvider = { "local" }
        let session = RecordingSession(audioService: audio, transcriptionService: transcription)
        let collector = NoteCollector()
        session.onRecordingComplete = { collector.append($0) }

        session.stopDueToInterruption()
        for _ in 0..<100 where collector.notes.first?.transcriptionState != .queued {
            await Task.yield()
        }

        #expect(collector.count == 1)
        guard let note = collector.notes.first else { return }
        #expect(note.transcriptionOriginDeviceID == "local")
        #expect(note.transcriptionState == .queued)
        transcription.setModelManager(TranscriptionServiceTests.LoadedModelManager())
        var attempts = 0
        transcription.transcribeImpl = { _, _ in attempts += 1; return "Recovered" }
        await transcription.processPendingTranscriptions(notes: [note])
        #expect(attempts == 1)
        #expect(note.transcription == "Recovered")
    }

    @Test func fallbackPathIsPublishedAndDeletionBlockedWhileFinalFlushWaits() async throws {
        let (session, audio, collector) = makeSession()
        let pcmURL = try IncrementalTranscriptionCoordinatorTests().makeSilentCAF(seconds: 5)
        let destination = pcmURL.deletingPathExtension().appendingPathExtension("m4a")
        // Use a distinct durable CAF path so the source remains a final-flush input.
        let output = destination.deletingLastPathComponent()
            .appendingPathComponent("durable_\(UUID().uuidString).m4a")
        let fallback = output.deletingPathExtension().appendingPathExtension("caf")
        defer {
            try? FileManager.default.removeItem(at: pcmURL)
            try? FileManager.default.removeItem(at: fallback)
        }
        audio.currentPCMFileURL = pcmURL
        let gate = TranscriptionServiceTests.TranscriptionGate()
        session.coordinatorFactory = { url in
            let coordinator = IncrementalTranscriptionCoordinator(
                transcriptionService: TranscriptionService(), recordingFileURL: url)
            coordinator.transcribeOverride = { @Sendable _ in
                await gate.wait()
                return "finished tail"
            }
            return coordinator
        }
        session.startRecording()
        try await waitUntil { session.currentRecordingNote != nil }
        let note = try #require(collector.notes.first)
        audio.recordingDuration = 5
        audio.currentFramePosition = 5 * 16_000
        audio.stopResultOverride = .converting(
            sourceURL: pcmURL, destinationURL: output, duration: 5
        ) { _, _ in throw CocoaError(.fileWriteUnknown) }
        session.stopRecording()
        #expect(session.isRecording(note))
        #expect(session.isPreparingAudio(note))
        #expect(note.audioFilePath == output.lastPathComponent)
        await gate.waitUntilArmed()
        try await waitUntil { note.audioFilePath == fallback.lastPathComponent }
        #expect(note.audioFilePath == fallback.lastPathComponent)
        #expect(!session.isPreparingAudio(note))
        #expect(session.isRecording(note))
        #expect(FileManager.default.fileExists(atPath: pcmURL.path))
        await gate.resume()
        try await waitUntil { !session.isRecording(note) }
        #expect(!session.isRecording(note))
        #expect(!FileManager.default.fileExists(atPath: pcmURL.path))
        #expect(FileManager.default.fileExists(atPath: fallback.path))
    }

    @Test func failedLiveTailQueuesRecoveryInsteadOfCompletingPartialText() async throws {
        let (session, audio, collector) = makeSession()
        let pcmURL = try IncrementalTranscriptionCoordinatorTests().makeSilentCAF(seconds: 40)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        audio.currentPCMFileURL = pcmURL
        let sequence = IncrementalTranscriptionCoordinatorTests.TranscriptSequence(["first slice"])
        session.coordinatorFactory = { url in
            let coordinator = IncrementalTranscriptionCoordinator(
                transcriptionService: TranscriptionService(), recordingFileURL: url)
            coordinator.transcribeOverride = { @Sendable _ in await sequence.next() }
            return coordinator
        }
        session.startRecording()
        try await waitUntil { session.currentRecordingNote != nil }
        let note = collector.notes.first
        audio.recordingDuration = 40
        audio.currentFramePosition = 40 * 16_000

        session.stopRecording()
        try await waitUntil { note?.transcriptionState == .queued }

        #expect(note?.transcription == "first slice")
        #expect(note?.transcriptionState == .queued)
        #expect(note?.pendingTranscription == true)
    }

    @Test func missingStopAssetDoesNotLeaveNoteTranscribing() async throws {
        let (session, audio, collector) = makeSession()
        session.startRecording()
        try await waitUntil { session.currentRecordingNote != nil }
        let note = try #require(collector.notes.first)
        audio.recordingDuration = 2
        audio.stopResultOverride = RecordingStopResult(filePath: nil, duration: 2)
        session.stopRecording()
        #expect(!note.isTranscribing)
        #expect(note.transcriptionOutcome == .failed)
        #expect(!session.isRecording(note))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        // Hosted parallel suites can delay MainActor startup beyond two seconds.
        // Fail at the unmet prerequisite rather than continuing with a nil note.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            try #require(clock.now < deadline, "Timed out waiting for recording session state")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Regression test for the rotation bug: a normal start → stop must reuse the
    /// single in-progress note, attach the audio to it, and never spawn a second
    /// note for the same recording.
    @Test func stoppingReusesTheInProgressNote() async throws {
        let (session, audio, collector) = makeSession()

        session.startRecording()
        try await waitUntil { session.currentRecordingNote != nil }

        #expect(session.currentRecordingNote != nil)
        #expect(collector.count == 1)
        let recordingNote = session.currentRecordingNote

        // Enough elapsed time to clear the accidental-stop guard.
        audio.recordingDuration = 2
        audio.currentFramePosition = 0

        session.stopRecording()
        try await waitUntil { session.currentRecordingNote == nil }

        #expect(collector.count == 1)
        #expect(audio.stopCount == 1)
        #expect(collector.notes.first === recordingNote)
        #expect(recordingNote?.audioFilePath == "recording.m4a")
        #expect(recordingNote?.duration == 2)
    }

    /// A system interruption must finalize the in-progress note in place, exactly
    /// like a manual stop — not create a duplicate.
    @Test func interruptionFinalizesInProgressNote() async throws {
        let (session, audio, collector) = makeSession()

        session.startRecording()
        try await waitUntil { session.currentRecordingNote != nil }
        let note = session.currentRecordingNote
        audio.recordingDuration = 5

        session.stopDueToInterruption()
        try await waitUntil { session.currentRecordingNote == nil }

        #expect(collector.count == 1)
        #expect(collector.notes.first === note)
        #expect(note?.audioFilePath == "recording.m4a")
    }

    /// The accidental-stop guard still applies: an immediate stop on a fresh
    /// recording is ignored, leaving the session recording.
    @Test func immediateStopIsIgnoredOnFreshRecording() async throws {
        let (session, audio, _) = makeSession()

        session.startRecording()
        try await waitUntil { session.currentRecordingNote != nil }

        // recordingDuration stays at 0 → within the accidental-stop window.
        session.stopRecording()

        #expect(session.currentRecordingNote != nil)
        #expect(audio.stopCount == 0)
    }
}
