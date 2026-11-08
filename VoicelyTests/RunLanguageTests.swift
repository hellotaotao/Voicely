import Foundation
import Testing
@testable import Voicely

/// The language a transcription run uses is fixed when it is requested and
/// kept across launches; a re-transcription uses the note's own language.
@MainActor
struct RunLanguageTests {
    private final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "RunLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func storeKeepsChoicesAcrossLaunches() {
        let store = RunLanguageStore(defaults: makeDefaults())
        let noteID = UUID()

        store.save([noteID: .init(key: "english", source: .userChoice)])
        #expect(store.load()[noteID] == .init(key: "english", source: .userChoice))

        store.save([:])
        #expect(store.load().isEmpty)
    }

    @Test func serviceRestoresAFixedLanguageAfterRelaunch() {
        let store = RunLanguageStore(defaults: makeDefaults())
        let noteID = UUID()
        let first = TranscriptionService()
        first.runLanguageStore = store
        first.setLanguageKey("english", for: noteID, source: .noteLanguage)

        let relaunched = TranscriptionService()
        relaunched.languageSettingKey = { "auto" }
        relaunched.runLanguageStore = store

        #expect(relaunched.languageHint(for: noteID) == "English")
        #expect(relaunched.fixedLanguage(for: noteID)?.source == .noteLanguage)
        relaunched.setLanguageKey(nil, for: noteID)
        #expect(store.load().isEmpty)
    }

    @Test func reTranscribingUsesTheLanguageTheNoteWasTranscribedIn() {
        typealias Entry = RunLanguageStore.Entry
        // All Parakeet: English, whatever the setting says now.
        #expect(TranscriptionService.noteLanguage(
            transcriptionModelIdentifier: EnglishStretchRouting.parakeetOnlyModelIdentifier, settingKey: "auto")
            == Entry(key: "english", source: .noteLanguage))
        // Qwen3-ASR wrote it, alone or with English passages from Parakeet: Auto Detect.
        #expect(TranscriptionService.noteLanguage(transcriptionModelIdentifier: "qwen3-asr-0.6b-coreml", settingKey: "english")
            == Entry(key: "auto", source: .noteLanguage))
        #expect(TranscriptionService.noteLanguage(
            transcriptionModelIdentifier: "qwen3-asr-0.6b-coreml" + EnglishStretchRouting.parakeetModelSuffix, settingKey: "english")
            == Entry(key: "auto", source: .noteLanguage))
        // Nothing to go by: the setting.
        #expect(TranscriptionService.noteLanguage(transcriptionModelIdentifier: nil, settingKey: "english")
            == Entry(key: "english", source: .setting))
        #expect(TranscriptionService.noteLanguage(transcriptionModelIdentifier: "openai_whisper-large-v3", settingKey: nil)
            == Entry(key: "auto", source: .setting))
        // Text that reads as English goes to English whoever wrote it; other text to Auto Detect.
        #expect(TranscriptionService.noteLanguage(
            transcriptionModelIdentifier: "qwen3-asr-0.6b-coreml" + EnglishStretchRouting.parakeetModelSuffix,
            transcriptReadsAsEnglish: true, settingKey: "auto")
            == Entry(key: "english", source: .noteLanguage))
        #expect(TranscriptionService.noteLanguage(
            transcriptionModelIdentifier: "openai_whisper-small", transcriptReadsAsEnglish: false, settingKey: "english")
            == Entry(key: "auto", source: .noteLanguage))
        // All Parakeet stays English even when its text does not read as English.
        #expect(TranscriptionService.noteLanguage(
            transcriptionModelIdentifier: EnglishStretchRouting.parakeetOnlyModelIdentifier,
            transcriptReadsAsEnglish: false, settingKey: "auto")
            == Entry(key: "english", source: .noteLanguage))
    }

    /// An English meeting Qwen3-ASR once wrote re-runs in English once its
    /// text has been read, instead of through Qwen3-ASR first.
    @Test func anEnglishNoteQwenWroteReRunsInEnglishOnceItsTextIsRead() async {
        let service = TranscriptionService()
        service.languageSettingKey = { "auto" }
        var reads = 0
        service.transcriptLanguageReader = { _ in reads += 1; return true }
        let note = VoiceNote(title: "Standup", audioFilePath: "standup.m4a")
        note.transcription = "So I think we should move the launch to next week."
        note.transcriptionModelIdentifier = "qwen3-asr-0.6b-coreml"

        #expect(service.noteLanguage(for: note).key == "auto")
        #expect(await service.readTranscriptLanguage(of: note) == true)
        #expect(service.noteLanguage(for: note) == .init(key: "english", source: .noteLanguage))
        // Read once per text.
        await service.readTranscriptLanguage(of: note)
        #expect(reads == 1)
        // Edited text has to be read again.
        note.transcription += " One more thing."
        #expect(service.noteLanguage(for: note).key == "auto")
    }

    /// Today's case: a Chinese note Qwen3-ASR transcribed, re-transcribed
    /// while English is the setting, runs with Auto Detect; picking English
    /// for the run sends it to English.
    @Test(arguments: [nil, "english"] as [String?])
    func reTranscriptionRunsInTheNotesLanguageUnlessTheUserPicksAnother(picked: String?) async {
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager(backend: .coreML))
        service.deviceIDProvider = { "local" }
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        service.audioDurationProvider = { _ in 10 }
        service.heartbeatInterval = 3600
        service.releaseEnglishEngine = {}
        service.languageSettingKey = { "english" }
        let note = VoiceNote(title: "Meeting", audioFilePath: "meeting.m4a")
        note.duration = 10
        note.transcription = "旧的文字"
        note.transcriptionModelIdentifier = "qwen3-asr-0.6b-coreml"
        note.transcriptionOriginDeviceID = "local"
        note.completeTranscription()
        var hints: [String?] = []
        service.transcribeImpl = { [unowned service] _, _ in
            hints.append(service.languageHint(for: note.id))
            return "新的文字。"
        }

        let started = await service.requestTranscription(
            for: note, force: true,
            language: picked.map { .init(key: $0, source: .userChoice) })

        #expect(started)
        #expect(hints == [picked == nil ? nil : "English"])
        #expect(note.transcription == "新的文字。")
        // Done: the run's language is gone.
        #expect(service.fixedLanguage(for: note.id) == nil)
    }
}
