import AVFoundation
import Foundation
@testable import Voicely

enum SegmentedAudioTestSupport {
    /// Float32 / 16 kHz / mono silent CAF of the given length. Returns its URL.
    static func makeSilentCAF(seconds: Double) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount((seconds * 16_000).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg_test_\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Parses the extraction index N from a `voicely_seg_<N>_<nonce>.wav` segment
    /// URL, so a mock can fail a specific slice (and, after bisection, halves).
    static func extractionIndex(of url: URL) -> Int {
        let rest = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "voicely_seg_", with: "")
        return rest.split(separator: "_").first.flatMap { Int($0) } ?? -1
    }

    static func makeStore() -> SegmentProgressStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg_\(UUID().uuidString)")
        return SegmentProgressStore(rootDirectory: root)
    }

    @MainActor
    static func makeTranscriber(store: SegmentProgressStore,
                                service: TranscriptionService? = nil) -> SegmentedAudioTranscriber {
        // Build the service in this @MainActor body — its init is main-actor
        // isolated and cannot be called from a default-argument context.
        let transcriber = SegmentedAudioTranscriber(transcriptionService: service ?? TranscriptionService(),
                                                    progressStore: store)
        transcriber.nextCutFrame = { _, _, target in target }   // deterministic 29 s cuts in tests
        return transcriber
    }
}
