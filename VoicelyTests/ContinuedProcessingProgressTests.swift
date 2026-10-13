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
/// stalled"), so progress has to keep moving while a recording is decoded.
@Suite(.serialized)
struct ContinuedProcessingProgressTests {

    // MARK: Saved-audio re-transcription

    @Test @MainActor func decoderProgressInsideASegmentMovesTheWholeFileForward() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)   // 14 + 14 + 12 s
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

        let halfwayThroughEach: [Float] = [7.0 / 40, 21.0 / 40, 34.0 / 40].map { Float($0) }
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

    // MARK: Decode work heartbeat

    @Test @MainActor func workStillAdvancesAtTheEndWithoutFinishingTheTask() {
        let reporter = ContinuedProcessingProgress()
        reporter.update(0.99)
        var previous = reporter.progress.fractionCompleted
        for _ in 0..<500 {
            let units = reporter.progress.completedUnitCount
            reporter.advanceForWork()
            #expect(reporter.progress.completedUnitCount > units)
            #expect(reporter.progress.fractionCompleted > previous)
            #expect(!reporter.progress.isFinished)
            previous = reporter.progress.fractionCompleted
        }
        reporter.complete(success: true)
        #expect(reporter.progress.isFinished)
    }

    @Test @MainActor func audioPositionAloneCannotFinishTheSystemTask() {
        let reporter = ContinuedProcessingProgress()
        reporter.update(1)
        #expect(!reporter.progress.isFinished)
        reporter.complete(success: false)
        #expect(!reporter.progress.isFinished)
    }

    @Test @MainActor func completedTasksIgnoreLateProgressAndWork() {
        for success in [false, true] {
            let reporter = ContinuedProcessingProgress()
            reporter.update(0.99)
            reporter.advanceForWork()
            reporter.complete(success: success)
            let completed = reporter.progress.completedUnitCount
            let total = reporter.progress.totalUnitCount
            reporter.update(1)
            reporter.advanceForWork()
            reporter.complete(success: !success)
            #expect(reporter.progress.completedUnitCount == completed)
            #expect(reporter.progress.totalUnitCount == total)
            #expect(reporter.progress.isFinished == success)
        }
    }

    @Test @MainActor func pendingProgressHandlesInvalidPositionsWithoutRegressing() {
        let reporter = ContinuedProcessingProgress()
        reporter.update(0.5)
        for fraction in [Double.nan, .infinity, -1, 0.2] { reporter.update(fraction) }
        #expect(reporter.progress.completedUnitCount == 5_000)
        #expect(reporter.progress.totalUnitCount == 10_000)
    }

    @Test @MainActor func decoderCompletionIsHeldUntilOutputValidationFinishes() async {
        let model = TranscriptionServiceTests.ToggleableModelManager(backend: .coreML)
        model.setLoaded(true)
        let service = TranscriptionService(modelManager: model)
        var values: [Float] = []
        service.transcribeImpl = { _, progress in
            progress(1)
            #expect(values.allSatisfy { $0 < 1 })
            // A prompt-free retry starts at zero after the first pass finished.
            progress(0.2)
            progress(1)
            #expect(values.allSatisfy { $0 < 1 })
            return .text("Validated transcript")
        }
        _ = await service.transcribeAudioOutcome(filePath: "/tmp/progress-test.caf") { values.append($0) }
        #expect(values.last == 1)
    }

    @Test @MainActor func unusableOutputNeverReportsCompletedAudio() async {
        let model = TranscriptionServiceTests.ToggleableModelManager(backend: .coreML)
        model.setLoaded(true)
        let service = TranscriptionService(modelManager: model)
        var values: [Float] = []
        service.transcribeImpl = { _, progress in
            progress(1)
            return .engineError("repetitive output")
        }
        _ = await service.transcribeAudioOutcome(filePath: "/tmp/progress-test.caf") { values.append($0) }
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0 < 1 })
    }

    @Test @MainActor func cancelledDecodeNeverReportsCompletedAudio() async {
        let model = TranscriptionServiceTests.LoadedModelManager(backend: .coreML)
        let service = TranscriptionService(modelManager: model)
        var values: [Float] = []
        service.transcribeImpl = { _, progress in
            progress(1)
            return .cancelled
        }
        _ = await service.transcribeAudioOutcome(filePath: "/tmp/progress-test.caf") { values.append($0) }
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0 < 1 })
    }

    @Test @MainActor func shortSavedJobDoesNotRepublishProgressAfterCompletion() async {
        let service = TranscriptionService(modelManager: TranscriptionServiceTests.LoadedModelManager(backend: .coreML))
        let driver = RecordingProgressDriver()
        service.requiresBackgroundExecution = true
        service.continuedProcessingDriver = driver
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        service.audioDurationProvider = { _ in 10 }
        service.transcribeImpl = { _, progress in
            progress(0.5)
            return .text("A complete saved transcript")
        }
        let note = VoiceNote(title: "Short", audioFilePath: "/tmp/progress-test.caf")
        _ = await service.requestTranscription(for: note)
        await Task.yield()
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(driver.handle.completions == [true])
        #expect(service.progressByNoteID[note.id] == nil)
    }

    @Test @MainActor func savedTimerRecordsRealProgressAt99PercentAndStopsOnExpiration() async {
        let driver = RecordingProgressDriver()
        let counter = WorkCounter()
        var expired = false
        let continuation = SavedTranscriptionContinuation(
            driver: driver, title: "Meeting", decodeWork: { counter.steps },
            heartbeatInterval: .milliseconds(20), onExpiration: { expired = true })
        // Preparation without decoder activity must not fabricate progress.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(driver.handle.samples.count == 1)
        continuation.update(progress: 0.99)
        let units = driver.handle.reporter.progress.completedUnitCount
        counter.steps += 1
        await waitUntil(.seconds(2)) { driver.handle.reporter.progress.completedUnitCount > units }
        #expect(driver.handle.reporter.progress.completedUnitCount > units)
        #expect(!driver.handle.reporter.progress.isFinished)
        driver.handle.expirationHandler?()
        let samples = driver.handle.samples.count
        counter.steps += 1
        try? await Task.sleep(for: .milliseconds(80))
        #expect(expired)
        #expect(driver.handle.completions == [false])
        #expect(driver.handle.samples.count == samples)
    }

    @Test @MainActor func finalizationTimerRecordsRealProgressAt99Percent() async {
        let driver = RecordingProgressDriver()
        let counter = WorkCounter()
        let continuation = RecordingFinalizationContinuation(
            driver: driver, title: "Finishing", subtitle: "Meeting",
            decodeWork: { counter.steps }) { 0.99 }
        counter.steps += 1
        await waitUntil(.seconds(3)) { driver.handle.reporter.progress.completedUnitCount > 9_900 }
        #expect(driver.handle.reporter.progress.completedUnitCount > 9_900)
        #expect(!driver.handle.reporter.progress.isFinished)
        continuation.finish(success: true)
        #expect(driver.handle.reporter.progress.isFinished)
    }

    @MainActor final class WorkCounter { var steps: UInt64 = 0 }

    @Test @MainActor func heartbeatSeesOnlyNewDecoderSteps() {
        let counter = WorkCounter()
        var heartbeat = DecodeWorkHeartbeat(decodeWork: { counter.steps })
        let beforeAnyWork = heartbeat.decoderAdvanced()
        counter.steps += 3
        let afterWork = heartbeat.decoderAdvanced()
        let withoutNewWork = heartbeat.decoderAdvanced()
        #expect(!beforeAnyWork)
        #expect(afterWork)
        #expect(!withoutNewWork)
    }

    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test @MainActor func savedTaskMovesWhileTheDecoderWorksAndStopsWhenItStops() async {
        let driver = RecordingSessionTests.FakeContinuedProcessingDriver()
        let counter = WorkCounter()
        let continuation = SavedTranscriptionContinuation(
            driver: driver, title: "Meeting", decodeWork: { counter.steps },
            heartbeatInterval: .milliseconds(20), onExpiration: {})

        // Same audio re-decoded: the position stands still but tokens keep coming.
        counter.steps += 40
        await waitUntil(.seconds(2)) { driver.handle.workAdvances >= 1 }
        #expect(driver.handle.workAdvances >= 1)
        #expect(driver.handle.progressUpdates.allSatisfy { $0 == 0 })

        // A decoder that produces nothing is not reported as working.
        let idle = driver.handle.workAdvances
        try? await Task.sleep(for: .milliseconds(150))
        #expect(driver.handle.workAdvances == idle)

        continuation.finish(success: true)
        counter.steps += 40
        try? await Task.sleep(for: .milliseconds(150))
        #expect(driver.handle.workAdvances == idle)
    }

    @Test @MainActor func finalizationTaskMovesWhileTheDecoderWorks() async {
        let driver = RecordingSessionTests.FakeContinuedProcessingDriver()
        let counter = WorkCounter()
        let continuation = RecordingFinalizationContinuation(
            driver: driver, title: "Finishing transcription", subtitle: "Meeting",
            decodeWork: { counter.steps }) { 0.4 }

        counter.steps += 40
        await waitUntil(.seconds(3)) { driver.handle.workAdvances >= 1 }
        #expect(driver.handle.workAdvances >= 1)

        let idle = driver.handle.workAdvances
        try? await Task.sleep(for: .milliseconds(1_200))
        #expect(driver.handle.workAdvances == idle)
        continuation.finish(success: true)
    }

    // MARK: Recording finalization

    @MainActor final class Samples { var values: [Double] = [] }

    @Test @MainActor func finalizationProgressMovesWhileASliceDecodes() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 25)
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

        // Stopping at 25 s with nothing transcribed live flushes 0–14 s, then 14–25 s.
        _ = await coordinator.stop(currentFrame: 400_000)

        let halfwayThroughFirst = Double(112_000) / 400_000        // 7 s of 25 s
        let halfwayThroughTail = Double(224_000 + 88_000) / 400_000 // 14 s + 5.5 s of 25 s
        #expect(samples.values == [halfwayThroughFirst, halfwayThroughFirst,
                                   halfwayThroughTail, halfwayThroughTail])
        #expect(coordinator.finalizationProgress == 1)
    }
}
