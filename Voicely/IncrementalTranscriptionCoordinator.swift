//
//  IncrementalTranscriptionCoordinator.swift
//  Voicely
//

import AVFoundation
import Foundation

struct IncrementalTranscriptionTiming {
    static let intervalSecondsStorageKey = "incrementalTranscriptionIntervalSeconds"
    static let legacyIntervalMinutesStorageKey = "incrementalTranscriptionInterval"
    static let defaultIntervalSeconds = 30
    static let intervalOptionsSeconds = [15, 30, 45, 60]

    static func sanitizedIntervalSeconds(_ value: Int) -> Int {
        intervalOptionsSeconds.contains(value) ? value : defaultIntervalSeconds
    }

    static func resolvedIntervalSeconds(from defaults: UserDefaults = .standard) -> Int {
        if let storedSeconds = defaults.object(forKey: intervalSecondsStorageKey) as? Int {
            return sanitizedIntervalSeconds(storedSeconds)
        }

        if let legacyMinutes = defaults.object(forKey: legacyIntervalMinutesStorageKey) as? Int {
            return migratedIntervalSeconds(fromLegacyMinutes: legacyMinutes)
        }

        return defaultIntervalSeconds
    }

    @discardableResult
    static func migrateLegacyMinuteValueIfNeeded(in defaults: UserDefaults = .standard) -> Int {
        let resolvedSeconds = resolvedIntervalSeconds(from: defaults)
        let storedSeconds = defaults.object(forKey: intervalSecondsStorageKey) as? Int

        let sanitizedStoredSeconds = storedSeconds.map { sanitizedIntervalSeconds($0) }
        if storedSeconds == nil || sanitizedStoredSeconds != storedSeconds {
            defaults.set(resolvedSeconds, forKey: intervalSecondsStorageKey)
        }

        return resolvedSeconds
    }

    static func migratedIntervalSeconds(fromLegacyMinutes _: Int) -> Int {
        // Legacy values represented minutes. Do not reinterpret them as seconds.
        // Reset to the new recommended 30-second chunk cadence.
        defaultIntervalSeconds
    }
}

struct IncrementalVoiceActivityCutConfiguration: Sendable {
    var searchWindowSeconds: Double = 6
    var analysisWindowSeconds: Double = 0.20
    var hopSeconds: Double = 0.05
    var minimumSilenceSeconds: Double = 0.35
    var minimumSegmentSeconds: Double = 2
    var minimumSilenceRMS: Float = 0.003
    var maximumSilenceRMS: Float = 0.012
    var noiseFloorMultiplier: Float = 1.8

    static let `default` = IncrementalVoiceActivityCutConfiguration()
}

private struct IncrementalRMSWindow {
    let startFrame: Int
    let endFrame: Int
    let rms: Float
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
        let interval = TimeInterval(max(1, intervalSeconds))
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
        let endFrame = await resolvedSegmentEndFrame(
            requestedEndFrame,
            startFrame: startFrame,
            fileURL: fileURL,
            useVoiceActivityCut: useVoiceActivityCut
        )

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
        try? FileManager.default.removeItem(at: segmentURL)

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
    ) async -> AVAudioFramePosition {
        guard useVoiceActivityCut else { return requestedEndFrame }

        let cutFrame = await Task.detached {
            Self.voiceActivityAwareCutFrame(
                fileURL: fileURL,
                startFrame: startFrame,
                targetFrame: requestedEndFrame
            )
        }.value

        guard cutFrame > startFrame + minimumSegmentFrames else {
            return requestedEndFrame
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
            return AVAudioFramePosition(sourceFile.processingFormat.sampleRate)
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


    /// Chooses a cut point using lightweight energy-based silence detection.
    /// A neural VAD can replace this later without changing the coordinator API.
    nonisolated static func voiceActivityAwareCutFrame(
        fileURL: URL,
        startFrame: AVAudioFramePosition,
        targetFrame: AVAudioFramePosition,
        configuration: IncrementalVoiceActivityCutConfiguration = .default
    ) -> AVAudioFramePosition {
        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            let format = sourceFile.processingFormat
            let sampleRate = format.sampleRate
            let availableEndFrame = min(targetFrame, sourceFile.length)
            let minimumSegmentFrames = AVAudioFramePosition(configuration.minimumSegmentSeconds * sampleRate)

            guard availableEndFrame > startFrame + minimumSegmentFrames else {
                return availableEndFrame
            }

            let searchWindowFrames = AVAudioFramePosition(configuration.searchWindowSeconds * sampleRate)
            let analysisStartFrame = max(startFrame + minimumSegmentFrames, availableEndFrame - searchWindowFrames)
            let framesToRead = AVAudioFrameCount(availableEndFrame - analysisStartFrame)
            guard framesToRead > 0 else { return targetFrame }

            sourceFile.framePosition = analysisStartFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                return targetFrame
            }

            try sourceFile.read(into: buffer, frameCount: framesToRead)
            guard let floatChannelData = buffer.floatChannelData else { return targetFrame }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return targetFrame }

            let windowFrames = max(1, Int(configuration.analysisWindowSeconds * sampleRate))
            let hopFrames = max(1, Int(configuration.hopSeconds * sampleRate))
            let minimumSilenceFrames = max(1, Int(configuration.minimumSilenceSeconds * sampleRate))
            let channelCount = max(1, Int(format.channelCount))

            let windows = rmsWindows(
                floatChannelData: floatChannelData,
                channelCount: channelCount,
                frameLength: frameLength,
                windowFrames: windowFrames,
                hopFrames: hopFrames
            )
            guard !windows.isEmpty else { return targetFrame }

            let threshold = silenceThreshold(
                for: windows.map(\.rms),
                configuration: configuration
            )
            let localCutFrame = latestSilenceCutFrame(
                in: windows,
                threshold: threshold,
                minimumSilenceFrames: minimumSilenceFrames
            )

            guard let localCutFrame else { return availableEndFrame }

            let cutFrame = analysisStartFrame + AVAudioFramePosition(localCutFrame)
            guard cutFrame > startFrame + minimumSegmentFrames else { return availableEndFrame }
            return min(cutFrame, availableEndFrame)
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Voice activity cut failed: \(error)")
            return targetFrame
        }
    }

    nonisolated private static func rmsWindows(
        floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameLength: Int,
        windowFrames: Int,
        hopFrames: Int
    ) -> [IncrementalRMSWindow] {
        var windows: [IncrementalRMSWindow] = []
        var windowStart = 0

        while windowStart < frameLength {
            let windowEnd = min(frameLength, windowStart + windowFrames)
            guard windowEnd > windowStart else { break }

            var sumSquares: Double = 0
            var sampleCount = 0

            for channel in 0..<channelCount {
                let samples = floatChannelData[channel]
                for frame in windowStart..<windowEnd {
                    let sample = Double(samples[frame])
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }

            let rms = sampleCount > 0 ? Float((sumSquares / Double(sampleCount)).squareRoot()) : 0
            windows.append(IncrementalRMSWindow(startFrame: windowStart, endFrame: windowEnd, rms: rms))
            windowStart += hopFrames
        }

        return windows
    }

    nonisolated private static func silenceThreshold(
        for rmsValues: [Float],
        configuration: IncrementalVoiceActivityCutConfiguration
    ) -> Float {
        let sortedValues = rmsValues.sorted()
        let percentileIndex = min(sortedValues.count - 1, max(0, sortedValues.count / 5))
        let noiseFloor = sortedValues[percentileIndex]
        let adaptiveThreshold = noiseFloor * configuration.noiseFloorMultiplier
        return max(
            configuration.minimumSilenceRMS,
            min(configuration.maximumSilenceRMS, adaptiveThreshold)
        )
    }

    nonisolated private static func latestSilenceCutFrame(
        in windows: [IncrementalRMSWindow],
        threshold: Float,
        minimumSilenceFrames: Int
    ) -> Int? {
        var silenceStartFrame: Int?
        var latestCutFrame: Int?

        for window in windows {
            if window.rms <= threshold {
                if silenceStartFrame == nil {
                    silenceStartFrame = window.startFrame
                }

                if let silenceStartFrame, window.endFrame - silenceStartFrame >= minimumSilenceFrames {
                    latestCutFrame = window.endFrame
                }
            } else {
                silenceStartFrame = nil
            }
        }

        return latestCutFrame
    }

    nonisolated static func sanitizedSegmentText(_ text: String?) -> String? {
        guard let text else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased()
        if normalized == "[no audio]" || normalized == "no audio" {
            return nil
        }

        return trimmed
    }
}
