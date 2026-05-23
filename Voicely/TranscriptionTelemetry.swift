//
//  TranscriptionTelemetry.swift
//  Voicely
//
//  Created by Codex on 5/22/2026.
//

import CoreML
import Foundation

struct TranscriptionTelemetryMetrics: Equatable {
    let elapsedSeconds: TimeInterval
    let audioDurationSeconds: TimeInterval?

    var processingTimeRatioPercent: Int? {
        guard let audioDurationSeconds, audioDurationSeconds > 0 else {
            return nil
        }

        let percentage = elapsedSeconds / audioDurationSeconds * 100
        return max(0, Int(percentage.rounded()))
    }

    var processingTimeRatioLabel: String {
        guard let processingTimeRatioPercent else {
            return "Measuring"
        }

        return "\(processingTimeRatioPercent)%"
    }

    var speedMultiplier: Double? {
        guard elapsedSeconds > 0,
              let audioDurationSeconds,
              audioDurationSeconds > 0 else {
            return nil
        }

        return audioDurationSeconds / elapsedSeconds
    }

    var speedLabel: String {
        guard let speedMultiplier else {
            return "Measuring speed"
        }

        return String(format: "%.1f× realtime", speedMultiplier)
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
