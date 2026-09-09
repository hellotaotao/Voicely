//
//  CloudStorageManagerTests.swift
//  VoicelyTests
//
//  Created by Codex on 3/11/2026.
//

import Foundation
import Testing
import SwiftData
@testable import Voicely

struct CloudStorageManagerTests {
    @Test @MainActor func deleteFileRemovesMatchingLocalAndCloudCopies() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let localURL = rootURL.appendingPathComponent("local", isDirectory: true)
        let cloudURL = rootURL.appendingPathComponent("cloud", isDirectory: true)
        let filename = "recording.m4a"
        let localFileURL = localURL.appendingPathComponent(filename)
        let cloudFileURL = cloudURL.appendingPathComponent(filename)

        try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: cloudURL, withIntermediateDirectories: true, attributes: nil)
        try Data("local".utf8).write(to: localFileURL)
        try Data("cloud".utf8).write(to: cloudFileURL)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let manager = CloudStorageManager(
            testLocalContainerURL: localURL,
            testCloudContainerURL: cloudURL,
            testCloudEnabled: true
        )

        await manager.deleteFile(at: filename)?.value

        #expect(fileManager.fileExists(atPath: localFileURL.path) == false)
        #expect(fileManager.fileExists(atPath: cloudFileURL.path) == false)
    }

    @Test @MainActor func importAudioFileCopiesSourceIntoAudioStorage() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let localURL = rootURL.appendingPathComponent("local", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("Voice Memo.m4a")
        let sourceData = Data("audio".utf8)

        try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        try sourceData.write(to: sourceURL)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let manager = CloudStorageManager(
            testLocalContainerURL: localURL,
            testCloudEnabled: false
        )

        let imported = try manager.importAudioFile(from: sourceURL)
        let destinationURL = localURL.appendingPathComponent(imported.filePath)
        let destinationData = try Data(contentsOf: destinationURL)

        #expect(imported.title == "Voice Memo")
        #expect(imported.filePath.hasSuffix(".m4a"))
        #expect(fileManager.fileExists(atPath: destinationURL.path))
        #expect(destinationData == sourceData)
    }

    @Test @MainActor func permanentAbsenceRequiresAnExplicitLocalPathWhenCloudEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local")
        let cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CloudStorageManager(testLocalContainerURL: local,
                                          testCloudContainerURL: cloud, testCloudEnabled: true)
        #expect(manager.isAudioPermanentlyMissing(at: local.appendingPathComponent("gone.m4a").path))
        #expect(!manager.isAudioPermanentlyMissing(at: cloud.appendingPathComponent("unknown.m4a").path))
        #expect(!manager.isAudioPermanentlyMissing(at: "unknown.m4a"))
        let localManager = CloudStorageManager(testLocalContainerURL: local)
        #expect(localManager.isAudioPermanentlyMissing(at: "gone.m4a"))
        let placeholder = CloudStorageManager.cloudPlaceholderURL(for: local.appendingPathComponent("pending.m4a"))
        try Data().write(to: placeholder)
        #expect(!localManager.isAudioPermanentlyMissing(at: "pending.m4a"))
    }

    @Test @MainActor func icloudPlaceholderIsNotTreatedAsMissingAudio() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let localURL = rootURL.appendingPathComponent("local", isDirectory: true)
        let cloudURL = rootURL.appendingPathComponent("cloud", isDirectory: true)
        let filename = "recording.m4a"
        let placeholderURL = cloudURL.appendingPathComponent(".\(filename).icloud")

        try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: cloudURL, withIntermediateDirectories: true, attributes: nil)
        try Data().write(to: placeholderURL)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let manager = CloudStorageManager(
            testLocalContainerURL: localURL,
            testCloudContainerURL: cloudURL,
            testCloudEnabled: true
        )

        #expect(manager.isAudioFileMissing(at: cloudURL.appendingPathComponent(filename)) == false)
        #expect(manager.isAudioFileMissing(at: cloudURL.appendingPathComponent("other.m4a")) == true)
    }

    @Test @MainActor func prepareFileForReadingWaitsForPlaceholderToDownload() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let localURL = rootURL.appendingPathComponent("local", isDirectory: true)
        let cloudURL = rootURL.appendingPathComponent("cloud", isDirectory: true)
        let filename = "recording.m4a"
        let fileURL = cloudURL.appendingPathComponent(filename)
        let placeholderURL = cloudURL.appendingPathComponent(".\(filename).icloud")

        try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: cloudURL, withIntermediateDirectories: true, attributes: nil)
        try Data().write(to: placeholderURL)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let manager = CloudStorageManager(
            testLocalContainerURL: localURL,
            testCloudContainerURL: cloudURL,
            testCloudEnabled: true
        )

        let prepareTask = Task { @MainActor in
            await manager.prepareFileForReading(at: filename, timeout: 5)
        }

        // Simulate iCloud materialising the file shortly after the read request.
        try await Task.sleep(nanoseconds: 600_000_000)
        try Data("audio".utf8).write(to: fileURL)

        let preparedURL = await prepareTask.value
        #expect(preparedURL?.lastPathComponent == filename)
    }

    @Test @MainActor func resolvedDurationIsPersistedWithoutPlayback() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema([VoiceNote.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let note = VoiceNote(audioFilePath: url.path)
        context.insert(note)
        try context.save()
        let player = AudioPlayerService()
        var saved = false
        player.loadAudio(from: url.path) { duration in
            note.updateDuration(duration, forAudioPath: url.path)
            do { try context.save(); saved = true } catch { Issue.record(error) }
        }
        for _ in 0..<100 {
            if saved { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(saved)
        let reloaded = try #require(try ModelContext(container).fetch(FetchDescriptor<VoiceNote>()).first)
        #expect(abs(reloaded.duration - 4) < 0.01)
        #expect(!player.isPlaying)
        player.loadAudio(from: "")
    }

    @Test @MainActor func staleDurationResolutionCannotUpdateNewSelection() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayerService()
        let gate = TranscriptionServiceTests.TranscriptionGate()
        var calls = 0
        var firstUpdates = 0
        var secondUpdates = 0
        player.resolveAudioDuration = { _ in
            calls += 1
            if calls == 1 { await gate.wait(); return 999 }
            return 4
        }
        player.loadAudio(from: url.path) { _ in firstUpdates += 1 }
        await gate.waitUntilArmed()
        // Even reselecting the same path starts a distinct callback lifetime.
        player.loadAudio(from: url.path) { _ in secondUpdates += 1 }
        for _ in 0..<100 {
            if secondUpdates > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(firstUpdates == 0)
        #expect(secondUpdates == 1)
        #expect(player.duration == 4)
        player.loadAudio(from: "")
    }

    @Test @MainActor func readyAudioResolvesDurationWithoutPlaying() async throws {
        let url = try SegmentedAudioTestSupport.makeSilentCAF(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayerService()
        player.loadAudio(from: url.path)
        for _ in 0..<100 {
            if player.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(player.duration - 4) < 0.01)
        #expect(!player.isPlaying)
        player.loadAudio(from: "")
    }

    @Test @MainActor func missingSelectedAudioShowsUnavailableInsteadOfDownloading() async throws {
        let player = AudioPlayerService()
        let missingFilename = "missing-\(UUID().uuidString).m4a"

        player.loadAudio(from: missingFilename)

        for _ in 0..<20 {
            if player.playbackStatusMessage != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(player.playbackStatusMessage == "Audio file unavailable.")
    }
}
