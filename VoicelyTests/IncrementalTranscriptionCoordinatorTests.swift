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

    @Test func defaultIntervalHelperUsesWhisperSafeCadence() {
        #expect(IncrementalTranscriptionTiming.defaultIntervalSeconds == 29)
        #expect(IncrementalTranscriptionTiming.minimumEffectiveSpeechChunkSeconds == 20)
        #expect(IncrementalTranscriptionTiming.sanitizedIntervalSeconds(30) == 29)
        #expect(IncrementalTranscriptionTiming.sanitizedIntervalSeconds(20) == 29)
        #expect(IncrementalTranscriptionTiming.sanitizedIntervalSeconds(10) == 29)
    }

    @Test func storedIntervalChoicesNoLongerChangeRuntimeCadence() throws {
        let suiteName = "VoicelyFixedIncrementalTimingTests_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(20, forKey: IncrementalTranscriptionTiming.intervalSecondsStorageKey)

        #expect(IncrementalTranscriptionTiming.resolvedIntervalSeconds(from: defaults) == 29)

        defaults.set(30, forKey: IncrementalTranscriptionTiming.intervalSecondsStorageKey)

        #expect(IncrementalTranscriptionTiming.resolvedIntervalSeconds(from: defaults) == 29)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func legacyMinuteMigrationDoesNotCreateTenSecondChunks() throws {
        let suiteName = "VoicelyIncrementalTimingTests_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(10, forKey: IncrementalTranscriptionTiming.legacyIntervalMinutesStorageKey)

        let migratedSeconds = IncrementalTranscriptionTiming.migrateLegacyMinuteValueIfNeeded(in: defaults)

        #expect(migratedSeconds == 29)
        #expect(migratedSeconds != 10)
        #expect(defaults.integer(forKey: IncrementalTranscriptionTiming.intervalSecondsStorageKey) == 29)
        #expect(IncrementalTranscriptionTiming.resolvedIntervalSeconds(from: defaults) == 29)

        defaults.removePersistentDomain(forName: suiteName)
    }


    @Test func adaptiveThresholdGetsLessStrictAfterTargetTime() {
        let config = IncrementalVoiceActivityCutConfiguration.default
        let early = IncrementalTranscriptionCoordinator.adaptiveCutConfidenceThreshold(
            elapsedSeconds: 23.2,
            targetSeconds: 29,
            forcedCutSeconds: 29,
            configuration: config
        )
        let target = IncrementalTranscriptionCoordinator.adaptiveCutConfidenceThreshold(
            elapsedSeconds: 29,
            targetSeconds: 29,
            forcedCutSeconds: 29,
            configuration: config
        )
        let late = IncrementalTranscriptionCoordinator.adaptiveCutConfidenceThreshold(
            elapsedSeconds: 30,
            targetSeconds: 29,
            forcedCutSeconds: 29,
            configuration: config
        )

        #expect(early > target)
        #expect(target > late)
    }

    @Test func voiceActivityCutWaitsBeforeEarliestBoundary() throws {
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

    @Test func voiceActivityCutCanStartLookingForStrongSilenceAroundTwentyTwoSeconds() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 22.0, amplitude: 0.08)
        ])
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 2,
            silentRanges: [0.4..<1.0]
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 352_000,
            targetSegmentSeconds: 29,
            neuralVoiceActivityDetector: fakeVAD
        )

        #expect(cutFrame > 320_000)
        #expect(cutFrame < 352_000)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutUsesRecentNeuralVADSilenceBeforeTarget() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 8,
            silentRanges: [4.0..<4.8]
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        #expect(cutFrame >= 420_000)
        #expect(cutFrame <= 435_200)
        #expect(cutFrame < 480_000)

        try? FileManager.default.removeItem(at: pcmURL)
    }

    @Test func voiceActivityCutFallsBackToTargetWhenNeuralVADFindsNoSilence() throws {
        let pcmURL = try makeEnergyPatternCAF(segments: [
            (seconds: 30.0, amplitude: 0.08)
        ])
        let fakeVAD = FakeNeuralVAD(frameProbabilities: Self.makeNeuralVADFrames(
            seconds: 8,
            silentRanges: []
        ))

        let cutFrame = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
            fileURL: pcmURL,
            startFrame: 0,
            targetFrame: 480_000,
            neuralVoiceActivityDetector: fakeVAD
        )

        #expect(cutFrame == 480_000)

        try? FileManager.default.removeItem(at: pcmURL)
    }



    static func makeNeuralVADFrames(
        seconds: Double,
        silentRanges: [Range<Double>],
        frameSeconds: Double = Double(SileroNeuralVoiceActivityDetector.chunkSize) / Double(SileroNeuralVoiceActivityDetector.sampleRate)
    ) -> [(startFrame: Int, endFrame: Int, speechProbability: Double)] {
        var frames: [(startFrame: Int, endFrame: Int, speechProbability: Double)] = []
        var time = 0.0
        while time < seconds {
            let endTime = min(seconds, time + frameSeconds)
            let midpoint = (time + endTime) / 2
            let isSilent = silentRanges.contains { $0.contains(midpoint) }
            frames.append((
                startFrame: Int((time * 16_000).rounded()),
                endFrame: Int((endTime * 16_000).rounded()),
                speechProbability: isSilent ? 0.02 : 0.82
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

    @Test @MainActor func stopAccumulatesTranscriptFromSegments() async throws {
        let pcmURL = try makeSilentCAF(seconds: 70)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        coordinator.transcribeOverride = { @Sendable _ in "hello" }

        await coordinator.transcribeSegment(upToFrame: 480_000)
        await coordinator.transcribeSegment(upToFrame: 960_000)

        #expect(coordinator.accumulatedTranscript == "hello\nhello")
    }

    @Test @MainActor func stopWaitsForInFlightSegmentAndPendingFinalSegment() async throws {
        let pcmURL = try makeSilentCAF(seconds: 70)
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
            await coordinator.transcribeSegment(upToFrame: 480_000)
        }
        await harness.waitForCallCount(1)

        let stopRecorder = StopResultRecorder()
        let stopTask = Task { @MainActor in
            let transcript = await coordinator.stop(currentFrame: 960_000)
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
        let pcmURL = try makeSilentCAF(seconds: 70)
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

        await coordinator.transcribeSegment(upToFrame: 480_000)
        await coordinator.transcribeSegment(upToFrame: 960_000)

        #expect(updates == ["first", "first\nsecond"])
        #expect(coordinator.accumulatedTranscript == "first\nsecond")
    }

    @Test @MainActor func noAudioPlaceholderDoesNotPolluteAccumulatedTranscript() async throws {
        let pcmURL = try makeSilentCAF(seconds: 30)
        let service = TranscriptionService()
        let coordinator = IncrementalTranscriptionCoordinator(
            transcriptionService: service,
            recordingFileURL: pcmURL
        )
        coordinator.transcribeOverride = { @Sendable _ in " [no audio] " }

        await coordinator.transcribeSegment(upToFrame: 480_000)

        #expect(coordinator.accumulatedTranscript.isEmpty)
    }

    @Test func noSpeechPlaceholdersAreRemovedFromSegmentText() {
        #expect(IncrementalTranscriptionCoordinator.sanitizedSegmentText(" [Silence]\n[BLANK_AUDIO]\n(humming) ") == nil)
        #expect(IncrementalTranscriptionCoordinator.sanitizedSegmentText("hello\n[BLANK_AUDIO]\n(music)") == "hello")
    }

    @Test func neuralSpeechAnalyzerRejectsConfidentSilence() throws {
        let detector = FakeNeuralVAD(frameProbabilities: Self.makeVADFrames(
            durationSeconds: 1.0,
            silentRanges: [0.0..<1.0]
        ))

        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 16_000), detector: detector) == false)
    }

    @Test func neuralSpeechAnalyzerAcceptsUncertainOrSpeechFrames() throws {
        let uncertainDetector = FakeNeuralVAD(frameProbabilities: [
            (startFrame: 0, endFrame: 576, speechProbability: 0.45)
        ])
        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 576), detector: uncertainDetector) == true)

        let speechDetector = FakeNeuralVAD(frameProbabilities: Self.makeVADFrames(
            durationSeconds: 0.35,
            silentRanges: []
        ))
        #expect(try NeuralSpeechAnalyzer.containsProbableSpeech(in: Array(repeating: 0, count: 5_600), detector: speechDetector) == true)
    }
}
