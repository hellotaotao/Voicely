//
//  RetranscriptionGapTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Release builds have no debug log, so the note's failure message is the only
/// place a per-slice cause survives. A bare count could not tell a prompt-driven
/// decoder loop apart from unreadable audio.
@Suite(.serialized)
struct RetranscriptionGapTests {
    @Test @MainActor func failureMessageNamesEachCause() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)   // 3 segments
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Meeting", audioFilePath: url.path)   // no prior transcript

        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            // Segment 1 succeeds; segments 2 and 3 fail through their two retries.
            await calls.incrementAndGet() == 1
                ? .transcribed(.init(text: "slice 1", duration: 1, modelIdentifier: "m"))
                : .whisperError("repetitive output")
        }
        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionOutcome == .failed)
        #expect(note.transcriptionLastErrorMessage
                == "2 segment(s) failed after retry: repetitive output ×2")
        let firstGap = SegmentedAudioTranscriber.placeholder(
            forStart: 29 * 16_000, end: 58 * 16_000, sampleRate: 16_000)
        #expect(note.transcription.contains("slice 1"))
        #expect(note.transcription.contains(firstGap))
    }

    @Test @MainActor func causesAreListedSeparatelyWhenTheyDiffer() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Meeting", audioFilePath: url.path)

        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            // Segment 1 succeeds, segment 2 loops (calls 2-4), segment 3 is blank (5-7).
            let n = await calls.incrementAndGet()
            if n == 1 { return .transcribed(.init(text: "slice 1", duration: 1, modelIdentifier: "m")) }
            return n <= 4 ? .whisperError("repetitive output") : .whisperError("blank output")
        }
        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcriptionLastErrorMessage
                == "2 segment(s) failed after retry: repetitive output ×1, blank output ×1")
    }

    /// A partially failed re-transcription still keeps the previous transcript and
    /// parks the new text as a retained attempt. Confirmed here so the added
    /// diagnostics do not quietly change that.
    @Test @MainActor func partialFailureStillPreservesAnExistingTranscript() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        let note = VoiceNote(title: "Meeting", audioFilePath: url.path)
        note.transcription = "the previous transcript"

        let calls = Counter()
        transcriber.transcribeSegmentOutcome = { _ in
            await calls.incrementAndGet() == 1
                ? .transcribed(.init(text: "slice 1", duration: 1, modelIdentifier: "m"))
                : .whisperError("repetitive output")
        }
        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(note.transcription == "the previous transcript")
        #expect(note.transcriptionOutcome == .failed)
        #expect(store.listRetainedAttempts(for: note.id).first?.text.contains("slice 1") == true)
    }
}
