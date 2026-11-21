import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Re-transcription and imports find the speakers first, cut Qwen3-ASR slices
/// where the speaker changes and label the result as a live recording does.
@Suite(.serialized)
struct SpeakerRetranscriptionTests {
    private actor SliceLog {
        private(set) var durations: [Double] = []

        func record(_ url: URL) -> String {
            let file = try? AVAudioFile(forReading: url)
            let seconds = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            durations.append((seconds * 10).rounded() / 10)
            return "第\(durations.count)段话。"
        }
    }

    /// Speaker 0, then 1 from 5 s, then 0 again from 12 s.
    private static let threeTurns = LiveSpeakerSnapshot(
        coveredSeconds: 20,
        ranges: [SpeakerTimeRange(speaker: 0, start: 0, end: 4.8),
                 SpeakerTimeRange(speaker: 1, start: 5.2, end: 11.8),
                 SpeakerTimeRange(speaker: 0, start: 12.2, end: 20)],
        turnChanges: [5, 12])

    @MainActor private func transcriber(turns: LiveSpeakerSnapshot?, log: SliceLog,
                                        store: SegmentProgressStore) -> SegmentedAudioTranscriber {
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.nextCutFrame = { _, start, _ in start + 14 * 16_000 }
        transcriber.findSpeakerTurns = { _ in turns }
        transcriber.transcribeSegmentOutcome = { url in
            .transcribed(.init(text: await log.record(url), duration: 1, modelIdentifier: "m"))
        }
        return transcriber
    }

    @Test @MainActor func importIsCutWhereTheSpeakerChangesAndLabelledOnceItHasAudio() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = SliceLog()
        let transcriber = transcriber(turns: Self.threeTurns, log: log, store: SegmentedAudioTestSupport.makeStore())
        transcriber.storeImportedAudio = { _ in "listening-copy.m4a" }
        let note = VoiceNote(title: "imported", audioFilePath: "")

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await log.durations == [5, 7, 8])
        #expect(note.audioFilePath == "listening-copy.m4a")
        let speakers = try #require(note.speakerTranscript)
        #expect(speakers.units.map(\.speaker) == [1, 2, 1])
        #expect(speakers.audioPath == "listening-copy.m4a")
    }

    @Test @MainActor func shortFileWithAChangeOfSpeakerIsCutInsteadOfDecodedInOnePass() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = SliceLog()
        let turns = LiveSpeakerSnapshot(
            coveredSeconds: 10,
            ranges: [SpeakerTimeRange(speaker: 0, start: 0, end: 3.8), SpeakerTimeRange(speaker: 1, start: 4.2, end: 10)],
            turnChanges: [4])
        let transcriber = transcriber(turns: turns, log: log, store: SegmentedAudioTestSupport.makeStore())
        let note = VoiceNote(title: "Saved", audioFilePath: url.path)
        note.setTranscript("old text", spans: nil)

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await log.durations == [4, 6])
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(try #require(note.speakerTranscript).units.map(\.speaker) == [1, 2])
    }

    @Test @MainActor func oneSpeakerKeepsTheUsualCutsAndPlainText() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = SliceLog()
        let turns = LiveSpeakerSnapshot(
            coveredSeconds: 20, ranges: [SpeakerTimeRange(speaker: 0, start: 0, end: 20)], turnChanges: [])
        let transcriber = transcriber(turns: turns, log: log, store: SegmentedAudioTestSupport.makeStore())
        let note = VoiceNote(title: "Saved", audioFilePath: url.path)

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await log.durations == [14, 6])
        #expect(note.transcriptSpans?.count == 2)
        #expect(note.speakerTranscript == nil)
    }

    @Test @MainActor func resumedRunFindsTheSameCutsAgain() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let log = SliceLog()
        let note = VoiceNote(title: "Saved", audioFilePath: url.path)
        // The first run stopped after its first slice, which ended at the change at 5 s.
        store.save(.init(lastFrame: 5 * 16_000, totalFrames: 20 * 16_000, accumulatedText: "第0段话。",
                         failedRanges: [], updatedAt: Date(),
                         spans: [TranscriptSpan(length: "第0段话。".utf16.count, start: 0, end: 5)]), for: note.id)
        let transcriber = transcriber(turns: Self.threeTurns, log: log, store: store)

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(await log.durations == [7, 8])
        #expect(try #require(note.speakerTranscript).units.map(\.speaker) == [1, 2, 1])
    }

    @Test @MainActor func shortRetranscriptionWithTwoSpeakersGetsLabels() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        service.setModelManager(VoicelyTests.LoadedModelManager(backend: .coreML))
        service.deviceIDProvider = { "this-device" }
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        service.audioDurationProvider = { _ in 10 }
        service.findSpeakerTurns = { _ in
            LiveSpeakerSnapshot(
                coveredSeconds: 10,
                ranges: [SpeakerTimeRange(speaker: 0, start: 0, end: 3.8), SpeakerTimeRange(speaker: 1, start: 4.2, end: 10)],
                turnChanges: [4])
        }
        var qwenCalls = 0
        service.transcribeImpl = { _, _ in
            qwenCalls += 1
            return .text(qwenCalls == 1 ? "你好。" : "你也好。")
        }
        let note = VoiceNote(title: "Saved", audioFilePath: url.path)
        note.transcriptionOriginDeviceID = "this-device"
        note.setTranscript("old text", spans: nil)
        note.completeTranscription()
        note.transcriptionOutcome = .transcribed

        #expect(await service.requestTranscription(for: note, force: true))

        #expect(qwenCalls == 2)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(try #require(note.speakerTranscript).units.map(\.speaker) == [1, 2])
    }
}
