//
//  RecordingSessionTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

@MainActor
struct RecordingSessionTests {

    /// Stand-in recorder so the session's control flow can run without a real
    /// `AVAudioEngine`. Mirrors the public surface `RecordingSession` relies on.
    final class MockRecordingAudio: RecordingAudioControlling {
        var isRecording = false
        var isPaused = false
        var recordingDuration: TimeInterval = 0
        var hasPermission = true
        var currentPCMFileURL: URL?
        var currentFramePosition: AVAudioFramePosition = 0

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
            return RecordingStopResult(filePath: filename, duration: recordingDuration)
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

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Regression test for the rotation bug: a normal start → stop must reuse the
    /// single in-progress note, attach the audio to it, and never spawn a second
    /// note for the same recording.
    @Test func stoppingReusesTheInProgressNote() async {
        let (session, audio, collector) = makeSession()

        session.startRecording()
        await waitUntil { session.currentRecordingNote != nil }

        #expect(session.currentRecordingNote != nil)
        #expect(collector.count == 1)
        let recordingNote = session.currentRecordingNote

        // Enough elapsed time to clear the accidental-stop guard.
        audio.recordingDuration = 2
        audio.currentFramePosition = 0

        session.stopRecording()
        await waitUntil { session.currentRecordingNote == nil }

        #expect(collector.count == 1)
        #expect(audio.stopCount == 1)
        #expect(collector.notes.first === recordingNote)
        #expect(recordingNote?.audioFilePath == "recording.m4a")
        #expect(recordingNote?.duration == 2)
    }

    /// A system interruption must finalize the in-progress note in place, exactly
    /// like a manual stop — not create a duplicate.
    @Test func interruptionFinalizesInProgressNote() async {
        let (session, audio, collector) = makeSession()

        session.startRecording()
        await waitUntil { session.currentRecordingNote != nil }
        let note = session.currentRecordingNote
        audio.recordingDuration = 5

        session.stopDueToInterruption()
        await waitUntil { session.currentRecordingNote == nil }

        #expect(collector.count == 1)
        #expect(collector.notes.first === note)
        #expect(note?.audioFilePath == "recording.m4a")
    }

    /// The live path finalize writes the assembled transcript and its word
    /// timeline in one stroke — the stored text is exactly the joined words.
    @Test func finalizeWritesTranscriptAndWordTimelineInLockstep() async throws {
        let (session, audio, collector) = makeSession()

        // A real (silent) PCM file so the coordinator's final flush can extract
        // a segment; the transcription itself is stubbed below.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let frames: AVAudioFrameCount = 80_000   // 5 s
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let pcmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely_session_\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: pcmURL, settings: format.settings)
        try file.write(from: buffer)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        audio.currentPCMFileURL = pcmURL

        session.coordinatorFactory = { url in
            let coordinator = IncrementalTranscriptionCoordinator(
                transcriptionService: TranscriptionService(), recordingFileURL: url)
            coordinator.transcribeOverride = { @Sendable _ in "hello world" }
            coordinator.segmentWordsOverride = { @Sendable _ in
                [WordToken(word: " hello", start: 0.0, end: 0.5),
                 WordToken(word: " world", start: 0.5, end: 1.0)]
            }
            return coordinator
        }

        session.startRecording()
        await waitUntil { session.currentRecordingNote != nil }
        let note = collector.notes.first

        audio.recordingDuration = 5
        audio.currentFramePosition = AVAudioFramePosition(frames)
        session.stopRecording()
        await waitUntil { note?.transcription.isEmpty == false }

        #expect(note?.transcription == "hello world")
        #expect(note?.wordTimings.map(\.word).joined() == note?.transcription)
        #expect(note?.wordTimings.count == 2)
        #expect(note?.transcriptionState == .completed)
    }

    /// The note being recorded must be identifiable so the UI can refuse to
    /// delete it: deleting mid-recording leaves `finalizeRecording`'s trailing
    /// task writing to a note that no longer exists in the context.
    @Test func isRecordingNoteIdentifiesTheInProgressNoteOnly() async {
        let (session, audio, collector) = makeSession()

        let unrelated = VoiceNote(title: "other", audioFilePath: "other.m4a")
        #expect(session.isRecording(unrelated) == false)

        session.startRecording()
        await waitUntil { session.currentRecordingNote != nil }
        let recording = collector.notes.first

        #expect(recording.map { session.isRecording($0) } == true)
        #expect(session.isRecording(unrelated) == false)

        audio.recordingDuration = 2
        session.stopRecording()
        await waitUntil { session.currentRecordingNote == nil }

        // Once finalized the note is an ordinary note again — deletable.
        #expect(recording.map { session.isRecording($0) } == false)
    }

    /// The accidental-stop guard still applies: an immediate stop on a fresh
    /// recording is ignored, leaving the session recording.
    @Test func immediateStopIsIgnoredOnFreshRecording() async {
        let (session, audio, _) = makeSession()

        session.startRecording()
        await waitUntil { session.currentRecordingNote != nil }

        // recordingDuration stays at 0 → within the accidental-stop window.
        session.stopRecording()

        #expect(session.currentRecordingNote != nil)
        #expect(audio.stopCount == 0)
    }
}
