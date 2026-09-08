import Foundation
import Testing
@testable import Voicely

struct AudioPlaybackSelectionTests {
    @Test func recordingClearsOldSelectionAndStopSelectsNewAsset() {
        let oldNote = UUID()
        let newNote = UUID()
        let oldSelection = AudioPlaybackSelection(noteID: oldNote, filePath: "old.m4a", isRecording: false)
        let recordingSelection = AudioPlaybackSelection(noteID: newNote, filePath: "new.caf", isRecording: true)
        let stoppedSelection = AudioPlaybackSelection(noteID: newNote, filePath: "new.caf", isRecording: false)
        let finalizedSelection = AudioPlaybackSelection(noteID: newNote, filePath: "new.m4a", isRecording: false)

        #expect(oldSelection != nil)
        #expect(recordingSelection == nil)
        #expect(stoppedSelection != nil)
        #expect(stoppedSelection != oldSelection)
        #expect(finalizedSelection != stoppedSelection)
    }

    @Test func unchangedAssetKeepsSelectionAndMissingAudioClearsIt() {
        let noteID = UUID()
        let selection = AudioPlaybackSelection(noteID: noteID, filePath: "same.m4a", isRecording: false)
        #expect(selection == AudioPlaybackSelection(noteID: noteID, filePath: "same.m4a", isRecording: false))
        #expect(AudioPlaybackSelection(noteID: noteID, filePath: "", isRecording: false) == nil)
    }
}
