//
//  SavedAudioReplayTests.swift
//  VoicelyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Voicely

/// Opt-in, local-only input for `SavedAudioReplayTests`: copy an audio file to
/// `<tmp>/voicely-replay/saved.m4a` (inside the test host's container).
enum SavedAudioReplayInput {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicely-replay", isDirectory: true)
    static let audioURL = directory.appendingPathComponent("saved.m4a")
    static var isConfigured: Bool { FileManager.default.fileExists(atPath: audioURL.path) }
}

/// Replays a real recording through the saved-audio re-transcription path with a
/// real model, production continuation timers, and shared Foundation progress.
/// This measures submitted progress, not acceptance by the iOS scheduler.
@Suite(.serialized, .enabled(if: SavedAudioReplayInput.isConfigured))
@MainActor
struct SavedAudioReplayTests {
    private struct Attempt {
        let start: TimeInterval
        let seconds: TimeInterval
        let outcome: String
    }

    @Test func reportHowLongProgressStandsStill() async throws {
        let directory = SavedAudioReplayInput.directory
        let modelManager = ModelManager()
        let loadStarted = ProcessInfo.processInfo.systemUptime
        await modelManager.loadModel()
        let modelLoadSeconds = ProcessInfo.processInfo.systemUptime - loadStarted
        try #require(modelManager.isModelLoaded(), "The speech model could not be loaded")

        let store = SegmentProgressStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-replay-store-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let service = TranscriptionService(modelManager: modelManager, segmentProgressStore: store)
        let driver = RecordingProgressDriver()
        service.requiresBackgroundExecution = true
        service.continuedProcessingDriver = driver

        var attempts: [Attempt] = []
        let decodeSegment = service.transcribeImpl
        service.transcribeImpl = { path, progress in
            let start = ProcessInfo.processInfo.systemUptime
            let outcome = await decodeSegment(path, progress)
            let label: String
            switch outcome {
            case .text: label = "text"
            case .noSpeech: label = "noSpeech"
            case .engineError(let reason): label = "error: \(reason ?? "unknown")"
            case .modelUnavailable: label = "modelUnavailable"
            case .audioUnavailable: label = "audioUnavailable"
            case .cancelled: label = "cancelled"
            }
            attempts.append(Attempt(start: start, seconds: ProcessInfo.processInfo.systemUptime - start, outcome: label))
            return outcome
        }

        let audioSeconds = try Self.audioSeconds(SavedAudioReplayInput.audioURL)
        let note = VoiceNote(title: "Replay", audioFilePath: SavedAudioReplayInput.audioURL.path)
        let noteID = note.id

        // This poller measures audio-position changes only. Submitted system
        // progress is captured by RecordingProgressHandle, never inferred from tokens.
        var changes: [(TimeInterval, Int)] = []
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                let units = Int(Double(service.progressByNoteID[noteID] ?? 0) * 10_000)
                if changes.last?.1 != units {
                    changes.append((ProcessInfo.processInfo.systemUptime, units))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        let accepted = await service.requestTranscription(for: note)
        let finished = ProcessInfo.processInfo.systemUptime
        poller.cancel()
        await poller.value
        #expect(accepted)
        // MLX needs the GPU, which iOS withdraws in the background, so its
        // jobs never ask for background time.
        let expectedSubmissions = modelManager.loadedModelSupportsBackgroundTranscription ? 1 : 0
        #expect(driver.submissions == expectedSubmissions)
        #expect(driver.handle.completions.count == expectedSubmissions)

        var gaps: [(start: TimeInterval, seconds: TimeInterval, units: Int)] = []
        var previous = started
        var previousUnits = 0
        for (time, units) in changes + [(finished, -1)] {
            gaps.append((previous - started, time - previous, previousUnits))
            previous = time
            previousUnits = units
        }
        gaps.sort { $0.seconds > $1.seconds }
        let wall = finished - started
        var submittedGaps: [TimeInterval] = []
        var previousUpdate = started
        for sample in driver.handle.samples where sample.time >= started {
            submittedGaps.append(sample.time - previousUpdate)
            previousUpdate = sample.time
        }
        submittedGaps.append(finished - previousUpdate)
        submittedGaps.sort(by: >)

        var report = """
        model \(modelManager.selectedModel)
        model load before job submission \(String(format: "%.1f", modelLoadSeconds)) s (reported separately)
        audio \(Int(audioSeconds)) s, wall \(Int(wall)) s, speed \(String(format: "%.2f", audioSeconds / wall))x
        segment attempts \(attempts.count), outcome \(note.transcriptionOutcome?.rawValue ?? "none"), error \(note.transcriptionLastErrorMessage ?? "-")
        progress changes \(changes.count); gaps over 10 s: \(gaps.filter { $0.seconds > 10 }.count), over 20 s: \(gaps.filter { $0.seconds > 20 }.count)
        submitted Foundation progress updates \(driver.handle.samples.count), longest gaps (s): \(submittedGaps.prefix(5).map { String(format: "%.1f", $0) }.joined(separator: ", "))
        iOS scheduler acceptance: not measured by this replay
        longest gaps in audio progress alone (start s, length s, progress/10000):

        """
        for gap in gaps.prefix(12) {
            report += String(format: "  %6.1f  %5.1f  %d\n", gap.start, gap.seconds, gap.units)
        }
        report += "segment attempts (start s, seconds, outcome):\n"
        for attempt in attempts {
            report += String(format: "  %6.1f  %5.1f  %@\n",
                             attempt.start - started, attempt.seconds, attempt.outcome)
        }
        print("🔍 [SavedAudioReplay]\n" + report)
        try report.write(to: directory.appendingPathComponent("saved-report.txt"), atomically: true, encoding: .utf8)
        try note.transcription.write(
            to: directory.appendingPathComponent("saved-transcript.txt"), atomically: true, encoding: .utf8)
    }

    private static func audioSeconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
