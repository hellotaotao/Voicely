//
//  TranscriptionProgressPublishingTests.swift
//  VoicelyTests
//

import Combine
import Foundation
import Testing
@testable import Voicely

@MainActor
struct TranscriptionProgressPublishingTests {

    /// Progress smoothing ticks every 50 ms for the whole run. `ContentView` and
    /// `VoiceNoteDetailView` observe `TranscriptionService`, so any published
    /// change re-evaluates the entire note list and the open detail view — at
    /// 20 Hz that is a visible hitch on a large library. The smoothed value is
    /// internal bookkeeping that no view reads (rows and the detail view read
    /// `localProgress`, which updates once per slice), so smoothing must not
    /// touch the observable surface at all.
    @Test func smoothingProgressDoesNotNotifyObservers() {
        let service = TranscriptionService()
        var emissions = 0
        let cancellable = service.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        // The smoothing task writes this ~20×/s for the whole run.
        service.transcriptionProgress = 0.25
        service.transcriptionProgress = 0.5
        service.transcriptionProgress = 0.75

        #expect(emissions == 0)
        // The value is still tracked — it just isn't an observable UI input.
        #expect(service.transcriptionProgress == 0.75)
    }

    /// Per-note progress is what the UI actually shows, and it must keep
    /// publishing so the row's progress bar moves.
    @Test func perNoteProgressStillNotifiesObservers() async {
        let service = TranscriptionService()
        let note = VoiceNote(title: "rec", audioFilePath: "rec.m4a")
        service.beginExternalTranscription(noteID: note.id)

        var emissions = 0
        let cancellable = service.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        service.reportExternalProgress(0.5, for: note.id)

        #expect(emissions > 0)
        #expect(service.localProgress(for: note) == 0.5)
    }
}
