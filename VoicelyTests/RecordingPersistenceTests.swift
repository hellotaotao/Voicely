import Foundation
import Testing
@testable import Voicely

struct RecordingPersistenceTests {
    @Test func recordingConversionKeepsPCMUntilFinalFlushReleasesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.caf")
        let destination = directory.appendingPathComponent("note.m4a")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let result = RecordingStopResult.converting(
            sourceURL: source, destinationURL: destination, duration: 12
        ) { _, output in
            try bytes.write(to: output)
        }
        // Persist a portable destination, never the temporary PCM source.
        #expect(result.filePath == destination.lastPathComponent)
        #expect(await result.resolvedFilePath() == "note.m4a")
        // The final-flush reader can still open PCM after export has completed.
        #expect(try Data(contentsOf: source) == bytes)
        await result.cleanupTemporaryAudio()
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == bytes)
        await result.cleanupTemporaryAudio()
    }

    @Test func failedRecordingConversionPreservesDurableCAF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.caf")
        let destination = directory.appendingPathComponent("note.m4a")
        let bytes = Data([4, 5, 6])
        try bytes.write(to: source)
        let result = RecordingStopResult.converting(
            sourceURL: source, destinationURL: destination, duration: 12
        ) { _, output in
            try Data([0]).write(to: output)
            throw CocoaError(.fileWriteUnknown)
        }
        #expect(await result.resolvedFilePath() == "note.caf")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        await result.cleanupTemporaryAudio()
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: directory.appendingPathComponent("note.caf")) == bytes)
    }

    @Test func failedDurableFallbackNeverDeletesOnlyRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.caf")
        let destination = directory.appendingPathComponent("missing/note.m4a")
        let bytes = Data([7, 8, 9])
        try bytes.write(to: source)
        let result = RecordingStopResult.converting(
            sourceURL: source, destinationURL: destination, duration: 12
        ) { _, _ in throw CocoaError(.fileWriteUnknown) }
        #expect(await result.resolvedFilePath() == source.path)
        await result.cleanupTemporaryAudio()
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func recordingNamesNeverCollide() {
        let now = Date()
        #expect(AudioRecordingService.makePCMTemporaryURL(now: now) != AudioRecordingService.makePCMTemporaryURL(now: now))
    }
}
