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

    /// Two callers at once, such as a recording that stops during an English
    /// import, take turns: reading the model's progress stream together crashes.
    @Test func callersTakeTurnsOnTheEngine() async throws {
        let file = try AVAudioFile(forReading: ParakeetRealModelInput.audioURL)
        let end = min(file.length, AVAudioFramePosition(30 * file.processingFormat.sampleRate))
        async let first = ParakeetEnglishEngine.shared.transcribe(
            fileURL: ParakeetRealModelInput.audioURL, startFrame: 0, endFrame: end)
        async let second = ParakeetEnglishEngine.shared.transcribe(
            fileURL: ParakeetRealModelInput.audioURL, startFrame: 0, endFrame: end)
        let results = try await [first, second]
        await ParakeetEnglishEngine.shared.unload()

        #expect(results[0] == results[1])
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
        let replaced = await coordinator.transcribeEnglishStretches(mode: .automatic)
        print("🔍 Parakeet pass: \(ProcessInfo.processInfo.systemUptime - started) s")
        print("🔍 Parakeet tail: " + coordinator.accumulatedTranscript.suffix(300))

        let stretches = EnglishStretchRouting.stretches(in: tagged, mode: .automatic)
        try #require(!stretches.isEmpty, "No English stretch of three minutes in this recording")
        #expect(replaced)
        #expect(coordinator.accumulatedTranscript != qwenTranscript)
        // Slices outside the stretches keep Qwen3-ASR's text.
        let routedSlices = Set(stretches.flatMap { Array($0) })
        let kept = coordinator.languageTaggedSlices.enumerated().filter { !routedSlices.contains($0.offset) }
        #expect(kept.allSatisfy { $0.element.text == tagged[$0.offset].text })
        #expect(coordinator.accumulatedSpans?.count == coordinator.languageTaggedSlices.filter { $0.text != nil }.count)
    }

    /// A live recording with English chosen end to end: Parakeet decodes it
    /// slice by slice as it is "recorded" and whole again at stop, and
    /// Qwen3-ASR is never loaded.
    @Test @MainActor func englishRecordingRunsOnParakeetAlone() async throws {
        let file = try AVAudioFile(forReading: ParakeetRealModelInput.audioURL)
        let pcmURL = try ParakeetEnglishEngine.writeMono16k(
            from: ParakeetRealModelInput.audioURL, startFrame: 0, endFrame: file.length)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let modelManager = ModelManager()
        let service = TranscriptionService(modelManager: modelManager)
        let noteID = UUID()
        service.setLanguageKey("english", for: noteID)
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        coordinator.transcribesWithParakeet = true
        coordinator.configureTelemetry(noteID: noteID)
        await ParakeetEnglishEngine.shared.hold()

        let totalFrames = try AVAudioFile(forReading: pcmURL).length
        let liveStarted = ProcessInfo.processInfo.systemUptime
        var frame: AVAudioFramePosition = 0
        while frame < totalFrames {
            frame = min(totalFrames, frame + 16_000)
            await coordinator.transcribeSegment(upToFrame: frame)
        }
        let live = await coordinator.stop(currentFrame: totalFrames)
        let liveSeconds = ProcessInfo.processInfo.systemUptime - liveStarted
        let sliceCount = coordinator.languageTaggedSlices.count

        let wholeStarted = ProcessInfo.processInfo.systemUptime
        let replaced = await coordinator.transcribeEnglishStretches(mode: .english)
        let wholeSeconds = ProcessInfo.processInfo.systemUptime - wholeStarted
        let whole = coordinator.accumulatedTranscript
        await ParakeetEnglishEngine.shared.endHold()

        let liveWords = live.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        let wholeWords = whole.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        let audioSeconds = Double(totalFrames) / 16_000
        print("🔍 English recording: \(audioSeconds) s of audio, \(sliceCount) slices")
        print("🔍 live: \(liveWords.count) words in \(liveSeconds) s (slicing included); whole at stop: \(wholeWords.count) words in \(wholeSeconds) s")
        print("🔍 live head: " + live.prefix(300))
        print("🔍 whole head: " + whole.prefix(300))
        #expect(!modelManager.isModelLoaded())
        #expect(replaced)
        #expect(liveWords.count > Int(audioSeconds))
        #expect(wholeWords.count > Int(audioSeconds))
        #expect(coordinator.unrecoveredSliceCount == 0)
    }

    /// A recording with English chosen that switches to Auto Detect halfway,
    /// with both real models, ends with the same text as one that had Auto
    /// Detect from the start: what Parakeet took before the switch is
    /// transcribed again by Qwen3-ASR, which loads at the switch.
    @Test @MainActor func englishRecordingSwitchedToAutoDetectEndsAsAutoDetect() async throws {
        let file = try AVAudioFile(forReading: ParakeetRealModelInput.audioURL)
        let pcmURL = try ParakeetEnglishEngine.writeMono16k(
            from: ParakeetRealModelInput.audioURL, startFrame: 0, endFrame: file.length)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let totalFrames = try AVAudioFile(forReading: pcmURL).length
        let switchFrame = totalFrames / 2

        func replay(_ coordinator: IncrementalTranscriptionCoordinator, from start: AVAudioFramePosition,
                    to end: AVAudioFramePosition) async {
            var frame = start
            while frame < end {
                frame = min(end, frame + 16_000)
                await coordinator.transcribeSegment(upToFrame: frame)
            }
        }

        // English chosen, switched halfway.
        let modelManager = ModelManager()
        let service = TranscriptionService(modelManager: modelManager)
        let noteID = UUID()
        service.setLanguageKey("english", for: noteID)
        let switched = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        switched.transcribesWithParakeet = true
        switched.configureTelemetry(noteID: noteID)
        service.beginEnglishRecording(noteID: noteID)
        await service.waitForEngineSwitch()
        await replay(switched, from: 0, to: switchFrame)
        let beforeSwitch = switched.accumulatedTranscript
        switched.switchToAutoDetect()
        service.switchRecordingToAutoDetect(noteID: noteID)
        await replay(switched, from: switchFrame, to: totalFrames)
        let stopStarted = ProcessInfo.processInfo.systemUptime
        _ = await switched.stop(currentFrame: totalFrames)
        _ = await switched.transcribeEnglishStretches(mode: .automatic)
        let stopSeconds = ProcessInfo.processInfo.systemUptime - stopStarted
        await service.waitForEngineSwitch()

        // Auto Detect from the start, with the same loaded model.
        try #require(modelManager.isModelLoaded(), "Qwen3-ASR did not load at the switch")
        let autoNoteID = UUID()
        service.setLanguageKey("auto", for: autoNoteID)
        let automatic = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        automatic.configureTelemetry(noteID: autoNoteID)
        await replay(automatic, from: 0, to: totalFrames)
        _ = await automatic.stop(currentFrame: totalFrames)
        _ = await automatic.transcribeEnglishStretches(mode: .automatic)

        print("🔍 switched at \(Double(switchFrame) / 16_000) s of \(Double(totalFrames) / 16_000) s; stop took \(stopSeconds) s")
        print("🔍 before the switch (Parakeet): " + beforeSwitch.prefix(200))
        print("🔍 switched, final: " + switched.accumulatedTranscript.prefix(200))
        #expect(switched.accumulatedTranscript == automatic.accumulatedTranscript)
        #expect(switched.unrecoveredSliceCount == 0)
        #expect(!service.isRecordingEnglish)
    }

    /// A short import end to end with both real models: Qwen3-ASR decodes it
    /// in one pass, and the language it names sends the file to Parakeet.
    @Test @MainActor func shortEnglishImportGoesToParakeet() async throws {
        let clipURL = try Self.writeShortClip()
        defer { try? FileManager.default.removeItem(at: clipURL) }
        let modelManager = ModelManager()
        await modelManager.loadModel()
        try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")
        let service = TranscriptionService(modelManager: modelManager)
        let transcriber = SegmentedAudioTranscriber(
            transcriptionService: service, progressStore: SegmentedAudioTestSupport.makeStore())
        transcriber.storeImportedAudio = { _ in "imported.m4a" }
        let note = VoiceNote(title: "Import", audioFilePath: "")
        service.setLanguageKey("auto", for: note.id)

        await transcriber.transcribe(note: note, sourceURL: clipURL)

        #expect(!service.shouldSegmentTranscription(audioDuration: note.duration))
        print("🔍 Parakeet: " + note.transcription)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(note.usedParakeetForEnglish)
        #expect(!note.transcription.isEmpty)
    }

    /// Re-transcribing a short saved recording end to end with both real models.
    @Test @MainActor func shortEnglishRetranscriptionGoesToParakeet() async throws {
        let clipURL = try Self.writeShortClip()
        defer { try? FileManager.default.removeItem(at: clipURL) }
        let modelManager = ModelManager()
        await modelManager.loadModel()
        try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")
        let service = TranscriptionService(modelManager: modelManager)
        service.deviceIDProvider = { "this-device" }
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        let note = VoiceNote(title: "Saved", audioFilePath: clipURL.path)
        note.transcriptionOriginDeviceID = "this-device"
        note.setTranscript("old text", spans: nil)
        note.completeTranscription()
        note.transcriptionOutcome = .transcribed
        service.setLanguageKey("auto", for: note.id)

        #expect(await service.requestTranscription(for: note, force: true))

        #expect(!service.shouldSegmentTranscription(audioDuration: note.duration))
        print("🔍 Parakeet: " + note.transcription)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(note.usedParakeetForEnglish)
        #expect(!note.transcription.isEmpty)
    }

    /// Writes a minute into the recording, short enough for one pass, to an
    /// m4a file like the ones the app keeps.
    static func writeShortClip() throws -> URL {
        let file = try AVAudioFile(forReading: ParakeetRealModelInput.audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(60 * sampleRate)
        let pcmURL = try ParakeetEnglishEngine.writeMono16k(
            from: ParakeetRealModelInput.audioURL,
            startFrame: start,
            endFrame: start + AVAudioFramePosition((Qwen3ASRDefaults.singlePassSecondsLimit - 1) * sampleRate))
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let pcm = try AVAudioFile(forReading: pcmURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm.processingFormat, frameCapacity: AVAudioFrameCount(pcm.length)))
        try pcm.read(into: buffer)
        let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("voicely_clip_\(UUID().uuidString).m4a")
        let clip = try AVAudioFile(forWriting: clipURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        ])
        try clip.write(from: buffer)
        return clipURL
    }
}
