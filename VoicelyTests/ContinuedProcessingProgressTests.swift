//
//  ContinuedProcessingProgressTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// iOS expires a continued processing task whose progress does not move for
/// about 30 s ("Task has not reported progress within expected cadence, marking
/// stalled"). WhisperKit only advances its own progress when a decode window
/// ends, and every slice is one window, so on a locked phone a single 29 s slice
/// decoding in ~40 s was enough to get the task killed at a few percent.
@Suite(.serialized)
struct ContinuedProcessingProgressTests {

    // MARK: Timestamp tokens

    private let timeTokenBegin = 50_365

    private func timestamp(_ seconds: Double) -> Int {
        timeTokenBegin + Int((seconds / TranscriptionService.timestampTokenSeconds).rounded())
    }

    @Test func latestTimestampGivesThePositionInsideTheWindow() throws {
        // <|sot|> <|0.00|> text <|5.00|><|5.00|> text <|14.50|>
        let tokens = [50_258, timestamp(0), 1_234, 5_678, timestamp(5), timestamp(5), 999, timestamp(14.5)]
        let fraction = try #require(TranscriptionService.decodedWindowFraction(
            tokens: tokens, timeTokenBegin: timeTokenBegin, windowSeconds: 29))
        #expect(abs(fraction - 14.5 / 29) < 1e-9)
    }

    @Test func theFurthestTimestampWinsEvenIfItIsNotTheLastToken() throws {
        let tokens = [timestamp(12), 1_234, timestamp(3)]
        let fraction = try #require(TranscriptionService.decodedWindowFraction(
            tokens: tokens, timeTokenBegin: timeTokenBegin, windowSeconds: 24))
        #expect(abs(fraction - 0.5) < 1e-9)
    }

    @Test func noTimestampYetMeansNoPosition() {
        #expect(TranscriptionService.decodedWindowFraction(
            tokens: [50_258, 1_234, 5_678], timeTokenBegin: timeTokenBegin, windowSeconds: 29) == nil)
    }

    @Test func positionNeverPassesTheEndOfTheWindow() {
        #expect(TranscriptionService.decodedWindowFraction(
            tokens: [timestamp(30)], timeTokenBegin: timeTokenBegin, windowSeconds: 20) == 1)
    }

    @Test func aZeroLengthWindowHasNoPosition() {
        #expect(TranscriptionService.decodedWindowFraction(
            tokens: [timestamp(3)], timeTokenBegin: timeTokenBegin, windowSeconds: 0) == nil)
    }

    @Test func onlySingleWindowAudioIsMeasuredByTimestamps() throws {
        let short = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 29)
        let long = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 45)
        defer {
            try? FileManager.default.removeItem(at: short)
            try? FileManager.default.removeItem(at: long)
        }
        let seconds = try #require(TranscriptionService.singleWindowSeconds(of: short))
        #expect(abs(seconds - 29) < 1e-6)
        // Timestamps restart in every window, so they cannot measure a longer file.
        #expect(TranscriptionService.singleWindowSeconds(of: long) == nil)
    }

    // MARK: Saved-audio re-transcription

    @Test @MainActor func decoderProgressInsideASegmentMovesTheWholeFileForward() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 70)   // 29 + 29 + 12 s
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        let note = VoiceNote(title: "Meeting", audioFilePath: url.path)

        var observed: [Float] = []
        var call = 0
        transcriber.transcribeSegmentOutcome = { [unowned transcriber] _ in
            call += 1
            transcriber.reportSegmentProgress(0.5)
            observed.append(service.progressByNoteID[note.id] ?? -1)
            // A retry or temperature fallback restarts the decoder at zero; the
            // reported progress must not move backwards.
            transcriber.reportSegmentProgress(0.2)
            observed.append(service.progressByNoteID[note.id] ?? -1)
            return .transcribed(.init(text: "slice \(call)", duration: 1, modelIdentifier: "m"))
        }
        await transcriber.transcribe(note: note, sourceURL: url)

        let halfwayThroughEach: [Float] = [14.5 / 70, 43.5 / 70, 64.0 / 70].map { Float($0) }
        #expect(observed == halfwayThroughEach.flatMap { [$0, $0] })
        #expect(note.transcriptionOutcome == .transcribed)
    }

    @Test @MainActor func progressIsIgnoredBetweenSegments() async throws {
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        // No segment is decoding, so a late callback from a finished decode has
        // nothing to attach to.
        transcriber.reportSegmentProgress(0.9)
        #expect(service.progressByNoteID.isEmpty)
    }

    // MARK: Recording finalization

    @MainActor final class Samples { var values: [Double] = [] }

    @Test @MainActor func finalizationProgressMovesWhileASliceDecodes() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: url)
        let samples = Samples()
        coordinator.transcribeOverride = { @Sendable [weak coordinator] _ in
            await MainActor.run {
                guard let coordinator else { return }
                coordinator.reportSliceProgress(0.5)
                samples.values.append(coordinator.finalizationProgress)
                coordinator.reportSliceProgress(0.2)   // never moves backwards
                samples.values.append(coordinator.finalizationProgress)
            }
            return "hello"
        }

        // Stopping at 40 s with nothing transcribed live flushes 0–29 s, then 29–40 s.
        _ = await coordinator.stop(currentFrame: 640_000)

        let halfwayThroughFirst = Double(232_000) / 640_000        // 14.5 s of 40 s
        let halfwayThroughTail = Double(464_000 + 88_000) / 640_000 // 29 s + 5.5 s of 40 s
        #expect(samples.values == [halfwayThroughFirst, halfwayThroughFirst,
                                   halfwayThroughTail, halfwayThroughTail])
        #expect(coordinator.finalizationProgress == 1)
    }
}
