//
//  VoicelyTests.swift
//  VoicelyTests
//
//  Created by Tao Wang on 1/6/2025.
//

import Testing
@testable import Voicely

struct VoicelyTests {

    final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    @Test @MainActor func cancelTranscriptionReturnsNilAndStopsUpdates() async {
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager())

        service.transcribeImpl = { _, _, _ in
            for _ in 0..<10 {
                if Task.isCancelled {
                    return .cancelled
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return "ok"
        }

        let task = Task { await service.transcribeAudio(filePath: "dummy.m4a") }
        service.cancelTranscription()
        let result = await task.value

        #expect(result == nil)
        #expect(service.wasTranscriptionCancelled() == true)
        #expect(service.isTranscribing == false)
    }

    @Test func appRuntimeDetectsTestEnvironment() {
        #expect(AppRuntime.isRunningTests == true)
    }

    @Test func recordingStopResultWaitsForConversionOnlyWhenTranscriptIsEmpty() async {
        final class Probe: @unchecked Sendable {
            var waitCallCount = 0
        }

        let probe = Probe()
        let result = RecordingStopResult(
            filePath: "note.m4a",
            duration: 12
        ) {
            probe.waitCallCount += 1
        }

        await result.awaitConversionIfNeeded(forIncrementalTranscript: "Partial transcript")
        #expect(probe.waitCallCount == 0)

        await result.awaitConversionIfNeeded(forIncrementalTranscript: " \n ")
        #expect(probe.waitCallCount == 1)
    }

    @Test func pendingSeekStatePreservesIntentUntilPlayerIsPrepared() {
        var state = PendingSeekState()

        let stagedTime = state.storePendingSeek(42, fallbackDuration: 120)
        #expect(stagedTime == 42)
        #expect(state.pendingTime == 42)

        let resolvedTime = state.consumePendingSeek(preparedDuration: 30)
        #expect(resolvedTime == 30)
        #expect(state.pendingTime == nil)
    }

    @Test func selectingAlreadyLoadedModelKeepsLoadedState() {
        let keptState = ModelManager.selectionStateAfterPickingModel(
            "openai_whisper-small",
            loadedModelIdentifier: "openai_whisper-small"
        )
        #expect(keptState == .loaded)

        let resetState = ModelManager.selectionStateAfterPickingModel(
            "openai_whisper-large-v3-v20240930_626MB",
            loadedModelIdentifier: "openai_whisper-small"
        )
        #expect(resetState == .unloaded)
    }

}
