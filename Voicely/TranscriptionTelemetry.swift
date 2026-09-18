//
//  TranscriptionTelemetry.swift
//  Voicely
//
//  Created by Codex on 5/22/2026.
//

import Combine
import CoreML
import Foundation

struct TranscriptionTelemetryMetrics: Equatable {
    let elapsedSeconds: TimeInterval
    let audioDurationSeconds: TimeInterval?

    let processedAudioSeconds: TimeInterval

    // Omitting processed audio preserves the meaning of legacy completed samples.
    init(elapsedSeconds: TimeInterval, audioDurationSeconds: TimeInterval?, processedAudioSeconds: TimeInterval? = nil) {
        self.elapsedSeconds = elapsedSeconds
        self.audioDurationSeconds = audioDurationSeconds
        self.processedAudioSeconds = processedAudioSeconds ?? audioDurationSeconds ?? 0
    }

    var processedDurationLabel: String { Self.durationLabel(processedAudioSeconds) }
    var elapsedDurationLabel: String { Self.durationLabel(elapsedSeconds) }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    var processingTimeRatioPercent: Int? {
        guard processedAudioSeconds.isFinite, processedAudioSeconds > 0, elapsedSeconds.isFinite else {
            return nil
        }

        let percentage = elapsedSeconds / processedAudioSeconds * 100
        return max(0, Int(percentage.rounded()))
    }

    var processingTimeRatioLabel: String {
        guard let processingTimeRatioPercent else {
            return "Measuring"
        }

        return "\(processingTimeRatioPercent)%"
    }

    var speedMultiplier: Double? {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0,
              processedAudioSeconds.isFinite, processedAudioSeconds > 0 else {
            return nil
        }

        return processedAudioSeconds / elapsedSeconds
    }

    var speedLabel: String {
        guard let speedMultiplier else {
            return "Measuring speed"
        }

        return String(format: "%.1f× realtime", speedMultiplier)
    }
}

/// Union of successfully processed source-audio intervals in this run only.
struct TranscriptionAudioCoverage {
    private var ranges: [Range<TimeInterval>] = []

    var processedSeconds: TimeInterval { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    mutating func record(start: TimeInterval, end: TimeInterval) {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return }
        var merged: [Range<TimeInterval>] = []
        for range in (ranges + [start..<end]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }
}

struct TranscriptionComputeRoute: Equatable {
    let encoderUnits: MLComputeUnits
    let decoderUnits: MLComputeUnits

    var summary: String {
        if encoderUnits == decoderUnits {
            return Self.displayName(for: encoderUnits)
        }

        return "Mixed Compute"
    }

    var compactDescription: String {
        encoderUnits == decoderUnits ? Self.displayName(for: encoderUnits) : detail
    }

    var detail: String {
        "Encoder \(Self.shortName(for: encoderUnits)) · Decoder \(Self.shortName(for: decoderUnits))"
    }

    static func shortName(for units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly:
            return "CPU"
        case .cpuAndGPU:
            return "GPU"
        case .cpuAndNeuralEngine:
            return "ANE"
        case .all:
            return "Auto"
        @unknown default:
            return "Auto"
        }
    }

    static func displayName(for units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly:
            return "CPU"
        case .cpuAndGPU:
            return "GPU"
        case .cpuAndNeuralEngine:
            return "Neural Engine (NPU)"
        case .all:
            return "Auto"
        @unknown default:
            return "Auto"
        }
    }
}

struct TranscriptionTelemetrySnapshot: Equatable {
    var isActive: Bool
    var modelName: String
    var computeRoute: TranscriptionComputeRoute
    var metrics: TranscriptionTelemetryMetrics
    var thermalState: ProcessInfo.ThermalState

    static func inactive(
        modelName: String = "No model",
        computeRoute: TranscriptionComputeRoute = TranscriptionComputeRoute(
            encoderUnits: .cpuAndNeuralEngine,
            decoderUnits: .cpuAndNeuralEngine
        ),
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> TranscriptionTelemetrySnapshot {
        TranscriptionTelemetrySnapshot(
            isActive: false,
            modelName: modelName,
            computeRoute: computeRoute,
            metrics: TranscriptionTelemetryMetrics(
                elapsedSeconds: 0,
                audioDurationSeconds: nil
            ),
            thermalState: thermalState
        )
    }

    var thermalStateLabel: String {
        switch thermalState {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }
}

/// Identity and active-work clock for one transcription run.
@MainActor
final class TranscriptionTelemetrySession {
    let id = UUID()
    let noteID: UUID?
    let activeWorkOnly: Bool
    var isCancelled = false
    var runningSince: Date?
    var elapsed: TimeInterval = 0
    var audioDuration: TimeInterval?
    var coverage = TranscriptionAudioCoverage()

    init(noteID: UUID?, activeWorkOnly: Bool, now: Date) {
        self.noteID = noteID
        self.activeWorkOnly = activeWorkOnly
        self.runningSince = activeWorkOnly ? nil : now
    }
}

/// A separate observation boundary for per-second telemetry updates.
@MainActor
final class TranscriptionTelemetryState: ObservableObject {
    @Published private(set) var snapshot: TranscriptionTelemetrySnapshot = .inactive()

    @Published private(set) var noteSnapshots: [UUID: TranscriptionTelemetrySnapshot] = [:]

    func snapshot(for noteID: UUID) -> TranscriptionTelemetrySnapshot? { noteSnapshots[noteID] }

    func update(_ snapshot: TranscriptionTelemetrySnapshot, noteID: UUID? = nil) {
        if let noteID, noteSnapshots[noteID] != snapshot { noteSnapshots[noteID] = snapshot }

        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}
