//
//  IncrementalTranscriptionCoordinatorTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

@Suite(.serialized)
struct IncrementalTranscriptionCoordinatorTests {
    actor SegmentTranscriptionHarness {
        private var callCount = 0
        private var callWaiters: [CheckedContinuation<Void, Never>] = []
        private var firstCallContinuation: CheckedContinuation<Void, Never>?

        func transcribe(_: String) async -> String? {
            callCount += 1
            let currentCall = callCount
            resumeCallWaiters()

            if currentCall == 1 {
                await withCheckedContinuation { continuation in
                    firstCallContinuation = continuation
                }
            }

            return "segment \(currentCall)"
        }

        func waitForCallCount(_ expectedCount: Int) async {
            while callCount < expectedCount {
                await withCheckedContinuation { continuation in
                    callWaiters.append(continuation)
                }
            }
        }

        func resumeFirstCall() {
            firstCallContinuation?.resume()
            firstCallContinuation = nil
        }

        func numberOfCalls() -> Int {
            callCount
        }

        private func resumeCallWaiters() {
            let waiters = callWaiters
            callWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    actor StopResultRecorder {
        private var transcript: String?

        func setTranscript(_ transcript: String) {
            self.transcript = transcript
        }

        func recordedTranscript() -> String? {
            transcript
        }
    }

    actor TranscriptSequence {
        private var transcripts: [String]

        init(_ transcripts: [String]) {
            self.transcripts = transcripts
        }

        func next() -> String? {
            guard !transcripts.isEmpty else { return nil }
            return transcripts.removeFirst()
        }
    }

    /// Per-call slice results; nil simulates a failed slice. Calls past the
    /// script fail too.
    actor ScriptedSliceResults {
        private var results: [String?]
        private(set) var calls = 0

        init(_ results: [String?]) {
            self.results = results
        }

        func next() -> String? {
            calls += 1
            guard !results.isEmpty else { return nil }
            return results.removeFirst()
        }
    }

    struct FakeNeuralVAD: NeuralVoiceActivityDetecting {
        let frameProbabilities: [(startFrame: Int, endFrame: Int, speechProbability: Double)]

        func speechProbabilities(in _: [Float]) throws -> [NeuralVoiceActivityFrame] {
            frameProbabilities.map {
                NeuralVoiceActivityFrame(
                    startFrame: $0.startFrame,
                    endFrame: $0.endFrame,
                    speechProbability: $0.speechProbability
                )
            }
        }
    }

    /// Counts streaming calls so tests can assert chunked scans and early exit.
    final class CountingNeuralVAD: NeuralVoiceActivityDetecting {
        private(set) var callCount = 0
        let speechProbability: Double

        init(speechProbability: Double) {
            self.speechProbability = speechProbability
        }

        func speechProbabilities(in samples: [Float]) throws -> [NeuralVoiceActivityFrame] {
            callCount += 1
            return [NeuralVoiceActivityFrame(
                startFrame: 0,
                endFrame: samples.count,
                speechProbability: speechProbability
            )]
        }
    }


    static func makeVADFrames(
        durationSeconds: Double,
        silentRanges: [Range<Double>],
        frameSamples: Int = SileroNeuralVoiceActivityDetector.chunkSize,
        sampleRate: Double = Double(SileroNeuralVoiceActivityDetector.sampleRate)
    ) -> [(startFrame: Int, endFrame: Int, speechProbability: Double)] {
        let totalSamples = Int((durationSeconds * sampleRate).rounded())
        var frames: [(startFrame: Int, endFrame: Int, speechProbability: Double)] = []
        var start = 0
        while start < totalSamples {
            let end = min(start + frameSamples, totalSamples)
            let midpointSeconds = (Double(start + end) / 2.0) / sampleRate
            let isSilent = silentRanges.contains { $0.contains(midpointSeconds) }
            frames.append((
                startFrame: start,
                endFrame: end,
                speechProbability: isSilent ? 0.10 : 0.80
            ))
            start = end
        }
        return frames
    }

    // MARK: Helpers

    @Test func liveCadenceFollowsTheSliceLimits() {
        #expect(IncrementalTranscriptionTiming.defaultIntervalSeconds == 14)
        #expect(IncrementalTranscriptionTiming.minimumCutSeconds == 7)
    }

    @Test func voiceActivityCutWaitsWhileBatchIsStillFilling() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 8.0, amplitude: 0.08),
            (seconds: 1.0, amplitude: 0.0),
            (seconds: 1.0, amplitude: 0.08)
        ])

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 160_000,
            targetSegmentSeconds: 29
        )

        #expect(cutFrame == 0)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutDoesNotRunBeforeFullBatchAccumulates() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 22.0, amplitude: 0.08)
        ])
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 7,
            silentRanges: [0.4..<1.0]
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 352_000,
            targetSegmentSeconds: 29,
            neuralVoiceActivityDetector: fakeVAD
        )

        #expect(cutFrame == 0)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutPicksSilenceAfterMinimumCutPoint() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])
        // Analysis window starts at minimumCutSeconds (7 s); silence at
        // 2.0–2.8 s into the window is 9.0–9.8 s into the recording.
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 7,
            silentRanges: [2.0..<2.8]
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        // Cut in the middle of the pause (9.4 s), within one VAD frame.
        #expect(abs(cutFrame - 150_400) <= 576)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutPrefersLaterSilenceAmongEquals() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 7,
            silentRanges: [1.0..<2.0, 4.0..<5.0]
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        // Equal-confidence silences: the later one wins so less audio carries
        // over, cut in its middle (11.5 s).
        #expect(abs(cutFrame - 184_000) <= 576)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutFallsBackToBatchEndWhenNeuralVADFindsNoSilence() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 7,
            silentRanges: []
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        // Batch is capped at targetSegmentSeconds (14 s = 224 000 frames).
        #expect(cutFrame == 224_000)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutFallsBackToDeepestShortDipInsteadOfBatchEnd() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])
        // Both dips are shorter than the 0.35 s minimum pause; the deeper one
        // at 4.0–4.2 s into the window (11.0–11.2 s) wins.
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 7,
            quietRanges: [(2.0..<2.2, 0.20), (4.0..<4.2, 0.02)]
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        #expect(abs(cutFrame - 177_600) <= 576)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutPrefersFullPauseOverDeeperShortDip() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])
        // A shallow 0.6 s pause at 2.0–2.6 s (9.0–9.6 s) beats a 0.15 s dip
        // that is deeper.
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 7,
            quietRanges: [(2.0..<2.6, 0.25), (4.0..<4.15, 0.0)]
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        #expect(abs(cutFrame - 148_800) <= 576)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutCapsBatchAtTargetEvenWhenMoreAudioIsAvailable() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 40.0, amplitude: 0.08)
        ])
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 7,
            silentRanges: []
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 640_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        // Overshoot past one batch carries over instead of producing a >15 s chunk.
        #expect(cutFrame == 224_000)

        try? FileManager.default.removeItem(at: pcmURL)
    }



    static func makeNeuralVADFrames(
        seconds: Double,
        silentRanges: [Range<Double>],
        frameSeconds: Double = Double(SileroNeuralVoiceActivityDetector.chunkSize) / Double(SileroNeuralVoiceActivityDetector.sampleRate)
    ) -> [(startFrame: Int, endFrame: Int, speechProbability: Double)] {
        makeNeuralVADFrames(seconds: seconds, quietRanges: silentRanges.map { ($0, 0.02) }, frameSeconds: frameSeconds)
    }

    /// Speech at 0.82 everywhere except `quietRanges`, which carry their own probability.
    static func makeNeuralVADFrames(
        seconds: Double,
        quietRanges: [(range: Range<Double>, probability: Double)],
        frameSeconds: Double = Double(SileroNeuralVoiceActivityDetector.chunkSize) / Double(SileroNeuralVoiceActivityDetector.sampleRate)
    ) -> [(startFrame: Int, endFrame: Int, speechProbability: Double)] {
        var frames: [(startFrame: Int, endFrame: Int, speechProbability: Double)] = []
        var time = 0.0
        while time < seconds {
            let endTime = min(seconds, time + frameSeconds)
            let midpoint = (time + endTime) / 2
            let quiet = quietRanges.first { $0.range.contains(midpoint) }
            frames.append((
                startFrame: Int((time * 16_000).rounded()),
                endFrame: Int((endTime * 16_000).rounded()),
                speechProbability: quiet?.probability ?? 0.82
            ))
            time = endTime
        }
        return frames
    }

    /// Creates a Float32 16 kHz mono CAF file with explicit energy segments.
    func makeEnergyPatternCAF(segments: [(seconds: Double, amplitude: Float)]) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let totalFrames = segments.reduce(0) { partialResult, segment in
            partialResult + Int((segment.seconds * 16000).rounded())
        }
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        )!
        buffer.frameLength = AVAudioFrameCount(totalFrames)

        let samples = buffer.floatChannelData![0]
        var cursor = 0
        for segment in segments {
            let segmentFrames = Int((segment.seconds * 16000).rounded())
            let end = min(totalFrames, cursor + segmentFrames)
            for frame in cursor..<end {
                samples[frame] = segment.amplitude
            }
            cursor = end
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_energy_\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Creates a silent Float32 16 kHz mono CAF file with the given duration.
    func makeSilentCAF(seconds: Double) throws -> URL {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test @MainActor func coordinatorInitialisesWithEmptyTranscript() throws {
        let service = TranscriptionService()
        let pcmURL = try makeSilentCAF(seconds: 5)
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        #expect(coordinator.accumulatedTranscript == "")
    }

    @Test @MainActor func extractSegmentProducesCorrectFrameCount() throws {
        // 5-second CAF file at 16 kHz = 80 000 frames
        let pcmURL = try makeSilentCAF(seconds: 5)

        // Verify the source file is readable
        let sourceCheck = try AVAudioFile(forReading: pcmURL)
        #expect(sourceCheck.length == 80_000)

        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )

        // Extract frames 0 – 32 000 (first 2 seconds)
        guard let segmentURL = coordinator.extractSegmentPublic(from: 0, to: 32_000) else {
            Issue.record("extractSegmentPublic returned nil")
            return
        }

        let segFile = try AVAudioFile(forReading: segmentURL)
        // Allow small rounding difference due to AVAudioFile block-aligned reads
        let diff = abs(segFile.length - 32_000)
        #expect(diff < 512, "Expected ~32000 frames, got \(segFile.length)")

        try? FileManager.default.removeItem(at: segmentURL)
    }

    @Test @MainActor func finishedTelemetryDoesNotRestartDuringFinalFlush() async throws {
        let url = try makeSilentCAF(seconds: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: url)
        coordinator.configureTelemetry(noteID: UUID())
        coordinator.transcribeOverride = { _ in
            Issue.record("Ended coordinator must not decode a new segment")
            return "unexpected"
        }
        coordinator.finishTelemetry()
        let text = await coordinator.stop(currentFrame: 30 * 16_000)
        #expect(text.isEmpty)
    }

    @Test @MainActor func stopAccumulatesTranscriptFromSegments() async throws {
        let pcmURL = try makeSilentCAF(seconds: 40)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        coordinator.transcribeOverride = { @Sendable _ in "hello" }

        await coordinator.transcribeSegment(upToFrame: 240_000)
        await coordinator.transcribeSegment(upToFrame: 480_000)

        #expect(coordinator.accumulatedTranscript == "hello\nhello")
    }

    @Test @MainActor func stopWaitsForInFlightSegmentAndPendingFinalSegment() async throws {
        let pcmURL = try makeSilentCAF(seconds: 40)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        let harness = SegmentTranscriptionHarness()
        coordinator.transcribeOverride = { @Sendable path in
            await harness.transcribe(path)
        }

        let segmentTask = Task { @MainActor in
            await coordinator.transcribeSegment(upToFrame: 240_000)
        }
        await harness.waitForCallCount(1)

        let stopRecorder = StopResultRecorder()
        let stopTask = Task { @MainActor in
            let transcript = await coordinator.stop(currentFrame: 480_000)
            await stopRecorder.setTranscript(transcript)
            return transcript
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await stopRecorder.recordedTranscript() == nil)

        await harness.resumeFirstCall()
        let transcript = await stopTask.value
        await segmentTask.value

        #expect(transcript == "segment 1\nsegment 2\nsegment 3")
        #expect(coordinator.accumulatedTranscript == "segment 1\nsegment 2\nsegment 3")
        #expect(await harness.numberOfCalls() == 3)
    }

    @Test func extractionRejectsTruncatedInputAndUsesUniquePaths() throws {
        let source = try makeSilentCAF(seconds: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let first = try #require(IncrementalTranscriptionCoordinator.extractSegment(
            fileURL: source, from: 0, to: 32_000, segmentIndex: 1))
        let second = try #require(IncrementalTranscriptionCoordinator.extractSegment(
            fileURL: source, from: 0, to: 32_000, segmentIndex: 1))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(first != second)
        #expect(try AVAudioFile(forReading: first).length == 32_000)
        #expect(IncrementalTranscriptionCoordinator.extractSegment(
            fileURL: source, from: 0, to: 48_000, segmentIndex: 2) == nil)
        #expect(IncrementalTranscriptionCoordinator.extractSegment(
            fileURL: source, from: 5, to: 0, segmentIndex: 2) == nil)
    }

    actor SliceDurationRecorder {
        private(set) var durations: [Double] = []

        func record(_ path: String) -> String? {
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
            durations.append(Double(file.length) / file.processingFormat.sampleRate)
            return "slice \(durations.count)"
        }
    }

    @Test @MainActor func finalFlushDrainsBacklogInEngineSizedWindows() async throws {
        let pcmURL = try makeSilentCAF(seconds: 36)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(), recordingFileURL: pcmURL)
        let recorder = SliceDurationRecorder()
        coordinator.transcribeOverride = { @Sendable path in await recorder.record(path) }

        _ = await coordinator.stop(currentFrame: 36 * 16_000)

        let durations = await recorder.durations
        #expect(durations == [14, 14, 8])
        #expect(!coordinator.requiresFullTranscription)
    }

    @Test @MainActor func sliceTheEngineRejectedLiveIsMarkedAtStopWithoutDecodingAgain() async throws {
        let pcmURL = try makeSilentCAF(seconds: 36)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(), recordingFileURL: pcmURL)
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        // Live: slice 1 succeeds, slice 2 fails. Stop: only the tail is decoded.
        let script = ScriptedSliceResults(["first", nil, "third"])
        coordinator.transcribeOverride = { @Sendable _ in await script.next() }

        await coordinator.transcribeSegment(upToFrame: 15 * 16_000)
        await coordinator.transcribeSegment(upToFrame: 30 * 16_000)
        #expect(coordinator.failedSliceCount == 1)
        #expect(coordinator.accumulatedTranscript == "first")
        #expect(coordinator.remainingAudioSeconds(upTo: 36 * 16_000) == 8)

        let transcript = await coordinator.stop(currentFrame: 36 * 16_000)

        let gap = SegmentedAudioTranscriber.placeholder(forStart: 14 * 16_000, end: 28 * 16_000, sampleRate: 16_000)
        #expect(transcript == "first\n\(gap)\nthird")
        #expect(!coordinator.requiresFullTranscription)
        #expect(coordinator.unrecoveredSliceCount == 1)
        #expect(coordinator.finalizationProgress == 1)
        #expect(await script.calls == 3)
    }

    final class SwitchableModelManager: ModelManager {
        var loaded = false
        override func isModelLoaded() -> Bool { loaded }
    }

    @Test @MainActor func sliceThatNeverReachedTheEngineIsDecodedAtStopInItsOriginalPosition() async throws {
        let pcmURL = try makeSilentCAF(seconds: 36)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let service = TranscriptionService()
        let modelManager = SwitchableModelManager(backend: .coreML)
        service.setModelManager(modelManager)
        var decoded = 0
        var engineThrows = false
        service.transcribeImpl = { _, _ in
            if engineThrows { return .engineError(TranscriptionService.engineFailurePrefix + "GPU work refused") }
            decoded += 1
            return .text("slice \(decoded)")
        }
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        var published: [String] = []
        coordinator.transcriptCallback = { published.append($0) }

        // The model is still loading for slice 1; the engine throws on slice 2.
        await coordinator.transcribeSegment(upToFrame: 15 * 16_000)
        modelManager.loaded = true
        engineThrows = true
        await coordinator.transcribeSegment(upToFrame: 30 * 16_000)
        engineThrows = false
        #expect(coordinator.failedSliceCount == 2)
        #expect(coordinator.remainingAudioSeconds(upTo: 36 * 16_000) == 36)

        let transcript = await coordinator.stop(currentFrame: 36 * 16_000)

        // Decode order was the tail, then slices 1 and 2 again.
        #expect(transcript == "slice 2\nslice 3\nslice 1")
        #expect(published.last == transcript)
        #expect(!coordinator.requiresFullTranscription)
        #expect(coordinator.unrecoveredSliceCount == 0)
        #expect(coordinator.failedSliceCount == 0)
        #expect(coordinator.finalizationProgress == 1)
    }

    @Test @MainActor func sliceTheEngineKeepsRejectingIsRetriedOnceThenSettledAsGap() async throws {
        let pcmURL = try makeSilentCAF(seconds: 25)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let service = TranscriptionService()
        let modelManager = SwitchableModelManager(backend: .coreML)
        modelManager.loaded = true
        service.setModelManager(modelManager)
        var calls = 0
        service.transcribeImpl = { _, _ in
            calls += 1
            return calls == 1 ? .text("first slice")
                : .engineError(TranscriptionService.engineFailurePrefix + "GPU work refused")
        }
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)

        let transcript = await coordinator.stop(currentFrame: 25 * 16_000)

        let gap = SegmentedAudioTranscriber.placeholder(forStart: 14 * 16_000, end: 25 * 16_000, sampleRate: 16_000)
        #expect(transcript == "first slice\n\(gap)")
        #expect(calls == 3)  // slice 1, the tail, and one retry of the tail
        #expect(!coordinator.requiresFullTranscription)
        #expect(coordinator.unrecoveredSliceCount == 1)
        #expect(coordinator.finalizationProgress == 1)
        #expect(coordinator.remainingAudioSeconds(upTo: 25 * 16_000) == 0)
    }

    @Test @MainActor func remainingAudioIncludesTheSliceStillBeingTranscribed() async throws {
        let pcmURL = try makeSilentCAF(seconds: 25)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(), recordingFileURL: pcmURL)
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        let harness = SegmentTranscriptionHarness()
        coordinator.transcribeOverride = { @Sendable path in await harness.transcribe(path) }

        let live = Task { @MainActor in await coordinator.transcribeSegment(upToFrame: 15 * 16_000) }
        await harness.waitForCallCount(1)

        // The 14 s slice is still in flight when recording stops at 16 s.
        #expect(coordinator.remainingAudioSeconds(upTo: 16 * 16_000) == 16)

        await harness.resumeFirstCall()
        await live.value
        #expect(coordinator.remainingAudioSeconds(upTo: 16 * 16_000) == 2)
    }

    @Test @MainActor func sliceThatKeepsFailingIsMarkedInPlaceInsteadOfWholeFileRecovery() async throws {
        let pcmURL = try makeSilentCAF(seconds: 25)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(), recordingFileURL: pcmURL)
        let script = ScriptedSliceResults(["first slice"])
        coordinator.transcribeOverride = { @Sendable _ in await script.next() }

        let transcript = await coordinator.stop(currentFrame: 25 * 16_000)

        let gap = SegmentedAudioTranscriber.placeholder(forStart: 14 * 16_000, end: 25 * 16_000, sampleRate: 16_000)
        #expect(transcript == "first slice\n\(gap)")
        #expect(!coordinator.requiresFullTranscription)
        #expect(coordinator.unrecoveredSliceCount == 1)
        #expect(coordinator.finalizationProgress == 1)
        #expect(await script.calls == 2)
    }

    @Test @MainActor func sliceThatCannotBeDecodedStillHandsRecordingToQueue() async throws {
        let pcmURL = try makeSilentCAF(seconds: 25)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        // No model is loaded, so every attempt reports the model as unavailable.
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: TranscriptionService(), recordingFileURL: pcmURL)

        let transcript = await coordinator.stop(currentFrame: 25 * 16_000)

        #expect(transcript.isEmpty)
        #expect(coordinator.requiresFullTranscription)
        #expect(coordinator.unrecoveredSliceCount == 0)
    }

    @Test @MainActor func stopTranscribesFinalTailShorterThanMinimumChunk() async throws {
        let pcmURL = try makeSilentCAF(seconds: 25)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        coordinator.transcribeOverride = { @Sendable _ in "hello" }

        // First segment cuts at one full batch (~14 s), leaving a tail
        // shorter than a batch when the recording stops at 40 s.
        await coordinator.transcribeSegment(upToFrame: 240_000)
        let transcript = await coordinator.stop(currentFrame: 320_000)

        #expect(transcript == "hello\nhello")

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test @MainActor func stopQueuedBehindInFlightSegmentTranscribesShortTail() async throws {
        let pcmURL = try makeSilentCAF(seconds: 25)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        let harness = SegmentTranscriptionHarness()
        coordinator.transcribeOverride = { @Sendable path in
            await harness.transcribe(path)
        }

        let segmentTask = Task { @MainActor in
            await coordinator.transcribeSegment(upToFrame: 240_000)
        }
        await harness.waitForCallCount(1)

        // Stop while the first segment is still transcribing; the remaining
        // tail is shorter than the minimum chunk but must not be dropped.
        let stopTask = Task { @MainActor in
            await coordinator.stop(currentFrame: 320_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        await harness.resumeFirstCall()
        let transcript = await stopTask.value
        await segmentTask.value

        #expect(transcript == "segment 1\nsegment 2")
        #expect(await harness.numberOfCalls() == 2)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test @MainActor func transcriptCallbackPublishesAccumulatedTranscript() async throws {
        let pcmURL = try makeSilentCAF(seconds: 40)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        let sequence = TranscriptSequence(["first", "second"])
        var updates: [String] = []
        coordinator.transcribeOverride = { @Sendable _ in
            await sequence.next()
        }
        coordinator.transcriptCallback = { transcript in
            updates.append(transcript)
        }

        await coordinator.transcribeSegment(upToFrame: 240_000)
        await coordinator.transcribeSegment(upToFrame: 480_000)

        #expect(updates == ["first", "first\nsecond"])
        #expect(coordinator.accumulatedTranscript == "first\nsecond")
    }

    @Test @MainActor func noAudioPlaceholderDoesNotPolluteAccumulatedTranscript() async throws {
        let pcmURL = try makeSilentCAF(seconds: 15)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        coordinator.transcribeOverride = { @Sendable _ in " [no audio] " }

        await coordinator.transcribeSegment(upToFrame: 240_000)

        #expect(coordinator.accumulatedTranscript.isEmpty)
    }

    @Test func noSpeechPlaceholdersAreRemovedFromSegmentText() {
        #expect(IncrementalTranscriptionCoordinator.sanitizedSegmentText(" [Silence]\n[BLANK_AUDIO]\n(humming) ") == nil)
        #expect(IncrementalTranscriptionCoordinator.sanitizedSegmentText("hello\n[BLANK_AUDIO]\n(music)") == "hello")
    }

    @Test func neuralSpeechAnalyzerStreamsFileAndStopsAtFirstSpeech() throws {
        let fileURL = try makeSilentCAF(seconds: 60)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let detector = CountingNeuralVAD(speechProbability: 0.82)

        let result = try NeuralSpeechAnalyzer.containsProbableSpeech(at: fileURL, detector: detector)

        #expect(result == true)
        // Speech in the first chunk must stop the scan immediately.
        #expect(detector.callCount == 1)
    }

    @Test func neuralSpeechAnalyzerScansWholeSilentFileInChunks() throws {
        let fileURL = try makeSilentCAF(seconds: 35)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let detector = CountingNeuralVAD(speechProbability: 0.02)

        let result = try NeuralSpeechAnalyzer.containsProbableSpeech(at: fileURL, detector: detector)

        #expect(result == false)
        // 35 s of audio in ~10 s streaming chunks: several calls, bounded memory.
        #expect(detector.callCount >= 4)
    }

    @Test func neuralSpeechAnalyzerRejectsConfidentSilence() throws {
        let detector = FakeNeuralVAD(frameProbabilities: Self.makeVADFrames(
            durationSeconds: 1.0,
            silentRanges: [0.0..<1.0]
        ))

        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 16_000), detector: detector) == false)
    }

    @Test func neuralSpeechAnalyzerRequiresSustainedUncertaintyButAcceptsSpeech() throws {
        let uncertainDetector = FakeNeuralVAD(frameProbabilities: [
            (startFrame: 0, endFrame: 576, speechProbability: 0.45)
        ])
        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 576), detector: uncertainDetector) == false)

        let sustainedDetector = FakeNeuralVAD(frameProbabilities: [
            (startFrame: 0, endFrame: 4_032, speechProbability: 0.45)
        ])
        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 4_032), detector: sustainedDetector))

        let shortSpeechDetector = FakeNeuralVAD(frameProbabilities: [
            (startFrame: 0, endFrame: 576, speechProbability: 0.9)
        ])
        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 576), detector: shortSpeechDetector))

        let speechDetector = FakeNeuralVAD(frameProbabilities: Self.makeVADFrames(
            durationSeconds: 0.35,
            silentRanges: []
        ))
        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 5_600), detector: speechDetector) == true)
    }
}
