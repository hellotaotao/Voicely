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
    /// Earliest position inside a full batch where a VAD cut is allowed,
    /// so every chunk sent to Whisper carries at least this much audio.
    static let minimumCutSeconds = 15

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
    var minimumSilenceSeconds: Double = 0.35
    var minimumCutSeconds: Double = Double(IncrementalTranscriptionTiming.minimumCutSeconds)
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

    /// Word-level timings accumulated so far, re-based to global recording time.
    private(set) var accumulatedWords: [WordToken] = []

    /// Overridable for testing. When non-nil, used instead of TranscriptionService.
    var transcribeOverride: (@Sendable (String) async -> String?)? = nil

    /// Test-only companion to `transcribeOverride`, supplying slice-local word
    /// timings for the same segment so tests can exercise word accumulation.
    var segmentWordsOverride: (@Sendable (String) async -> [WordToken])? = nil

    /// Closure that returns the current number of frames written to the recording file.
    var frameCountProvider: () -> AVAudioFramePosition = { 0 }

    /// Optional transcript relay after a segment appends to the accumulated transcript.
    var transcriptCallback: ((String) -> Void)? = nil

    // MARK: Private

    private let transcriptionService: TranscriptionService
    private let recordingFileURL: URL
    private let recordingSampleRate: Double

    private var segmentTimer: Timer?
    private var targetIntervalSeconds: Int = IncrementalTranscriptionTiming.defaultIntervalSeconds
    private var lastSegmentEndFrame: AVAudioFramePosition = 0
    private var segmentIndex: Int = 0
    private var isProcessingSegment = false
    private struct PendingSegmentRequest {
        var frameEnd: AVAudioFramePosition
        var useVoiceActivityCut: Bool
    }

    private let minimumCutFrames: AVAudioFramePosition

    private var pendingSegmentRequest: PendingSegmentRequest?
    private var segmentProcessingWaiters: [CheckedContinuation<Void, Never>] = []

    private var targetIntervalFrames: AVAudioFramePosition {
        AVAudioFramePosition(Double(targetIntervalSeconds) * recordingSampleRate)
    }

    // MARK: Init

    init(transcriptionService: TranscriptionService, recordingFileURL: URL) {
        self.transcriptionService = transcriptionService
        self.recordingFileURL = recordingFileURL
        self.recordingSampleRate = Self.sampleRate(for: recordingFileURL)
        self.minimumCutFrames = AVAudioFramePosition(
            Double(IncrementalTranscriptionTiming.minimumCutSeconds) * recordingSampleRate
        )
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

        guard upToFrame > lastSegmentEndFrame + requiredMinimumSegmentFrames(useVoiceActivityCut: useVoiceActivityCut) else { return }

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
            if request.frameEnd > lastSegmentEndFrame + requiredMinimumSegmentFrames(useVoiceActivityCut: request.useVoiceActivityCut) {
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

        // No separate speech preflight here: transcribeAudio runs the same
        // neural VAD gate before invoking Whisper, so checking twice would
        // just double the inference cost per segment.
        let textResult: String?
        var segmentWords: [WordToken] = []
        if let override = transcribeOverride {
            textResult = await override(segmentURL.path)
            segmentWords = await segmentWordsOverride?(segmentURL.path) ?? []
        } else if let result = await transcriptionService.transcribeAudio(filePath: segmentURL.path) {
            textResult = result.text
            segmentWords = result.words
        } else {
            textResult = nil
        }

        if let text = Self.sanitizedSegmentText(textResult) {
            if accumulatedTranscript.isEmpty {
                accumulatedTranscript = text
            } else {
                accumulatedTranscript += "\n" + text
            }
            // Re-base this slice's word times (0-based within the slice) to global
            // recording time before accumulating, mirroring the import path.
            let offset = recordingSampleRate > 0 ? Double(startFrame) / recordingSampleRate : 0
            accumulatedWords.append(contentsOf: segmentWords.map {
                WordToken(word: $0.word, start: $0.start + offset, end: $0.end + offset)
            })
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

        guard cutFrame > startFrame + minimumCutFrames else {
            return nil
        }

        return cutFrame
    }

    /// Periodic VAD cuts wait until a full batch has accumulated so the VAD
    /// runs once per batch instead of probing every tick. The final flush
    /// (non-VAD) must transcribe whatever remains, however short, otherwise
    /// the tail of the recording is silently lost.
    private func requiredMinimumSegmentFrames(useVoiceActivityCut: Bool) -> AVAudioFramePosition {
        useVoiceActivityCut ? targetIntervalFrames : 0
    }

    private func queuePendingSegment(
        upToFrame: AVAudioFramePosition,
        useVoiceActivityCut: Bool
    ) {
        guard upToFrame > lastSegmentEndFrame + requiredMinimumSegmentFrames(useVoiceActivityCut: useVoiceActivityCut) else { return }

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

    private nonisolated static func sampleRate(for fileURL: URL) -> Double {
        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            return sourceFile.processingFormat.sampleRate
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Failed to read recording sample rate: \(error)")
            return 16_000
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


    /// Chooses a cut point with a single neural VAD pass per full batch.
    ///
    /// The coordinator accumulates `targetSegmentSeconds` of audio, then this
    /// runs Silero VAD once over [start + minimumCutSeconds, batch end] and cuts
    /// at the best silence found, or at the batch end when no silence exists.
    /// Audio past the cut carries over into the next batch.
    ///
    /// Returns `startFrame` while the batch is still filling, which tells the
    /// coordinator to keep recording before cutting the chunk.
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
            let targetSeconds = max(configuration.minimumCutSeconds, targetSegmentSeconds)
            let targetFrames = AVAudioFramePosition(targetSeconds * sampleRate)
            let minimumCutFrames = AVAudioFramePosition(configuration.minimumCutSeconds * sampleRate)

            // A batch is exactly `targetSeconds` long; audio past it carries
            // over so every chunk stays within Whisper's 30 s window.
            let batchEndFrame = min(targetFrame, sourceFile.length, startFrame + targetFrames)

            guard batchEndFrame >= startFrame + targetFrames else {
                return startFrame
            }

            let analysisStartFrame = startFrame + minimumCutFrames
            let framesToRead = AVAudioFrameCount(batchEndFrame - analysisStartFrame)
            guard framesToRead > 0 else { return batchEndFrame }

            sourceFile.framePosition = analysisStartFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                return batchEndFrame
            }

            try sourceFile.read(into: buffer, frameCount: framesToRead)
            let samples = monoFloatSamples(from: buffer)
            guard !samples.isEmpty else { return batchEndFrame }

            let detector = try neuralVoiceActivityDetector ?? SileroNeuralVoiceActivityDetector()
            let vadFrames = try detector.speechProbabilities(in: samples)
            let candidate = bestNeuralSilenceCutCandidate(
                in: vadFrames,
                speechProbabilityThreshold: configuration.speechProbabilityThreshold,
                minimumSilenceFrames: max(1, Int(configuration.minimumSilenceSeconds * sampleRate))
            )

            guard let candidate else {
                return batchEndFrame
            }

            let cutFrame = analysisStartFrame + AVAudioFramePosition(candidate.localFrame)
            return min(max(cutFrame, analysisStartFrame), batchEndFrame)
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
        // A segment with no real speech (the whole thing is non-speech) is dropped
        // rather than accumulating a placeholder into the live transcript. Decided by
        // meaning (sanitizer finds no speech), not by matching a placeholder string.
        guard let finalized = LocalTranscriptFinalizer.finalizedText(text),
              TranscriptSanitizer.cleanedTranscript(finalized) != nil else {
            return nil
        }
        return finalized
    }
}
