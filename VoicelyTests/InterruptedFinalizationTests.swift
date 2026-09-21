//
//  InterruptedFinalizationTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Live slices exist only in the coordinator's memory, so an app killed while
/// finalizing leaves `isTranscribing` persisted with nothing left to finish it.
/// The note then shows "Finalizing" forever.
@MainActor
struct InterruptedFinalizationTests {

    private func makeSession() -> RecordingSession {
        RecordingSession(audioService: RecordingSessionTests.MockRecordingAudio(),
                         transcriptionService: TranscriptionService())
    }

    @Test func aNoteLeftMidFinalizationIsReleasedAndKeepsItsLiveText() {
        let note = VoiceNote(title: "Meeting", audioFilePath: "/tmp/meeting.caf")
        note.duration = 3_600
        note.isTranscribing = true
        note.transcription = "text written by the live pass"

        makeSession().recoverInterruptedFinalizations(in: [note])

        #expect(!note.isTranscribing)
        #expect(note.transcription == "text written by the live pass")
        #expect(note.transcriptionState == .completed)
        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage?.contains("interrupted") == true)
        #expect(!note.pendingTranscription)
    }

    @Test func anActiveRecordingIsLeftAlone() {
        // Still recording: no duration yet, so this is not a stalled finalization.
        let note = VoiceNote(title: "Recording", audioFilePath: "/tmp/live.caf")
        note.duration = 0
        note.isTranscribing = true

        makeSession().recoverInterruptedFinalizations(in: [note])

        #expect(note.isTranscribing)
        #expect(note.transcriptionOutcome != .failed)
    }

    @Test func aNoteWaitingInTheTranscriptionQueueIsLeftAlone() {
        let note = VoiceNote(title: "Queued", audioFilePath: "/tmp/queued.caf")
        note.duration = 120
        note.isTranscribing = true
        note.isAwaitingTranscription = true

        makeSession().recoverInterruptedFinalizations(in: [note])

        #expect(note.isTranscribing)
        #expect(note.transcriptionOutcome != .failed)
    }

    @Test func anIdleNoteIsUntouched() {
        let note = VoiceNote(title: "Done", audioFilePath: "/tmp/done.caf")
        note.duration = 60
        note.transcription = "finished"
        note.completeTranscription()

        makeSession().recoverInterruptedFinalizations(in: [note])

        #expect(note.transcriptionOutcome != .failed)
        #expect(note.transcriptionLastErrorMessage == nil)
    }
}
