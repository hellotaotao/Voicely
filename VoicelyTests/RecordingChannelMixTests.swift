import AVFoundation
import Testing
@testable import Voicely

struct RecordingChannelMixTests {
    private func buffer(channels: AVAudioChannelCount, interleaved: Bool = false, activeChannel: Int? = nil) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: channels, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        buffer.frameLength = 4_096
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                let value: Float = (activeChannel == -1 || channel == (activeChannel ?? Int(channels) - 1)) ? 0.5 : 0
                if interleaved { data[0][frame * Int(channels) + channel] = value }
                else { data[channel][frame] = value }
            }
        }
        return buffer
    }

    @Test(arguments: [false, true], [0, 1, -1])
    func stereoChannelsSurviveMix(interleaved: Bool, activeChannel: Int) throws {
        let input = try buffer(channels: 2, interleaved: interleaved, activeChannel: activeChannel)
        let mono = try #require(AudioRecordingService.mixedDownToMono(input))
        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == 48_000)
        #expect(mono.frameLength == input.frameLength)
        let samples = try #require(mono.floatChannelData?[0])
        #expect((0..<Int(mono.frameLength)).allSatisfy { abs(samples[$0] - (activeChannel == -1 ? 0.5 : 0.25)) < 0.00001 })
    }

    @Test func monoInputKeepsItsSamples() throws {
        let input = try buffer(channels: 1)
        let mono = try #require(AudioRecordingService.mixedDownToMono(input))
        #expect(mono.frameLength == input.frameLength)
        #expect(mono.floatChannelData?[0][0] == 0.5)
    }

    @Test func emptyInputIsRejected() throws {
        let input = try buffer(channels: 2)
        input.frameLength = 0
        #expect(AudioRecordingService.mixedDownToMono(input) == nil)
    }

    @Test(arguments: [false, true], [0, 1, -1])
    func monoResamplingProducesNonzeroWhisperAudio(interleaved: Bool, activeChannel: Int) throws {
        let input = try buffer(channels: 2, interleaved: interleaved, activeChannel: activeChannel)
        let mono = try #require(AudioRecordingService.mixedDownToMono(input))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: mono.format, to: target))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1_400))
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return mono
        }
        #expect(error == nil)
        #expect(status != .error)
        #expect(output.frameLength > 1_000)
        let samples = try #require(output.floatChannelData?[0])
        #expect((0..<Int(output.frameLength)).contains { abs(samples[$0]) > 0.1 })
    }
}
