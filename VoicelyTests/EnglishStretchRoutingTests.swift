import AVFoundation
import Foundation
import os
import Testing
@testable import Voicely

struct EnglishStretchRoutingTests {
    /// 60 s slices tagged in order; "-" is a slice without a tag.
    static func slices(_ tags: [String], seconds: Double = 60) -> [LanguageTaggedSlice] {
        tags.enumerated().map { index, tag in
            LanguageTaggedSlice(start: Double(index) * seconds, end: Double(index + 1) * seconds,
                                text: tag == "-" ? nil : "q\(index)", language: tag == "-" ? nil : tag)
        }
    }

    @Test func englishStretchesNeedThreeMinutesFromFirstToLastEnglishSlice() {
        // 3 English minutes count; 2 do not.
        #expect(EnglishStretchRouting.stretches(in: Self.slices(["English", "English", "English", "Chinese"]),
                                                mode: .automatic) == [0...2])
        #expect(EnglishStretchRouting.stretches(in: Self.slices(["English", "English", "Chinese"]), mode: .automatic).isEmpty)
    }

    @Test func englishOnlyRecordingsNeedNoMinimum() {
        let short = Self.slices(["-", "English", "None"], seconds: 10)
        #expect(EnglishStretchRouting.stretches(in: short, mode: .automatic) == [1...1])
        // Han characters in Qwen3-ASR's text mean the slice mixed in Chinese.
        var mixed = short
        mixed[1].text = "可不可以帮我去做个化验？ Yeah, a patient had"
        #expect(EnglishStretchRouting.stretches(in: mixed, mode: .automatic).isEmpty)
    }

    @Test func anyOtherLanguageEndsTheStretchAndEnglishAfterItStartsAgain() {
        let tags = ["English", "English", "English", "Chinese", "English", "English", "French",
                    "English", "English", "English", "English"]
        #expect(EnglishStretchRouting.stretches(in: Self.slices(tags), mode: .automatic) == [0...2, 7...10])
    }

    @Test func untaggedAndNoneSlicesStayInsideAStretchButNeverAtItsEdges() {
        let tags = ["-", "None", "English", "-", "None", "English", "English", "-", "None"]
        #expect(EnglishStretchRouting.stretches(in: Self.slices(tags), mode: .automatic) == [2...6])
        // Untagged slices do not count towards the three minutes on their own.
        #expect(EnglishStretchRouting.stretches(in: Self.slices(["English", "-", "-", "-", "Chinese"]), mode: .automatic).isEmpty)
    }

    @Test func chosenLanguageDecidesAlone() {
        let tags = ["Chinese", "-"]
        #expect(EnglishStretchRouting.stretches(in: Self.slices(tags), mode: .english) == [0...1])
        #expect(EnglishStretchRouting.Mode(languageHint: nil) == .automatic)
        #expect(EnglishStretchRouting.Mode(languageHint: "English") == .english)
    }

    @Test(arguments: [
        "So I think we should move the launch to next week and see how the numbers look.",
        "Um, so the, uh, the thing I wanted to say is, um, that it mostly works now.",
        // Too short for the recognizer to judge: it reads these as Danish and Spanish.
        "Bye.",
        "No no no.",
        // Words Qwen3-ASR's own failure placeholder uses must not end a stretch.
        "[12:30–12:59 transcription unavailable]",
    ])
    func englishReadsAsEnglish(text: String) {
        #expect(EnglishStretchRouting.readsAsEnglish(text))
    }

    @Test(arguments: [
        "We should ship it 下周 and see how it goes.",
        "We should ship it すぐに and see how it goes.",
        "We should ship it 다음주 and see how it goes.",
        "We should ship it завтра and see how it goes.",
        "The meeting starts at noon. Je ne sais pas si nous pouvons terminer ce travail avant la fin de la semaine.",
        "The meeting starts at noon. No sé si podemos terminar este trabajo antes del final de la semana que viene.",
        "The meeting starts at noon. Ich weiß nicht, ob wir diese Arbeit bis zum Ende der Woche schaffen können.",
    ])
    func otherLanguagesDoNotReadAsEnglish(text: String) {
        #expect(!EnglishStretchRouting.readsAsEnglish(text))
    }

    /// Keeps a background task alive while Parakeet loads and converts audio,
    /// and stops when the model takes over reporting.
    @Test func preparationHeartbeatBeatsUntilCancelled() async throws {
        let beats = OSAllocatedUnfairLock(initialState: 0)
        let heartbeat = ParakeetEnglishEngine.preparationHeartbeat(every: .milliseconds(1)) {
            beats.withLock { $0 += 1 }
        }
        for _ in 0..<500 where beats.withLock({ $0 }) < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        heartbeat.cancel()
        await heartbeat.value

        let stopped = beats.withLock { $0 }
        #expect(stopped >= 3)
        try await Task.sleep(for: .milliseconds(20))
        #expect(beats.withLock { $0 } == stopped)
    }

    @Test func aSliceWhoseTextIsNotEnglishEndsTheStretchEvenWhenTaggedEnglish() {
        var slices = Self.slices(["English", "English", "English", "English", "English", "English", "English"])
        slices[3].text = "Nous devons absolument terminer ce travail avant la fin de la semaine prochaine."
        #expect(EnglishStretchRouting.stretches(in: slices, mode: .automatic) == [0...2, 4...6])
    }

    @Test func aSliceWithoutATagEndsTheStretchWhenItsTextIsNotEnglish() {
        var slices = Self.slices(["English", "English", "English", "None", "English"])
        slices[3].text = "嗯哼，嗯哼。"
        #expect(EnglishStretchRouting.stretches(in: slices, mode: .automatic) == [0...2])
    }

    @Test func aShortRecordingWithForeignTextStaysWithQwenThroughout() {
        var slices = Self.slices(["English", "English"], seconds: 10)
        slices[1].text = "No sé si podemos terminar este trabajo antes del final de la semana que viene."
        #expect(EnglishStretchRouting.stretches(in: slices, mode: .automatic).isEmpty)
    }

    @Test func parakeetIsMarkedOnceOnTheModelIdentifier() {
        let marked = EnglishStretchRouting.modelIdentifier(afterParakeet: "model")
        #expect(marked == "model+parakeet")
        #expect(EnglishStretchRouting.modelIdentifier(afterParakeet: marked) == marked)
    }

    @Test func wordsGoToTheSliceTheirMiddleFallsIn() {
        let slices = Self.slices(["English", "-", "English"], seconds: 10)
        let words = [
            TimedWord(text: "Hello,", start: 1, end: 2),
            TimedWord(text: "world.", start: 2, end: 3),
            // Straddles the first cut, mostly after it.
            TimedWord(text: "Next", start: 9.5, end: 21),
            TimedWord(text: "one.", start: 22, end: 23),
            // Past the last slice.
            TimedWord(text: "Bye.", start: 31, end: 32),
        ]
        #expect(EnglishStretchRouting.distribute(words, over: slices) == ["Hello, world.", "Next", "one. Bye."])
        #expect(EnglishStretchRouting.distribute([], over: slices) == [nil, nil, nil])
    }

    @Test func transcriptKeepsOneLinePerSliceWithItsTimes() {
        var slices = Self.slices(["English", "-", "English"], seconds: 10)
        slices[2].text = "Two"
        let transcript = EnglishStretchRouting.transcript(of: slices)
        #expect(transcript.text == "q0\nTwo")
        #expect(transcript.spans == [TranscriptSpan(length: 3, start: 0, end: 10),
                                     TranscriptSpan(length: 3, start: 20, end: 30)])
    }

    @Test func aFailedStretchKeepsQwenText() async {
        struct Failure: Error {}
        let slices = Self.slices(["English", "English", "English", "Chinese", "English", "English", "English"])
        var calls = 0
        let routed = await EnglishStretchRouting.transcribeStretches(
            EnglishStretchRouting.stretches(in: slices, mode: .automatic),
            in: slices, fileURL: URL(fileURLWithPath: "/dev/null"), sampleRate: 16_000
        ) { _, start, end in
            calls += 1
            if calls == 1 { throw Failure() }
            #expect(start == 240 * 16_000 && end == 420 * 16_000)
            return [TimedWord(text: "Parakeet.", start: 250, end: 251)]
        }
        #expect(routed.replaced == [4, 5, 6])
        #expect(routed.slices.map(\.text) == ["q0", "q1", "q2", "q3", "Parakeet.", nil, nil])
    }

    @Test @MainActor func noteRemembersParakeetInItsModelIdentifier() {
        let note = VoiceNote(title: "Meeting")
        note.setTranscript("Parakeet text", spans: nil)
        note.transcriptionModelIdentifier = Qwen3Backend.coreML.modelIdentifier
        let qwenName = note.transcriptionModelDisplayName
        #expect(!note.usedParakeetForEnglish)

        note.transcriptionModelIdentifier = EnglishStretchRouting.modelIdentifier(
            afterParakeet: Qwen3Backend.coreML.modelIdentifier)
        #expect(note.usedParakeetForEnglish)
        #expect(note.transcriptionModelDisplayName == qwenName)

        note.applyEditedTranscript("Parakeet text, edited")
        #expect(note.usedParakeetForEnglish)

        note.transcriptionModelIdentifier = EnglishStretchRouting.modelIdentifier(afterParakeet: nil)
        #expect(note.usedParakeetForEnglish)
        #expect(note.transcriptionModelDisplayName == qwenName)
    }
}

/// The Parakeet pass on a live recording and on saved audio, with a fake
/// Parakeet. Test fixtures cut 14 s slices.
@Suite(.serialized)
struct EnglishStretchTranscriptionTests {
    final class LoadedModelManager: ModelManager {
        override func isModelLoaded() -> Bool { true }
    }

    /// One word in the middle of each 14 s slice in `range`, named after the slice.
    static func words(for range: ClosedRange<Int>, start: Int64, end: Int64) -> [TimedWord] {
        #expect(start == Int64(range.lowerBound * 14 * 16_000))
        return range.map { TimedWord(text: "en\($0)", start: Double($0 * 14) + 6, end: Double($0 * 14) + 7) }
    }

    @Test @MainActor func liveRecordingReplacesOnlyTheLongEnglishStretch() async throws {
        // Slice 0 Chinese, 1–13 English (182 s), 14 Chinese, 15–16 English (too short).
        let languages = ["Chinese"] + Array(repeating: "English", count: 13) + ["Chinese", "English", "English"]
        let pcmURL = try SegmentedAudioTestSupport.makeSilentCAF(seconds: Double(languages.count * 14))
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager(backend: .coreML))
        var decoded = 0
        service.transcribeImpl = { [unowned service] _, _ in
            service.decodedLanguage = languages[decoded]
            defer { decoded += 1 }
            return .text("q\(decoded)")
        }
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        let noteID = UUID()
        coordinator.configureTelemetry(noteID: noteID)
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        var stretches: [(Int64, Int64)] = []
        coordinator.transcribeEnglish = { _, start, end, progress in
            stretches.append((start, end))
            progress(0.5)
            return Self.words(for: 1...13, start: start, end: end)
        }
        var released = false
        coordinator.releaseEnglishEngine = { released = true }

        for slice in 0..<(languages.count - 1) {
            await coordinator.transcribeSegment(upToFrame: Int64(slice * 14 + 15) * 16_000)
        }
        _ = await coordinator.stop(currentFrame: Int64(languages.count * 14) * 16_000)
        let qwenSpans = coordinator.accumulatedSpans
        let workBefore = service.decodeWorkCount
        #expect(service.telemetryState.snapshot(for: noteID)?.models == [.qwen3])

        let replaced = await coordinator.transcribeEnglishStretches(mode: .automatic)

        // Parakeet's pass runs after the live clock stopped and still shows on the card.
        #expect(service.telemetryState.snapshot(for: noteID)?.models == [.qwen3, .parakeet])

        #expect(stretches.count == 1 && stretches[0] == (14 * 16_000, 14 * 14 * 16_000))
        #expect(service.decodeWorkCount > workBefore)
        #expect(released)
        #expect(replaced)
        let expected = ["q0"] + (1...13).map { "en\($0)" } + ["q14", "q15", "q16"]
        #expect(coordinator.accumulatedTranscript == expected.joined(separator: "\n"))
        #expect(coordinator.accumulatedSpans?.map(\.start) == qwenSpans?.map(\.start))
    }

    @Test @MainActor func savedAudioReplacesTheEnglishStretchAndMarksTheNote() async throws {
        let languages = Array(repeating: "English", count: 13) + ["Chinese"]
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: Double(languages.count * 14))
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SegmentedAudioTestSupport.makeStore()
        let service = TranscriptionService()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        transcriber.nextCutFrame = { _, start, _ in start + 14 * 16_000 }
        var decoded = 0
        transcriber.transcribeSegmentOutcome = { _ in
            defer { decoded += 1 }
            return .transcribed(.init(text: "q\(decoded)", duration: 1, modelIdentifier: "m",
                                      language: languages[decoded]))
        }
        transcriber.transcribeEnglish = { _, start, end in Self.words(for: 0...12, start: start, end: end) }
        transcriber.releaseEnglishEngine = {}
        let note = VoiceNote(title: "Import", audioFilePath: "")
        service.setLanguageKey("auto", for: note.id)

        await transcriber.transcribe(note: note, sourceURL: url)

        #expect(decoded == languages.count)
        #expect(note.transcription == ((0...12).map { "en\($0)" } + ["q13"]).joined(separator: "\n"))
        #expect(note.transcriptSpans?.count == languages.count)
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(note.transcriptionModelIdentifier == "m" + EnglishStretchRouting.parakeetModelSuffix)
        // Qwen3-ASR is stubbed past the service here, so only Parakeet's mark is checked.
        #expect(service.telemetryState.snapshot(for: note.id)?.models.contains(.parakeet) == true)
    }

    /// Imports a 10 s file, which Qwen3-ASR decodes in one pass, in auto-detect.
    /// Returns the note and the stretches Parakeet was given.
    @MainActor static func importShortFile(
        qwenText: String,
        language: String?,
        parakeet: @escaping EnglishStretchRouting.Transcriber
    ) async throws -> (note: VoiceNote, stretches: [(Int64, Int64)]) {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(
            store: SegmentedAudioTestSupport.makeStore(), service: service)
        transcriber.transcribeSegmentOutcome = { _ in
            .transcribed(.init(text: qwenText, duration: 1, modelIdentifier: "m", language: language))
        }
        var stretches: [(Int64, Int64)] = []
        transcriber.transcribeEnglish = { url, start, end in
            stretches.append((start, end))
            return try await parakeet(url, start, end)
        }
        transcriber.releaseEnglishEngine = {}
        let note = VoiceNote(title: "Import", audioFilePath: "")
        service.setLanguageKey("auto", for: note.id)

        await transcriber.transcribe(note: note, sourceURL: url)
        return (note, stretches)
    }

    @Test @MainActor func shortEnglishImportGoesToParakeet() async throws {
        let (note, stretches) = try await Self.importShortFile(qwenText: "qwen", language: "English") { _, _, _ in
            [TimedWord(text: "parakeet", start: 4, end: 5)]
        }

        #expect(stretches.count == 1 && stretches[0] == (0, 10 * 16_000))
        #expect(note.transcription == "parakeet")
        #expect(note.transcriptionOutcome == .transcribed)
        #expect(note.transcriptSpans?.count == 1)
        #expect(note.usedParakeetForEnglish)
    }

    @Test(arguments: [("qwen", "Chinese"), ("qwen 你好", "English"), ("qwen", "None"), ("qwen", nil)] as [(String, String?)])
    @MainActor func shortImportThatIsNotEnglishStaysWithQwen(qwenText: String, language: String?) async throws {
        let (note, stretches) = try await Self.importShortFile(qwenText: qwenText, language: language) { _, _, _ in
            [TimedWord(text: "parakeet", start: 4, end: 5)]
        }

        #expect(stretches.isEmpty)
        #expect(note.transcription == qwenText)
        #expect(!note.usedParakeetForEnglish)
    }

    @Test @MainActor func shortImportKeepsQwenWhenParakeetHasNoText() async throws {
        struct ParakeetFailure: Error {}
        let failed = try await Self.importShortFile(qwenText: "qwen", language: "English") { _, _, _ in
            throw ParakeetFailure()
        }
        let empty = try await Self.importShortFile(qwenText: "qwen", language: "English") { _, _, _ in [] }

        for note in [failed.note, empty.note] {
            #expect(note.transcription == "qwen")
            #expect(note.transcriptionOutcome == .transcribed)
            #expect(!note.usedParakeetForEnglish)
        }
    }

    /// Re-transcribes a saved 10 s recording, which Qwen3-ASR decodes in one pass.
    /// Returns the note and the stretches Parakeet was given.
    @MainActor static func retranscribeShortNote(
        qwen: RawTranscription,
        language: String? = nil,
        languageKey: String = "auto",
        parakeet: @escaping EnglishStretchRouting.Transcriber
    ) async throws -> (note: VoiceNote, service: TranscriptionService, stretches: [(Int64, Int64)], qwenCalls: Int, released: Bool) {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        service.setModelManager(LoadedModelManager(backend: .coreML))
        service.deviceIDProvider = { "this-device" }
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        service.audioDurationProvider = { _ in 10 }
        var qwenCalls = 0
        service.transcribeImpl = { [unowned service] _, _ in
            qwenCalls += 1
            service.decodedLanguage = language
            return qwen
        }
        var stretches: [(Int64, Int64)] = []
        service.transcribeEnglish = { url, start, end in
            stretches.append((start, end))
            return try await parakeet(url, start, end)
        }
        var released = false
        service.releaseEnglishEngine = { released = true }
        let note = VoiceNote(title: "Saved", audioFilePath: url.path)
        note.transcriptionOriginDeviceID = "this-device"
        note.setTranscript("old text", spans: nil)
        note.completeTranscription()
        note.transcriptionOutcome = .transcribed
        service.setLanguageKey(languageKey, for: note.id)

        #expect(await service.requestTranscription(for: note, force: true))
        return (note, service, stretches, qwenCalls, released)
    }

    @Test @MainActor func shortEnglishRetranscriptionGoesToParakeet() async throws {
        let run = try await Self.retranscribeShortNote(qwen: "qwen", language: "English") { _, _, _ in
            [TimedWord(text: "parakeet", start: 4, end: 5)]
        }

        #expect(run.stretches.count == 1 && run.stretches[0] == (0, 10 * 16_000))
        #expect(run.released)
        #expect(run.note.transcription == "parakeet")
        #expect(run.note.transcriptionOutcome == .transcribed)
        #expect(run.note.transcriptSpans?.count == 1)
        #expect(run.note.usedParakeetForEnglish)
    }

    @Test(arguments: [("qwen", "Chinese"), ("qwen 你好", "English"), ("qwen", "None"), ("qwen", nil)] as [(String, String?)])
    @MainActor func shortRetranscriptionThatIsNotEnglishStaysWithQwen(qwenText: String, language: String?) async throws {
        let run = try await Self.retranscribeShortNote(qwen: .text(qwenText), language: language) { _, _, _ in
            [TimedWord(text: "parakeet", start: 4, end: 5)]
        }

        #expect(run.stretches.isEmpty)
        #expect(run.note.transcription == qwenText)
        #expect(!run.note.usedParakeetForEnglish)
    }

    @Test @MainActor func shortRetranscriptionKeepsQwenWhenParakeetHasNoText() async throws {
        struct ParakeetFailure: Error {}
        let failed = try await Self.retranscribeShortNote(qwen: "qwen", language: "English") { _, _, _ in
            throw ParakeetFailure()
        }
        let empty = try await Self.retranscribeShortNote(qwen: "qwen", language: "English") { _, _, _ in [] }

        for run in [failed, empty] {
            #expect(run.released)
            #expect(run.note.transcription == "qwen")
            #expect(run.note.transcriptionOutcome == .transcribed)
            #expect(!run.note.usedParakeetForEnglish)
        }
    }

    @Test @MainActor func englishChoiceGivesAShortNoteWithoutSpeechToParakeet() async throws {
        let run = try await Self.retranscribeShortNote(qwen: .noSpeech, languageKey: "english") { _, _, _ in
            [TimedWord(text: "parakeet", start: 4, end: 5)]
        }

        #expect(run.note.transcription == "parakeet")
        #expect(run.note.transcriptionOutcome == .transcribed)
        #expect(run.note.usedParakeetForEnglish)
        #expect(run.note.transcriptionModelDisplayName != nil)
    }

    /// A file imported with English chosen, cut into 14 s slices when it does
    /// not fit one pass. Returns the note and the stretches Parakeet was given.
    @MainActor
    private static func importWithEnglishChosen(
        seconds: Double,
        qwen: TranscriptionOutcome = .noSpeech,
        savedFrame: Int64? = nil,
        parakeet: @escaping () throws -> [TimedWord]
    ) async throws -> (note: VoiceNote, service: TranscriptionService, stretches: [(Int64, Int64)], qwenCalls: Int, released: Bool) {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: seconds)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        let store = SegmentedAudioTestSupport.makeStore()
        let transcriber = SegmentedAudioTestSupport.makeTranscriber(store: store, service: service)
        transcriber.nextCutFrame = { _, start, _ in start + 14 * 16_000 }
        var qwenCalls = 0
        transcriber.transcribeSegmentOutcome = { _ in
            qwenCalls += 1
            return qwen
        }
        var stretches: [(Int64, Int64)] = []
        transcriber.transcribeEnglish = { _, start, end in
            stretches.append((start, end))
            return try parakeet()
        }
        var released = false
        transcriber.releaseEnglishEngine = { released = true }
        let note = VoiceNote(title: "Import", audioFilePath: "")
        service.setLanguageKey("english", for: note.id)
        if let savedFrame {
            store.save(.init(lastFrame: savedFrame, totalFrames: Int64(seconds * 16_000), accumulatedText: "saved",
                             failedRanges: [], updatedAt: Date()), for: note.id)
        }

        await transcriber.transcribe(note: note, sourceURL: url)
        return (note, service, stretches, qwenCalls, released)
    }

    private static let wordsAt4And20And40 = [
        TimedWord(text: "one", start: 4, end: 5),
        TimedWord(text: "two", start: 20, end: 21),
        TimedWord(text: "three", start: 40, end: 41),
    ]

    /// 10 s is transcribed in one pass, 42 s in slices.
    @Test(arguments: [(10.0, "one two three"), (42.0, "one\ntwo\nthree")])
    @MainActor func englishChoiceTranscribesAnImportInOneGoWithoutQwen(seconds: Double, expected: String) async throws {
        let run = try await Self.importWithEnglishChosen(seconds: seconds) { Self.wordsAt4And20And40 }

        #expect(run.qwenCalls == 0)
        #expect(run.stretches.count == 1 && run.stretches[0] == (0, Int64(seconds * 16_000)))
        #expect(run.note.transcription == expected)
        #expect(run.note.transcriptionOutcome == .transcribed)
        #expect(run.note.usedParakeetForEnglish)
        #expect(run.note.transcriptionModelDisplayName != nil)
        #expect(run.released)
        // The choice was for this run: a later Re-transcribe follows the setting.
        #expect(run.service.languageHint(for: run.note.id) == nil)
    }

    @Test @MainActor func aSliceParakeetHeardNothingInHasNoSpeech() async throws {
        let run = try await Self.importWithEnglishChosen(seconds: 42) { [TimedWord(text: "one", start: 4, end: 5)] }

        #expect(run.qwenCalls == 0)
        #expect(run.note.transcription == "one")
        #expect(run.note.transcriptionOutcome == .transcribed)
    }

    @Test @MainActor func englishChoiceResumesAParakeetRunFromTheSavedFrame() async throws {
        let run = try await Self.importWithEnglishChosen(seconds: 42, savedFrame: 14 * 16_000) {
            Array(Self.wordsAt4And20And40.dropFirst())
        }

        #expect(run.stretches.count == 1 && run.stretches[0] == (14 * 16_000, 42 * 16_000))
        #expect(run.note.transcription == "saved\ntwo\nthree")
    }

    private struct ParakeetFailed: Error {}

    /// Parakeet failing or hearing nothing leaves the file to Qwen3-ASR, once.
    @Test(arguments: [(10.0, true), (10.0, false), (42.0, true), (42.0, false)])
    @MainActor func qwenTakesAFileParakeetFailsOnOrHearsNothingIn(seconds: Double, fails: Bool) async throws {
        let run = try await Self.importWithEnglishChosen(
            seconds: seconds, qwen: .transcribed(TranscriptionResult(text: "qwen", duration: 1, modelIdentifier: "model"))
        ) {
            if fails { throw ParakeetFailed() }
            return []
        }

        #expect(run.stretches.count == 1)
        #expect(run.note.transcription.split(separator: "\n").allSatisfy { $0 == "qwen" })
        #expect(!run.note.transcription.isEmpty)
        #expect(run.note.transcriptionOutcome == .transcribed)
        #expect(!run.note.usedParakeetForEnglish)
        #expect(run.released)
    }

    @Test @MainActor func englishChoiceFindsNoSpeechWhenNeitherEngineHearsAny() async throws {
        let run = try await Self.importWithEnglishChosen(seconds: 42) { [] }

        #expect(run.note.transcription.isEmpty)
        #expect(run.note.transcriptionOutcome == .noSpeech)
        #expect(!run.note.usedParakeetForEnglish)
    }

    @Test @MainActor func englishChoiceGivesAShortRetranscriptionToParakeetWithoutQwen() async throws {
        let run = try await Self.retranscribeShortNote(qwen: "qwen", languageKey: "english") { _, _, _ in
            [TimedWord(text: "parakeet", start: 4, end: 5)]
        }

        #expect(run.qwenCalls == 0)
        #expect(run.stretches.count == 1 && run.stretches[0] == (0, 10 * 16_000))
        #expect(run.released)
        #expect(run.service.telemetryState.snapshot(for: run.note.id)?.modelName == "Parakeet TDT 0.6B v2")
        #expect(run.note.transcription == "parakeet")
        #expect(run.note.transcriptionOutcome == .transcribed)
        #expect(run.note.transcriptSpans?.count == 1)
        #expect(run.note.usedParakeetForEnglish)
        // Done, so the note's own choice is gone and the setting applies again.
        #expect(run.service.languageHint(for: run.note.id) == run.service.languageHint(for: nil))
    }

    /// Parakeet failing or hearing nothing leaves a short English note to Qwen3-ASR, once.
    @Test(arguments: [true, false])
    @MainActor func qwenTakesAShortEnglishNoteParakeetFailsOnOrHearsNothingIn(fails: Bool) async throws {
        let run = try await Self.retranscribeShortNote(qwen: "qwen", languageKey: "english") { _, _, _ in
            if fails { throw ParakeetFailed() }
            return []
        }

        #expect(run.stretches.count == 1)
        #expect(run.qwenCalls == 1)
        #expect(run.service.telemetryState.snapshot(for: run.note.id)?.models == [.qwen3, .parakeet])
        #expect(run.note.transcription == "qwen")
        #expect(run.note.transcriptionOutcome == .transcribed)
        #expect(!run.note.usedParakeetForEnglish)
    }

    @Test @MainActor func shortEnglishNoteKeepsItsTextWhenBothEnginesFail() async throws {
        let run = try await Self.retranscribeShortNote(qwen: .engineError("rejected"), languageKey: "english") { _, _, _ in
            throw ParakeetFailed()
        }

        #expect(run.note.transcription == "old text")
        #expect(run.note.transcriptionOutcome == .failed)
    }
}

/// A recording with English chosen runs on Parakeet alone.
@Suite(.serialized)
struct EnglishRecordingTests {
    private struct ParakeetDown: Error {}

    @Test @MainActor func liveSlicesGoToParakeetAndNeverToQwen() async throws {
        let pcmURL = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 3 * 14)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let service = TranscriptionService()
        service.setModelManager(EnglishStretchTranscriptionTests.LoadedModelManager(backend: .coreML))
        var qwenCalls = 0
        service.transcribeImpl = { _, _ in
            qwenCalls += 1
            return "qwen"
        }
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        let noteID = UUID()
        coordinator.configureTelemetry(noteID: noteID)
        coordinator.transcribesWithParakeet = true
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        var failSecondSlice = true
        coordinator.transcribeEnglishSlice = { _, start, _, progress in
            progress(0.5)
            let slice = start / (14 * 16_000)
            if slice == 1, failSecondSlice {
                failSecondSlice = false
                throw ParakeetDown()
            }
            return [TimedWord(text: "live\(slice)", start: 1, end: 2)]
        }
        var stretches: [(Int64, Int64)] = []
        coordinator.transcribeEnglish = { _, start, end, _ in
            stretches.append((start, end))
            return EnglishStretchTranscriptionTests.words(for: 0...2, start: start, end: end)
        }
        coordinator.releaseEnglishEngine = {}
        let workBefore = service.decodeWorkCount

        for slice in 0..<2 {
            await coordinator.transcribeSegment(upToFrame: Int64(slice * 14 + 15) * 16_000)
        }
        // The second slice failed live.
        #expect(coordinator.accumulatedTranscript == "live0")
        #expect(service.decodeWorkCount > workBefore)

        // Stop retries it, then Parakeet transcribes the whole recording again.
        _ = await coordinator.stop(currentFrame: 3 * 14 * 16_000)
        #expect(coordinator.accumulatedTranscript == "live0\nlive1\nlive2")
        #expect(await coordinator.transcribeEnglishStretches(mode: .english))
        #expect(stretches.count == 1 && stretches[0] == (0, 3 * 14 * 16_000))
        #expect(coordinator.accumulatedTranscript == "en0\nen1\nen2")
        #expect(qwenCalls == 0)
        #expect(service.telemetryState.snapshot(for: noteID)?.models == [.parakeet])
    }

    @Test(arguments: [("Chinese", "qwen\nqwen\nqwen"), ("English", "en0\nen1\nen2")])
    @MainActor func switchingToAutoDetectEndsAsIfAutoDetectWasChosen(language: String, finalText: String) async throws {
        let pcmURL = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 3 * 14)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let service = TranscriptionService()
        service.setModelManager(EnglishStretchTranscriptionTests.LoadedModelManager(backend: .coreML))
        var qwenCalls = 0
        service.transcribeImpl = { [weak service] _, _ in
            qwenCalls += 1
            service?.decodedLanguage = language
            return "qwen"
        }
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        coordinator.transcribesWithParakeet = true
        coordinator.resolveVoiceActivityCut = { _, start, _, _ in start + 14 * 16_000 }
        var liveParakeetSlices = 0
        coordinator.transcribeEnglishSlice = { _, start, _, _ in
            liveParakeetSlices += 1
            return [TimedWord(text: "live\(start / (14 * 16_000))", start: 1, end: 2)]
        }
        coordinator.transcribeEnglish = { _, start, end, _ in
            EnglishStretchTranscriptionTests.words(for: 0...2, start: start, end: end)
        }
        coordinator.releaseEnglishEngine = {}

        await coordinator.transcribeSegment(upToFrame: 15 * 16_000)
        #expect(coordinator.accumulatedTranscript == "live0")
        let remainingBefore = coordinator.remainingAudioSeconds(upTo: 14 * 16_000)
        coordinator.switchToAutoDetect()
        // The slice Parakeet transcribed is still to do.
        #expect(coordinator.remainingAudioSeconds(upTo: 14 * 16_000) == remainingBefore + 14)

        await coordinator.transcribeSegment(upToFrame: 29 * 16_000)
        #expect(coordinator.accumulatedTranscript == "live0\nqwen")
        _ = await coordinator.stop(currentFrame: 3 * 14 * 16_000)

        #expect(liveParakeetSlices == 1)
        #expect(qwenCalls == 3)
        #expect(coordinator.accumulatedTranscript == "qwen\nqwen\nqwen")
        #expect(coordinator.finalizationProgress == 1)
        // Auto Detect's rule then takes English back to Parakeet.
        _ = await coordinator.transcribeEnglishStretches(mode: .automatic)
        #expect(coordinator.accumulatedTranscript == finalText)
    }

    @Test(arguments: [nil, "english"] as [String?])
    @MainActor func switchingToAutoDetectLoadsQwenForTheRestOfTheRecording(setting: String?) async throws {
        let service = TranscriptionService()
        service.languageSettingKey = { setting }
        let manager = ModelManager(backend: .coreML, loader: { _ in })
        service.setModelManager(manager)
        service.keepEnglishEngineLoaded = { _ in }
        let recording = UUID()
        service.setLanguageKey("english", for: recording)
        service.beginEnglishRecording(noteID: recording)
        await service.waitForEngineSwitch()
        try #require(!manager.isModelLoaded())

        service.switchRecordingToAutoDetect(noteID: recording)
        await service.waitForEngineSwitch()
        for _ in 0..<100 where !manager.isModelLoaded() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(manager.isModelLoaded())
        #expect(!service.isRecordingEnglish)
        #expect(!service.transcribesWithParakeet(recording))
        #expect(service.languageHint(for: recording) == nil)
    }

    @Test @MainActor func qwenIsUnloadedUntilTheRecordingEnds() async throws {
        let service = TranscriptionService()
        var loads = 0
        let manager = ModelManager(backend: .coreML, loader: { _ in loads += 1 })
        service.setModelManager(manager)
        #expect(await service.loadSpeechModel())
        var holds: [Bool] = []
        service.keepEnglishEngineLoaded = { holds.append($0) }
        var qwenCalls = 0
        service.transcribeImpl = { _, _ in
            qwenCalls += 1
            return "qwen"
        }
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = UUID()

        service.beginEnglishRecording(noteID: recording)
        await service.waitForEngineSwitch()

        #expect(!manager.isModelLoaded())
        #expect(holds == [true])
        #expect(service.isReadyToTranscribe())
        #expect(await service.loadSpeechModel() == false)
        let outcome = await service.transcribeAudioOutcome(filePath: url.path)
        if case .modelUnavailable = outcome {} else { Issue.record("Qwen3-ASR decoded during the recording: \(outcome)") }
        #expect(qwenCalls == 0)

        service.endEnglishRecording(noteID: recording)
        await service.waitForEngineSwitch()

        #expect(manager.isModelLoaded())
        #expect(loads == 2)
        #expect(holds == [true, false])
    }

    @Test @MainActor func anotherRecordingBringsQwenBackWhileOneWithEnglishSettles() async {
        let service = TranscriptionService()
        let manager = ModelManager(backend: .coreML, loader: { _ in })
        service.setModelManager(manager)
        service.keepEnglishEngineLoaded = { _ in }
        _ = await service.loadSpeechModel()
        let settling = UUID()
        service.beginEnglishRecording(noteID: settling)
        await service.waitForEngineSwitch()

        service.endEnglishRecordings()
        await service.waitForEngineSwitch()

        #expect(!service.isRecordingEnglish)
        #expect(manager.isModelLoaded())
        // The settling recording ending later changes nothing.
        service.endEnglishRecording(noteID: settling)
        await service.waitForEngineSwitch()
        #expect(manager.isModelLoaded())
    }

    @Test @MainActor func queueRunsOnlyParakeetNotesDuringTheRecording() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = TranscriptionService()
        let manager = ModelManager(backend: .coreML, loader: { _ in })
        service.setModelManager(manager)
        _ = await service.loadSpeechModel()
        service.deviceIDProvider = { "this-device" }
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        service.audioDurationProvider = { _ in 10 }
        service.keepEnglishEngineLoaded = { _ in }
        service.releaseEnglishEngine = {}
        var qwenCalls = 0
        service.transcribeImpl = { _, _ in
            qwenCalls += 1
            return "qwen"
        }
        service.transcribeEnglish = { _, _, _ in [TimedWord(text: "parakeet", start: 4, end: 5)] }
        let other = VoiceNote(title: "Chinese", audioFilePath: url.path)
        let english = VoiceNote(title: "English", audioFilePath: url.path)
        for note in [other, english] {
            note.transcriptionOriginDeviceID = "this-device"
            note.queueTranscription(at: Date())
        }
        service.setLanguageKey("auto", for: other.id)
        service.setLanguageKey("english", for: english.id)

        service.beginEnglishRecording(noteID: UUID())
        await service.waitForEngineSwitch()
        try #require(!manager.isModelLoaded())
        await service.processPendingTranscriptions(notes: [other, english])

        #expect(english.transcription == "parakeet")
        #expect(english.transcriptionState == .completed)
        #expect(other.transcriptionState == .queued)
        #expect(qwenCalls == 0)
    }

    /// A service with English as the setting and Qwen3-ASR not loaded, set up
    /// to transcribe 10 s notes queued on this device.
    @MainActor
    private func englishSettingService(
        parakeetWords: [TimedWord]
    ) -> (service: TranscriptionService, manager: ModelManager, loads: () -> Int, qwenCalls: () -> Int) {
        let service = TranscriptionService()
        service.languageSettingKey = { "english" }
        var loads = 0
        let manager = ModelManager(backend: .coreML, loader: { _ in loads += 1 })
        service.setModelManager(manager)
        service.deviceIDProvider = { "this-device" }
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }
        service.audioDurationProvider = { _ in 10 }
        service.keepEnglishEngineLoaded = { _ in }
        service.releaseEnglishEngine = {}
        var qwenCalls = 0
        service.transcribeImpl = { _, _ in
            qwenCalls += 1
            return "qwen"
        }
        service.transcribeEnglish = { _, _, _ in parakeetWords }
        return (service, manager, { loads }, { qwenCalls })
    }

    private func queuedNote(_ title: String, url: URL) -> VoiceNote {
        let note = VoiceNote(title: title, audioFilePath: url.path)
        note.transcriptionOriginDeviceID = "this-device"
        note.queueTranscription(at: Date())
        return note
    }

    @Test @MainActor func englishSettingRunsTheQueueOnParakeetWithoutLoadingQwen() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let setup = englishSettingService(parakeetWords: [TimedWord(text: "parakeet", start: 4, end: 5)])
        let note = queuedNote("English", url: url)

        #expect(setup.service.isReadyToTranscribe())
        #expect(setup.service.waitReason(for: note) != .waitingForModel)
        await setup.service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription == "parakeet")
        #expect(note.transcriptionState == .completed)
        #expect(setup.loads() == 0)
        #expect(!setup.manager.isModelLoaded())
        #expect(setup.qwenCalls() == 0)
    }

    @Test(arguments: [true, false])
    @MainActor func englishSettingLoadsQwenForADecodeThatNeedsIt(autoDetect: Bool) async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        // Parakeet hears nothing in the English note, so Qwen3-ASR takes it.
        let setup = englishSettingService(parakeetWords: [])
        let note = queuedNote("Note", url: url)
        if autoDetect { setup.service.setLanguageKey("auto", for: note.id) }

        await setup.service.processPendingTranscriptions(notes: [note])

        #expect(note.transcription == "qwen")
        #expect(note.transcriptionState == .completed)
        #expect(setup.loads() == 1)
        #expect(setup.qwenCalls() == 1)
    }

    @Test @MainActor func englishRecordingEndsWithoutLoadingQwenWhenEnglishIsTheSetting() async {
        let setup = englishSettingService(parakeetWords: [])
        let resumed = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .transcriptionCanResumeNotification, object: nil, queue: nil) { _ in resumed.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let recording = UUID()

        setup.service.beginEnglishRecording(noteID: recording)
        await setup.service.waitForEngineSwitch()
        setup.service.endEnglishRecording(noteID: recording)
        await setup.service.waitForEngineSwitch()

        #expect(!setup.manager.isModelLoaded())
        #expect(setup.loads() == 0)
        #expect(resumed.withLock { $0 } == 1)
        #expect(setup.service.isReadyToTranscribe())
    }

    @Test @MainActor func leavingEnglishInSettingsLoadsQwen() async {
        let setup = englishSettingService(parakeetWords: [])
        var setting = "english"
        setup.service.languageSettingKey = { setting }

        await setup.service.followLanguageSetting()
        #expect(setup.loads() == 0)

        setting = "auto"
        #expect(!setup.service.isReadyToTranscribe())
        await setup.service.followLanguageSetting()
        #expect(setup.manager.isModelLoaded())
        #expect(setup.loads() == 1)
    }

    @Test func liveSlicesGoAheadOfWorkAlreadyWaiting() {
        var turns = ParakeetTurns<String>()
        let first = turns.takeIfFree()
        let second = turns.takeIfFree()
        #expect(first && !second)
        turns.wait("import", ahead: false)
        turns.wait("slice 1", ahead: true)
        turns.wait("stretch", ahead: false)
        turns.wait("slice 2", ahead: true)

        var order: [String] = []
        while let next = turns.handOver() {
            order.append(next)
            #expect(turns.isBusy)
        }
        #expect(order == ["slice 1", "slice 2", "import", "stretch"])
        #expect(!turns.isBusy)
    }
}
