import AVFoundation
import Foundation
import Testing
@testable import Voicely

struct SpeakerDiarizationEngineTests {
    @Test func speakerActivityStaysOpenAcrossChunksAndPreservesOverlap() throws {
        var activity = SpeakerActivitySegments(speakerCount: 2)
        func frames(_ interval: Range<Int>) -> [Float] {
            interval.flatMap { frame -> [Float] in
                [(5..<28).contains(frame) ? 0.8 : 0, frame >= 12 ? 0.9 : 0]
            }
        }

        try activity.append(probabilities: frames(0..<15), frameCount: 15)
        try activity.append(probabilities: frames(15..<36), frameCount: 21)
        let ranges = activity.finish(duration: 0.355)
        #expect(ranges.map(\.speaker) == [0, 1])
        #expect(ranges.map(\.start) == [0.05, 0.12])
        #expect(ranges.map(\.end) == [0.28, 0.355])
    }

    @Test func shortSpikesAndThresholdTiesAreNotSpeakers() throws {
        var activity = SpeakerActivitySegments(speakerCount: 1)
        try activity.append(probabilities: Array(repeating: 0.51, count: 19) + [0.5], frameCount: 20)
        #expect(activity.finish(duration: 0.20).isEmpty)
    }

    @Test func rejectsMismatchedSpeakerFrameDimensions() {
        var activity = SpeakerActivitySegments(speakerCount: 2)
        #expect(throws: SpeakerDiarizationEngine.EngineError.invalidModelOutput) {
            try activity.append(probabilities: [0.9, 0], frameCount: 2)
        }
    }

    @Test func stereoRecordingIsMixedAndResampledInBoundedBuffers() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
        ))
        let frameCount: AVAudioFrameCount = 144_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let channels = try #require(buffer.floatChannelData)
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            channels[0][index] = 0
            channels[1][index] = 0.6 * sin(Float(index) * 0.1)
        }
        do {
            let file = try AVAudioFile(
                forWriting: fixture, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
            )
            try file.write(from: buffer)
        }

        var sampleCount = 0
        var maximumBufferSize = 0
        var peak: Float = 0
        let duration = try SpeakerDiarizationEngine.readAudio(fixture) { samples in
            sampleCount += samples.count
            maximumBufferSize = max(maximumBufferSize, samples.count)
            peak = max(peak, samples.map(abs).max() ?? 0)
        }
        #expect(abs(duration - 3.0) < 0.01)
        #expect(abs(sampleCount - 48_000) < 160)
        #expect(maximumBufferSize <= 32_768)
        #expect((0.25...0.35).contains(peak))
    }

    @Test func macAppPackageContainsTheSpeakerModelAndMobileDoesNot() throws {
        let root = try #require(Bundle.main.resourceURL?.appendingPathComponent("SpeakerDiarizationModel"))
        #if targetEnvironment(macCatalyst)
        let model = root.appendingPathComponent("Nemotron3Diarizer_c128_split_w8a8.mlmodelc")
        let weights = model.appendingPathComponent("weights/weight.bin")
        #expect(try weights.resourceValues(forKeys: [.fileSizeKey]).fileSize == 99_249_792)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("learnable_sil_emb.bin").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pre_encode_proj_t.bin").path))
        #else
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #endif
    }
}
