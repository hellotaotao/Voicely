import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Speaker model stand-in: fixed turn changes and ranges, judged up to the
/// recording position minus `lagSeconds`, all of it once finished.
private actor ScriptedSpeakerTracker: LiveSpeakerTracking {
    let turnChanges: [TimeInterval]
    let ranges: [SpeakerTimeRange]
    let lagSeconds: Double
    private(set) var finishedAt: AVAudioFramePosition?

    init(turnChanges: [TimeInterval] = [], ranges: [SpeakerTimeRange] = [], lagSeconds: Double = 0) {
        self.turnChanges = turnChanges
        self.ranges = ranges
        self.lagSeconds = lagSeconds
    }

    func advance(toFrame frame: AVAudioFramePosition) -> LiveSpeakerSnapshot {
        snapshot(covered: max(0, Double(frame) / 16_000 - lagSeconds))
    }

    func finish(atFrame frame: AVAudioFramePosition) -> LiveSpeakerSnapshot {
        finishedAt = frame
        return snapshot(covered: Double(frame) / 16_000)
    }

    private func snapshot(covered: Double) -> LiveSpeakerSnapshot {
        LiveSpeakerSnapshot(
            coveredSeconds: covered,
            ranges: ranges.filter { $0.start < covered }.map {
                SpeakerTimeRange(speaker: $0.speaker, start: $0.start, end: min($0.end, covered))
            },
            turnChanges: turnChanges.filter { $0 < covered })
    }
}

private actor SliceRecorder {
    private(set) var durations: [Double] = []

    func record(_ path: String) -> String? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        durations.append((Double(file.length) / file.processingFormat.sampleRate * 10).rounded() / 10)
        return "slice \(durations.count)"
    }
}

@Suite(.serialized)
struct LiveSpeakerTests {
    // MARK: Turn changes from Nemotron frames

    /// One 10 ms frame per entry: the speaker above 0.5, or nil for silence.
    private func timeline(_ runs: [(speaker: Int?, frames: Int)]) throws -> SpeakerTurnTimeline {
        var timeline = SpeakerTurnTimeline(speakerCount: 2)
        for run in runs {
            var probabilities: [Float] = []
            for _ in 0..<run.frames {
                probabilities += [run.speaker == 0 ? 0.9 : 0.1, run.speaker == 1 ? 0.9 : 0.1]
            }
            try timeline.append(probabilities: probabilities, frameCount: run.frames)
        }
        return timeline
    }

    @Test func turnChangeSitsInTheMiddleOfThePauseBetweenSpeakers() throws {
        let snapshot = try timeline([(0, 100), (nil, 30), (1, 100)]).snapshot()
        #expect(snapshot.turnChanges == [1.15])
        #expect(snapshot.coveredSeconds == 2.3)
        #expect(snapshot.ranges.map(\.speaker) == [0, 1])
    }

    @Test func briefBlipOfAnotherSpeakerIsNotATurn() throws {
        let snapshot = try timeline([(0, 100), (1, 10), (0, 100)]).snapshot()
        #expect(snapshot.turnChanges.isEmpty)
    }

    @Test func turnStillRunningCountsOnceItIsLongEnough() throws {
        #expect(try timeline([(0, 100), (1, 15)]).snapshot().turnChanges.isEmpty)
        #expect(try timeline([(0, 100), (1, 25)]).snapshot().turnChanges == [1.0])
    }

    @Test func sameSpeakerAcrossAPauseStaysOneTurn() throws {
        let snapshot = try timeline([(0, 100), (nil, 50), (0, 100), (1, 40)]).snapshot()
        #expect(snapshot.turnChanges == [2.5])
    }

    // MARK: Labels for live slices

    @Test func eachLiveSliceGoesToTheSpeakerWhoHeldIt() throws {
        let first = "第一个人先说两句。还有一句。\n"
        let second = "第二个人回答。"
        let text = first + second
        let spans = [TranscriptSpan(length: first.utf16.count, start: 0, end: 5),
                     TranscriptSpan(length: second.utf16.count, start: 5, end: 9)]
        let ranges = [SpeakerTimeRange(speaker: 3, start: 0.3, end: 2.0),
                      SpeakerTimeRange(speaker: 3, start: 2.6, end: 4.7),
                      SpeakerTimeRange(speaker: 5, start: 5.2, end: 8.6)]

        let labels = try #require(SpeakerTranscriptBuilder.makeLive(
            text: text, spans: spans, audioPath: "note.m4a", segments: ranges))
        #expect(labels.speakerIDs == [1, 2])
        #expect(labels.units.map(\.speaker) == [1, 1, 2])
        #expect(labels.units.allSatisfy { $0.start != nil })
        #expect(labels.fits(text: text, audioPath: "note.m4a"))
    }

    @Test func oneSpeakerNeedsNoLabels() {
        let text = "只有一个人。\n还是同一个人。"
        let spans = [TranscriptSpan(length: 7, start: 0, end: 5), TranscriptSpan(length: 7, start: 5, end: 9)]
        let ranges = [SpeakerTimeRange(speaker: 0, start: 0, end: 9)]
        #expect(SpeakerTranscriptBuilder.makeLive(
            text: text, spans: spans, audioPath: "note.m4a", segments: ranges) == nil)
    }

    @Test func sliceSharedEvenlyByTwoSpeakersStaysUncertain() throws {
        let first = "一半一半。\n"
        let second = "后来的人说。\n"
        let third = "另一个人接着说。"
        let text = first + second + third
        let spans = [TranscriptSpan(length: first.utf16.count, start: 0, end: 10),
                     TranscriptSpan(length: second.utf16.count, start: 10, end: 14),
                     TranscriptSpan(length: third.utf16.count, start: 14, end: 18)]
        let ranges = [SpeakerTimeRange(speaker: 0, start: 0, end: 5),
                      SpeakerTimeRange(speaker: 1, start: 5, end: 10),
                      SpeakerTimeRange(speaker: 0, start: 10, end: 14),
                      SpeakerTimeRange(speaker: 1, start: 14, end: 18)]
        let labels = try #require(SpeakerTranscriptBuilder.makeLive(
            text: text, spans: spans, audioPath: "note.m4a", segments: ranges))
        #expect(labels.units.map(\.speaker) == [nil, 1, 2])
    }

    @Test func secondSpeakerOnlyInAnUncertainSliceShowsNoLabels() {
        let first = "一半一半。\n"
        let second = "后来的人说。"
        let text = first + second
        let spans = [TranscriptSpan(length: first.utf16.count, start: 0, end: 10),
                     TranscriptSpan(length: second.utf16.count, start: 10, end: 14)]
        let ranges = [SpeakerTimeRange(speaker: 0, start: 0, end: 5),
                      SpeakerTimeRange(speaker: 1, start: 5, end: 10),
                      SpeakerTimeRange(speaker: 0, start: 10, end: 14)]
        #expect(SpeakerTranscriptBuilder.makeLive(
            text: text, spans: spans, audioPath: "note.m4a", segments: ranges) == nil)
    }

    @Test func parakeetWordsAreLabelledWordByWord() throws {
        let text = "Hello there. Yes indeed."
        let spans = [TranscriptSpan(length: text.utf16.count, start: 0, end: 6, wordTimings: [
            .init(offset: 0, length: 5, start: 0.1, end: 0.6),
            .init(offset: 6, length: 6, start: 0.7, end: 1.2),
            .init(offset: 13, length: 3, start: 3.0, end: 3.4),
            .init(offset: 17, length: 7, start: 3.5, end: 4.2)
        ])]
        let ranges = [SpeakerTimeRange(speaker: 0, start: 0, end: 1.5),
                      SpeakerTimeRange(speaker: 1, start: 2.8, end: 4.5)]
        let labels = try #require(SpeakerTranscriptBuilder.makeLive(
            text: text, spans: spans, audioPath: "note.m4a", segments: ranges))
        #expect(labels.units.map(\.speaker) == [1, 2])
    }

    // MARK: Slicing at speaker changes

    @MainActor private func coordinator(seconds: Double, tracker: ScriptedSpeakerTracker,
                                        recorder: SliceRecorder) throws -> (IncrementalTranscriptionCoordinator, URL) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16_000))!
        buffer.frameLength = buffer.frameCapacity
        let url = TestTemporaryDirectory.fileURL(prefix: "live_speakers_", extension: "caf")
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(), recordingFileURL: url)
        coordinator.speakerTracker = tracker
        coordinator.snapTurnChange = { _, frame, _, _ in frame }
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        coordinator.transcribeOverride = { @Sendable path in await recorder.record(path) }
        return (coordinator, url)
    }

    @Test @MainActor func liveSliceEndsWhereTheSpeakerChangesWithoutWaitingForAFullBatch() async throws {
        let recorder = SliceRecorder()
        let (coordinator, url) = try coordinator(
            seconds: 20, tracker: ScriptedSpeakerTracker(turnChanges: [5]), recorder: recorder)
        defer { try? FileManager.default.removeItem(at: url) }

        await coordinator.transcribeSegment(upToFrame: 8 * 16_000)
        #expect(await recorder.durations == [5])
        // Nothing new after the change, and far less than a full batch.
        await coordinator.transcribeSegment(upToFrame: 10 * 16_000)
        #expect(await recorder.durations == [5])
    }

    @Test @MainActor func changeTooSoonAfterTheSliceStartIsSkipped() async throws {
        let recorder = SliceRecorder()
        let (coordinator, url) = try coordinator(
            seconds: 20, tracker: ScriptedSpeakerTracker(turnChanges: [0.5, 6]), recorder: recorder)
        defer { try? FileManager.default.removeItem(at: url) }

        await coordinator.transcribeSegment(upToFrame: 8 * 16_000)
        #expect(await recorder.durations == [6])
    }

    @Test @MainActor func fullBatchWaitsUntilTheSpeakerModelHasJudgedIt() async throws {
        let recorder = SliceRecorder()
        let (coordinator, url) = try coordinator(
            seconds: 40, tracker: ScriptedSpeakerTracker(lagSeconds: 5), recorder: recorder)
        defer { try? FileManager.default.removeItem(at: url) }

        await coordinator.transcribeSegment(upToFrame: 16 * 16_000)
        #expect(await recorder.durations.isEmpty)
        await coordinator.transcribeSegment(upToFrame: 19 * 16_000 + 8_000)
        #expect(await recorder.durations == [14])
    }

    @Test @MainActor func fullBatchStopsWaitingForASpeakerModelThatFellBehind() async throws {
        let recorder = SliceRecorder()
        let (coordinator, url) = try coordinator(
            seconds: 40, tracker: ScriptedSpeakerTracker(lagSeconds: 100), recorder: recorder)
        defer { try? FileManager.default.removeItem(at: url) }

        await coordinator.transcribeSegment(upToFrame: 30 * 16_000)
        #expect(await recorder.durations.isEmpty)
        await coordinator.transcribeSegment(upToFrame: 35 * 16_000)
        #expect(await recorder.durations == [14])
    }

    @Test @MainActor func stopCutsAtTheLastChangeAndKeepsTheShortTailWithItsOwnSpeaker() async throws {
        let recorder = SliceRecorder()
        let tracker = ScriptedSpeakerTracker(
            turnChanges: [10],
            ranges: [SpeakerTimeRange(speaker: 0, start: 0, end: 9.8), SpeakerTimeRange(speaker: 1, start: 10.2, end: 12)],
            lagSeconds: 100)
        let (coordinator, url) = try coordinator(seconds: 13, tracker: tracker, recorder: recorder)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = await coordinator.stop(currentFrame: 12 * 16_000)
        // A 2 s tail would otherwise be decoded again with the slice before it.
        #expect(await recorder.durations == [10, 2])
        #expect(await tracker.finishedAt == 12 * 16_000)
        #expect(coordinator.speakerRanges?.count == 2)
        #expect(coordinator.accumulatedSpans?.map(\.start) == [0, 10])
    }

    // MARK: Recording session

    private actor ScriptedTexts {
        private var texts: [String]
        init(_ texts: [String]) { self.texts = texts }
        func next() -> String? { texts.isEmpty ? nil : texts.removeFirst() }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for recording session state")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test @MainActor func recordingNoteShowsSpeakersWhileRecordingAndAfterStop() async throws {
        let audio = RecordingSessionTests.MockRecordingAudio()
        let pcmURL = try IncrementalTranscriptionCoordinatorTests().makeSilentCAF(seconds: 13)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        audio.currentPCMFileURL = pcmURL
        let transcription = TranscriptionService()
        transcription.languageSettingKey = { "auto" }
        let session = RecordingSession(audioService: audio, transcriptionService: transcription)
        var notes: [VoiceNote] = []
        session.onRecordingComplete = { notes.append($0) }
        let tracker = ScriptedSpeakerTracker(
            turnChanges: [5, 9],
            ranges: [SpeakerTimeRange(speaker: 4, start: 0.3, end: 4.7),
                     SpeakerTimeRange(speaker: 6, start: 5.3, end: 8.7),
                     SpeakerTimeRange(speaker: 4, start: 9.3, end: 11.8)])
        session.speakerTrackerFactory = { _ in tracker }
        let texts = ScriptedTexts(["第一个人说的话。", "第二个人回答。", "第一个人又说。"])
        var coordinator: IncrementalTranscriptionCoordinator?
        session.coordinatorFactory = { url in
            let created = IncrementalTranscriptionCoordinator(transcriptionService: transcription, recordingFileURL: url)
            created.snapTurnChange = { _, frame, _, _ in frame }
            created.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
            created.transcribeOverride = { @Sendable _ in await texts.next() }
            coordinator = created
            return created
        }

        session.startRecording()
        try await waitUntil { session.currentRecordingNote != nil }
        let note = try #require(notes.first)
        let live = try #require(coordinator)

        await live.transcribeSegment(upToFrame: 6 * 16_000)
        #expect(note.transcription == "第一个人说的话。")
        // One voice so far: plain text.
        #expect(note.speakerTranscript == nil)

        await live.transcribeSegment(upToFrame: 10 * 16_000)
        let duringRecording = try #require(note.speakerTranscript)
        #expect(duringRecording.units.map(\.speaker) == [1, 2])

        audio.recordingDuration = 12
        audio.currentFramePosition = 12 * 16_000
        session.stopRecording()
        try await waitUntil { !session.isRecording(note) && note.transcriptionState == .completed }

        #expect(note.transcription == "第一个人说的话。\n第二个人回答。\n第一个人又说。")
        let final = try #require(note.speakerTranscript)
        #expect(final.units.map(\.speaker) == [1, 2, 1])
        #expect(final.audioPath == note.audioFilePath)
        #expect(await tracker.finishedAt == 12 * 16_000)
    }

    @Test @MainActor func withoutASpeakerModelSlicingIsUnchanged() async throws {
        let recorder = SliceRecorder()
        let (coordinator, url) = try coordinator(
            seconds: 20, tracker: ScriptedSpeakerTracker(turnChanges: [5]), recorder: recorder)
        defer { try? FileManager.default.removeItem(at: url) }
        coordinator.speakerTracker = nil

        await coordinator.transcribeSegment(upToFrame: 8 * 16_000)
        #expect(await recorder.durations.isEmpty)
        await coordinator.transcribeSegment(upToFrame: 15 * 16_000)
        #expect(await recorder.durations == [14])
    }
}
