//
//  IncrementalTranscriptionCoordinatorTests.swift
//  VoicelyTests
//

import AVFoundation
import Testing
@testable import Voicely

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
}
