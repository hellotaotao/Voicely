//
//  IncrementalTranscriptionCoordinator.swift
//  Voicely
//

import AVFoundation
import Foundation

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

    // MARK: Private

    private let transcriptionService: TranscriptionService
    private let recordingFileURL: URL

    private var segmentTimer: Timer?
    private var lastSegmentEndFrame: AVAudioFramePosition = 0
    private var segmentIndex: Int = 0
    private var isProcessingSegment = false
    private var pendingSegmentFrameEnd: AVAudioFramePosition?

    // MARK: Init

    init(transcriptionService: TranscriptionService, recordingFileURL: URL) {
        self.transcriptionService = transcriptionService
        self.recordingFileURL = recordingFileURL
    }

    // MARK: Lifecycle

    /// Start periodic transcription every `intervalMinutes` minutes.
    func start(intervalMinutes: Int) {
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
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
        await transcribeSegment(upToFrame: currentFrame)
        return accumulatedTranscript
    }

    /// Pause the timer while recording is paused.
    func pause() {
        segmentTimer?.invalidate()
        segmentTimer = nil
    }

    /// Resume periodic transcription with the original interval.
    func resume(intervalMinutes: Int) {
        start(intervalMinutes: intervalMinutes)
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
        guard upToFrame > lastSegmentEndFrame + 16000 else { return } // Skip < 1 s

        if isProcessingSegment {
            pendingSegmentFrameEnd = upToFrame
            return
        }

        isProcessingSegment = true
        defer { isProcessingSegment = false }

        segmentIndex += 1
        let index = segmentIndex
        let startFrame = lastSegmentEndFrame
        let fileURL = recordingFileURL

        let extracted = await Task.detached {
            Self.extractSegment(
                fileURL: fileURL,
                from: startFrame,
                to: upToFrame,
                segmentIndex: index
            )
        }.value

        guard let segmentURL = extracted else { return }
        lastSegmentEndFrame = upToFrame

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
        }

        // Process any queued segment
        if let pending = pendingSegmentFrameEnd {
            pendingSegmentFrameEnd = nil
            await transcribeSegment(upToFrame: pending)
        }
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
