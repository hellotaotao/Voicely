import Foundation
import SwiftData
import Testing
@testable import Voicely

@MainActor
struct SpeakerNameTests {
    @Test func legacyLabelsAndMalformedNameFieldsStillDecode() throws {
        let legacy = #"{"audioPath":"audio.m4a","units":[{"length":2,"start":0,"speaker":2},{"length":2,"start":1},{"length":2,"start":2,"speaker":1},{"length":2,"start":3,"speaker":2}]}"#
        let original = try JSONDecoder().decode(SpeakerTranscript.self, from: Data(legacy.utf8))
        #expect(original.speakerIDs == [1, 2])
        #expect(original.customNames == nil)
        #expect(original.displayName(for: 2) == String(localized: "Speaker \(2)"))
        #expect(original.displayName(for: nil) == String(localized: "Uncertain speaker"))

        let malformed = legacy.dropLast() + #","customNames":{"2":42}}"#
        let recovered = try JSONDecoder().decode(SpeakerTranscript.self, from: Data(malformed.utf8))
        #expect(recovered == original)
    }

    @Test func namesForUnassignedIDsAreNeverDisplayed() throws {
        let stored = #"{"audioPath":"audio.m4a","units":[{"length":2,"start":0,"speaker":1},{"length":2,"start":1}],"customNames":{"0":"False unknown","1":" Alice ","9":"False new speaker"}}"#
        let labels = try JSONDecoder().decode(SpeakerTranscript.self, from: Data(stored.utf8))
        #expect(labels.speakerIDs == [1])
        #expect(labels.customName(for: 1) == "Alice")
        #expect(labels.customName(for: 0) == nil)
        #expect(labels.customName(for: 9) == nil)
        #expect(labels.displayName(for: nil) == String(localized: "Uncertain speaker"))
        #expect(labels.displayName(for: 9) == String(localized: "Speaker \(9)"))
    }

    @Test func savesOneNamePerIDForEveryHeadingAndSharingWithoutChangingAudioOrTimes() throws {
        let (container, note, expected) = try makeSavedNote()
        let originalText = note.transcription
        let originalSpans = note.transcriptSpans
        let original = try #require(SpeakerTranscriptPresentation(
            text: originalText, speakers: expected, label: expected.displayName(for:)
        ))
        // Same display name for two distinct IDs does not merge their turns.
        try note.saveSpeakerNames([1: "  Alice \r\n\t Chen ", 2: "Alice Chen", 0: "Unknown", 9: "Unused"], matching: expected)

        let restored = try #require(try ModelContext(container).fetch(FetchDescriptor<VoiceNote>()).first)
        let labels = try #require(restored.speakerTranscript)
        let named = try #require(SpeakerTranscriptPresentation(
            text: restored.transcription, speakers: labels, label: labels.displayName(for:)
        ))
        #expect(labels.customNames == [1: "Alice Chen", 2: "Alice Chen"])
        #expect(labels.units == expected.units)
        #expect(restored.transcription == originalText)
        #expect(restored.transcriptSpans == originalSpans)
        #expect(restored.audioFilePath == expected.audioPath)
        #expect(named.headings.map { (named.text as NSString).substring(with: $0) }
                == ["Alice Chen", "Alice Chen", String(localized: "Uncertain speaker"), "Alice Chen"])
        #expect(named.text.contains("Alice Chen\nOne."))
        #expect(named.text.contains("Alice Chen\n Two."))
        #expect(named.text.contains("Alice Chen\n Four."))
        #expect(named.playbackUnits.map(\.start) == original.playbackUnits.map(\.start))
        #expect(named.playbackUnits.map(TranscriptTimeline.seekTime(for:))
                == original.playbackUnits.map(TranscriptTimeline.seekTime(for:)))
    }

    @Test func clearingNamesRestoresDefaultsWithoutRemovingLabels() throws {
        let (container, note, original) = try makeSavedNote()
        defer { withExtendedLifetime(container) {} }
        try note.saveSpeakerNames([1: "Alice", 2: "Bob"], matching: original)
        let named = try #require(note.speakerTranscript)
        try note.saveSpeakerNames([1: "   \n\t", 2: ""], matching: named)
        #expect(note.speakerTranscript == original)
    }

    @Test func pencilTargetsRecognizedHeadingOccurrencesByIDRatherThanName() throws {
        let (container, note, original) = try makeSavedNote()
        defer { withExtendedLifetime(container) {} }
        var labels = original
        labels.customNames = [1: "Same", 2: "Same"]
        let presentation = try #require(SpeakerTranscriptPresentation(
            text: note.transcription, speakers: labels, label: labels.displayName(for:)
        ))
        #expect(presentation.headings.count == 4)
        #expect(presentation.editableHeadings.map(\.speakerID) == [1, 2, 1])
        #expect(presentation.editableHeadings.map(\.range) ==
                [presentation.headings[0], presentation.headings[1], presentation.headings[3]])
        let text = presentation.text as NSString
        #expect(presentation.editableHeadings.map { text.substring(with: $0.range) } == ["Same", "Same", "Same"])
        let body = (note.transcription as NSString).range(of: "Three.")
        #expect(text.substring(with: presentation.displayRange(for: body)) == "Three.")
    }

    @Test func inlineRenameOnlyChangesItsSpeakerAndClearingItKeepsOtherNames() throws {
        let (container, note, original) = try makeSavedNote()
        defer { withExtendedLifetime(container) {} }
        try note.saveSpeakerNames([1: "Alice", 2: "Bob"], matching: original)
        let bothNamed = try #require(note.speakerTranscript)
        try note.saveSpeakerName("Harry", for: 1, matching: bothNamed)
        let renamed = try #require(note.speakerTranscript)
        #expect(renamed.customNames == [1: "Harry", 2: "Bob"])
        #expect(renamed.units == original.units)
        #expect(throws: SpeakerNameSaveError.changed) {
            try note.saveSpeakerName("Not saved", for: 1, matching: bothNamed)
        }
        #expect(throws: SpeakerNameSaveError.changed) {
            try note.saveSpeakerName("Not saved", for: 0, matching: renamed)
        }
        try note.saveSpeakerName(" ", for: 1, matching: renamed)
        #expect(note.speakerTranscript?.customNames == [2: "Bob"])
    }

    @Test func pencilTouchAreaStaysBesideTheNameAndWithinTheAvailableWidth() throws {
        let lane = CGRect(x: 0, y: 0, width: 220, height: 280)
        let line = CGRect(x: 0, y: 40, width: 190, height: 44)
        let name = CGRect(x: 4, y: 40, width: 92, height: 44)
        let pencil = try #require(TranscriptSpeakerRenameLayout.pencilFrame(
            at: name, line: line, within: lane, side: 44, rightToLeft: false
        ))
        #expect(pencil.minX > name.maxX)
        #expect(pencil.minY == line.minY)
        #expect(pencil.maxY == line.maxY)
        #expect(pencil.width == 44)
        #expect(TranscriptSpeakerRenameLayout.pencilFrame(
            at: line, line: line, within: lane, side: 44, rightToLeft: false
        ) == nil)

        let rtlName = CGRect(x: 100, y: 40, width: 90, height: 44)
        let rtlPencil = try #require(TranscriptSpeakerRenameLayout.pencilFrame(
            at: rtlName, line: line, within: lane, side: 44, rightToLeft: true
        ))
        #expect(rtlPencil.maxX < rtlName.minX)
    }

    @Test func inlineEditorUsesTheAvailableWidthWithoutStretchingAcrossAMacWindow() {
        let mac = CGRect(x: 0, y: 0, width: 900, height: 30)
        #expect(TranscriptSpeakerRenameLayout.editorRowFrame(in: mac, side: 30, rightToLeft: false)
                == CGRect(x: 0, y: 0, width: 320, height: 30))
        #expect(TranscriptSpeakerRenameLayout.editorRowFrame(in: mac, side: 30, rightToLeft: true)
                == CGRect(x: 580, y: 0, width: 320, height: 30))
        let narrow = CGRect(x: 0, y: 0, width: 248, height: 44)
        #expect(TranscriptSpeakerRenameLayout.editorRowFrame(in: narrow, side: 44, rightToLeft: false) == narrow)
    }

    @Test func refusesAnEditorSnapshotWhenAnotherWriteChangedSpeakerNames() throws {
        let (container, note, stale) = try makeSavedNote()
        defer { withExtendedLifetime(container) {} }
        try note.saveSpeakerNames([1: "Synced"], matching: stale)
        let syncedTimeline = note.transcriptSpansData
        #expect(throws: SpeakerNameSaveError.changed) {
            try note.saveSpeakerNames([1: "Stale edit", 2: "Stale other name"], matching: stale)
        }
        #expect(note.transcriptSpansData == syncedTimeline)
        #expect(note.speakerTranscript?.customNames == [1: "Synced"])
    }

    @Test func refusesToSaveNamesAfterTranscriptOrAudioWasReplaced() throws {
        let (container, note, stale) = try makeSavedNote()
        defer { withExtendedLifetime(container) {} }
        note.audioFilePath = "other.m4a"
        let originalTimeline = note.transcriptSpansData
        #expect(throws: SpeakerNameSaveError.changed) { try note.saveSpeakerNames([1: "Alice"], matching: stale) }
        #expect(note.transcriptSpansData == originalTimeline)

        note.audioFilePath = stale.audioPath
        note.applyEditedTranscript("Edited. Two. Three. Four.")
        let editedTimeline = note.transcriptSpansData
        #expect(throws: SpeakerNameSaveError.changed) { try note.saveSpeakerNames([1: "Alice"], matching: stale) }
        #expect(note.transcriptSpansData == editedTimeline)
    }

    @Test func refusesToSaveNamesForADeletedNote() throws {
        let (container, note, stale) = try makeSavedNote()
        container.mainContext.delete(note)
        #expect(throws: SpeakerNameSaveError.changed) { try note.saveSpeakerNames([1: "Alice"], matching: stale) }
    }

    @Test func aNewSpeakerIdentificationStartsWithDefaultNames() throws {
        let (container, note, original) = try makeSavedNote()
        defer { withExtendedLifetime(container) {} }
        try note.saveSpeakerNames([1: "Alice", 2: "Bob"], matching: original)
        let previouslyNamed = try #require(note.speakerTranscript)
        let spans = try #require(note.transcriptSpans)
        let source = note.transcription as NSString
        let new = try #require(SpeakerTranscriptBuilder.make(
            text: note.transcription, spans: spans, audioPath: original.audioPath,
            tokens: [
                .init(range: source.range(of: "One"), start: 1, end: 1.25),
                .init(range: source.range(of: "Two"), start: 2, end: 2.25)
            ],
            segments: [
                .init(speaker: 3, start: 1, end: 1.25),
                .init(speaker: 4, start: 2, end: 2.25)
            ]
        ))
        #expect(note.setSpeakerTranscript(new))
        #expect(note.speakerTranscript?.speakerIDs == [1, 2])
        #expect(note.speakerTranscript?.customNames == nil)
        #expect(throws: SpeakerNameSaveError.changed) {
            try note.saveSpeakerNames([1: "Old editor"], matching: previouslyNamed)
        }
    }

    private func makeSavedNote() throws -> (ModelContainer, VoiceNote, SpeakerTranscript) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: VoiceNote.self, configurations: configuration)
        let note = VoiceNote(title: "Speaker names test", audioFilePath: "audio.m4a")
        container.mainContext.insert(note)
        note.setTranscript("One. Two. Three. Four.", spans: [
            .init(length: 22, start: 0, end: 5,
                  wordTimings: [.init(offset: 0, length: 3, start: 1, end: 1.25)])
        ])
        let speakers = SpeakerTranscript(audioPath: note.audioFilePath, units: [
            .init(length: 4, start: 1, speaker: 1),
            .init(length: 5, start: 2, speaker: 2),
            .init(length: 7, start: 3, speaker: nil),
            .init(length: 6, start: 4, speaker: 1)
        ])
        try #require(note.setSpeakerTranscript(speakers))
        try container.mainContext.save()
        return (container, note, speakers)
    }
}
