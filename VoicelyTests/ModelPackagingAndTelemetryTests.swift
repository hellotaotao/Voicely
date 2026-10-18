//
//  ModelPackagingAndTelemetryTests.swift
//  VoicelyTests
//
//  Created by Codex on 5/22/2026.
//

import Combine
import CoreML
import Foundation
import Testing
@testable import Voicely

struct ModelPackagingAndTelemetryTests {
    @Test @MainActor func telemetrySessionsIsolateNotesAndExcludeLiveIdle() {
        let service = TranscriptionService()
        var now = Date(timeIntervalSince1970: 100)
        service.nowProvider = { now }
        let liveNote = UUID(), savedNote = UUID()
        let live = service.beginTelemetrySession(noteID: liveNote, activeWorkOnly: true)
        let saved = service.beginTelemetrySession(noteID: savedNote)
        service.resumeTelemetryWork(live)
        now += 5
        service.recordProcessedAudio(start: 0, end: 20, session: live)
        service.pauseTelemetryWork(live)
        now += 100
        service.recordProcessedAudio(start: 0, end: 60, session: saved)
        #expect(service.telemetryState.snapshot(for: liveNote)?.metrics.elapsedSeconds == 5)
        #expect(service.telemetryState.snapshot(for: savedNote)?.metrics.elapsedSeconds == 105)
        service.resumeTelemetryWork(live)
        now += 5
        service.recordProcessedAudio(start: 20, end: 40, session: live)
        service.pauseTelemetryWork(live)
        #expect(service.telemetryState.snapshot(for: liveNote)?.metrics.speedMultiplier == 4)
        let next = service.beginTelemetrySession(noteID: savedNote)
        service.endTelemetrySession(saved)
        service.recordProcessedAudio(start: 0, end: 500, session: saved)
        #expect(service.telemetryState.snapshot(for: savedNote)?.metrics.processedAudioSeconds == 0)
        #expect(service.telemetryState.snapshot(for: savedNote)?.isActive == true)
        service.endTelemetrySession(next)
        service.endTelemetrySession(live)
    }

    @MainActor
    @Test func telemetryUpdatesNotifyOnlyTelemetrySubscribers() {
        let service = TranscriptionService()
        var serviceUpdates = 0
        var telemetryUpdates = 0
        let serviceSubscription = service.objectWillChange.sink { serviceUpdates += 1 }
        let telemetrySubscription = service.telemetryState.objectWillChange.sink { telemetryUpdates += 1 }
        var snapshot = TranscriptionTelemetrySnapshot.inactive()
        snapshot.isActive = true
        snapshot.metrics = TranscriptionTelemetryMetrics(elapsedSeconds: 1, audioDurationSeconds: 60)

        service.telemetryState.update(snapshot)
        snapshot.metrics = TranscriptionTelemetryMetrics(elapsedSeconds: 2, audioDurationSeconds: 60)
        service.telemetryState.update(snapshot)
        service.telemetryState.update(snapshot)

        #expect(serviceUpdates == 0)
        #expect(telemetryUpdates == 2)
        #expect(service.transcriptionTelemetry == snapshot)
        withExtendedLifetime((serviceSubscription, telemetrySubscription)) {}
    }

    @MainActor
    @Test func savedTranscriptEqualityDependsOnlyOnText() {
        #expect(SavedTranscriptText(text: "Original transcript") == SavedTranscriptText(text: "Original transcript"))
        #expect(SavedTranscriptText(text: "Original transcript") != SavedTranscriptText(text: "New transcript"))
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
        #expect(note.averageTranscriptionSpeedLabel == "3.0× avg")
        #expect(note.transcriptionComputeBadgeLabel == "NPU")
        #expect(note.transcriptionThermalStateLabel == "Fair")
    }

    @Test func telemetryMeasuresOnlyCompletedAudio() {
        let metrics = TranscriptionTelemetryMetrics(
            elapsedSeconds: 120, audioDurationSeconds: 3600, processedAudioSeconds: 480)
        #expect(metrics.speedLabel == "4.0× realtime")
        #expect(metrics.processedDurationLabel == "8:00")
        #expect(metrics.elapsedDurationLabel == "2:00")
        let preparing = TranscriptionTelemetryMetrics(
            elapsedSeconds: 10, audioDurationSeconds: 3600, processedAudioSeconds: 0)
        #expect(preparing.speedMultiplier == nil)
    }

    @Test func completedAudioRangesDoNotCountRetriesOrOverlapTwice() {
        var coverage = TranscriptionAudioCoverage()
        coverage.record(start: 60, end: 90)
        coverage.record(start: 60, end: 90)
        coverage.record(start: 80, end: 110)
        coverage.record(start: 120, end: 125)
        coverage.record(start: .nan, end: 140)
        #expect(coverage.processedSeconds == 55)
    }

    @Test func telemetryFormatsRealtimeProcessingRatio() {
        let metrics = TranscriptionTelemetryMetrics(
            elapsedSeconds: 10,
            audioDurationSeconds: 40
        )

        #expect(metrics.processingTimeRatioPercent == 25)
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

}
