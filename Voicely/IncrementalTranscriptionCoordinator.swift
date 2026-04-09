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
    var transcribeOverride: ((String) async -> String?)? = nil

    /// Closure that returns the current number of frames written to the recording file.
    var frameCountProvider: () -> AVAudioFramePosition = { 0 }

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

        guard let segmentURL = extractSegmentPublic(from: lastSegmentEndFrame, to: upToFrame) else { return }
        let frameEnd = upToFrame
        lastSegmentEndFrame = frameEnd

        let textResult: String?
        if let override = transcribeOverride {
            textResult = await override(segmentURL.path)
        } else {
            textResult = await transcriptionService.transcribeAudio(filePath: segmentURL.path)?.text
        }
        try? FileManager.default.removeItem(at: segmentURL)

        if let text = textResult, !text.isEmpty {
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

    /// Reads audio frames from the recording file and writes them to a temp WAV.
    /// Returns nil if the file can't be read or there are insufficient frames.
    func extractSegmentPublic(
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition
    ) -> URL? {
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard frameCount > 0 else { return nil }

        do {
            let sourceFile = try AVAudioFile(forReading: recordingFileURL)
            sourceFile.framePosition = startFrame

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: frameCount
            ) else { return nil }

            try sourceFile.read(into: buffer, frameCount: frameCount)

            segmentIndex += 1
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
}
