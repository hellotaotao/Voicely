//
//  Item.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import SwiftData

enum TranscriptionOwnershipState: String {
    case queued
    case claimed
    case completed
}

enum WaveformSeedGenerator {
    static func stableSeed(for uuid: UUID) -> Int {
        let hash = uuid.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Int(hash % 10_000)
    }
}

@Model
final class VoiceNote {
    var id: UUID = UUID()
    var title: String = "Voice Note"
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFilePath: String = ""
    var transcription: String = ""
    var transcriptionModelIdentifier: String?
    var transcriptionLastErrorMessage: String?
    var isTranscribing: Bool = false
    var transcriptionProgress: Float = 0.0
    var pendingTranscription: Bool = false // Mark if waiting for transcription
    var lastTranscriptionDuration: TimeInterval = 0
    var transcriptionStateRaw: String = ""
    var transcriptionOriginDeviceID: String?
    var transcriptionOwnerDeviceID: String?
    var transcriptionAttemptID: String?
    var transcriptionQueuedAt: Date?
    var transcriptionLeaseExpiresAt: Date?
    var transcriptionTelemetrySampleCount: Int = 0
    var transcriptionAverageProcessingLoadPercent: Double = 0
    var transcriptionAverageSpeedMultiplier: Double = 0
    var transcriptionComputeSummary: String?
    var transcriptionComputeDetail: String?
    var transcriptionThermalStateLabel: String?
    
    init(title: String = "", audioFilePath: String = "", transcription: String = "") {
        self.id = UUID()
        self.title = title.isEmpty ? "Voice Note" : title
        self.timestamp = Date()
        self.duration = 0
        self.audioFilePath = audioFilePath
        self.transcription = transcription
        self.transcriptionModelIdentifier = nil
        self.transcriptionLastErrorMessage = nil
        self.isTranscribing = false
        self.transcriptionProgress = 0.0
        self.pendingTranscription = false
        self.transcriptionTelemetrySampleCount = 0
        self.transcriptionAverageProcessingLoadPercent = 0
        self.transcriptionAverageSpeedMultiplier = 0
        self.transcriptionComputeSummary = nil
        self.transcriptionComputeDetail = nil
        self.transcriptionThermalStateLabel = nil
    }
}

extension VoiceNote {
    var transcriptionState: TranscriptionOwnershipState? {
        get {
            TranscriptionOwnershipState(rawValue: transcriptionStateRaw)
        }
        set {
            transcriptionStateRaw = newValue?.rawValue ?? ""
        }
    }

    var transcriptionModelDisplayName: String? {
        guard let transcriptionModelIdentifier, !transcriptionModelIdentifier.isEmpty else {
            return nil
        }
        return ModelManager.displayName(for: transcriptionModelIdentifier)
    }

    var averageProcessingLoadLabel: String? {
        guard transcriptionTelemetrySampleCount > 0 else {
            return nil
        }

        return "\(Int(transcriptionAverageProcessingLoadPercent.rounded()))% avg"
    }

    var averageTranscriptionSpeedLabel: String? {
        guard transcriptionTelemetrySampleCount > 0 else {
            return nil
        }

        return String(format: "%.1f× avg", transcriptionAverageSpeedMultiplier)
    }

    var transcriptionComputeBadgeLabel: String? {
        guard let transcriptionComputeSummary,
              !transcriptionComputeSummary.isEmpty else {
            return nil
        }

        switch transcriptionComputeSummary {
        case "Neural Engine (NPU)":
            return "NPU"
        case "Mixed Compute":
            return "Mixed"
        default:
            return transcriptionComputeSummary
        }
    }

    var hasOwnershipState: Bool {
        !transcriptionStateRaw.isEmpty
    }

    var isAwaitingTranscription: Bool {
        get {
            pendingTranscription
        }
        set {
            pendingTranscription = newValue
        }
    }

    func queueTranscription(at queuedAt: Date) {
        transcriptionState = .queued
        transcriptionQueuedAt = queuedAt
        transcriptionOwnerDeviceID = nil
        transcriptionAttemptID = nil
        transcriptionLeaseExpiresAt = nil
        pendingTranscription = true
        isTranscribing = false
        transcriptionProgress = 0.0
    }

    func claimTranscription(
        ownerDeviceID: String,
        attemptID: String,
        queuedAt: Date,
        leaseExpiresAt: Date
    ) {
        transcriptionState = .claimed
        transcriptionOwnerDeviceID = ownerDeviceID
        transcriptionAttemptID = attemptID
        transcriptionQueuedAt = queuedAt
        transcriptionLeaseExpiresAt = leaseExpiresAt
        transcriptionLastErrorMessage = nil
        pendingTranscription = false
    }

    func completeTranscription() {
        transcriptionState = .completed
        transcriptionOwnerDeviceID = nil
        transcriptionAttemptID = nil
        transcriptionLeaseExpiresAt = nil
        transcriptionLastErrorMessage = nil
        pendingTranscription = false
    }

    func markTranscriptionFailure(_ message: String) {
        transcriptionLastErrorMessage = message
    }

    func clearTransientTranscriptionFlags() {
        isTranscribing = false
        transcriptionProgress = 0.0
        pendingTranscription = false
    }

    func recordTranscriptionTelemetry(_ snapshot: TranscriptionTelemetrySnapshot) {
        guard let processingLoadPercent = snapshot.metrics.processingLoadPercent,
              let speedMultiplier = snapshot.metrics.speedMultiplier else {
            return
        }

        let currentCount = max(transcriptionTelemetrySampleCount, 0)
        let nextCount = currentCount + 1

        transcriptionAverageProcessingLoadPercent = Self.updatedAverage(
            currentAverage: transcriptionAverageProcessingLoadPercent,
            currentCount: currentCount,
            newValue: Double(processingLoadPercent)
        )
        transcriptionAverageSpeedMultiplier = Self.updatedAverage(
            currentAverage: transcriptionAverageSpeedMultiplier,
            currentCount: currentCount,
            newValue: speedMultiplier
        )
        transcriptionTelemetrySampleCount = nextCount
        transcriptionComputeSummary = snapshot.computeRoute.summary
        transcriptionComputeDetail = snapshot.computeRoute.detail
        transcriptionThermalStateLabel = snapshot.thermalStateLabel
    }

    func clearTranscriptionTelemetrySummary() {
        transcriptionTelemetrySampleCount = 0
        transcriptionAverageProcessingLoadPercent = 0
        transcriptionAverageSpeedMultiplier = 0
        transcriptionComputeSummary = nil
        transcriptionComputeDetail = nil
        transcriptionThermalStateLabel = nil
    }

    private static func updatedAverage(
        currentAverage: Double,
        currentCount: Int,
        newValue: Double
    ) -> Double {
        guard currentCount > 0 else {
            return newValue
        }

        let total = currentAverage * Double(currentCount) + newValue
        return total / Double(currentCount + 1)
    }

}
