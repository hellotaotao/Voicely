//
//  VADGateReplayTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
import WhisperKit
@testable import Voicely

/// Opt-in, local-only input for `VADGateReplayTests`: copy a 16 kHz mono CAF to
/// `<tmp>/voicely-replay/vad.caf` (inside the test host's container). The model
/// and prompt come from `saved-model.txt` and `saved-prompt.txt`. Optional:
/// `vad-fallbacks.txt` overrides the temperature fallback count, and an empty
/// `vad-prompted-only.txt` skips the prompt-free pass.
enum VADGateReplayInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-replay", isDirectory: true)
    static let audioURL = directory.appendingPathComponent("vad.caf")
    static var isConfigured: Bool { FileManager.default.fileExists(atPath: audioURL.path) }
}

/// Cuts a real recording into the slices the app would decode and records, per
/// slice, what the neural VAD saw and what Whisper produced with and without the
/// custom prompt. The rows go to `vad-report.jsonl` so any gate threshold can be
/// evaluated afterwards without decoding again.
@Suite(.serialized, .enabled(if: VADGateReplayInput.isConfigured))
@MainActor
struct VADGateReplayTests {
    private struct Row: Encodable {
        let index: Int
        let start: Double
        let end: Double
        /// Speech probability of each 36 ms VAD frame, rounded to 3 decimals.
        let probabilities: [Double]
        let currentGateAdmits: Bool
        let promptedText: String
        let promptedVerdict: String
        let promptedSeconds: Double
        let promptFreeText: String?
        let promptFreeSeconds: Double?
    }

    @Test func recordVADAndWhisperOutputPerSlice() async throws {
        let directory = VADGateReplayInput.directory
        func option(_ name: String) -> String? {
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let modelName = option("saved-model.txt") ?? "openai_whisper-small"
        let prompt = option("saved-prompt.txt") ?? ""
        try #require(!prompt.isEmpty, "saved-prompt.txt is required to measure prompt echoes")

        let modelManager = ModelManager()
        await modelManager.loadModel(modelName)
        try #require(modelManager.isModelLoaded(), "Model \(modelName) is not downloaded")
        let whisperKit = try #require(modelManager.getWhisperKit())
        let tokenizer = try #require(whisperKit.tokenizer)
        let promptTokens = tokenizer.encode(text: " " + prompt)

        // Mirrors `TranscriptionService.transcribeWithWhisper`.
        var options = DecodingOptions(
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            temperatureFallbackCount: option("vad-fallbacks.txt").flatMap(Int.init) ?? 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: false,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            clipTimestamps: [0.0],
            compressionRatioThreshold: 2.0,
            chunkingStrategy: ChunkingStrategy.none
        )

        let sourceURL = VADGateReplayInput.audioURL
        let source = try AVAudioFile(forReading: sourceURL)
        let sampleRate = source.processingFormat.sampleRate
        let totalFrames = source.length
        let sliceFrames = AVAudioFramePosition(Double(IncrementalTranscriptionTiming.defaultIntervalSeconds) * sampleRate)
        let detector = try SileroNeuralVoiceActivityDetector()

        let reportURL = directory.appendingPathComponent("vad-report.jsonl")
        FileManager.default.createFile(atPath: reportURL.path, contents: nil)
        let report = try FileHandle(forWritingTo: reportURL)
        defer { try? report.close() }
        let encoder = JSONEncoder()

        var start: AVAudioFramePosition = 0
        var index = 0
        while start < totalFrames {
            let target = min(totalFrames, start + sliceFrames)
            var end = target
            if target < totalFrames {
                let cut = IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                    fileURL: sourceURL, startFrame: start, targetFrame: target)
                if cut > start { end = cut }
            }
            index += 1
            let sliceURL = try #require(IncrementalTranscriptionCoordinator.extractSegment(
                fileURL: sourceURL, from: start, to: end, segmentIndex: index))
            defer { try? FileManager.default.removeItem(at: sliceURL) }

            let samples = try Self.samples(of: sliceURL)
            let frames = try detector.speechProbabilities(in: samples)
            let admits = try NeuralSpeechAnalyzer.containsProbableSpeech(at: sliceURL)

            func decode(_ tokens: [Int]?) async throws -> (String, Double) {
                options.promptTokens = tokens
                let began = ProcessInfo.processInfo.systemUptime
                let results = try await whisperKit.transcribe(audioPath: sliceURL.path, decodeOptions: options)
                return (results.first?.text ?? "", ProcessInfo.processInfo.systemUptime - began)
            }

            let (promptedText, promptedSeconds) = try await decode(promptTokens)
            let verdict: String
            switch TranscriptionService.promptedOutputVerdict(for: promptedText, prompt: prompt) {
            case .usable: verdict = TranscriptSanitizer.cleanedTranscript(promptedText) == nil ? "blank" : "usable"
            case .promptEcho: verdict = "promptEcho"
            case .degenerate: verdict = "degenerate"
            }
            let promptedOnly = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("vad-prompted-only.txt").path)
            let (promptFreeText, promptFreeSeconds): (String?, Double?) = promptedOnly ? (nil, nil) : try await decode(nil)

            let row = Row(
                index: index,
                start: Double(start) / sampleRate,
                end: Double(end) / sampleRate,
                probabilities: frames.map { ($0.speechProbability * 1000).rounded() / 1000 },
                currentGateAdmits: admits,
                promptedText: promptedText,
                promptedVerdict: verdict,
                promptedSeconds: promptedSeconds,
                promptFreeText: promptFreeText,
                promptFreeSeconds: promptFreeSeconds
            )
            try report.write(contentsOf: try encoder.encode(row) + Data("\n".utf8))
            print("🔍 [VADGateReplay] slice \(index) \(Int(row.start))–\(Int(row.end)) s gate=\(admits) verdict=\(verdict)")
            start = end
        }
    }

    private static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
