import Foundation
import Testing
@testable import Voicely

/// Audio still in iCloud while the device is offline: the note waits for the
/// network instead of a download that cannot finish, and starts on its own
/// once the device is online.
@MainActor
struct NetworkWaitTests {
    private final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    private func makeService(now: @escaping () -> Date = Date.init) -> TranscriptionService {
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager(backend: .coreML))
        service.deviceIDProvider = { "local" }
        service.nowProvider = now
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        service.audioDurationProvider = { _ in 10 }
        service.heartbeatInterval = 3600
        service.requiresBackgroundExecution = true
        service.continuedProcessingDriver = RecordingProgressDriver()
        return service
    }

    private func makeTranscribedNote() -> VoiceNote {
        let note = VoiceNote(title: "Cloud", audioFilePath: "cloud.m4a")
        note.duration = 10
        note.transcription = "Old text."
        note.transcriptionModelIdentifier = "qwen3-asr-0.6b-coreml"
        note.transcriptionOriginDeviceID = "local"
        note.completeTranscription()
        return note
    }

    @Test func offlineCloudAudioWaitsWithoutABackgroundTaskAndStartsOnceOnline() async {
        let service = makeService()
        let driver = RecordingProgressDriver()
        service.continuedProcessingDriver = driver
        var offline = true
        service.audioWaitsForNetwork = { _ in offline }
        var decodes = 0
        service.transcribeImpl = { _, _ in
            decodes += 1
            return "New text."
        }
        let note = makeTranscribedNote()

        let started = await service.requestTranscription(for: note, force: true)

        #expect(started)
        #expect(driver.submissions == 0)
        #expect(decodes == 0)
        #expect(service.waitReason(for: note) == .waitingForNetwork)
        #expect(note.transcription == "Old text.")
        #expect(note.transcriptionOutcome != .failed)

        // Going to the background does not turn the wait into a pause by iOS.
        service.savedTranscriptionsDidEnterBackground()
        #expect(!service.isPausedForBackground(noteID: note.id))
        await service.resumeSavedTranscriptionsInForeground()
        #expect(driver.submissions == 0)
        #expect(service.waitReason(for: note) == .waitingForNetwork)

        offline = false
        await service.networkBecameAvailable()

        #expect(decodes == 1)
        #expect(driver.submissions == 1)
        #expect(note.transcription == "New text.")
        #expect(service.waitReason(for: note) == nil)
    }

    /// Time spent offline does not count toward the five minutes the audio
    /// gets to arrive: the first try once online keeps the note waiting.
    @Test func offlineTimeDoesNotUseUpTheAudioRetryWindow() async {
        var now = Date(timeIntervalSince1970: 10_000)
        let service = makeService(now: { now })
        var offline = true
        service.audioWaitsForNetwork = { _ in offline }
        service.prepareAudioFileForReading = { _ in nil }
        service.isAudioPermanentlyMissing = { _ in false }
        service.transcribeImpl = { _, _ in "New text." }
        let note = makeTranscribedNote()

        _ = await service.requestTranscription(for: note, force: true)
        #expect(service.waitReason(for: note) == .waitingForNetwork)

        now = now.addingTimeInterval(service.audioAvailabilityRetryWindow * 2)
        offline = false
        await service.networkBecameAvailable()

        #expect(note.transcriptionState == .queued)
        #expect(note.transcriptionOutcome != .failed)
        #expect(service.waitReason(for: note) == .waitingForAudio)
        #expect(note.transcription == "Old text.")
    }

    @Test func cancellingANoteWaitingForTheNetworkStopsTheWait() async {
        let service = makeService()
        service.audioWaitsForNetwork = { _ in true }
        let note = makeTranscribedNote()

        _ = await service.requestTranscription(for: note, force: true)
        service.cancelTranscription(for: note)

        #expect(service.waitReason(for: note) == nil)
        #expect(!service.networkWaitNoteIDs.contains(note.id))
    }

    /// Audio the voice detector is sure holds no speech does not load
    /// Qwen3-ASR when it loads on demand.
    @Test func confidentSilenceDoesNotLoadQwen() async {
        let service = TranscriptionService()
        var loads = 0
        let manager = ModelManager(backend: .coreML, loader: { _ in loads += 1 })
        service.setModelManager(manager)
        service.keepsQwenLoaded = false
        service.isConfidentSilence = { _ in true }

        let silent = await service.transcribeAudioOutcome(filePath: "/silent.caf")

        guard case .noSpeech = silent else {
            Issue.record("Expected no speech, got \(silent)")
            return
        }
        #expect(loads == 0)

        service.isConfidentSilence = { _ in false }
        service.transcribeImpl = { _, _ in "Some words." }
        _ = await service.transcribeAudioOutcome(filePath: "/speech.caf")
        #expect(loads == 1)
    }
}
