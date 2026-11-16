import Foundation
import Testing
@testable import Voicely

struct SpeakerTimingPlanTests {
    @Test func storedTimingUsesAbsoluteSecondsAndExcludesTheAlignerDownload() async throws {
        let text = "Hello world."
        let spans = [TranscriptSpan(length: text.utf16.count, start: 0, end: 2700, wordTimings: [
            TranscriptWordTiming(offset: 0, length: 5, start: 2501, end: 2502),
            TranscriptWordTiming(offset: 6, length: 6, start: 2503, end: 2504)
        ])]
        let plan = try #require(SpeakerTimingPlan(text: text, spans: spans))
        #expect(plan.fallbackSpans.isEmpty)
        #expect(!plan.needsAlignmentDownload(alignmentInstalled: false))

        // No audio or alignment model is consulted when we already have all the timing.
        let missingAudio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tokens = try await SpeakerTranscriptAligner.align(
            audioURL: missingAudio, plan: plan, isEnglish: true
        )
        #expect(tokens.map(\.start) == [2501, 2503])
        #expect(tokens.map(\.range) == [NSRange(location: 0, length: 5), NSRange(location: 6, length: 5)])
    }

    @Test func onlyUntimedSpeechNeedsAlignmentAndKeepsOriginalUTF16Offsets() throws {
        let opener = "🙂 Yes.\n"
        let unavailable = "[0:30–0:35 transcription unavailable]\n"
        let gap = "早上好。\n"
        let closer = "Thanks."
        let spans = [
            TranscriptSpan(length: opener.utf16.count, start: 0, end: 10, wordTimings: [
                TranscriptWordTiming(offset: 3, length: 4, start: 1, end: 2)
            ]),
            TranscriptSpan(length: unavailable.utf16.count, start: 30, end: 35),
            TranscriptSpan(length: gap.utf16.count, start: 48, end: 51),
            TranscriptSpan(length: closer.utf16.count, start: 60, end: 72, wordTimings: [
                TranscriptWordTiming(offset: 0, length: 7, start: 61, end: 62)
            ])
        ]
        let plan = try #require(SpeakerTimingPlan(text: opener + unavailable + gap + closer, spans: spans))
        let fallback = try #require(plan.fallbackSpans.first)
        #expect(plan.fallbackSpans.count == 1)
        #expect(fallback.text == gap)
        #expect(fallback.utf16Offset == opener.utf16.count + unavailable.utf16.count)
        #expect(fallback.start == 48)
        #expect(plan.storedTokens.map(\.range) == [
            NSRange(location: 3, length: 3),
            NSRange(location: (opener + unavailable + gap).utf16.count, length: 6)
        ])
        #expect(plan.needsAlignmentDownload(alignmentInstalled: false))
        #expect(!plan.needsAlignmentDownload(alignmentInstalled: true))
    }

    @Test func corruptAndInsufficientCoverageDoNotSilentlySuppressAlignment() throws {
        let text = "Hello world."
        let corruptRanges: [[TranscriptWordTiming]] = [
            [TranscriptWordTiming(offset: Int.max, length: 4, start: 1, end: 2)],
            [TranscriptWordTiming(offset: 0, length: 11, start: 9, end: 10)],
            [TranscriptWordTiming(offset: 0, length: 5, start: 1, end: 2)],
            [TranscriptWordTiming(offset: 0, length: 11, start: 2, end: 2)]
        ]
        for timings in corruptRanges {
            let span = TranscriptSpan(length: text.utf16.count, start: 0, end: 4, wordTimings: timings)
            let plan = try #require(SpeakerTimingPlan(text: text, spans: [span]))
            #expect(plan.storedTokens.isEmpty)
            #expect(plan.fallbackSpans.count == 1)
        }
    }

    @Test func aWordMayCrossASliceCutIfItsMidpointBelongsToThatSlice() throws {
        let text = "Yes."
        let span = TranscriptSpan(length: text.utf16.count, start: 10, end: 20, wordTimings: [
            TranscriptWordTiming(offset: 0, length: 4, start: 9.8, end: 10.4)
        ])
        let plan = try #require(SpeakerTimingPlan(text: text, spans: [span]))
        #expect(plan.fallbackSpans.isEmpty)
        #expect(plan.storedTokens.first?.start == 9.8)
    }

    @Test func placeholderOnlyDoesNotPromptForTheAlignmentModel() throws {
        let unavailable = "[0:30–0:35 transcription unavailable]"
        let plan = try #require(SpeakerTimingPlan(text: unavailable, spans: [
            TranscriptSpan(length: unavailable.utf16.count, start: 30, end: 35)
        ]))
        #expect(!plan.hasSpeech)
        #expect(!plan.needsAlignmentDownload(alignmentInstalled: false))
    }
}
