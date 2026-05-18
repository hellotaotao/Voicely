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
    private static let stateShape: [NSNumber] = [1, 128]

    init() throws {
        let modelURL = try Self.locateModelURL()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        hiddenState = try Self.zeroState()
        cellState = try Self.zeroState()
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
        let audioInput = try Self.multiArray(from: samples, shape: [1, NSNumber(value: Self.chunkSize)])
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

    private static func multiArray(from values: [Float], shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        for index in values.indices {
            pointer[index] = values[index]
        }
        return array
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
