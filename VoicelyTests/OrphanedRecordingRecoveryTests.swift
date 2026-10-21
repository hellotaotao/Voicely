//
//  OrphanedRecordingRecoveryTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// An app killed while recording never runs stop: the note has no duration and
/// no `.m4a`, and without recovery it stays "Queued" on every device.
@MainActor
struct OrphanedRecordingRecoveryTests {

    private let thisDevice = "this-device"

    /// A tmp directory and an audio directory, isolated per test.
    @MainActor
    private final class Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan_recovery_\(UUID().uuidString)", isDirectory: true)
        var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
        var audio: URL { root.appendingPathComponent("audio", isDirectory: true) }

        init() throws {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var storage: OrphanedRecordingStorage {
            var storage = OrphanedRecordingStorage.live
            storage.temporaryDirectory = { [tmp] in tmp }
            storage.isAudioAbsent = { [audio] path in
                !FileManager.default.fileExists(atPath: audio.appendingPathComponent(path).path)
            }
            storage.destinationURL = { [audio] name in audio.appendingPathComponent(name) }
            return storage
        }

        /// Writes the live PCM file a recording started at `start` would leave behind.
        func orphanedPCM(startedAt start: TimeInterval, seconds: Double) throws -> URL {
            let source = try IncrementalTranscriptionCoordinatorTests().makeSilentCAF(seconds: seconds)
            let url = tmp.appendingPathComponent(
                "\(AudioRecordingService.pcmTemporaryFilePrefix)\(Int(start))_\(UUID().uuidString).caf")
            try FileManager.default.moveItem(at: source, to: url)
            return url
        }
    }

    private func makeSession(_ sandbox: Sandbox, audio: RecordingSessionTests.MockRecordingAudio? = nil)
        -> (RecordingSession, TranscriptionService) {
        // No model manager: recovered notes are queued, never transcribed here.
        let transcription = TranscriptionService()
        transcription.deviceIDProvider = { [thisDevice] in thisDevice }
        let session = RecordingSession(audioService: audio ?? RecordingSessionTests.MockRecordingAudio(),
                                       transcriptionService: transcription)
        session.orphanedRecordingStorage = sandbox.storage
        return (session, transcription)
    }

    /// A note as left by a recording that started at `start` and was never stopped.
    private func interruptedNote(startedAt start: TimeInterval, origin: String?) -> VoiceNote {
        let note = VoiceNote(title: "Voice Note 11:16 am", audioFilePath: "recording_\(start).m4a")
        note.transcriptionOriginDeviceID = origin
        // What launch-time live-recording recovery leaves behind.
        note.queueTranscription(at: Date(timeIntervalSince1970: start))
        return note
    }

    @Test func anOrphanedPCMFileIsExportedAttachedAndQueued() async throws {
        let sandbox = try Sandbox()
        let start = 1_792_457_173.749301
        let pcm = try sandbox.orphanedPCM(startedAt: start, seconds: 2)
        // The next recording, 36 s later, must not be mistaken for this one.
        let later = try sandbox.orphanedPCM(startedAt: start + 36, seconds: 1)
        let note = interruptedNote(startedAt: start, origin: thisDevice)
        let (session, transcription) = makeSession(sandbox)

        let tasks = session.recoverInterruptedRecordings(in: [note])
        #expect(tasks.count == 1)
        #expect(transcription.isLocalRecording(noteID: note.id))
        for task in tasks { await task.value }

        #expect(note.audioFilePath == "recording_\(start).m4a")
        #expect(abs(note.duration - 2) < 0.05)
        #expect(FileManager.default.fileExists(atPath: sandbox.audio.appendingPathComponent(note.audioFilePath).path))
        #expect(!FileManager.default.fileExists(atPath: pcm.path))
        #expect(FileManager.default.fileExists(atPath: later.path))
        #expect(note.transcriptionState == .queued)
        #expect(note.transcriptionOutcome != .failed)
        #expect(note.transcriptionLastErrorMessage == nil)
        #expect(!transcription.isLocalRecording(noteID: note.id))
        #expect(!session.isPreparingAudio(note))
    }

    @Test func withoutOrphanedAudioTheNoteStopsWaitingAndSaysWhy() throws {
        let sandbox = try Sandbox()
        let start = 1_792_457_173.749301
        let unrelated = try sandbox.orphanedPCM(startedAt: start + 36, seconds: 1)
        let note = interruptedNote(startedAt: start, origin: thisDevice)
        let (session, _) = makeSession(sandbox)

        #expect(session.recoverInterruptedRecordings(in: [note]).isEmpty)

        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage?.contains("interrupted before it was saved") == true)
        #expect(!note.pendingTranscription)
        #expect(!note.isTranscribing)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func theRecordingInProgressIsLeftAlone() async throws {
        let sandbox = try Sandbox()
        let audio = RecordingSessionTests.MockRecordingAudio()
        let livePCM = try IncrementalTranscriptionCoordinatorTests().makeSilentCAF(seconds: 1)
        defer { try? FileManager.default.removeItem(at: livePCM) }
        audio.currentPCMFileURL = livePCM
        audio.startFilename = "recording_\(Date().timeIntervalSince1970).m4a"
        let (session, _) = makeSession(sandbox, audio: audio)
        session.coordinatorFactory = { url in
            let coordinator = IncrementalTranscriptionCoordinator(
                transcriptionService: TranscriptionService(), recordingFileURL: url)
            coordinator.transcribeOverride = { @Sendable _ in "" }
            return coordinator
        }

        session.startRecording()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while session.currentRecordingNote == nil {
            try #require(clock.now < deadline, "Timed out waiting for the recording to start")
            try await Task.sleep(for: .milliseconds(10))
        }
        let note = try #require(session.currentRecordingNote)

        #expect(note.transcriptionOriginDeviceID == thisDevice)
        #expect(session.recoverInterruptedRecordings(in: [note]).isEmpty)
        #expect(note.isTranscribing)
        #expect(note.transcriptionOutcome != .failed)
        #expect(note.transcriptionLastErrorMessage == nil)
        session.stopDueToInterruption()
    }

    @Test func notesRecordedOnAnotherDeviceAreUntouched() throws {
        let sandbox = try Sandbox()
        let start = 1_792_457_173.749301
        let pcm = try sandbox.orphanedPCM(startedAt: start, seconds: 1)
        let note = interruptedNote(startedAt: start, origin: "other-device")
        let (session, _) = makeSession(sandbox)

        #expect(session.recoverInterruptedRecordings(in: [note]).isEmpty)

        #expect(note.transcriptionState == .queued)
        #expect(note.duration == 0)
        #expect(note.transcriptionLastErrorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: pcm.path))
    }
}
