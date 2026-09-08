import Foundation
import Testing
@testable import Voicely

@Suite(.serialized)
@MainActor
struct TranscriptSnapshotReuseTests {
    @Test func eachSegmentBuildsOneSnapshotForCheckpointAndPreview() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        var snapshotCount = 0
        transcriber.joinTranscriptPieces = { pieces in
            snapshotCount += 1
            return pieces.joined(separator: "\n")
        }
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "same", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(snapshotCount == 3)
        #expect(note.transcription == "same\nsame\nsame")
    }

    @Test func resumeReusesSavedSnapshotAndPersistsNewTextBeforePause() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 90)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        store.save(.init(lastFrame: 29 * 16_000, totalFrames: 90 * 16_000,
                         accumulatedText: "saved\ntext", failedRanges: [], updatedAt: Date()), for: note.id)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        var snapshots: [String] = []
        transcriber.joinTranscriptPieces = { pieces in
            let text = pieces.joined(separator: "\n")
            snapshots.append(text)
            return text
        }
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "new", duration: 1, modelIdentifier: "m"))
        }
        transcriber.shouldStopForBackground = { !snapshots.isEmpty }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(snapshots == ["saved\ntext\nnew"])
        let checkpoint = try #require(store.load(for: note.id))
        #expect(checkpoint.accumulatedText == snapshots[0])
        #expect(checkpoint.lastFrame == 58 * 16_000)
        #expect(note.transcriptionState == .queued)
    }
}
