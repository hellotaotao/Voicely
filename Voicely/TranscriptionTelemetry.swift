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

/// A speech model that worked on a transcription run, as its speed card and
/// compute badge name it.
enum SpeechModelKind: Int, Comparable {
    case qwen3
    case parakeet

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .qwen3: return Qwen3ASRDefaults.modelDisplayName
        case .parakeet: return "Parakeet TDT 0.6B v2"
        }
    }

    /// MLX runs Qwen3-ASR on the GPU and CoreML keeps it off it; Parakeet is
    /// CoreML on CPU + Neural Engine on every device.
    func computeUnits(qwenBackend: Qwen3Backend) -> MLComputeUnits {
        switch self {
        case .qwen3: return qwenBackend == .mlx ? .cpuAndGPU : .cpuAndNeuralEngine
        case .parakeet: return .cpuAndNeuralEngine
        }
    }
}

struct TranscriptionComputeRoute: Equatable {
    /// The units the run's models ran on, each once.
    let units: [MLComputeUnits]

    init(units: [MLComputeUnits]) {
        var distinct: [MLComputeUnits] = []
        for unit in units where !distinct.contains(unit) { distinct.append(unit) }
        self.units = distinct
    }

    /// Qwen3-ASR alone.
    init(backend: Qwen3Backend) {
        self.init(models: [.qwen3], qwenBackend: backend)
    }

    init(models: [SpeechModelKind], qwenBackend: Qwen3Backend) {
        self.init(units: models.sorted().map { $0.computeUnits(qwenBackend: qwenBackend) })
    }

    var summary: String {
        units.map(Self.displayName(for:)).joined(separator: " + ")
    }

    var compactDescription: String { summary }

    var detail: String {
        units.map(Self.shortName(for:)).joined(separator: " + ")
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
    /// The models `modelName` and `computeRoute` describe.
    var models: [SpeechModelKind] = []

    /// Names `models`, Qwen3-ASR first, and the units they ran on.
    mutating func describe(_ models: [SpeechModelKind], qwenBackend: Qwen3Backend) {
        self.models = Array(Set(models)).sorted()
        modelName = self.models.map(\.displayName).joined(separator: " + ")
        computeRoute = TranscriptionComputeRoute(models: self.models, qwenBackend: qwenBackend)
    }

    static func inactive(describing models: [SpeechModelKind], qwenBackend: Qwen3Backend) -> TranscriptionTelemetrySnapshot {
        var snapshot = inactive()
        snapshot.describe(models, qwenBackend: qwenBackend)
        return snapshot
    }

    static func inactive(
        modelName: String = "No model",
        computeRoute: TranscriptionComputeRoute = TranscriptionComputeRoute(units: [.cpuAndNeuralEngine]),
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
    /// The models that have worked on this run so far.
    var models = Set<SpeechModelKind>()

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
