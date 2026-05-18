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

    // MARK: Helpers

    @Test func defaultIntervalHelperUsesThirtySeconds() {
        #expect(IncrementalTranscriptionTiming.defaultIntervalSeconds == 30)
        #expect(IncrementalTranscriptionTiming.sanitizedIntervalSeconds(30) == 30)
        #expect(IncrementalTranscriptionTiming.sanitizedIntervalSeconds(10) == 30)
    }

    @Test func legacyMinuteMigrationDoesNotCreateTenSecondChunks() throws {
        let suiteName = "VoicelyIncrementalTimingTests_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(10, forKey: IncrementalTranscriptionTiming.legacyIntervalMinutesStorageKey)

        let migratedSeconds = IncrementalTranscriptionTiming.migrateLegacyMinuteValueIfNeeded(in: defaults)

        #expect(migratedSeconds == 30)
        #expect(migratedSeconds != 10)
        #expect(defaults.integer(forKey: IncrementalTranscriptionTiming.intervalSecondsStorageKey) == 30)
        #expect(IncrementalTranscriptionTiming.resolvedIntervalSeconds(from: defaults) == 30)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func voiceActivityCutUsesRecentSilenceBeforeTarget() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 26.0, amplitude: 0.08),
            (seconds: 0.8, amplitude: 0.0),
            (seconds: 3.2, amplitude: 0.08)
        ])

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000
        )

        #expect(cutFrame >= 420_000)
        #expect(cutFrame <= 435_200)
        #expect(cutFrame < 480_000)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutFallsBackToTargetWhenNoSilenceExists() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000
        )

        #expect(cutFrame == 480_000)

        try? FileManager.default.removeItem(at: pcmURL)
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

    @Test @MainActor func stopAccumulatesTranscriptFromSegments() async throws {
        let pcmURL = try makeSilentCAF(seconds: 30)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        coordinator.transcribeOverride = { @Sendable _ in "hello" }

        await coordinator.transcribeSegment(upToFrame: 160_000)
        await coordinator.transcribeSegment(upToFrame: 320_000)

        #expect(coordinator.accumulatedTranscript == "hello\nhello")
    }

    @Test @MainActor func stopWaitsForInFlightSegmentAndPendingFinalSegment() async throws {
        let pcmURL = try makeSilentCAF(seconds: 30)
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
            await coordinator.transcribeSegment(upToFrame: 160_000)
        }
        await harness.waitForCallCount(1)

        let stopRecorder = StopResultRecorder()
        let stopTask = Task { @MainActor in
            let transcript = await coordinator.stop(currentFrame: 320_000)
            await stopRecorder.setTranscript(transcript)
            return transcript
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await stopRecorder.recordedTranscript() == nil)

        await harness.resumeFirstCall()
        let transcript = await stopTask.value
        await segmentTask.value

        #expect(transcript == "segment 1\nsegment 2")
        #expect(coordinator.accumulatedTranscript == "segment 1\nsegment 2")
        #expect(await harness.numberOfCalls() == 2)
    }

    @Test @MainActor func transcriptCallbackPublishesAccumulatedTranscript() async throws {
        let pcmURL = try makeSilentCAF(seconds: 30)
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

        await coordinator.transcribeSegment(upToFrame: 160_000)
        await coordinator.transcribeSegment(upToFrame: 320_000)

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

        await coordinator.transcribeSegment(upToFrame: 160_000)

        #expect(coordinator.accumulatedTranscript.isEmpty)
    }
}
