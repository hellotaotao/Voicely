//
//  CloudStorageManagerTests.swift
//  VoicelyTests
//
//  Created by Codex on 3/11/2026.
//

import Foundation
import Testing
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
