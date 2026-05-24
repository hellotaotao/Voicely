//
//  IncrementalTranscriptionCoordinator.swift
//  Voicely
//

import AVFoundation
import Foundation

struct IncrementalTranscriptionTiming {
    static let intervalSecondsStorageKey = "incrementalTranscriptionIntervalSeconds"
    static let legacyIntervalMinutesStorageKey = "incrementalTranscriptionInterval"
    static let defaultIntervalSeconds = 29
    static let minimumEffectiveSpeechChunkSeconds = 20

    static func sanitizedIntervalSeconds(_: Int) -> Int {
        defaultIntervalSeconds
    }

    static func resolvedIntervalSeconds(from _: UserDefaults = .standard) -> Int {
        return defaultIntervalSeconds
    }

    @discardableResult
    static func migrateLegacyMinuteValueIfNeeded(in defaults: UserDefaults = .standard) -> Int {
        let resolvedSeconds = defaultIntervalSeconds
        let storedSeconds = defaults.object(forKey: intervalSecondsStorageKey) as? Int

        if storedSeconds != resolvedSeconds {
            defaults.set(resolvedSeconds, forKey: intervalSecondsStorageKey)
        }

        return resolvedSeconds
    }

    static func migratedIntervalSeconds(fromLegacyMinutes _: Int) -> Int {
        // Legacy values represented minutes. Do not reinterpret them as seconds.
        // Reset to the current recommended Whisper-safe chunk cadence.
        defaultIntervalSeconds
    }
}

struct IncrementalVoiceActivityCutConfiguration: Sendable {
    var searchWindowSeconds: Double = 8
    var minimumSilenceSeconds: Double = 0.35
    var minimumSegmentSeconds: Double = Double(IncrementalTranscriptionTiming.minimumEffectiveSpeechChunkSeconds)
    var earliestCutRatio: Double = 0.8
    var forcedCutRatio: Double = 1.0
    var earlyCutConfidence: Double = 0.88
    var targetCutConfidence: Double = 0.62
    var lateCutConfidence: Double = 0.25
    var speechProbabilityThreshold: Double = 0.30

    static let `default` = IncrementalVoiceActivityCutConfiguration()
}

private struct VoiceActivityCutCandidate {
    let localFrame: Int
    let confidence: Double
}

/// Manages incremental (segment-by-segment) transcription during a long recording.
/// Lives only for the duration of one recording session.
@MainActor
final class IncrementalTranscriptionCoordinator {

    // MARK: Public state

    /// All transcribed text accumulated so far. Updated after each segment completes.
    private(set) var accumulatedTranscript: String = ""

    /// Overridable for testing. When non-nil, used instead of TranscriptionService.
    var transcribeOverride: (@Sendable (String) async -> String?)? = nil

    /// Closure that returns the current number of frames written to the recording file.
    var frameCountProvider: () -> AVAudioFramePosition = { 0 }

    /// Optional progress relay for UI updates when a segment is being transcribed.
    var progressCallback: ((Float) -> Void)? = nil

    /// Optional transcript relay after a segment appends to the accumulated transcript.
    var transcriptCallback: ((String) -> Void)? = nil

    // MARK: Private

    private let transcriptionService: TranscriptionService
    private let recordingFileURL: URL

    private var segmentTimer: Timer?
    private var targetIntervalSeconds: Int = IncrementalTranscriptionTiming.defaultIntervalSeconds
    private var lastSegmentEndFrame: AVAudioFramePosition = 0
    private var segmentIndex: Int = 0
    private var isProcessingSegment = false
    private struct PendingSegmentRequest {
        var frameEnd: AVAudioFramePosition
        var useVoiceActivityCut: Bool
    }

    private let minimumSegmentFrames: AVAudioFramePosition

    private var pendingSegmentRequest: PendingSegmentRequest?
    private var segmentProcessingWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Init

    init(transcriptionService: TranscriptionService, recordingFileURL: URL) {
        self.transcriptionService = transcriptionService
        self.recordingFileURL = recordingFileURL
        self.minimumSegmentFrames = Self.minimumSegmentFrames(for: recordingFileURL)
    }

    // MARK: Lifecycle

    /// Start periodic transcription every `intervalSeconds` seconds.
    func start(intervalSeconds: Int) {
        targetIntervalSeconds = max(1, intervalSeconds)
        let interval = TimeInterval(1)
        segmentTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleTimerFired()
            }
        }
    }

    /// Stop the timer and transcribe any remaining frames.
    /// Returns the complete accumulated transcript.
    func stop(currentFrame: AVAudioFramePosition) async -> String {
        segmentTimer?.invalidate()
        segmentTimer = nil
        await transcribeSegment(
            upToFrame: currentFrame,
            waitForCompletion: true,
            useVoiceActivityCut: false
        )
        return accumulatedTranscript
    }

    /// Pause the timer while recording is paused.
    func pause() {
        segmentTimer?.invalidate()
        segmentTimer = nil
    }

    /// Resume periodic transcription with the original interval.
    func resume(intervalSeconds: Int) {
        start(intervalSeconds: intervalSeconds)
    }

    // MARK: Private helpers

    private func handleTimerFired() {
        let frame = frameCountProvider()
        Task { @MainActor [weak self] in
            await self?.transcribeSegment(upToFrame: frame)
        }
    }

    /// Extract frames [lastSegmentEndFrame, upToFrame) into a temp WAV file,
    /// transcribe it, and append the result to accumulatedTranscript.
    func transcribeSegment(upToFrame: AVAudioFramePosition) async {
        await transcribeSegment(
            upToFrame: upToFrame,
            waitForCompletion: false,
            useVoiceActivityCut: true
        )
    }

    private func transcribeSegment(
        upToFrame: AVAudioFramePosition,
        waitForCompletion: Bool,
        useVoiceActivityCut: Bool
    ) async {
        if isProcessingSegment {
            queuePendingSegment(upToFrame: upToFrame, useVoiceActivityCut: useVoiceActivityCut)
            if waitForCompletion {
                await waitForSegmentProcessingToFinish()
            }
            return
        }

        guard upToFrame > lastSegmentEndFrame + minimumSegmentFrames else { return }

        isProcessingSegment = true
        defer {
            isProcessingSegment = false
            resumeSegmentProcessingWaiters()
        }

        var nextRequest: PendingSegmentRequest? = PendingSegmentRequest(
            frameEnd: upToFrame,
            useVoiceActivityCut: useVoiceActivityCut
        )
        while let request = nextRequest {
            pendingSegmentRequest = nil
            if request.frameEnd > lastSegmentEndFrame + minimumSegmentFrames {
                await transcribeCurrentSegment(
                    upToFrame: request.frameEnd,
                    useVoiceActivityCut: request.useVoiceActivityCut
                )
            }
            nextRequest = pendingSegmentRequest
        }
    }

    private func transcribeCurrentSegment(
        upToFrame requestedEndFrame: AVAudioFramePosition,
        useVoiceActivityCut: Bool
    ) async {
        segmentIndex += 1
        let index = segmentIndex
        let startFrame = lastSegmentEndFrame
        let fileURL = recordingFileURL
        guard let endFrame = await resolvedSegmentEndFrame(
            requestedEndFrame,
            startFrame: startFrame,
            fileURL: fileURL,
            useVoiceActivityCut: useVoiceActivityCut
        ) else {
            return
        }

        let extracted = await Task.detached {
            Self.extractSegment(
                fileURL: fileURL,
                from: startFrame,
                to: endFrame,
                segmentIndex: index
            )
        }.value

        guard let segmentURL = extracted else { return }
        lastSegmentEndFrame = endFrame
        defer {
            try? FileManager.default.removeItem(at: segmentURL)
        }

        if transcribeOverride == nil {
            let containsProbableSpeech = await Task.detached(priority: .utility) {
                NeuralSpeechAnalyzer.safelyContainsProbableSpeech(at: segmentURL)
            }.value

            guard containsProbableSpeech else {
                progressCallback?(1.0)
                return
            }
        }

        let textResult: String?
        if let override = transcribeOverride {
            textResult = await override(segmentURL.path)
        } else {
            textResult = await transcriptionService.transcribeAudio(filePath: segmentURL.path) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.progressCallback?(progress)
                }
            }?.text
        }

        if let text = Self.sanitizedSegmentText(textResult) {
            if accumulatedTranscript.isEmpty {
                accumulatedTranscript = text
            } else {
                accumulatedTranscript += "\n" + text
            }
            transcriptCallback?(accumulatedTranscript)
        }
    }

    private func resolvedSegmentEndFrame(
        _ requestedEndFrame: AVAudioFramePosition,
        startFrame: AVAudioFramePosition,
        fileURL: URL,
        useVoiceActivityCut: Bool
    ) async -> AVAudioFramePosition? {
        guard useVoiceActivityCut else { return requestedEndFrame }

        let targetIntervalSeconds = self.targetIntervalSeconds
        let cutFrame = await Task.detached {
            Self.voiceActivityAwareCutFrame(
                fileURL: fileURL,
                startFrame: startFrame,
                targetFrame: requestedEndFrame,
                targetSegmentSeconds: Double(targetIntervalSeconds)
            )
        }.value

        guard cutFrame > startFrame + minimumSegmentFrames else {
            return nil
        }

        return cutFrame
    }

    private func queuePendingSegment(
        upToFrame: AVAudioFramePosition,
        useVoiceActivityCut: Bool
    ) {
        guard upToFrame > lastSegmentEndFrame + minimumSegmentFrames else { return }

        if var pendingSegmentRequest {
            pendingSegmentRequest.frameEnd = max(pendingSegmentRequest.frameEnd, upToFrame)
            pendingSegmentRequest.useVoiceActivityCut = pendingSegmentRequest.useVoiceActivityCut && useVoiceActivityCut
            self.pendingSegmentRequest = pendingSegmentRequest
        } else {
            pendingSegmentRequest = PendingSegmentRequest(
                frameEnd: upToFrame,
                useVoiceActivityCut: useVoiceActivityCut
            )
        }
    }

    private func waitForSegmentProcessingToFinish() async {
        guard isProcessingSegment else { return }

        await withCheckedContinuation { continuation in
            segmentProcessingWaiters.append(continuation)
        }
    }

    private func resumeSegmentProcessingWaiters() {
        let waiters = segmentProcessingWaiters
        segmentProcessingWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Test-only convenience that mirrors the legacy signature.
    /// Increments `segmentIndex` and calls into the nonisolated extractor.
    func extractSegmentPublic(
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition
    ) -> URL? {
        segmentIndex += 1
        return Self.extractSegment(
            fileURL: recordingFileURL,
            from: startFrame,
            to: endFrame,
            segmentIndex: segmentIndex
        )
    }

    private nonisolated static func minimumSegmentFrames(for fileURL: URL) -> AVAudioFramePosition {
        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            return AVAudioFramePosition(Double(IncrementalTranscriptionTiming.minimumEffectiveSpeechChunkSeconds) * sourceFile.processingFormat.sampleRate)
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Failed to read recording sample rate: \(error)")
            return AVAudioFramePosition(IncrementalTranscriptionTiming.minimumEffectiveSpeechChunkSeconds * 16_000)
        }
    }

    /// Reads audio frames from the recording file and writes them to a temp WAV.
    /// Runs off the MainActor (called from Task.detached) to keep file I/O off the UI thread.
    nonisolated static func extractSegment(
        fileURL: URL,
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition,
        segmentIndex: Int
    ) -> URL? {
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard frameCount > 0 else { return nil }

        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            sourceFile.framePosition = startFrame

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: frameCount
            ) else { return nil }

            try sourceFile.read(into: buffer, frameCount: frameCount)

            let segmentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicely_seg_\(segmentIndex).wav")

            let segmentFile = try AVAudioFile(
                forWriting: segmentURL,
                settings: sourceFile.processingFormat.settings
            )
            try segmentFile.write(from: buffer)
            return segmentURL
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Segment extraction failed: \(error)")
            return nil
        }
    }


    /// Chooses a cut point using Silero neural VAD probabilities plus adaptive boundary scoring.
    ///
    /// Returns `startFrame` when it is too early or no acceptable boundary exists yet,
    /// which tells the coordinator to keep recording before cutting the chunk.
    nonisolated static func voiceActivityAwareCutFrame(
        fileURL: URL,
        startFrame: AVAudioFramePosition,
        targetFrame: AVAudioFramePosition,
        targetSegmentSeconds: Double = Double(IncrementalTranscriptionTiming.defaultIntervalSeconds),
        configuration: IncrementalVoiceActivityCutConfiguration = .default,
        neuralVoiceActivityDetector: NeuralVoiceActivityDetecting? = nil
    ) -> AVAudioFramePosition {
        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            let format = sourceFile.processingFormat
            let sampleRate = format.sampleRate
            let availableEndFrame = min(targetFrame, sourceFile.length)
            let minimumSegmentFrames = AVAudioFramePosition(configuration.minimumSegmentSeconds * sampleRate)

            guard availableEndFrame > startFrame + minimumSegmentFrames else {
                return startFrame
            }

            let elapsedSeconds = Double(availableEndFrame - startFrame) / sampleRate
            let targetSeconds = max(configuration.minimumSegmentSeconds, targetSegmentSeconds)
            let earliestCutSeconds = max(configuration.minimumSegmentSeconds, targetSeconds * configuration.earliestCutRatio)
            let forcedCutSeconds = max(earliestCutSeconds, targetSeconds * configuration.forcedCutRatio)

            guard elapsedSeconds >= earliestCutSeconds else {
                return startFrame
            }

            let searchWindowFrames = AVAudioFramePosition(configuration.searchWindowSeconds * sampleRate)
            let analysisStartFrame = max(startFrame + minimumSegmentFrames, availableEndFrame - searchWindowFrames)
            let framesToRead = AVAudioFrameCount(availableEndFrame - analysisStartFrame)
            guard framesToRead > 0 else { return startFrame }

            sourceFile.framePosition = analysisStartFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                return startFrame
            }

            try sourceFile.read(into: buffer, frameCount: framesToRead)
            let samples = monoFloatSamples(from: buffer)
            guard !samples.isEmpty else { return startFrame }

            let detector = try neuralVoiceActivityDetector ?? SileroNeuralVoiceActivityDetector()
            let vadFrames = try detector.speechProbabilities(in: samples)
            let candidate = bestNeuralSilenceCutCandidate(
                in: vadFrames,
                speechProbabilityThreshold: configuration.speechProbabilityThreshold,
                minimumSilenceFrames: max(1, Int(configuration.minimumSilenceSeconds * sampleRate))
            )

            let requiredConfidence = adaptiveCutConfidenceThreshold(
                elapsedSeconds: elapsedSeconds,
                targetSeconds: targetSeconds,
                forcedCutSeconds: forcedCutSeconds,
                configuration: configuration
            )

            if let candidate, candidate.confidence >= requiredConfidence {
                let cutFrame = analysisStartFrame + AVAudioFramePosition(candidate.localFrame)
                guard cutFrame > startFrame + minimumSegmentFrames else { return startFrame }
                return min(cutFrame, availableEndFrame)
            }

            if elapsedSeconds >= forcedCutSeconds {
                if let candidate {
                    let cutFrame = analysisStartFrame + AVAudioFramePosition(candidate.localFrame)
                    if cutFrame > startFrame + minimumSegmentFrames {
                        return min(cutFrame, availableEndFrame)
                    }
                }
                return availableEndFrame
            }

            return startFrame
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Neural VAD cut failed: \(error)")
            return targetFrame
        }
    }

    nonisolated private static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let floatChannelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }
        let channelCount = max(1, Int(buffer.format.channelCount))

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        }

        var samples = Array(repeating: Float(0), count: frameLength)
        for channel in 0..<channelCount {
            let channelSamples = floatChannelData[channel]
            for frame in 0..<frameLength {
                samples[frame] += channelSamples[frame] / Float(channelCount)
            }
        }
        return samples
    }

    nonisolated static func adaptiveCutConfidenceThreshold(
        elapsedSeconds: Double,
        targetSeconds: Double,
        forcedCutSeconds: Double,
        configuration: IncrementalVoiceActivityCutConfiguration = .default
    ) -> Double {
        let earliestSeconds = max(configuration.minimumSegmentSeconds, targetSeconds * configuration.earliestCutRatio)
        if elapsedSeconds <= earliestSeconds {
            return configuration.earlyCutConfidence
        }
        if elapsedSeconds <= targetSeconds {
            let progress = (elapsedSeconds - earliestSeconds) / max(targetSeconds - earliestSeconds, 0.001)
            return interpolate(
                from: configuration.earlyCutConfidence,
                to: configuration.targetCutConfidence,
                progress: progress
            )
        }
        let progress = (elapsedSeconds - targetSeconds) / max(forcedCutSeconds - targetSeconds, 0.001)
        return interpolate(
            from: configuration.targetCutConfidence,
            to: configuration.lateCutConfidence,
            progress: min(max(progress, 0), 1)
        )
    }

    nonisolated private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return start + (end - start) * clamped
    }

    nonisolated private static func bestNeuralSilenceCutCandidate(
        in vadFrames: [NeuralVoiceActivityFrame],
        speechProbabilityThreshold: Double,
        minimumSilenceFrames: Int
    ) -> VoiceActivityCutCandidate? {
        var silenceStartFrame: Int?
        var silenceProbabilities: [Double] = []
        var bestCandidate: VoiceActivityCutCandidate?

        func considerCandidate(endFrame: Int) {
            guard let silenceStartFrame else { return }
            let durationFrames = endFrame - silenceStartFrame
            guard durationFrames >= minimumSilenceFrames else { return }
            let averageSpeechProbability = silenceProbabilities.isEmpty
                ? speechProbabilityThreshold
                : silenceProbabilities.reduce(0, +) / Double(silenceProbabilities.count)
            let silenceConfidence = max(
                0,
                min(1, (speechProbabilityThreshold - averageSpeechProbability) / max(speechProbabilityThreshold, 0.000_001))
            )
            let durationConfidence = min(1, Double(durationFrames) / Double(max(minimumSilenceFrames * 2, 1)))
            let confidence = min(1, 0.75 * silenceConfidence + 0.25 * durationConfidence)
            let candidate = VoiceActivityCutCandidate(localFrame: endFrame, confidence: confidence)
            if bestCandidate == nil || candidate.confidence >= bestCandidate!.confidence {
                bestCandidate = candidate
            }
        }

        for frame in vadFrames {
            if frame.speechProbability <= speechProbabilityThreshold {
                if silenceStartFrame == nil {
                    silenceStartFrame = frame.startFrame
                    silenceProbabilities.removeAll()
                }
                silenceProbabilities.append(frame.speechProbability)
                considerCandidate(endFrame: frame.endFrame)
            } else {
                silenceStartFrame = nil
                silenceProbabilities.removeAll()
            }
        }

        return bestCandidate
    }

    nonisolated static func sanitizedSegmentText(_ text: String?) -> String? {
        LocalTranscriptFinalizer.finalizedText(text)
    }
}
