//
//  SileroNeuralVoiceActivityDetector.swift
//  Voicely
//

import CoreML
import Foundation

protocol NeuralVoiceActivityDetecting {
    func speechProbabilities(in samples: [Float]) throws -> [NeuralVoiceActivityFrame]
}

struct NeuralVoiceActivityFrame {
    let startFrame: Int
    let endFrame: Int
    let speechProbability: Double
}

enum SileroNeuralVoiceActivityDetectorError: LocalizedError {
    case modelNotFound
    case inferenceError

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Silero neural VAD CoreML model not found in app bundle."
        case .inferenceError:
            return "Silero neural VAD inference did not return vad_output."
        }
    }
}

/// On-device neural VAD backed by Silero VAD v6 CoreML.
///
/// The model consumes 576-sample mono Float32 windows at 16 kHz and returns a
/// speech probability for each 36 ms frame. LSTM state is reset per analysis
/// window because Voicely uses it to find safe split points inside a recent
/// recording range, not as the long-lived transcript engine.
final class SileroNeuralVoiceActivityDetector: NeuralVoiceActivityDetecting {
    static let sampleRate = 16_000
    static let chunkSize = 576

    private let model: MLModel
    private var hiddenState: MLMultiArray
    private var cellState: MLMultiArray
    private let audioInput: MLMultiArray
    private static let stateShape: [NSNumber] = [1, 128]

    /// Loading the compiled CoreML model dominates detector creation cost, so
    /// it is loaded once per process and shared. MLModel predictions are
    /// thread-safe; each detector instance keeps only its own LSTM state.
    private static let sharedModelResult: Result<MLModel, Error> = Result {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: locateModelURL(), configuration: configuration)
    }

    init() throws {
        model = try Self.sharedModelResult.get()
        hiddenState = try Self.zeroState()
        cellState = try Self.zeroState()
        audioInput = try MLMultiArray(
            shape: [1, NSNumber(value: Self.chunkSize)],
            dataType: .float32
        )
    }

    func speechProbabilities(in samples: [Float]) throws -> [NeuralVoiceActivityFrame] {
        reset()
        guard !samples.isEmpty else { return [] }

        var frames: [NeuralVoiceActivityFrame] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + Self.chunkSize, samples.count)
            var chunk = Array(samples[offset..<end])
            if chunk.count < Self.chunkSize {
                chunk.append(contentsOf: repeatElement(0, count: Self.chunkSize - chunk.count))
            }

            let probability = try process(chunk)
            frames.append(NeuralVoiceActivityFrame(
                startFrame: offset,
                endFrame: min(offset + Self.chunkSize, samples.count),
                speechProbability: Double(probability)
            ))
            offset += Self.chunkSize
        }
        return frames
    }

    private func process(_ samples: [Float]) throws -> Float {
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            audioInput.dataPointer
                .bindMemory(to: Float.self, capacity: Self.chunkSize)
                .update(from: base, count: min(samples.count, Self.chunkSize))
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": MLFeatureValue(multiArray: audioInput),
            "hidden_state": MLFeatureValue(multiArray: hiddenState),
            "cell_state": MLFeatureValue(multiArray: cellState)
        ])

        let result = try model.prediction(from: provider)
        if let newHiddenState = result.featureValue(for: "new_hidden_state")?.multiArrayValue {
            hiddenState = newHiddenState
        }
        if let newCellState = result.featureValue(for: "new_cell_state")?.multiArrayValue {
            cellState = newCellState
        }
        guard let output = result.featureValue(for: "vad_output")?.multiArrayValue else {
            throw SileroNeuralVoiceActivityDetectorError.inferenceError
        }
        return output[0].floatValue
    }

    private func reset() {
        if let hidden = try? Self.zeroState() {
            hiddenState = hidden
        }
        if let cell = try? Self.zeroState() {
            cellState = cell
        }
    }

    private static func zeroState() throws -> MLMultiArray {
        try MLMultiArray(shape: stateShape, dataType: .float32)
    }

    private static func locateModelURL() throws -> URL {
        let bundles = Bundle.allBundles + Bundle.allFrameworks + [Bundle.main]
        for bundle in bundles {
            if let url = bundle.url(forResource: "silero_vad", withExtension: "mlmodelc") {
                return url
            }
            if let url = bundle.url(forResource: "Resources/silero_vad", withExtension: "mlmodelc") {
                return url
            }
            if let resourceURL = bundle.resourceURL {
                let nested = resourceURL.appendingPathComponent("silero_vad.mlmodelc")
                if FileManager.default.fileExists(atPath: nested.path) {
                    return nested
                }
                let nestedResources = resourceURL.appendingPathComponent("Resources/silero_vad.mlmodelc")
                if FileManager.default.fileExists(atPath: nestedResources.path) {
                    return nestedResources
                }
            }
        }
        throw SileroNeuralVoiceActivityDetectorError.modelNotFound
    }
}
