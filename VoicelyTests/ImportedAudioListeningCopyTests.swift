import AVFoundation
import Foundation
import Testing
@testable import Voicely

@Suite(.serialized)
struct ImportedAudioListeningCopyTests {
    /// 44.1 kHz stereo with a tone in the left channel only, like a phone or
    /// field recorder file where one side carries the voice.
    private func makeStereoFile(seconds: Double) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for frame in 0..<Int(frames) {
            left[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 44_100)
            right[frame] = 0
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo_\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

    @Test func stereoBecomesAudibleMonoAtSixteenKilohertz() throws {
        let source = try makeStereoFile(seconds: 3)
        let pcm = FileManager.default.temporaryDirectory.appendingPathComponent("mono_\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: pcm)
        }
        try ImportedAudioListeningCopy.writeMonoPCM(from: source, to: pcm)
        let file = try AVAudioFile(forReading: pcm)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(abs(Double(file.length) - 48_000) < 400)
        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: pcm)
        // Half the left channel's 0.5 amplitude once averaged with silence.
        #expect(peak(samples) > 0.2)
    }

    @Test func listeningCopyIsASmallMonoM4A() async throws {
        let source = try makeStereoFile(seconds: 3)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("copy_\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try await ImportedAudioListeningCopy.write(from: source, to: destination)
        let file = try AVAudioFile(forReading: destination)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(abs(Double(file.length) / 16_000 - 3) < 0.1)
        #expect(peak(try Qwen3AudioPCM.loadPCM16kMono(url: destination)) > 0.1)
    }

    @Test func transcriptionDecodeKeepsStereoAudible() throws {
        let source = try makeStereoFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(peak(try Qwen3AudioPCM.loadPCM16kMono(url: source)) > 0.1)
    }

    // MARK: Import flow

    @Test @MainActor func aFinishedImportKeepsItsAudio() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        var stored: [URL] = []
        transcriber.storeImportedAudio = { source in
            stored.append(source)
            return "recording_kept.m4a"
        }
        transcriber.transcribeSegmentOutcome = { _ in .transcribed(.init(text: "words", duration: 1, modelIdentifier: "m")) }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(stored == [url])
        #expect(note.audioFilePath == "recording_kept.m4a")
        #expect(note.transcriptSpans != nil)
    }

    @Test @MainActor func aFailedImportStaysWithoutAudioForItsRetry() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        var storeCalls = 0
        transcriber.storeImportedAudio = { _ in
            storeCalls += 1
            return "recording_kept.m4a"
        }
        transcriber.transcribeSegmentOutcome = { _ in .engineError("failed") }
        let note = VoiceNote(title: "imported", audioFilePath: "")
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(note.transcriptionOutcome == .failed)
        #expect(storeCalls == 0)
        #expect(note.audioFilePath.isEmpty)
    }

    @Test @MainActor func reTranscribingARecordingLeavesItsAudioAlone() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 40)
        let store = SegmentedAudioTestSupport.makeStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.directory)
        }
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store)
        var storeCalls = 0
        transcriber.storeImportedAudio = { _ in
            storeCalls += 1
            return "other.m4a"
        }
        transcriber.transcribeSegmentOutcome = { _ in .transcribed(.init(text: "words", duration: 1, modelIdentifier: "m")) }
        let note = VoiceNote(title: "recorded", audioFilePath: "recording_1.m4a")
        await transcriber.transcribe(note: note, sourceURL: url)
        #expect(storeCalls == 0)
        #expect(note.audioFilePath == "recording_1.m4a")
    }
}
