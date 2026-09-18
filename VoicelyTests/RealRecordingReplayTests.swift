//
//  RealRecordingReplayTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Opt-in, local-only input for `RealRecordingReplayTests`: copy an audio file to
/// `<tmp>/voicely-replay/recording.m4a` (inside the test host's container) and,
/// optionally, a model folder name to `<tmp>/voicely-replay/model.txt`.
enum RealRecordingReplayInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-replay", isDirectory: true)
    static let audioURL = directory.appendingPathComponent("recording.m4a")
    static var isConfigured: Bool { FileManager.default.fileExists(atPath: audioURL.path) }
}

/// Replays a real recording through the live-transcription pipeline with a real
/// Whisper model.
@Suite(.serialized, .enabled(if: RealRecordingReplayInput.isConfigured))
@MainActor
struct RealRecordingReplayTests {
    nonisolated static let replayDirectory = RealRecordingReplayInput.directory
    nonisolated static let audioURL = RealRecordingReplayInput.audioURL

    private struct Run {
        let transcript: String
        let seconds: TimeInterval
        let liveFailures: Int
        let unrecovered: Int
        let requiresFullTranscription: Bool
    }

    @Test func injectedLiveFailuresAreRecoveredInPlaceInOrder() async throws {
        let pcmURL = try Self.makeRecorderPCM(from: Self.audioURL)
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        let modelName = (try? String(contentsOf: Self.replayDirectory.appendingPathComponent("model.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "openai_whisper-small"
        let modelManager = ModelManager()
        await modelManager.loadModel(modelName)
        try #require(modelManager.isModelLoaded(), "Model \(modelName) is not downloaded")
        let service = TranscriptionService(modelManager: modelManager)
        let whisper = service.transcribeImpl
        // Real Whisper failures (not the injected ones), per run.
        var realFailures: [String] = []
        let decode: TranscriptionService.TranscribeImpl = { path, progress in
            let raw = await whisper(path, progress)
            if case .whisperError(let reason) = raw { realFailures.append(reason ?? "unknown") }
            return raw
        }
        service.transcribeImpl = decode

        let clean = try await replay(pcmURL, service: service)
        let cleanFailures = realFailures

        // A few live slices fail once, as a busy engine or a locked phone can cause.
        realFailures = []
        var calls = 0
        service.transcribeImpl = { path, progress in
            calls += 1
            if [2, 4, 7].contains(calls) { return .whisperError("injected") }
            return await decode(path, progress)
        }
        let spotty = try await replay(pcmURL, service: service)
        let spottyFailures = realFailures

        // Every live slice fails (e.g. no GPU while locked); all work happens at stop.
        realFailures = []
        var failLive = true
        service.transcribeImpl = { path, progress in
            failLive ? .whisperError("injected") : await decode(path, progress)
        }
        let allFailed = try await replay(pcmURL, service: service) { failLive = false }
        let allFailedFailures = realFailures
        service.transcribeImpl = whisper

        func lines(_ run: Run) -> Int { run.transcript.split(separator: "\n").count }
        let report = """
        REPLAY model=\(modelName) audio=\(Self.audioSeconds(pcmURL))s
        REPLAY clean: \(clean.seconds)s lines=\(lines(clean)) live failures=\(clean.liveFailures) unrecovered=\(clean.unrecovered) full=\(clean.requiresFullTranscription) whisper errors=\(cleanFailures)
        REPLAY spotty: \(spotty.seconds)s lines=\(lines(spotty)) live failures=\(spotty.liveFailures) unrecovered=\(spotty.unrecovered) full=\(spotty.requiresFullTranscription) whisper errors=\(spottyFailures)
        REPLAY all-failed: \(allFailed.seconds)s lines=\(lines(allFailed)) live failures=\(allFailed.liveFailures) unrecovered=\(allFailed.unrecovered) full=\(allFailed.requiresFullTranscription) whisper errors=\(allFailedFailures)
        """
        print(report)
        try? report.write(to: Self.replayDirectory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        for (name, run) in [("clean", clean), ("spotty", spotty), ("all-failed", allFailed)] {
            try? run.transcript.write(
                to: Self.replayDirectory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }

        // Whisper's temperature fallback samples, so wording can differ between
        // runs; what must hold is that failed slices are filled in place, in order.
        #expect(!clean.transcript.isEmpty)
        #expect(spotty.liveFailures >= 3)
        #expect(!spotty.requiresFullTranscription)
        #expect(lines(spotty) == lines(clean))
        #expect(allFailed.liveFailures > 0)
        #expect(!allFailed.requiresFullTranscription)
        #expect(lines(allFailed) == lines(clean))
    }

    /// Feeds the file to the coordinator one second at a time, like the
    /// recorder's timer, then stops it at the end of the audio.
    private func replay(
        _ pcmURL: URL,
        service: TranscriptionService,
        beforeStop: () -> Void = {}
    ) async throws -> Run {
        let totalFrames = try AVAudioFile(forReading: pcmURL).length
        let coordinator = IncrementalTranscriptionCoordinator(transcriptionService: service, recordingFileURL: pcmURL)
        coordinator.configureTelemetry(noteID: UUID())
        let started = Date()
        var frame: AVAudioFramePosition = 0
        while frame < totalFrames {
            frame = min(totalFrames, frame + 16_000)
            await coordinator.transcribeSegment(upToFrame: frame)
        }
        let liveFailures = coordinator.failedSliceCount
        beforeStop()
        let transcript = await coordinator.stop(currentFrame: totalFrames)
        return Run(
            transcript: transcript,
            seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10,
            liveFailures: liveFailures,
            unrecovered: coordinator.unrecoveredSliceCount,
            requiresFullTranscription: coordinator.requiresFullTranscription
        )
    }

    /// Converts to the recorder's working format: 16 kHz mono Float32 CAF.
    private static func makeRecorderPCM(from sourceURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        try #require(source.processingFormat.sampleRate == 16_000 && source.processingFormat.channelCount == 1,
                     "Replay expects 16 kHz mono audio like Voicely recordings")
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-replay-\(UUID().uuidString).caf")
        let destination = try AVAudioFile(forWriting: destinationURL, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384))
        // Stop on the frame count: AVAudioFile throws instead of returning 0 frames at EOF.
        while source.framePosition < source.length {
            let remaining = AVAudioFrameCount(source.length - source.framePosition)
            try source.read(into: buffer, frameCount: min(buffer.frameCapacity, remaining))
            guard buffer.frameLength > 0 else { break }
            try destination.write(from: buffer)
        }
        return destinationURL
    }

    private static func audioSeconds(_ url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Int(Double(file.length) / file.processingFormat.sampleRate)
    }
}
