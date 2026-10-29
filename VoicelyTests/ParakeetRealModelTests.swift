import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Input for the real Parakeet check: place a recording at `audioURL` (inside
/// the test host's container) to enable it.
enum ParakeetRealModelInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-parakeet-real", isDirectory: true)
    static let audioURL = directory.appendingPathComponent("audio.m4a")
    static var isConfigured: Bool { FileManager.default.fileExists(atPath: audioURL.path) }
}

/// Loads the bundled Parakeet model and transcribes a real recording, the
/// way the English stretches are transcribed. Unit tests use a fake.
@Suite(.serialized, .enabled(if: ParakeetRealModelInput.isConfigured))
struct ParakeetRealModelTests {
    @Test func transcribesARealRecordingFromTheBundledModel() async throws {
        #expect(ParakeetEnglishEngine.isAvailable)
        let file = try AVAudioFile(forReading: ParakeetRealModelInput.audioURL)
        let sampleRate = file.processingFormat.sampleRate
        // Start a minute in, so word times must carry the offset.
        let start = AVAudioFramePosition(60 * sampleRate)
        let started = ProcessInfo.processInfo.systemUptime
        let words = try await ParakeetEnglishEngine.shared.transcribe(
            fileURL: ParakeetRealModelInput.audioURL, startFrame: start, endFrame: file.length)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        await ParakeetEnglishEngine.shared.unload()

        let audioSeconds = Double(file.length - start) / sampleRate
        print("🔍 Parakeet: \(words.count) words, \(audioSeconds) s of audio in \(seconds) s (load included)")
        print("🔍 " + words.prefix(40).map(\.text).joined(separator: " "))
        #expect(words.count > Int(audioSeconds))
        #expect(words.first.map { $0.start >= 60 } == true)
        #expect(words.last.map { $0.end <= 60 + audioSeconds + 1 } == true)
    }

    /// A live recording end to end with both real models: Qwen3-ASR decodes
    /// it slice by slice as it is "recorded", then the English stretch goes
    /// to Parakeet.
    @Test @MainActor func liveRecordingSendsItsEnglishStretchToParakeet() async throws {
        let file = try AVAudioFile(forReading: ParakeetRealModelInput.audioURL)
        let pcmURL = try ParakeetEnglishEngine.writeMono16k(
            from: ParakeetRealModelInput.audioURL, startFrame: 0, endFrame: file.length)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let modelManager = ModelManager()
        await modelManager.loadModel()
        try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")
        let service = TranscriptionService(modelManager: modelManager)
        let noteID = UUID()
        service.setLanguageKey("auto", for: noteID)
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        coordinator.configureTelemetry(noteID: noteID)

        let totalFrames = try AVAudioFile(forReading: pcmURL).length
        var frame: AVAudioFramePosition = 0
        while frame < totalFrames {
            frame = min(totalFrames, frame + 16_000)
            await coordinator.transcribeSegment(upToFrame: frame)
        }
        let qwenTranscript = await coordinator.stop(currentFrame: totalFrames)
        let tagged = coordinator.languageTaggedSlices
        print("🔍 tags: " + tagged.map { $0.language ?? "-" }.joined(separator: " "))

        let started = ProcessInfo.processInfo.systemUptime
        let qwenVersion = await coordinator.transcribeEnglishStretches(mode: .automatic)
        print("🔍 Parakeet pass: \(ProcessInfo.processInfo.systemUptime - started) s")
        print("🔍 Parakeet tail: " + coordinator.accumulatedTranscript.suffix(300))

        let stretches = EnglishStretchRouting.stretches(in: tagged, mode: .automatic)
        try #require(!stretches.isEmpty, "No English stretch of three minutes in this recording")
        #expect(qwenVersion?.text == qwenTranscript)
        #expect(coordinator.accumulatedTranscript != qwenTranscript)
        // Slices outside the stretches keep Qwen3-ASR's text.
        let routedSlices = Set(stretches.flatMap { Array($0) })
        let kept = coordinator.languageTaggedSlices.enumerated().filter { !routedSlices.contains($0.offset) }
        #expect(kept.allSatisfy { $0.element.text == tagged[$0.offset].text })
        #expect(coordinator.accumulatedSpans?.count == coordinator.languageTaggedSlices.filter { $0.text != nil }.count)
    }
}
