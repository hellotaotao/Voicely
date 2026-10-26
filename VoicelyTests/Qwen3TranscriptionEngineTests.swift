//
//  Qwen3TranscriptionEngineTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Decoding audio for the Qwen3 engine. The recorder's whole pipeline runs at
/// 16 kHz mono Float32, which is exactly the model's target format — so real
/// recordings take the direct-read path, and the m4a/wav distinction only
/// changes which decoder AVAudioFile uses underneath.
struct Qwen3AudioPCMTests {
    private func makeWAV(rate: Double, frames: AVAudioFrameCount) throws -> URL {
        let url = TestTemporaryDirectory.fileURL(prefix: "qwen3pcm_", extension: "wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.4
        }
        try file.write(from: buffer)
        return url
    }

    private func makeM4A(rate: Double, frames: AVAudioFrameCount) throws -> URL {
        let url = TestTemporaryDirectory.fileURL(prefix: "qwen3pcm_", extension: "m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.4
        }
        try file.write(from: buffer)
        return url
    }

    /// 16 kHz mono Float32 hits the direct-read path. AVAudioFile.read throws a
    /// bare nilError when called again at EOF, so the loop must stop on frame
    /// position — this is the decode that failed for every real recording.
    @Test func decodesRecorderFormatWAVDirectly() throws {
        let url = try makeWAV(rate: 16_000, frames: 87_871)  // odd length, like a real take
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: url)
        #expect(samples.count == 87_871)
    }

    /// Same direct-read path, but with the read chunk boundary landing exactly
    /// on EOF (length a multiple of the 32_768 read capacity).
    @Test func decodesWhenEOFLandsOnChunkBoundary() throws {
        let url = try makeWAV(rate: 16_000, frames: 65_536)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: url)
        #expect(samples.count == 65_536)
    }

    /// The recorder's m4a output decodes to 16 kHz mono Float32 too, so the
    /// compressed container takes the same direct-read path.
    @Test func decodesRecorderFormatM4A() throws {
        let url = try makeM4A(rate: 16_000, frames: 32_000)  // 2 s
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: url)
        // AAC priming/padding shifts the exact frame count a little.
        #expect(abs(samples.count - 32_000) < 4_096)
    }

    /// Non-16 kHz input exercises the converter path.
    @Test func resamples48kWAVThroughConverter() throws {
        let url = try makeWAV(rate: 48_000, frames: 96_000)  // 2 s
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try Qwen3AudioPCM.loadPCM16kMono(url: url)
        #expect(abs(samples.count - 32_000) < 1_600)  // 2 s at 16 kHz, ±0.1 s
    }
}

struct Qwen3BackendTests {
    /// MLX needs the GPU, which iOS withdraws from a backgrounded app, so only
    /// a Mac with a capable GPU may use it.
    @Test func onlyAMacWithACapableGPUUsesMLX() {
        #expect(Qwen3Backend.resolve(isMacCatalyst: true, gpuSupportsMLX: true) == .mlx)
        #expect(Qwen3Backend.resolve(isMacCatalyst: true, gpuSupportsMLX: false) == .coreML)
        #expect(Qwen3Backend.resolve(isMacCatalyst: false, gpuSupportsMLX: true) == .coreML)
        #expect(Qwen3Backend.resolve(isMacCatalyst: false, gpuSupportsMLX: false) == .coreML)
    }

    @Test func modelNamesAreFriendly() {
        #expect(ModelManager.displayName(for: Qwen3Backend.mlx.modelIdentifier) == Qwen3ASRDefaults.modelDisplayName)
        #expect(ModelManager.displayName(for: Qwen3Backend.coreML.modelIdentifier) == Qwen3ASRDefaults.modelDisplayName)
        // Notes transcribed before the switch keep their Whisper identifiers.
        #expect(ModelManager.displayName(for: "openai_whisper-large-v3_turbo_954MB") == "Whisper Large v3 Turbo 954MB")
    }
}

struct Qwen3ASRDefaultsTests {
    @Test func autoLanguageMapsToNil() {
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: nil) == nil)
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "auto") == nil)
    }

    @Test func knownLanguagesMapToTheNamesTheModelExpects() {
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "chinese") == "Chinese")
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "english") == "English")
    }

    /// A key saved from the longer Whisper language list must not be passed on.
    @Test func languageTheModelDoesNotSupportMapsToNil() {
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "welsh") == nil)
    }

    @Test func everyOfferedLanguageHasAHint() {
        for language in LanguageConstants.availableLanguages where language != "auto" {
            #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: language) != nil)
        }
    }

    /// Both backends take slices up to the CoreML encoder's 30 s window; the
    /// unit tests run on the shorter cadence their fixtures are written for.
    @Test func sliceLimits() {
        #expect(Qwen3SliceLimits.production == Qwen3SliceLimits(singlePassSeconds: 30, chunkSeconds: 29, minimumCutSeconds: 15))
        #expect(Qwen3SliceLimits.current == Qwen3SliceLimits.testFixtures)
        for limits in [Qwen3SliceLimits.production, .testFixtures] {
            #expect(limits.minimumCutSeconds < limits.chunkSeconds)
            #expect(limits.chunkSeconds < limits.singlePassSeconds)
        }
    }

    /// The 4-bit weights drop text on long slices, and the package's
    /// long-input n-gram block stalls them.
    @Test func mlxUsesTheEightBitWeightsWithoutTheLongInputBlock() {
        #expect(Qwen3ASRDefaults.mlxModelId.hasSuffix("-8bit"))
        let options = Qwen3ASRModelStore.mlxOptions(languageHint: "English")
        #expect(options.longInputThresholdSeconds == .infinity)
        #expect(options.repetitionPenalty == Qwen3ASRDefaults.repetitionPenalty)
        #expect(options.language == "English")
    }

    @Test func chunkSizingStaysInsideFastPath() {
        #expect(Qwen3ASRDefaults.chunkSeconds < Qwen3ASRDefaults.singlePassSecondsLimit)
        #expect(Qwen3ASRDefaults.minimumChunkCutSeconds < Qwen3ASRDefaults.chunkSeconds)
        #expect(IncrementalTranscriptionTiming.defaultIntervalSeconds == Int(Qwen3ASRDefaults.chunkSeconds))
    }
}

struct Qwen3ModelFilesTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen3ModelFiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func touch(_ url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    @Test func mlxNeedsWeightsConfigAndVocabulary() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        touch(directory.appendingPathComponent("model.safetensors"))
        touch(directory.appendingPathComponent("config.json"))
        #expect(!Qwen3ASRModelStore.isComplete(directory, backend: .mlx))
        touch(directory.appendingPathComponent("vocab.json"))
        #expect(Qwen3ASRModelStore.isComplete(directory, backend: .mlx))
        // The MLX weights say nothing about the CoreML models.
        #expect(!Qwen3ASRModelStore.isComplete(directory, backend: .coreML))
    }

    @Test func coreMLNeedsEveryModelBundle() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        touch(directory.appendingPathComponent("config.json"))
        touch(directory.appendingPathComponent("vocab.json"))
        for bundle in Qwen3ASRDefaults.coreMLBundles.dropLast() {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(bundle), withIntermediateDirectories: true)
        }
        #expect(!Qwen3ASRModelStore.isComplete(directory, backend: .coreML))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(Qwen3ASRDefaults.coreMLBundles.last!), withIntermediateDirectories: true)
        #expect(Qwen3ASRModelStore.isComplete(directory, backend: .coreML))
    }

    /// The model ships in the app's resources, filled by a build phase.
    @Test func theAppBundlesTheModelForThisPlatform() throws {
        let directory = try #require(Qwen3ASRModelStore.defaultModelDirectory())
        #expect(directory.lastPathComponent == Qwen3ASRModelStore.bundledDirectoryName)
        #expect(Qwen3ASRModelStore.isComplete(directory, backend: .current))
    }

    @Test func aMissingModelFailsToLoadWithoutNetwork() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Qwen3ASRModelStore(backend: .mlx, modelDirectory: directory)
        await #expect(throws: Qwen3ASRModelStore.StoreError.self) { try await store.prepareModel() }
    }
}

struct Qwen3CoreMLTokenPickTests {
    private func pick(_ logits: [Float], seen: Set<Int32> = [], excluding: Int32? = nil) -> Int32 {
        Qwen3CoreMLModel.pickToken(count: logits.count, seen: seen, excluding: excluding) { logits[$0] }
    }

    @Test func picksTheHighestLogit() {
        #expect(pick([0.1, 2.0, 1.9]) == 1)
    }

    /// The loop a stretch of laughter produces: the same token narrowly wins
    /// every step until the token limit.
    @Test func aTokenAlreadyEmittedLosesANarrowLead() {
        #expect(pick([0.1, 2.0, 1.9], seen: [1]) == 2)
    }

    @Test func aRepeatedTokenStillWinsWhenItIsClearlyBest() {
        #expect(pick([0.1, 9.0, 1.9], seen: [1]) == 1)
    }

    @Test func thePenaltyAlsoLowersNegativeLogits() {
        #expect(pick([-1.0, -1.05], seen: [0]) == 1)
    }

    @Test func anExcludedTokenIsNeverPicked() {
        #expect(pick([0.1, 2.0, 1.9], excluding: 1) == 2)
    }

    @Test func aNaNLogitCannotWin() {
        #expect(pick([.nan, 0.5, 0.2]) == 1)
    }
}

@MainActor
struct ModelManagerLoadingTests {
    @Test func loadingReportsProgressAndEndsLoaded() async {
        var states: [ModelState] = []
        let manager = ModelManager(loader: { progress in
            progress(.loading, 0.4)
            progress(.prewarming, 0.98)
        })
        let observation = manager.$modelState.sink { states.append($0) }
        defer { observation.cancel() }

        await manager.loadModel()

        #expect(manager.isModelLoaded())
        #expect(manager.loadingProgressValue == 1)
        #expect(manager.currentModelIdentifier() == manager.selectedModel)
        #expect(states.contains(.loading) && states.contains(.prewarming))
    }

    @Test func aFailedLoadLeavesTheModelUnloadedWithAMessage() async {
        struct Broken: LocalizedError { var errorDescription: String? { "broken" } }
        let manager = ModelManager(loader: { _ in throw Broken() })

        await manager.loadModel()

        #expect(!manager.isModelLoaded())
        #expect(manager.modelState == .unloaded)
        #expect(manager.errorMessage?.contains("broken") == true)
        #expect(manager.currentModelIdentifier() == nil)
    }

    @Test func concurrentCallersShareOneLoad() async {
        var loads = 0
        let manager = ModelManager(loader: { _ in
            loads += 1
            try await Task.sleep(nanoseconds: 50_000_000)
        })

        async let first: Void = manager.loadModel()
        async let second: Void = manager.loadModel()
        _ = await (first, second)

        #expect(loads == 1)
        #expect(manager.isModelLoaded())
    }
}

struct RetiredModelFilesTests {
    @Test func downloadedModelsAreRemovedAndRecordingsKept() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetiredModels-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let whisper = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        let qwen = support.appendingPathComponent("Qwen3ASR/models/mlx-community/Qwen3-ASR-0.6B-8bit")
        try FileManager.default.createDirectory(at: whisper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: qwen, withIntermediateDirectories: true)
        let recording = documents.appendingPathComponent("recording.m4a")
        FileManager.default.createFile(atPath: recording.path, contents: Data())
        let store = support.appendingPathComponent("default.store")
        FileManager.default.createFile(atPath: store.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }

        RetiredModelFiles.remove(documentsDirectory: documents, applicationSupportDirectory: support)

        #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent("huggingface").path))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Qwen3ASR").path))
        #expect(FileManager.default.fileExists(atPath: recording.path))
        #expect(FileManager.default.fileExists(atPath: store.path))
    }
}

struct LanguageMigrationTests {
    @Test func aLanguageQwenDoesNotSupportFallsBackToAuto() throws {
        let suite = "LanguageMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("welsh", forKey: Qwen3ASRDefaults.selectedLanguageKey)
        Qwen3ASRDefaults.migrateSelectedLanguage(in: defaults)
        #expect(defaults.string(forKey: Qwen3ASRDefaults.selectedLanguageKey) == "auto")

        defaults.set("chinese", forKey: Qwen3ASRDefaults.selectedLanguageKey)
        Qwen3ASRDefaults.migrateSelectedLanguage(in: defaults)
        #expect(defaults.string(forKey: Qwen3ASRDefaults.selectedLanguageKey) == "chinese")
    }
}
