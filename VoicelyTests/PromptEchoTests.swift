//
//  PromptEchoTests.swift
//  VoicelyTests
//

import Foundation
import Testing
@testable import Voicely

/// A custom transcription prompt is prefilled into every ~29 s slice. On slices
/// with no intelligible speech Whisper hands that prompt back, often on a loop,
/// which used to be recorded as a hard per-segment failure.
struct PromptEchoTests {
    private let prompt = "This is a product planning meeting covering CoreML, WhisperKit and CloudKit."

    @Test func promptHandedBackVerbatimIsRecognized() {
        #expect(TranscriptionService.isPromptEcho(prompt, prompt: prompt))
    }

    @Test func promptRepeatedOnALoopIsRecognized() {
        let text = Array(repeating: prompt, count: 6).joined(separator: " ")
        #expect(TranscriptionService.isPromptEcho(text, prompt: prompt))
    }

    @Test func promptEchoSurvivesPunctuationAndCaseDifferences() {
        let text = "this is a product planning meeting covering coreml, whisperkit and cloudkit"
        #expect(TranscriptionService.isPromptEcho(text, prompt: prompt))
    }

    @Test func realSpeechIsNotAPromptEcho() {
        let text = "Let's start with the CoreML conversion and then look at the CloudKit schema."
        #expect(!TranscriptionService.isPromptEcho(text, prompt: prompt))
    }

    @Test func speechThatQuotesThePromptIsNotAnEcho() {
        let text = prompt + " We agreed to ship the sliced transcription path first."
        #expect(!TranscriptionService.isPromptEcho(text, prompt: prompt))
    }

    @Test func aVeryShortPromptNeverMatches() {
        // Two characters would collide with ordinary speech.
        #expect(!TranscriptionService.isPromptEcho("ok", prompt: "ok"))
    }

    @Test func emptyPromptNeverMatches() {
        #expect(!TranscriptionService.isPromptEcho("anything at all", prompt: ""))
    }

    @Test func verdictSeparatesEchoFromDecoderLoop() {
        #expect(TranscriptionService.promptedOutputVerdict(for: prompt, prompt: prompt) == .promptEcho)

        let loop = String(repeating: "thanks everyone, ", count: 120)
        #expect(TranscriptionService.promptedOutputVerdict(for: loop, prompt: prompt) == .degenerate)

        let speech = "The CloudKit schema still needs the new fields deployed to production."
        #expect(TranscriptionService.promptedOutputVerdict(for: speech, prompt: prompt) == .usable)
    }
}

struct SegmentFailureSummaryTests {
    @Test func summaryNamesEachCauseWithItsCount() {
        let ranges = [
            SegmentFailureRange(startFrame: 0, endFrame: 16_000, reason: "repetitive output"),
            SegmentFailureRange(startFrame: 16_000, endFrame: 32_000, reason: "blank output"),
            SegmentFailureRange(startFrame: 32_000, endFrame: 48_000, reason: "repetitive output")
        ]
        #expect(SegmentedAudioTranscriber.failureSummary(for: ranges)
                == "3 segment(s) failed after retry: repetitive output ×2, blank output ×1")
    }

    @Test func missingReasonsStillProduceAUsableSummary() {
        let ranges = [SegmentFailureRange(startFrame: 0, endFrame: 16_000)]
        #expect(SegmentedAudioTranscriber.failureSummary(for: ranges)
                == "1 segment(s) failed after retry: unknown error ×1")
    }

    @Test func sidecarsWrittenBeforeReasonsWereRecordedStillDecode() throws {
        let legacy = """
        {"lastFrame":16000,"totalFrames":32000,"accumulatedText":"hi",
         "failedRanges":[{"startFrame":0,"endFrame":16000}],
         "updatedAt":760000000}
        """
        let progress = try JSONDecoder().decode(
            SegmentedTranscriptionProgress.self, from: Data(legacy.utf8))
        #expect(progress.failedRanges.count == 1)
        #expect(progress.failedRanges[0].reason == nil)
    }
}
