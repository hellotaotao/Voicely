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

    /// The recorder's live directory, the legacy tmp directory and an audio
    /// directory, isolated per test.
    @MainActor
    private final class Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan_recovery_\(UUID().uuidString)", isDirectory: true)
        var live: URL { root.appendingPathComponent("live", isDirectory: true) }
        var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
        var audio: URL { root.appendingPathComponent("audio", isDirectory: true) }
        var now = Date()

        init() throws {
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var storage: OrphanedRecordingStorage {
            var storage = OrphanedRecordingStorage.live
            storage.pcmDirectories = { [live, tmp] in [live, tmp] }
            storage.now = { [unowned self] in self.now }
            storage.isAudioAbsent = { [audio] path in
                !FileManager.default.fileExists(atPath: audio.appendingPathComponent(path).path)
            }
            storage.destinationURL = { [audio] name in audio.appendingPathComponent(name) }
            return storage
        }

        /// Writes the live PCM file a recording started at `start` would leave behind.
        func orphanedPCM(startedAt start: TimeInterval, seconds: Double, inTmp: Bool = false) throws -> URL {
            let source = try IncrementalTranscriptionCoordinatorTests().makeSilentCAF(seconds: seconds)
            let url = AudioRecordingService.makeLivePCMURL(
                now: Date(timeIntervalSince1970: start), in: inTmp ? tmp : live)
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

    @Test func aPCMFileLeftInTmpByAnEarlierVersionIsStillRecovered() async throws {
        let sandbox = try Sandbox()
        let start = 1_792_457_173.749301
        let pcm = try sandbox.orphanedPCM(startedAt: start, seconds: 1, inTmp: true)
        let note = interruptedNote(startedAt: start, origin: thisDevice)
        let (session, _) = makeSession(sandbox)

        for task in session.recoverInterruptedRecordings(in: [note]) { await task.value }

        #expect(abs(note.duration - 1) < 0.05)
        #expect(FileManager.default.fileExists(atPath: sandbox.audio.appendingPathComponent(note.audioFilePath).path))
        #expect(!FileManager.default.fileExists(atPath: pcm.path))
        #expect(note.transcriptionState == .queued)
    }

    @Test func pcmFilesNoNoteClaimsAreRemovedOnlyOnceTheyAreAWeekOld() throws {
        let sandbox = try Sandbox()
        let start = 1_792_457_173.749301
        let stale = try sandbox.orphanedPCM(startedAt: start, seconds: 1)
        let recent = try sandbox.orphanedPCM(startedAt: start + 600, seconds: 1)
        // A note whose export and fallback copy failed plays its PCM file directly.
        let playedDirectly = try sandbox.orphanedPCM(startedAt: start + 1200, seconds: 1)
        let note = VoiceNote(title: "Kept", audioFilePath: playedDirectly.path)
        let unrelated = sandbox.root.appendingPathComponent("live/notes.caf")
        try Data([1]).write(to: unrelated)
        let weekAgo = sandbox.now.addingTimeInterval(-RecordingSession.unclaimedPCMRetention - 60)
        for url in [stale, playedDirectly, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: weekAgo], ofItemAtPath: url.path)
        }
        let (session, _) = makeSession(sandbox)

        #expect(session.recoverInterruptedRecordings(in: [note]).isEmpty)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: playedDirectly.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func aRecoveryStillExportingKeepsItsFileThroughLaterPasses() async throws {
        let sandbox = try Sandbox()
        let start = 1_792_457_173.749301
        let pcm = try sandbox.orphanedPCM(startedAt: start, seconds: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: sandbox.now.addingTimeInterval(-RecordingSession.unclaimedPCMRetention * 2)],
            ofItemAtPath: pcm.path)
        let note = interruptedNote(startedAt: start, origin: thisDevice)
        let (session, _) = makeSession(sandbox)
        let (gate, release) = AsyncStream<Void>.makeStream()
        var storage = sandbox.storage
        storage.convert = { source, destination in
            for await _ in gate { break }
            try await AudioRecordingService.convertCAFToM4A(from: source, to: destination)
        }
        session.orphanedRecordingStorage = storage

        let tasks = session.recoverInterruptedRecordings(in: [note])
        #expect(tasks.count == 1)
        // The app becomes active again while the first export is still running.
        #expect(session.recoverInterruptedRecordings(in: [note]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: pcm.path))
        #expect(note.transcriptionLastErrorMessage == nil)

        release.yield()
        for task in tasks { await task.value }
        #expect(FileManager.default.fileExists(atPath: sandbox.audio.appendingPathComponent(note.audioFilePath).path))
        #expect(!FileManager.default.fileExists(atPath: pcm.path))
    }
}
