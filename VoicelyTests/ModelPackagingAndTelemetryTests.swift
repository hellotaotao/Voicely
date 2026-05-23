//
//  ModelPackagingAndTelemetryTests.swift
//  VoicelyTests
//
//  Created by Codex on 5/22/2026.
//

import CoreML
import Foundation
import Testing
@testable import Voicely

struct ModelPackagingAndTelemetryTests {
    @Test func bundledModelLocationIsPreferredBeforeDownloadedModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-bundled-model-test-")
            .appendingPathComponent(UUID().uuidString)
        let bundledFolder = root
            .appendingPathComponent("BundledModels")
            .appendingPathComponent("openai_whisper-small")
        let downloadedRoot = root.appendingPathComponent("DownloadedModels")
        let downloadedFolder = downloadedRoot.appendingPathComponent("openai_whisper-small")

        try FileManager.default.createDirectory(at: bundledFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadedFolder, withIntermediateDirectories: true)
        try Self.createMinimalWhisperModelFiles(in: bundledFolder)
        try Self.createMinimalWhisperModelFiles(in: downloadedFolder)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = ModelManager.preferredLocalModelSource(
            for: "openai_whisper-small",
            downloadedModels: ["openai_whisper-small"],
            downloadedModelsRootPath: downloadedRoot.path,
            bundledModelsRoot: root
        )

        #expect(source?.kind == .bundled)
        #expect(source?.url.path == bundledFolder.path)
    }

    @Test func downloadedModelLocationIsUsedWhenBundleDoesNotContainModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-downloaded-model-test-")
            .appendingPathComponent(UUID().uuidString)
        let downloadedRoot = root.appendingPathComponent("DownloadedModels")
        let downloadedFolder = downloadedRoot.appendingPathComponent("openai_whisper-small")

        try FileManager.default.createDirectory(at: downloadedFolder, withIntermediateDirectories: true)
        try Self.createMinimalWhisperModelFiles(in: downloadedFolder)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = ModelManager.preferredLocalModelSource(
            for: "openai_whisper-small",
            downloadedModels: ["openai_whisper-small"],
            downloadedModelsRootPath: downloadedRoot.path,
            bundledModelsRoot: root
        )

        #expect(source?.kind == .downloaded)
        #expect(source?.url.path == downloadedFolder.path)
    }

    @Test func bundledBundleFolderKeepsModelIdentifierWithoutBundleExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-bundled-bundle-test-")
            .appendingPathComponent(UUID().uuidString)
        let bundledFolder = root
            .appendingPathComponent("BundledModels")
            .appendingPathComponent("openai_whisper-small.bundle")

        try FileManager.default.createDirectory(at: bundledFolder, withIntermediateDirectories: true)
        try Self.createMinimalWhisperModelFiles(in: bundledFolder)
        defer { try? FileManager.default.removeItem(at: root) }

        let identifiers = ModelManager.bundledModelIdentifiers(in: root)
        let source = ModelManager.preferredLocalModelSource(
            for: "openai_whisper-small",
            downloadedModels: [],
            downloadedModelsRootPath: root.path,
            bundledModelsRoot: root
        )

        #expect(identifiers == ["openai_whisper-small"])
        #expect(source?.kind == .bundled)
        #expect(source?.url.path == bundledFolder.path)
    }

    @Test func voiceNoteAveragesCompletedTelemetrySamples() {
        let note = VoiceNote(title: "Telemetry")
        let route = TranscriptionComputeRoute(
            encoderUnits: .cpuAndNeuralEngine,
            decoderUnits: .cpuAndNeuralEngine
        )

        note.recordTranscriptionTelemetry(
            TranscriptionTelemetrySnapshot(
                isActive: false,
                modelName: "Small",
                computeRoute: route,
                metrics: TranscriptionTelemetryMetrics(
                    elapsedSeconds: 5,
                    audioDurationSeconds: 20
                ),
                thermalState: .nominal
            )
        )
        note.recordTranscriptionTelemetry(
            TranscriptionTelemetrySnapshot(
                isActive: false,
                modelName: "Small",
                computeRoute: route,
                metrics: TranscriptionTelemetryMetrics(
                    elapsedSeconds: 10,
                    audioDurationSeconds: 20
                ),
                thermalState: .fair
            )
        )

        #expect(note.transcriptionTelemetrySampleCount == 2)
        #expect(note.averageProcessingLoadLabel == "38% avg")
        #expect(note.averageTranscriptionSpeedLabel == "3.0× avg")
        #expect(note.transcriptionComputeBadgeLabel == "NPU")
        #expect(note.transcriptionThermalStateLabel == "Fair")
    }

    @Test func telemetryFormatsRealtimeProcessingPressure() {
        let metrics = TranscriptionTelemetryMetrics(
            elapsedSeconds: 10,
            audioDurationSeconds: 40
        )

        #expect(metrics.processingLoadPercent == 25)
        #expect(metrics.processingLoadLabel == "25%")
        #expect(metrics.speedLabel == "4.0× realtime")
    }

    @Test func telemetryLabelsNeuralEngineAsNPU() {
        let route = TranscriptionComputeRoute(
            encoderUnits: .cpuAndNeuralEngine,
            decoderUnits: .cpuAndNeuralEngine
        )

        #expect(route.summary == "Neural Engine (NPU)")
        #expect(route.detail == "Encoder ANE · Decoder ANE")
    }

    private static func createMinimalWhisperModelFiles(in folder: URL) throws {
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(component).mlmodelc"),
                withIntermediateDirectories: true
            )
        }
    }
}
