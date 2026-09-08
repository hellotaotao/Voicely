import Combine
import Foundation
import Testing
@testable import Voicely

@MainActor
struct ProgressNotificationTests {
    @Test func internalProgressAccumulatorDoesNotPublishObservableChanges() {
        let service = TranscriptionService()
        var notifications = 0
        let subscription = service.objectWillChange.sink { notifications += 1 }

        service.transcriptionProgress = 0.01

        #expect(service.transcriptionProgress == 0.01)
        #expect(notifications == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test func progressPublishesOnlyDistinctClampedValuesPerNote() {
        let service = TranscriptionService()
        let first = UUID()
        let second = UUID()
        var notifications = 0
        let subscription = service.objectWillChange.sink { notifications += 1 }

        service.reportExternalProgress(-1, for: first)
        service.reportExternalProgress(0, for: first)
        service.reportExternalProgress(0.5, for: first)
        service.reportExternalProgress(0.5, for: first)
        service.reportExternalProgress(1, for: first)
        service.reportExternalProgress(2, for: first)
        service.reportExternalProgress(1, for: second)

        #expect(notifications == 4)
        #expect(service.progressByNoteID[first] == 1)
        #expect(service.progressByNoteID[second] == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test func previewPublishesOnlyDistinctTextPerNote() {
        let service = TranscriptionService()
        let first = UUID()
        let second = UUID()
        var notifications = 0
        let subscription = service.objectWillChange.sink { notifications += 1 }

        service.reportExternalPreview("", for: first)
        service.reportExternalPreview("", for: first)
        service.reportExternalPreview("First segment", for: first)
        service.reportExternalPreview("First segment", for: first)
        service.reportExternalPreview("First segment", for: second)
        service.reportExternalPreview("", for: first)

        #expect(notifications == 4)
        #expect(service.transcriptionPreview(for: first) == "")
        #expect(service.transcriptionPreview(for: second) == "First segment")
        withExtendedLifetime(subscription) {}
    }

    @Test func endingAndRestartingExternalTranscriptionClearsTransientValues() {
        let service = TranscriptionService()
        let noteID = UUID()
        service.beginExternalTranscription(noteID: noteID)
        service.reportExternalPreview("Complete", for: noteID)
        service.reportExternalProgress(1, for: noteID)

        service.endExternalTranscription(noteID: noteID)

        #expect(service.activeNoteID == nil)
        #expect(service.transcriptionPreview(for: noteID) == nil)
        #expect(service.progressByNoteID[noteID] == nil)

        service.beginExternalTranscription(noteID: noteID)

        #expect(service.activeNoteID == noteID)
        #expect(service.progressByNoteID[noteID] == 0)
        #expect(service.transcriptionPreview(for: noteID) == nil)
    }
}
