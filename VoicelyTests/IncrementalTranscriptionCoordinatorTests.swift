//
//  IncrementalTranscriptionCoordinatorTests.swift
//  VoicelyTests
//

import AVFoundation
import Testing
@testable import Voicely

@Suite(.serialized)
struct IncrementalTranscriptionCoordinatorTests {

    // MARK: Helpers

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
}
