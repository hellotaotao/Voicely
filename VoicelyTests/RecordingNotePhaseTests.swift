//
//  RecordingNotePhaseTests.swift
//  VoicelyTests
//

import Testing
@testable import Voicely

struct RecordingNotePhaseTests {
    private func phase(
        isTranscribing: Bool = true,
        duration: Double,
        hasText: Bool,
        ownedByJob: Bool = false
    ) -> RecordingNotePhase {
        RecordingNotePhase(
            isTranscribing: isTranscribing,
            duration: duration,
            hasVisibleTranscript: hasText,
            isOwnedByTranscriptionJob: ownedByJob
        )
    }

    @Test func stoppedRecordingWithLiveTextIsFinalizingNotRecording() {
        let stopped = phase(duration: 304, hasText: true)
        #expect(stopped == .finalizing)
        #expect(!stopped.isLiveUpdatingTranscript)
        #expect(!stopped.isRecording)
        #expect(phase(duration: 304, hasText: false) == .finalizing)
    }

    @Test func runningRecordingShowsLiveTextOnlyOnceItExists() {
        #expect(phase(duration: 0, hasText: true).isLiveUpdatingTranscript)
        #expect(phase(duration: 0, hasText: true).isRecording)
        #expect(phase(duration: 0, hasText: false) == .recording(hasLiveText: false))
        #expect(!phase(duration: 0, hasText: false).isLiveUpdatingTranscript)
    }

    @Test func notesOwnedByATranscriptionJobOrIdleHaveNoRecordingPhase() {
        #expect(phase(duration: 304, hasText: true, ownedByJob: true) == .none)
        #expect(phase(isTranscribing: false, duration: 304, hasText: true) == .none)
    }
}
