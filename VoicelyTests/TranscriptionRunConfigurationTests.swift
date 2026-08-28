import Foundation
import Testing
@testable import Voicely

struct TranscriptionRunConfigurationTests {
    final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    @Test @MainActor func capturesQwenSettingsAndCapabilitiesOnce() {
        let service = TranscriptionService()
        service.engineModeProvider = { .qwen3ASR }
        service.selectedLanguageProvider = { "chinese" }
        service.transcriptionPromptProvider = { " Acme, Project Atlas " }

        let configuration = service.captureRunConfiguration()

        #expect(configuration.engineMode == .qwen3ASR)
        #expect(configuration.modelIdentifier == Qwen3ASRDefaults.modelId)
        #expect(configuration.selectedLanguageKey == "chinese")
        #expect(configuration.prompt == "Acme, Project Atlas")
        #expect(configuration.chunkSeconds == Qwen3ASRDefaults.chunkSeconds)
        #expect(configuration.singlePassSecondsLimit == Qwen3ASRDefaults.singlePassSecondsLimit)
        #expect(configuration.minimumChunkCutSeconds == Qwen3ASRDefaults.minimumChunkCutSeconds)
        #expect(configuration.timingGranularity == .segment)
    }

    @Test @MainActor func capturesWhisperModelAndWordTimingCapability() {
        let manager = LoadedModelManager()
        manager.selectedModel = "openai_whisper-small"
        let service = TranscriptionService(modelManager: manager)
        service.engineModeProvider = { .whisperKit }
        service.selectedLanguageProvider = { "auto" }
        service.transcriptionPromptProvider = { "   " }

        let configuration = service.captureRunConfiguration()

        #expect(configuration.engineMode == .whisperKit)
        #expect(configuration.modelIdentifier == "openai_whisper-small")
        #expect(configuration.selectedLanguageKey == "auto")
        #expect(configuration.prompt == nil)
        #expect(configuration.chunkSeconds == Double(IncrementalTranscriptionTiming.defaultIntervalSeconds))
        #expect(configuration.singlePassSecondsLimit == 30)
        #expect(configuration.minimumChunkCutSeconds == Double(IncrementalTranscriptionTiming.minimumCutSeconds))
        #expect(configuration.timingGranularity == .word)
    }

    @Test func codableRoundTripPreservesEveryField() throws {
        let original = TranscriptionRunConfiguration(
            engineMode: .qwen3ASR,
            modelIdentifier: Qwen3ASRDefaults.modelId,
            selectedLanguageKey: "english",
            prompt: "names and terms",
            chunkSeconds: 14,
            singlePassSecondsLimit: 15,
            minimumChunkCutSeconds: 7,
            timingGranularity: .segment
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionRunConfiguration.self, from: data)

        #expect(decoded == original)
    }

    @Test @MainActor func transcriptionUsesCapturedConfigurationAfterDefaultsChange() async {
        let manager = LoadedModelManager()
        manager.selectedModel = "openai_whisper-small"
        let service = TranscriptionService(modelManager: manager)
        service.engineModeProvider = { .whisperKit }
        service.selectedLanguageProvider = { "english" }
        service.transcriptionPromptProvider = { "Project Atlas" }
        let captured = service.captureRunConfiguration()

        service.engineModeProvider = { .qwen3ASR }
        service.selectedLanguageProvider = { "chinese" }
        service.transcriptionPromptProvider = { "Different prompt" }

        var observed: TranscriptionRunConfiguration?
        service.transcribeImpl = { _, configuration, _ in
            observed = configuration
            return "hello"
        }

        let outcome = await service.transcribeAudioOutcome(
            filePath: "/tmp/captured-configuration.wav",
            driveTelemetry: false,
            configuration: captured
        )

        #expect(observed == captured)
        guard case .transcribed(let result) = outcome else {
            Issue.record("Expected a transcription result")
            return
        }
        #expect(result.modelIdentifier == captured.modelIdentifier)
        #expect(result.timingGranularity == .word)
    }

    @Test @MainActor func activeRunOwnsConfigurationUntilMatchingTokenEndsIt() {
        let service = TranscriptionService()
        service.engineModeProvider = { .whisperKit }
        let configuration = service.captureRunConfiguration()

        let token = service.beginTranscriptionRun(configuration: configuration)

        #expect(token != nil)
        #expect(service.isRunConfigurationLocked)
        #expect(service.activeRunConfiguration == configuration)
        #expect(service.beginTranscriptionRun(configuration: configuration) == nil)
        #expect(service.unloadEngine(.whisperKit) == false)

        service.endTranscriptionRun(TranscriptionRunToken())
        #expect(service.isRunConfigurationLocked)

        if let token {
            service.endTranscriptionRun(token)
        }
        #expect(!service.isRunConfigurationLocked)
        #expect(service.activeRunConfiguration == nil)
    }
}
