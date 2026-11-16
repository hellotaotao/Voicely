import Foundation
import Testing
@testable import Voicely

struct SpeakerTranscriptTests {
    private func token(_ location: Int, _ length: Int, _ start: Double, _ end: Double) -> SpeakerAlignedToken {
        .init(range: NSRange(location: location, length: length), start: start, end: end)
    }

    private func segment(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerTimeRange {
        .init(speaker: speaker, start: start, end: end)
    }

    private func spans(_ text: String) -> [TranscriptSpan] {
        [.init(length: text.utf16.count, start: 0, end: 8)]
    }

    @Test func numbersSpeakersInTranscriptOrderAndKeepsTheirNumber() throws {
        let text = "First. Then. First."
        let payload = try #require(SpeakerTranscriptBuilder.make(
            text: text, spans: spans(text), audioPath: "a",
            tokens: [token(0, 5, 0.5, 1.5), token(7, 4, 2, 3), token(13, 5, 4, 5)],
            segments: [segment(6, 0, 1.5), segment(1, 2, 3), segment(6, 4, 5)]
        ))
        #expect(payload.units.map(\.speaker) == [1, 2, 1])
        #expect(payload.units.map(\.start) == [0.5, 2, 4])
        #expect(payload.units.map(\.length).reduce(0, +) == text.utf16.count)
    }

    @Test func insertsChangeOfSpeakerInsideLongSentenceAtAlignedWord() throws {
        let text = "Welcome everyone please continue."
        let payload = try #require(SpeakerTranscriptBuilder.make(
            text: text, spans: spans(text), audioPath: "a",
            tokens: [token(0, 7, 0, 0.8), token(8, 8, 0.9, 1.8),
                     token(17, 6, 2.0, 2.6), token(24, 8, 2.7, 3.3)],
            segments: [segment(3, 0, 1.8), segment(5, 2, 3.3)]
        ))
        #expect(payload.units.map(\.speaker) == [1, 2])
        #expect(payload.units.map(\.length) == [17, 16])
        #expect(payload.units.last?.start == 2)
    }

    @Test func overlappingVoicesAndUnalignedTextRemainUnknown() throws {
        let text = "Overlap. Missing. Clear."
        let payload = try #require(SpeakerTranscriptBuilder.make(
            text: text, spans: spans(text), audioPath: "a",
            tokens: [token(0, 7, 0, 1), token(18, 5, 4, 5)],
            segments: [segment(4, 0, 1), segment(7, 0, 1), segment(7, 4, 5)]
        ))
        #expect(payload.units.map(\.speaker) == [nil, nil, 1])
        #expect(payload.units[1].start == nil)
    }

    @Test func cannotDoubleCountDuplicateSegmentsOrAssignFromTinyOverlap() {
        let text = "Unclear."
        #expect(SpeakerTranscriptBuilder.make(
            text: text, spans: spans(text), audioPath: "a", tokens: [token(0, 7, 0, 1)],
            segments: [segment(0, 0, 0.4), segment(0, 0.1, 0.4)]
        ) == nil)
    }

    @Test func transcriptPresentationPreservesSearchAndPlaybackCoordinates() throws {
        let text = "A🙂. Bye."
        let speakers = SpeakerTranscript(audioPath: "a", units: [
            .init(length: 4, start: 1, speaker: 1),
            .init(length: 5, start: 3, speaker: 2)
        ])
        let presentation = try #require(SpeakerTranscriptPresentation(
            text: text, speakers: speakers, label: { "S\($0 ?? 0)" }
        ))
        #expect(presentation.text == "S1\nA🙂.\n\nS2\n Bye.")
        let original = (text as NSString).range(of: "Bye")
        let displayed = presentation.displayRange(for: original)
        #expect((presentation.text as NSString).substring(with: displayed) == "Bye")
        let crossesTurn = presentation.displayRange(for: NSRange(location: 3, length: 2))
        #expect(presentation.textRanges(in: crossesTurn).map {
            (presentation.text as NSString).substring(with: $0)
        } == [".", " "])
        #expect(presentation.playbackUnits.map(\.start) == [1, 3])
    }

    @Test func uncertainUnalignedSentenceKeepsItsEstimatedPlaybackTarget() throws {
        let text = "One. Two. Three."
        let speakers = SpeakerTranscript(audioPath: "a", units: [
            .init(length: 4, start: 1, speaker: 1),
            .init(length: 5, start: nil, speaker: nil),
            .init(length: 7, start: 2, speaker: 2)
        ])
        let presentation = try #require(SpeakerTranscriptPresentation(
            text: text, speakers: speakers, fallbackSpans: spans(text), label: { "S\($0 ?? 0)" }
        ))
        #expect(presentation.playbackUnits.count == 3)
        let estimated = presentation.playbackUnits[1].start
        #expect(estimated > 1 && estimated < 2)
        #expect((presentation.text as NSString).substring(with: presentation.playbackUnits[1].range) == " Two.")
    }

    @Test @MainActor func storedLabelsRequireMatchingAudioAndTextAndDowngradeGracefully() throws {
        let note = VoiceNote(title: "Note", audioFilePath: "a")
        note.setTranscript("Hi.", spans: spans("Hi."))
        let originalData = note.transcriptSpansData
        #expect(note.speakerTranscript == nil)
        #expect(note.setSpeakerTranscript(.init(
            audioPath: "a", units: [.init(length: 3, start: 1, speaker: 1)]
        )))
        #expect(note.speakerTranscript?.units.first?.speaker == 1)
        #expect(note.transcriptSpans == spans("Hi."))
        note.audioFilePath = "b"
        #expect(note.speakerTranscript == nil)
        note.audioFilePath = "a"
        note.transcription = "No."
        #expect(note.speakerTranscript == nil)
        note.transcription = "Hi."
        note.applyEditedTranscript("Hi!")
        #expect(note.speakerTranscript == nil)
        note.transcriptSpansData = originalData
        note.transcription = "Hi."
        #expect(note.transcriptSpans == spans("Hi."))
        #expect(note.speakerTranscript == nil)
    }

    @Test @MainActor func invalidPayloadDoesNotReplaceExistingData() {
        let note = VoiceNote(title: "Note", audioFilePath: "a")
        note.setTranscript("Hi.", spans: spans("Hi."))
        let original = note.transcriptSpansData
        let wroteInvalidLabels = note.setSpeakerTranscript(.init(
            audioPath: "a", units: [.init(length: 9, start: 1, speaker: 1)]
        ))
        #expect(wroteInvalidLabels == false)
        #expect(note.transcriptSpansData == original)
    }
}

@MainActor
struct SpeakerLabelingSourceTests {
    @Test func snapshotRejectsRetimedNotesWithTheSameAudioAndText() throws {
        let note = VoiceNote(title: "Note", audioFilePath: "example.m4a")
        note.setTranscript("Hi.", spans: [.init(length: 3, start: 1, end: 2)])
        let source = try #require(SpeakerLabelingSource(note: note))
        #expect(source.matches(note))
        note.setTranscript("Hi.", spans: [.init(length: 3, start: 2, end: 3)])
        #expect(!source.matches(note))
    }

    @Test func editInvalidatesPendingWorkWithoutChangingNoteIdentity() throws {
        let note = VoiceNote(title: "Note", audioFilePath: "example.m4a")
        note.setTranscript("Hi.", spans: [.init(length: 3, start: 1, end: 2)])
        let source = try #require(SpeakerLabelingSource(note: note))
        note.applyEditedTranscript("Hello.")
        #expect(!source.matches(note))
    }

    @Test func oldNoteWithoutTimelineCannotStartSpeakerLabeling() {
        let note = VoiceNote(title: "Note", audioFilePath: "example.m4a", transcription: "Hi.")
        #expect(SpeakerLabelingSource(note: note) == nil)
    }
}
