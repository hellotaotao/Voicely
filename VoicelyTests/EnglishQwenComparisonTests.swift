#if DEBUG && targetEnvironment(macCatalyst)
import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Qwen3-ASR alone on the AMI meetings in `build/speaker-cut-english/` (see
/// `EnglishSpeakerCutComparisonTests`), transcribed the way the app
/// re-transcribes a note before the English & European model is on the
/// device: speaker turns found first, slices cut there and at pauses, no
/// passage handed to Parakeet. Scored like Parakeet's whole-file runs there.
/// Local only; run with `VOICELY_RUN_ENGLISH_CUTS=1` and
/// `VOICELY_SLICE_LIMITS=production`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VOICELY_RUN_ENGLISH_CUTS"] == "1"))
struct EnglishQwenComparisonTests {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/speaker-cut-english")

    private struct Reference: Decodable {
        let words: [[Value]]

        enum Value: Decodable {
            case number(Double)
            case text(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) {
                    self = .number(number)
                } else {
                    self = .text(try container.decode(String.self))
                }
            }
        }

        var text: [String] {
            words.compactMap { entry -> String? in
                guard entry.count == 4, case .text(let word) = entry[3] else { return nil }
                return word
            }
        }
    }

    @Test @MainActor func qwenAloneOnAMIMeetings() async throws {
        #expect(Qwen3SliceLimits.current.chunkSeconds > 20, "Run with VOICELY_SLICE_LIMITS=production")
        let modelManager = ModelManager()
        await modelManager.loadModel()
        try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")
        let service = TranscriptionService(modelManager: modelManager)
        service.englishModelIsReady = { false }
        service.findSpeakerTurns = { url in try? await SpeakerDiarizationEngine.turns(for: url) }
        service.prepareAudioFileForReading = { URL(fileURLWithPath: $0) }

        let recordings = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".wav") }.sorted()
        var pooled: [String: (errors: Int, words: Int, audio: Double, seconds: Double)] = [:]
        for name in recordings {
            let url = Self.directory.appendingPathComponent(name)
            let meeting = String(name.prefix { $0 != "." })
            let microphone = String(name.split(separator: ".")[1])
            let reference = try JSONDecoder().decode(Reference.self, from: Data(
                contentsOf: Self.directory.appendingPathComponent("\(meeting).json")))
            let referenceTokens = EnglishSpeakerCutComparisonTests.tokens(reference.text.joined(separator: " "))
            let file = try AVAudioFile(forReading: url)
            let audioSeconds = Double(file.length) / file.processingFormat.sampleRate

            let note = VoiceNote(title: name, audioFilePath: url.path)
            note.transcriptionOriginDeviceID = service.deviceIDProvider()
            note.setTranscript("old text", spans: nil)
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            service.setLanguageKey("auto", for: note.id)
            let started = ProcessInfo.processInfo.systemUptime
            #expect(await service.requestTranscription(for: note, force: true))
            let seconds = ProcessInfo.processInfo.systemUptime - started

            let hypothesis = EnglishSpeakerCutComparisonTests.tokens(note.transcription)
            let errors = EnglishSpeakerCutComparisonTests.editDistance(referenceTokens, hypothesis)
            var entry = pooled[microphone] ?? (0, 0, 0, 0)
            entry.errors += errors
            entry.words += referenceTokens.count
            entry.audio += audioSeconds
            entry.seconds += seconds
            pooled[microphone] = entry
            print(String(format: "📊 qwen %@ %@: %.2f%% (%d/%d, written %d), model %@, %.0f s for %.0f s audio",
                         meeting, microphone, Double(errors) / Double(referenceTokens.count) * 100, errors,
                         referenceTokens.count, hypothesis.count, note.transcriptionModelIdentifier ?? "-",
                         seconds, audioSeconds))
            #expect(note.transcriptionOutcome == .transcribed)
            #expect(!(note.transcriptionModelIdentifier ?? "").contains("parakeet"))
        }
        for (microphone, entry) in pooled.sorted(by: { $0.key < $1.key }) {
            print(String(format: "📊 qwen all %@: %.2f%% (%d/%d), %.1f× real time",
                         microphone, Double(entry.errors) / Double(entry.words) * 100, entry.errors, entry.words,
                         entry.audio / entry.seconds))
        }
        await modelManager.unloadModel()
    }

    /// Parakeet on the same files, the whole file at once as the app gives it
    /// a recording with English & European chosen, scored the same way.
    @Test func parakeetOnAMIMeetings() async throws {
        let recordings = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".wav") }.sorted()
        var pooled: [String: (errors: Int, words: Int, audio: Double, seconds: Double)] = [:]
        for name in recordings {
            let url = Self.directory.appendingPathComponent(name)
            let meeting = String(name.prefix { $0 != "." })
            let microphone = String(name.split(separator: ".")[1])
            let reference = try JSONDecoder().decode(Reference.self, from: Data(
                contentsOf: Self.directory.appendingPathComponent("\(meeting).json")))
            let referenceTokens = EnglishSpeakerCutComparisonTests.tokens(reference.text.joined(separator: " "))
            let file = try AVAudioFile(forReading: url)
            let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
            let started = ProcessInfo.processInfo.systemUptime
            let words = try await ParakeetEnglishEngine.shared.transcribe(fileURL: url, startFrame: 0, endFrame: file.length)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            let hypothesis = EnglishSpeakerCutComparisonTests.tokens(words.map(\.text).joined(separator: " "))
            let errors = EnglishSpeakerCutComparisonTests.editDistance(referenceTokens, hypothesis)
            var entry = pooled[microphone] ?? (0, 0, 0, 0)
            entry.errors += errors
            entry.words += referenceTokens.count
            entry.audio += audioSeconds
            entry.seconds += seconds
            pooled[microphone] = entry
            print(String(format: "📊 parakeet %@ %@: %.2f%% (%d/%d, written %d), %.0f s for %.0f s audio",
                         meeting, microphone, Double(errors) / Double(referenceTokens.count) * 100, errors,
                         referenceTokens.count, hypothesis.count, seconds, audioSeconds))
        }
        for (microphone, entry) in pooled.sorted(by: { $0.key < $1.key }) {
            print(String(format: "📊 parakeet all %@: %.2f%% (%d/%d), %.1f× real time",
                         microphone, Double(entry.errors) / Double(entry.words) * 100, entry.errors, entry.words,
                         entry.audio / entry.seconds))
        }
        await ParakeetEnglishEngine.shared.unload()
    }
}
#endif
