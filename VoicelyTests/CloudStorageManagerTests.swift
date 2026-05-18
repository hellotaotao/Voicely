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
    @Test @MainActor func deleteFileRemovesMatchingLocalAndCloudCopies() throws {
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

        manager.deleteFile(at: filename)

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
}
