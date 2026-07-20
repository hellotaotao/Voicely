//
//  Qwen3TranscriptionEngineTests.swift
//  VoicelyTests
//

import Foundation
import Testing
@testable import Voicely

struct TranscriptionEngineModeTests {
    @Test func defaultsToQwen3OnSupportedHardware() {
        #expect(TranscriptionEngineMode.resolve(fromRawValue: nil, deviceSupportsQwen3: true) == .qwen3ASR)
    }

    @Test func resolvesStoredValue() {
        #expect(TranscriptionEngineMode.resolve(fromRawValue: "whisperKit", deviceSupportsQwen3: true) == .whisperKit)
        #expect(TranscriptionEngineMode.resolve(fromRawValue: "qwen3ASR", deviceSupportsQwen3: true) == .qwen3ASR)
    }

    @Test func invalidStoredValueFallsBackToDefault() {
        #expect(TranscriptionEngineMode.resolve(fromRawValue: "coreML", deviceSupportsQwen3: true) == .qwen3ASR)
    }

    @Test func unsupportedHardwareAlwaysResolvesWhisper() {
        #expect(TranscriptionEngineMode.resolve(fromRawValue: nil, deviceSupportsQwen3: false) == .whisperKit)
        #expect(TranscriptionEngineMode.resolve(fromRawValue: "qwen3ASR", deviceSupportsQwen3: false) == .whisperKit)
    }

    /// The legacy suites exercise the Whisper paths with mocked model managers,
    /// so a test process without an explicitly stored engine must keep them on
    /// Whisper. (This test itself runs in that environment.)
    @Test func testRunWithoutStoredValueDefaultsToWhisper() {
        let defaults = UserDefaults(suiteName: "Qwen3EngineModeTests-\(UUID().uuidString)")!
        defaults.removeObject(forKey: TranscriptionEngineMode.storageKey)
        #expect(TranscriptionEngineMode.currentResolved(userDefaults: defaults) == .whisperKit)
    }

    @Test func testRunWithStoredValueHonoursIt() {
        let defaults = UserDefaults(suiteName: "Qwen3EngineModeTests-\(UUID().uuidString)")!
        defaults.set("qwen3ASR", forKey: TranscriptionEngineMode.storageKey)
        let resolved = TranscriptionEngineMode.currentResolved(userDefaults: defaults)
        // On MLX-capable hardware (Mac test runs) the stored choice wins; on
        // the simulator the device gate still forces Whisper.
        if TranscriptionDeviceSupport.deviceSupportsQwen3 {
            #expect(resolved == .qwen3ASR)
        } else {
            #expect(resolved == .whisperKit)
        }
        defaults.removeObject(forKey: TranscriptionEngineMode.storageKey)
    }
}

struct Qwen3ASRDefaultsTests {
    @Test func autoLanguageMapsToNil() {
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "auto") == nil)
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: nil) == nil)
    }

    @Test func knownLanguagesMapToISOCodes() {
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "chinese") == "zh")
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "english") == "en")
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "japanese") == "ja")
    }

    @Test func unknownLanguageMapsToNil() {
        #expect(Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: "klingon") == nil)
    }

    @Test func chunkSizingStaysInsideFastPath() {
        #expect(Qwen3ASRDefaults.chunkSeconds < Qwen3ASRDefaults.singlePassSecondsLimit)
        #expect(Qwen3ASRDefaults.minimumChunkCutSeconds < Qwen3ASRDefaults.chunkSeconds)
    }
}

struct Qwen3ASRModelStoreTests {
    /// The hub layout (…/models/<org>/<name>) is load-bearing: the package's
    /// downloader derives its download base by stripping that suffix.
    @Test func modelDirectoryUsesHubLayout() throws {
        let directory = try Qwen3ASRModelStore.modelDirectory()
        let expectedSuffix = ["models"] + Qwen3ASRDefaults.modelId.split(separator: "/").map(String.init)
        let components = directory.pathComponents.suffix(expectedSuffix.count)
        #expect(Array(components) == expectedSuffix)
        #expect(directory.pathComponents.contains("Qwen3ASR"))
    }

    @Test func downloadDetectionNeedsWeightsAndVocab() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen3StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(Qwen3ASRModelStore.isModelDownloaded(at: directory) == false)

        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("model.safetensors").path, contents: Data())
        #expect(Qwen3ASRModelStore.isModelDownloaded(at: directory) == false)

        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("vocab.json").path, contents: Data())
        #expect(Qwen3ASRModelStore.isModelDownloaded(at: directory) == true)
    }
}

@MainActor
struct Qwen3EngineRoutingTests {
    /// A service pinned to Qwen3 without downloaded weights must report
    /// itself unavailable instead of falling through to Whisper state.
    @Test func qwenModeWithoutWeightsIsNotReady() {
        let service = TranscriptionService()
        service.engineModeProvider = { .qwen3ASR }
        // No weights are downloaded in the test environment.
        guard !Qwen3ASRModelStore.isModelDownloaded() else { return }
        #expect(service.isWhisperAvailable() == false)
        #expect(service.currentEngine == .notAvailable)
    }

    @Test func engineModelIdentifierFollowsMode() {
        let service = TranscriptionService()
        service.engineModeProvider = { .qwen3ASR }
        #expect(service.currentEngineModelIdentifier() == Qwen3ASRDefaults.modelId)
    }

    @Test func qwenDisplayNameIsFriendly() {
        #expect(ModelManager.displayName(for: Qwen3ASRDefaults.modelId) == Qwen3ASRDefaults.modelDisplayName)
    }
}

@MainActor
struct TranscriptionMemoryPressureTests {
    /// The segmented path transcribes many chunks back to back, so a warning
    /// that lands mid-run must be ignored — dropping the model between chunks
    /// would reload hundreds of MB each time and worsen the pressure.
    @Test func memoryWarningIsIgnoredWhileTranscribing() {
        let service = TranscriptionService()
        service.engineModeProvider = { .whisperKit }
        service.loadingProgress = 0.5
        service.isTranscribing = true

        service.handleMemoryWarning()

        #expect(service.loadingProgress == 0.5)
    }

    /// Idle: the resident model is the process's largest allocation, so a
    /// warning releases it. Both engines reload lazily on the next run.
    @Test func memoryWarningReleasesEngineWhenIdle() {
        let service = TranscriptionService()
        service.engineModeProvider = { .whisperKit }
        service.loadingProgress = 0.5
        service.isTranscribing = false

        service.handleMemoryWarning()

        #expect(service.loadingProgress == 0.0)
    }
}
