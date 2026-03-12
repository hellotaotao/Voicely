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

        service.transcribeImpl = { _, _ in
            for _ in 0..<10 {
                if Task.isCancelled {
                    return nil
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

}
