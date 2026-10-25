import Foundation
import Testing
@testable import Voicely

struct TranscriptTimelineTests {
    /// "aaa\n" 0–10 s, "bbb\n" 10–20 s, "ccc" 20–30 s.
    private let text = "aaa\nbbb\nccc"
    private let spans = [
        TranscriptSpan(length: 4, start: 0, end: 10),
        TranscriptSpan(length: 4, start: 10, end: 20),
        TranscriptSpan(length: 3, start: 20, end: 30)
    ]

    private func lengths(_ spans: [TranscriptSpan]?) -> [Int] { spans?.map(\.length) ?? [] }
    private func times(_ spans: [TranscriptSpan]?) -> [[Double]] { spans?.map { [$0.start, $0.end] } ?? [] }

    // MARK: Building

    @Test func builderGivesTheJoiningLineBreakToThePreviousSpan() {
        var builder = TranscriptSpanBuilder()
        builder.append("aaa", start: 0, end: 10)
        builder.append("bbb", start: 10, end: 20)
        builder.append("ccc", start: 20, end: 30)
        #expect(builder.spans == spans)
        #expect(TranscriptTimeline.fits(spans, text))
    }

    @Test func builderDropsTheTimelineWhenResumedTextHasNoSpans() {
        var builder = TranscriptSpanBuilder(resumedText: "saved", resumedSpans: nil)
        builder.append("new", start: 14, end: 28)
        #expect(builder.spans == nil)
    }

    @Test func spansThatDoNotTileTheTextDoNotFit() {
        #expect(!TranscriptTimeline.fits(spans, text + "!"))
        #expect(!TranscriptTimeline.fits([], ""))
    }

    // MARK: Edits

    @Test func anEditInsideOneSpanKeepsEveryTime() {
        let edited = TranscriptTimeline.reanchored(spans, from: text, to: "aaa\nbXYZb\nccc")
        #expect(lengths(edited) == [4, 6, 3])
        #expect(times(edited) == times(spans))
    }

    @Test func anEditAcrossABoundaryMergesTheSpansItTouches() {
        // "a\nb" spans the 10 s boundary; where it now falls is unknown.
        let edited = TranscriptTimeline.reanchored(spans, from: text, to: "aaQbb\nccc")
        #expect(lengths(edited) == [6, 3])
        #expect(times(edited) == [[0, 20], [20, 30]])
    }

    @Test func deletingAWholeSpanDropsIt() {
        let edited = TranscriptTimeline.reanchored(spans, from: text, to: "aaa\nccc")
        #expect(lengths(edited) == [4, 3])
        #expect(times(edited) == [[0, 10], [20, 30]])
    }

    @Test func textInsertedAtABoundaryJoinsTheSpanBefore() {
        let edited = TranscriptTimeline.reanchored(spans, from: text, to: "aaa\nXbbb\nccc")
        #expect(lengths(edited) == [5, 4, 3])
        #expect(times(edited) == times(spans))
    }

    @Test func joiningTwoParagraphsKeepsBothSpans() {
        let edited = TranscriptTimeline.reanchored(spans, from: text, to: "aaabbb\nccc")
        #expect(lengths(edited) == [3, 4, 3])
        #expect(times(edited) == times(spans))
    }

    @Test func separateEditsAreHandledApart() {
        let edited = TranscriptTimeline.reanchored(spans, from: text, to: "xaa\nbbb\nccy")
        #expect(lengths(edited) == [4, 4, 3])
        #expect(times(edited) == times(spans))
    }

    @Test func rewritingEverythingLeavesOneSpanOverTheWholeRecording() {
        let edited = TranscriptTimeline.reanchored(spans, from: text, to: "完全不同的内容")
        #expect(lengths(edited) == [7])
        #expect(times(edited) == [[0, 30]])
    }

    @Test func clearingTheTextClearsTheTimeline() {
        #expect(TranscriptTimeline.reanchored(spans, from: text, to: "") == nil)
    }

    // MARK: Sentences

    @Test func sentencesGetTimesByTheirPositionInTheirSpan() {
        // "一二。三四五六。\n" is 9 characters over 0–9 s; "ab. v3.5" 6+ over 10–18 s.
        let text = "一二。三四五六。\nab. v3.5"
        let spans = [TranscriptSpan(length: 9, start: 0, end: 9), TranscriptSpan(length: 8, start: 10, end: 18)]
        let units = TranscriptTimeline.units(text: text, spans: spans)
        let pieces = units.map { (text as NSString).substring(with: $0.range) }
        #expect(pieces == ["一二。", "三四五六。\n", "ab.", " v3.5"])
        #expect(units.map(\.start) == [0, 3, 10, 13])
        #expect(units.map(\.spanStart) == [0, 0, 10, 10])
    }

    @Test func playbackTimeLightsTheLastSentenceStartedSoFar() {
        let units = TranscriptTimeline.units(text: text, spans: spans)
        #expect(TranscriptTimeline.unitIndex(at: -1, in: units) == nil)
        #expect(TranscriptTimeline.unitIndex(at: 15, in: units) == 1)
        #expect(TranscriptTimeline.unitIndex(at: 99, in: units) == 2)
        #expect(TranscriptTimeline.unitIndex(containing: 5, in: units) == 1)
    }

    @Test func aSeekStartsALittleEarlyButNeverBeforeItsSpan() {
        let inside = TranscriptUnit(range: NSRange(location: 0, length: 1), start: 13, spanStart: 10)
        let first = TranscriptUnit(range: NSRange(location: 0, length: 1), start: 10.4, spanStart: 10)
        #expect(TranscriptTimeline.seekTime(for: inside) == 12)
        #expect(TranscriptTimeline.seekTime(for: first) == 10)
    }

    // MARK: Note

    @Test @MainActor func noteKeepsSpansOnlyWhileTheyFitItsText() {
        let note = VoiceNote(title: "n")
        note.setTranscript(text, spans: spans)
        #expect(note.transcriptSpans == spans)

        note.setTranscript("other", spans: spans)
        #expect(note.transcriptSpansData == nil)

        note.setTranscript(text, spans: spans)
        note.transcription = text + "?"   // a write that skipped setTranscript
        #expect(note.transcriptSpans == nil)

        // Same length, different text: what an iCloud merge of the two fields
        // from different edits can produce.
        note.setTranscript(text, spans: spans)
        note.transcription = "a\nbbbbb\nccc"
        #expect(note.transcriptSpans == nil)
    }

    @Test func aTappedSentenceStaysLitUntilPlaybackReachesIt() {
        // Units start at 0, 10, 20 s; the tap on unit 1 seeks to 9 s.
        let units = TranscriptTimeline.units(text: text, spans: spans)
        let preroll = TranscriptTimeline.highlight(at: 9.5, holding: 1, from: 9, in: units)
        #expect(preroll.index == 1 && preroll.hold == 1)
        let reached = TranscriptTimeline.highlight(at: 10.2, holding: 1, from: 9, in: units)
        #expect(reached.index == 1 && reached.hold == nil)
    }

    @Test func draggingBackBeforeTheSeekPointReleasesTheTappedSentence() {
        let units = TranscriptTimeline.units(text: text, spans: spans)
        let dragged = TranscriptTimeline.highlight(at: 3, holding: 1, from: 9, in: units)
        #expect(dragged.index == 0 && dragged.hold == nil)
    }

    @Test @MainActor func editingANoteCarriesItsSpans() {
        let note = VoiceNote(title: "n")
        note.setTranscript(text, spans: spans)
        note.applyEditedTranscript("aaa\nbXYZb\nccc")
        #expect(lengths(note.transcriptSpans) == [4, 6, 3])
    }

    // MARK: Transcription paths

    @Test @MainActor func segmentedTranscriptionRecordsWhereEachSliceSits() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "same", duration: 1, modelIdentifier: "m"))
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcription == "same\nsame\nsame")
        #expect(lengths(note.transcriptSpans) == [5, 5, 4])
        #expect(times(note.transcriptSpans) == [[0, 14], [14, 28], [28, 40]])
    }

    @Test @MainActor func resumedTranscriptionContinuesTheSavedTimeline() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        store.save(.init(lastFrame: 14 * 16_000, totalFrames: 40 * 16_000, accumulatedText: "saved",
                         failedRanges: [], updatedAt: Date(),
                         spans: [TranscriptSpan(length: 5, start: 0, end: 14)]), for: note.id)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "new", duration: 1, modelIdentifier: "m"))
        }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcription == "saved\nnew\nnew")
        #expect(times(note.transcriptSpans) == [[0, 14], [14, 28], [28, 40]])
    }

    @Test @MainActor func aCheckpointWithoutSpansLeavesTheNoteUntimed() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        store.save(.init(lastFrame: 14 * 16_000, totalFrames: 40 * 16_000, accumulatedText: "saved",
                         failedRanges: [], updatedAt: Date()), for: note.id)
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: "new", duration: 1, modelIdentifier: "m"))
        }
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcription == "saved\nnew\nnew")
        #expect(note.transcriptSpansData == nil)
    }

    @Test @MainActor func liveSlicesCarryTheirPlaceInTheRecording() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: TranscriptionService(),
                                                              recordingFileURL: url)
        coordinator.transcribeOverride = { @Sendable _ in "hello" }
        coordinator.resolveVoiceActivityCut = { _, _, end, _ in end }
        await coordinator.transcribeSegment(upToFrame: 240_000)
        await coordinator.transcribeSegment(upToFrame: 480_000)
        #expect(coordinator.accumulatedTranscript == "hello\nhello")
        #expect(times(coordinator.accumulatedSpans) == [[0, 15], [15, 30]])
        #expect(lengths(coordinator.accumulatedSpans) == [6, 5])
    }
}
