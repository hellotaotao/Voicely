import Foundation
import AudioCommon
import os
import Testing
@testable import Voicely

struct SpeakerTranscriptAlignerTests {
    @Test func reusesStoredTimingWithoutReportingAlignmentProgress() async throws {
        let plan = try #require(SpeakerTimingPlan(text: "Hello.", spans: [
            TranscriptSpan(length: 6, start: 0, end: 1, wordTimings: [
                TranscriptWordTiming(offset: 0, length: 5, start: 0.125, end: 0.75)
            ])
        ]))
        let updates = OSAllocatedUnfairLock(initialState: [SpeakerProcessingProgress]())
        let tokens = try await SpeakerTranscriptAligner.align(
            audioURL: URL(fileURLWithPath: "/unused"), plan: plan, isEnglish: true,
            onProgress: { update in updates.withLock { $0.append(update) } }
        )
        #expect(tokens.map(\.start) == [0.125])
        #expect(updates.withLock { $0.isEmpty })
    }

    @Test func mapsMixedTextAcrossPunctuationAndUTF16Offsets() {
        let source = "😀你好。 Hello!"
        let words = [
            AlignedWord(text: "你", startTime: 0.25, endTime: 0.5),
            AlignedWord(text: "好", startTime: 0.5, endTime: 0.75),
            AlignedWord(text: "。Hello!", startTime: 1, endTime: 1.5)
        ]
        let tokens = SpeakerTranscriptAligner.mapTokens(words, in: source, utf16Offset: 7, spanStart: 30, duration: 2)
        #expect(tokens.map(\.range) == [
            NSRange(location: 9, length: 1),
            NSRange(location: 10, length: 1),
            NSRange(location: 13, length: 5)
        ])
        #expect(tokens.map(\.start) == [30.25, 30.5, 31])
        #expect(tokens.map(\.end) == [30.5, 30.75, 31.5])
    }

    @Test func omitsInvalidTimesWithoutAssigningTheNextRepeatedWordToTheWrongRange() {
        let words = [
            AlignedWord(text: "yes", startTime: 0, endTime: 0),
            AlignedWord(text: "yes", startTime: 1, endTime: 1.25),
            AlignedWord(text: "okay", startTime: 2.5, endTime: 2.75)
        ]
        let tokens = SpeakerTranscriptAligner.mapTokens(words, in: "yes yes okay",
                                                       utf16Offset: 0, spanStart: 0, duration: 2)
        #expect(tokens.map(\.range) == [NSRange(location: 4, length: 3)])
    }

    @Test func neverSkipsUnmatchedSpeechToFindARepeatedWordLater() {
        let words = [
            AlignedWord(text: "first", startTime: 0, endTime: 0.5),
            AlignedWord(text: "third", startTime: 1, endTime: 1.5)
        ]
        let tokens = SpeakerTranscriptAligner.mapTokens(words, in: "first second third",
                                                       utf16Offset: 0, spanStart: 0, duration: 2)
        #expect(tokens.map(\.range) == [NSRange(location: 0, length: 5)])
    }

    @Test func groupsAPunctuationJoinButDoesNotIncludeSurroundingPunctuation() {
        let words = [
            AlignedWord(text: "“don't”", startTime: 0, endTime: 0.5),
            AlignedWord(text: "go-now。", startTime: 0.75, endTime: 1.25)
        ]
        let tokens = SpeakerTranscriptAligner.mapTokens(words, in: "“DON'T” go-now。",
                                                       utf16Offset: 0, spanStart: 0, duration: 2)
        #expect(tokens.map(\.range) == [NSRange(location: 1, length: 5), NSRange(location: 8, length: 6)])
    }

    @Test func skipsEmojiDecorationAndMatchesCanonicallyEquivalentSpeech() {
        let words = [AlignedWord(text: "café", startTime: 0, endTime: 0.5)]
        let tokens = SpeakerTranscriptAligner.mapTokens(words, in: "❤️ cafe\u{0301}",
                                                       utf16Offset: 0, spanStart: 0, duration: 2)
        #expect(tokens.map(\.range) == [NSRange(location: 3, length: 5)])
    }
}

#if DEBUG && targetEnvironment(macCatalyst)
import AVFoundation

/// Optional end-to-end run using local synthetic voices and the exact release weights.
/// Uses the generated fixtures only when both are available to the test host.
private enum SpeakerTranscriptAlignmentFixtures {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    static let audio = repository.appendingPathComponent("build/speaker-alignment-fixtures/mixed.wav")
    static let model = repository.appendingPathComponent("build/speaker-alignment-model")

    static var isConfigured: Bool {
        [audio, model.appendingPathComponent("model.safetensors")].allSatisfy {
            FileManager.default.isReadableFile(atPath: $0.path)
        }
    }
}

@Suite(.serialized, .enabled(if: SpeakerTranscriptAlignmentFixtures.isConfigured))
struct SpeakerTranscriptAlignmentReplayTests {
    @Test func alignsEnglishAndChineseToTheirRecordedSpans() async throws {
        let fixtures = SpeakerTranscriptAlignmentFixtures.self
        let english = "Good morning everyone. The next meeting will begin tomorrow.\n"
        let chinese = "今天上午开会。会议结束以后请把文件发给我。"
        let audioFile = try AVAudioFile(forReading: fixtures.audio)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let updates = OSAllocatedUnfairLock(initialState: [SpeakerProcessingProgress]())
        let tokens = try await SpeakerTranscriptAligner.alignWithLocalModelForTesting(
            audioURL: fixtures.audio, text: english + chinese,
            spans: [
                TranscriptSpan(length: english.utf16.count, start: 0, end: 5),
                TranscriptSpan(length: chinese.utf16.count, start: 5, end: duration)
            ],
            isEnglish: false, modelDirectory: fixtures.model,
            onProgress: { update in updates.withLock { $0.append(update) } }
        )
        let progress = updates.withLock { $0 }
        #expect(progress.map(\.completedUnits) == [0, 1, 2])
        #expect(progress.map(\.totalUnits) == [2, 2, 2])
        let source = (english + chinese) as NSString
        let englishTokens = tokens.filter { $0.range.location < english.utf16.count }
        let chineseTokens = tokens.filter { $0.range.location >= english.utf16.count }
        #expect(englishTokens.count >= 8)
        // A few short syllables can collapse to one timestamp; those words
        // stay unknown rather than being assigned an invented duration.
        #expect(chineseTokens.count >= 15)
        #expect(englishTokens.allSatisfy { $0.start >= 0 && $0.end <= 5 })
        #expect(chineseTokens.allSatisfy { $0.start >= 5 && $0.end <= duration })
        let alignedText = tokens.map { source.substring(with: $0.range) }
        #expect(alignedText.contains("meeting"))
        #expect(alignedText.contains("上"))
        #expect(alignedText.contains("我"))
    }

    @Test func reusesExactEnglishTimesWhileAligningAnUntimedChineseSpan() async throws {
        let fixtures = SpeakerTranscriptAlignmentFixtures.self
        let english = "Good morning everyone. The next meeting will begin tomorrow.\n"
        let chinese = "今天上午开会。会议结束以后请把文件发给我。"
        let audioFile = try AVAudioFile(forReading: fixtures.audio)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        var offset = 0
        let wordTimings = english.split(whereSeparator: \.isWhitespace).enumerated().map { index, word in
            let start = 0.125 + Double(index) * 0.25
            let timing = TranscriptWordTiming(offset: offset, length: word.utf16.count, start: start, end: start + 0.125)
            offset += word.utf16.count + 1
            return timing
        }
        let updates = OSAllocatedUnfairLock(initialState: [SpeakerProcessingProgress]())
        let tokens = try await SpeakerTranscriptAligner.alignWithLocalModelForTesting(
            audioURL: fixtures.audio, text: english + chinese,
            spans: [
                TranscriptSpan(length: english.utf16.count, start: 0, end: 5, wordTimings: wordTimings),
                TranscriptSpan(length: chinese.utf16.count, start: 5, end: duration)
            ],
            isEnglish: false, modelDirectory: fixtures.model,
            onProgress: { update in updates.withLock { $0.append(update) } }
        )
        let progress = updates.withLock { $0 }
        #expect(progress.map(\.completedUnits) == [0, 1])
        #expect(progress.map(\.totalUnits) == [1, 1])
        let englishTokens = tokens.filter { $0.range.location < english.utf16.count }
        let chineseTokens = tokens.filter { $0.range.location >= english.utf16.count }
        #expect(englishTokens.map(\.start) == wordTimings.map(\.start))
        #expect(chineseTokens.count >= 15)
        #expect(chineseTokens.allSatisfy { $0.start >= 5 && $0.end <= duration })
    }
}
#endif
