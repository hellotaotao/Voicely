#if DEBUG && targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import os
import SwiftData
import Testing
@testable import Voicely

private enum SpeakerLabelingReplayFixture {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    static let audio = repository.appendingPathComponent("build/speaker-alignment-fixtures/mixed.wav")
    static let alignmentModel = repository.appendingPathComponent("build/speaker-alignment-model")

    static var isConfigured: Bool {
        FileManager.default.isReadableFile(atPath: audio.path)
            && FileManager.default.isReadableFile(atPath: alignmentModel.appendingPathComponent("model.safetensors").path)
    }
}

@Suite(.enabled(if: SpeakerLabelingReplayFixture.isConfigured))
struct SpeakerLabelingReplayTests {
    @Test @MainActor func separatesTwoLocalVoicesAndPersistsLabelsWithoutRewritingText() async throws {
        let fixture = SpeakerLabelingReplayFixture.self
        // One system voice reads English, then a different voice reads Mandarin.
        let english = "Good morning everyone. The next meeting will begin tomorrow.\n"
        let mandarin = "今天上午开会。会议结束以后请把文件发给我。"
        let text = english + mandarin
        let audio = try AVAudioFile(forReading: fixture.audio)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        let spans: [TranscriptSpan] = [
            .init(length: english.utf16.count, start: 0, end: 5),
            .init(length: mandarin.utf16.count, start: 5, end: duration)
        ]

        let progress = OSAllocatedUnfairLock(initialState: [SpeakerProcessingProgress]())
        let ranges = try await SpeakerDiarizationEngine.segments(for: fixture.audio) { update in
            progress.withLock { $0.append(update) }
        }
        let updates = progress.withLock { $0 }
        let expectedTotal = Int((duration * 100).rounded(.up))
        let completedFrames = updates.map(\.completedUnits)
        #expect(updates.allSatisfy { $0.totalUnits == expectedTotal })
        #expect(completedFrames.first == 0)
        #expect(completedFrames.dropFirst().dropLast().contains { $0 > 0 && $0 < expectedTotal })
        #expect(zip(completedFrames, completedFrames.dropFirst()).allSatisfy { $0.0 < $0.1 })
        #expect(completedFrames.last == expectedTotal)

        let tokens = try await SpeakerTranscriptAligner.alignWithLocalModelForTesting(
            audioURL: fixture.audio, text: text, spans: spans, isEnglish: false, modelDirectory: fixture.alignmentModel
        )
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: VoiceNote.self, configurations: config)
        let note = VoiceNote(title: "Speaker labeling replay", audioFilePath: "two-voices.wav")
        container.mainContext.insert(note)
        note.setTranscript(text, spans: spans)

        let labels = try #require(SpeakerTranscriptBuilder.make(
            text: text, spans: spans, audioPath: note.audioFilePath, tokens: tokens, segments: ranges
        ))
        #expect(Set(labels.units.compactMap(\.speaker)) == [1, 2])
        #expect(labels.units.first?.speaker == 1)
        #expect(labels.units.last?.speaker == 2)
        #expect(note.setSpeakerTranscript(labels))
        try container.mainContext.save()

        let readContext = ModelContext(container)
        let restored = try #require(readContext.fetch(FetchDescriptor<VoiceNote>()).first)
        #expect(restored.transcription == text)
        #expect(restored.transcriptSpans == spans)
        #expect(restored.speakerTranscript == labels)
        let presentation = try #require(SpeakerTranscriptPresentation(text: restored.transcription, speakers: labels) {
            "Speaker \($0 ?? 0)"
        })
        #expect(presentation.text.contains("Speaker 1\nGood morning"))
        // Initial Mandarin phones may have zero-width alignment; the first
        // sentence can remain uncertain, but the second must belong to voice 2.
        #expect(presentation.text.contains("Speaker 2\n会议结束以后请把文件发给我。"))
    }
}
#endif
