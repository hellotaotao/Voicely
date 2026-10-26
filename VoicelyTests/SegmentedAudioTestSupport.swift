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
        let url = TestTemporaryDirectory.fileURL(prefix: "seg_test_", extension: "caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    static func makeStore() -> SegmentProgressStore {
        let root = TestTemporaryDirectory.directoryURL(prefix: "seg_")
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
        transcriber.storeImportedAudio = noListeningCopy
        return transcriber
    }

    struct ListeningCopySkipped: Error {}

    /// Keeps tests from writing listening copies into the app's audio storage.
    static let noListeningCopy: (URL) async throws -> String = { _ in throw ListeningCopySkipped() }
}
