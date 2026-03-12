//
//  TranscriptionServiceTests.swift
//  VoicelyTests
//
//  Created by Codex on 1/22/2026.
//

import Foundation
import Testing
@testable import Voicely

struct TranscriptionServiceTests {
    actor TranscriptionGate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    final class UnloadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { false }
    }

    @Test @MainActor func transcribeAudioReturnsResultWhenModelLoaded() async {
        let service = TranscriptionService()
        let modelManager = LoadedModelManager()
        modelManager.selectedModel = "openai_whisper-small"
        service.setModelManager(modelManager)

        service.transcribeImpl = { _, progress in
            progress(0.2)
            return "hello"
        }

        let result = await service.transcribeAudio(filePath: "file.m4a")

        #expect(result?.text == "hello")
        #expect((result?.duration ?? -1) >= 0)
        #expect(result?.modelIdentifier == "openai_whisper-small")
        #expect(service.isTranscribing == false)
        #expect(service.transcriptionProgress == 0.0)
    }

    @Test @MainActor func transcribeAudioReturnsNilWhenModelNotLoaded() async {
        let service = TranscriptionService()
        service.setModelManager(UnloadedModelManager())
        service.transcribeImpl = { _, _ in "hello" }

        let result = await service.transcribeAudio(filePath: "file.m4a")

        #expect(result == nil)
        #expect(service.isTranscribing == false)
    }

    @Test @MainActor func cancelRequestedBeforeTranscribeReturnsNilAndMarksCancelled() async {
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager())

        service.cancelTranscription()
        let result = await service.transcribeAudio(filePath: "file.m4a")

        #expect(result == nil)
        #expect(service.wasTranscriptionCancelled() == true)
    }

    @Test @MainActor func processPendingTranscriptionsUpdatesNotes() async {
        let service = TranscriptionService()
        let modelManager = LoadedModelManager()
        modelManager.selectedModel = "openai_whisper-large-v3-turbo"
        service.setModelManager(modelManager)
        service.transcribeImpl = { _, _ in "Transcribed text" }

        let pendingNote = VoiceNote(title: "Pending", audioFilePath: "file.m4a")
        pendingNote.pendingTranscription = true

        let skippedNote = VoiceNote(title: "Skipped", audioFilePath: "")
        skippedNote.pendingTranscription = true

        await service.processPendingTranscriptions(notes: [pendingNote, skippedNote])

        #expect(pendingNote.transcription == "Transcribed text")
        #expect(pendingNote.transcriptionModelIdentifier == "openai_whisper-large-v3-turbo")
        #expect(pendingNote.pendingTranscription == false)
        #expect(pendingNote.isTranscribing == false)
        #expect(skippedNote.pendingTranscription == true)
    }

    @Test @MainActor func processPendingTranscriptionsWaitsForActiveTranscription() async {
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager())
        let gate = TranscriptionGate()

        service.transcribeImpl = { filePath, _ in
            if filePath == "active.m4a" {
                await gate.wait()
                return "Active transcription"
            }
            return "Queued transcription"
        }

        let activeTask = Task {
            await service.transcribeAudio(filePath: "active.m4a")
        }

        while !service.isTranscribing {
            await Task.yield()
        }

        let pendingNote = VoiceNote(title: "Queued", audioFilePath: "queued.m4a")
        pendingNote.pendingTranscription = true

        let processingTask = Task {
            await service.processPendingTranscriptions(notes: [pendingNote])
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(pendingNote.transcription.isEmpty)
        #expect(pendingNote.pendingTranscription == true)

        await gate.resume()
        _ = await activeTask.value
        await processingTask.value

        #expect(pendingNote.transcription == "Queued transcription")
        #expect(pendingNote.pendingTranscription == false)
        #expect(pendingNote.isTranscribing == false)
    }

    @Test @MainActor func annotatedTextUsesHeaderAndBody() {
        let service = TranscriptionService()
        let formatted = service.formatTranscriptionDuration(1.2)

        let withBody = service.annotatedText(text: "Hello", duration: 1.2)
        #expect(withBody == "Transcription completed in \(formatted).\n\nHello")

        let withoutBody = service.annotatedText(text: "", duration: 1.2)
        #expect(withoutBody == "Transcription completed in \(formatted).")
    }

    @Test @MainActor func formatTranscriptionDurationFormatsShortDurations() {
        let service = TranscriptionService()
        #expect(service.formatTranscriptionDuration(0.4) == "0.40 seconds")
        #expect(service.formatTranscriptionDuration(12.3) == "12.30 seconds")
    }

    @Test @MainActor func engineStatusMessagesReflectAvailability() {
        let service = TranscriptionService()

        service.setModelManager(UnloadedModelManager())
        #expect(service.getCurrentEngineDescription() == "No transcription available")
        #expect(service.getEngineStatusMessage() == "WhisperKit not loaded. Please load a model first.")

        service.setModelManager(LoadedModelManager())
        #expect(service.getCurrentEngineDescription() == "WhisperKit (Local AI)")
        #expect(service.getEngineStatusMessage() == "Using WhisperKit for high-quality offline transcription")
    }
}
