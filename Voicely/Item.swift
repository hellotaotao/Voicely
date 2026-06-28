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

/// How a finished transcription attempt turned out, so the UI can show the right
/// calm state without re-deriving it from scattered flags. Absent (nil) means the
/// note hasn't produced a finished attempt yet.
enum VoiceNoteTranscriptionOutcome: String {
    case transcribed   // produced text (including verbatim non-speech like "Music")
    case partial       // produced text, but one or more segments couldn't be transcribed
    case noSpeech      // VAD found no speech anywhere — nothing to transcribe
    case failed        // a real error we couldn't recover from (diagnostic kept internally)
}

enum WaveformSeedGenerator {
    static func stableSeed(for uuid: UUID) -> Int {
        let hash = uuid.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Int(hash % 10_000)
    }
}

/// One transcribed word and its time span within the recording, in seconds.
/// Stored (option A) as a compact JSON array on the note; the readable text
/// still lives in `transcription`, so this carries only timing data.
struct WordToken: Codable, Equatable {
    let word: String
    let start: Double
    let end: Double
}

@Model
final class VoiceNote {
    var id: UUID = UUID()
    var title: String = "Voice Note"
    /// True once the user has explicitly set the title, or the note was created
    /// with a meaningful title (imported file name, seeded data). When false,
    /// the title is auto-derived from the transcript on completion.
    var titleWasManuallyEdited: Bool = false
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFilePath: String = ""
    var transcription: String = ""
    /// Word-level timings as a JSON-encoded `[WordToken]`. Optional for CloudKit
    /// compatibility; nil means no timing data (e.g. notes from before this feature).
    var wordTimingsData: Data?
    /// Decoded view over `wordTimingsData`. Empty array when none is stored.
    var wordTimings: [WordToken] {
        get {
            guard let wordTimingsData else { return [] }
            return (try? JSONDecoder().decode([WordToken].self, from: wordTimingsData)) ?? []
        }
        set {
            if newValue.isEmpty {
                wordTimingsData = nil
            } else {
                wordTimingsData = try? JSONEncoder().encode(newValue)
            }
        }
    }
    var transcriptionModelIdentifier: String?
    var transcriptionLastErrorMessage: String?
    var isTranscribing: Bool = false
    var transcriptionProgress: Float = 0.0
    var pendingTranscription: Bool = false // Mark if waiting for transcription
    var lastTranscriptionDuration: TimeInterval = 0
    var transcriptionStateRaw: String = ""
    var transcriptionOutcomeRaw: String = ""
    var transcriptionOriginDeviceID: String?
    var transcriptionOwnerDeviceID: String?
    var transcriptionAttemptID: String?
    var transcriptionQueuedAt: Date?
    var transcriptionLeaseExpiresAt: Date?
    var transcriptionTelemetrySampleCount: Int = 0
    var transcriptionAverageProcessingTimeRatioPercent: Double = 0
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
        self.transcriptionAverageProcessingTimeRatioPercent = 0
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

    var transcriptionOutcome: VoiceNoteTranscriptionOutcome? {
        get {
            VoiceNoteTranscriptionOutcome(rawValue: transcriptionOutcomeRaw)
        }
        set {
            transcriptionOutcomeRaw = newValue?.rawValue ?? ""
        }
    }

    var transcriptionModelDisplayName: String? {
        guard let transcriptionModelIdentifier, !transcriptionModelIdentifier.isEmpty else {
            return nil
        }
        return ModelManager.displayName(for: transcriptionModelIdentifier)
    }

    var averageProcessingTimeRatioLabel: String? {
        guard transcriptionTelemetrySampleCount > 0 else {
            return nil
        }

        return "\(Int(transcriptionAverageProcessingTimeRatioPercent.rounded()))% avg"
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
        transcriptionOutcomeRaw = ""
        pendingTranscription = false
    }

    func completeTranscription() {
        transcriptionState = .completed
        transcriptionOwnerDeviceID = nil
        transcriptionAttemptID = nil
        transcriptionLeaseExpiresAt = nil
        transcriptionLastErrorMessage = nil
        pendingTranscription = false
        applyAutoTitleIfNeeded()
    }

    /// Replaces an auto-generated title with one derived from the transcript's
    /// first sentence. No-op once the user has set their own title, or when the
    /// transcript has no usable speech. Runs fully on-device.
    func applyAutoTitleIfNeeded() {
        guard !titleWasManuallyEdited else { return }
        guard let derived = VoiceNoteAutoTitle.derive(from: transcription) else { return }
        guard derived != title else { return }
        title = derived
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
        guard let processingTimeRatioPercent = snapshot.metrics.processingTimeRatioPercent,
              let speedMultiplier = snapshot.metrics.speedMultiplier else {
            return
        }

        let currentCount = max(transcriptionTelemetrySampleCount, 0)
        let nextCount = currentCount + 1

        transcriptionAverageProcessingTimeRatioPercent = Self.updatedAverage(
            currentAverage: transcriptionAverageProcessingTimeRatioPercent,
            currentCount: currentCount,
            newValue: Double(processingTimeRatioPercent)
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
        transcriptionAverageProcessingTimeRatioPercent = 0
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
