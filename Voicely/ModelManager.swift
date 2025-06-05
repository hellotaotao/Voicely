//
//  ModelManager.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import WhisperKit
import CoreML

enum ModelState: CustomStringConvertible {
    case unloaded
    case loading
    case downloading
    case prewarming
    case loaded
    
    var description: String {
        switch self {
        case .unloaded:
            return "Not Loaded"
        case .loading:
            return "Loading..."
        case .downloading:
            return "Downloading..."
        case .prewarming:
            return "Optimizing..."
        case .loaded:
            return "Ready"
        }
    }
}

@MainActor
class ModelManager: ObservableObject {
    @Published var whisperKit: WhisperKit?
    @Published var modelState: ModelState = .unloaded
    @Published var localModels: [String] = []
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = "base"
    @Published var loadingProgressValue: Float = 0.0
    @Published var encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @Published var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    
    private let modelStorage = "huggingface/models/argmaxinc/whisperkit-coreml"
    private let repoName = "argmaxinc/whisperkit-coreml"
    private var localModelPath = ""
    private var disabledModels: [String] = []
    private let specializationProgressRatio: Float = 0.7
    
    init() {
        selectedModel = WhisperKit.recommendedModels().default
    }
    
    func fetchModels() async {
        availableModels = [selectedModel]
        
        // Check what's already downloaded locally
        await checkLocalModels()
        
        // Add local models to available models
        for model in localModels {
            if !availableModels.contains(model) {
                availableModels.append(model)
            }
        }
        
        // Fetch remote models
        let remoteModelSupport = await WhisperKit.recommendedRemoteModels()
        for model in remoteModelSupport.supported {
            if !availableModels.contains(model) {
                availableModels.append(model)
            }
        }
        for model in remoteModelSupport.disabled {
            if !disabledModels.contains(model) {
                disabledModels.append(model)
            }
        }
        
        print("recommendedRemoteModels: \(remoteModelSupport.supported)")
        print("Available models: \(availableModels)")
    }
    
    private func checkLocalModels() async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let modelPath = documents.appendingPathComponent(modelStorage).path
        localModelPath = modelPath
        
        if FileManager.default.fileExists(atPath: modelPath) {
            do {
                let downloadedModels = try FileManager.default.contentsOfDirectory(atPath: modelPath)
                localModels = WhisperKit.formatModelFiles(downloadedModels)
                print("Found local models: \(localModels)")
            } catch {
                print("Error enumerating files at \(modelPath): \(error.localizedDescription)")
            }
        }
    }
    
    func loadModel(_ model: String, redownload: Bool = false) async {
        print("Loading model: \(model)")
        print("Compute Options - Audio Encoder: \(encoderComputeUnits), Text Decoder: \(decoderComputeUnits)")
        
        whisperKit = nil
        modelState = .loading
        loadingProgressValue = 0.0
        
        do {
            let computeOptions = ModelComputeOptions(
                audioEncoderCompute: encoderComputeUnits,
                textDecoderCompute: decoderComputeUnits
            )
            
            let config = WhisperKitConfig(
                computeOptions: computeOptions,
                verbose: true,
                logLevel: .debug,
                prewarm: false,
                load: false,
                download: false
            )
            
            whisperKit = try await WhisperKit(config)
            
            guard let whisperKit = whisperKit else {
                modelState = .unloaded
                return
            }
            
            var folder: URL?
            
            // Check if model is available locally
            if localModels.contains(model) && !redownload {
                folder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
            } else {
                // Download the model
                modelState = .downloading
                folder = try await WhisperKit.download(variant: model, from: repoName) { [self] progress in
                    Task { @MainActor in
                        self.loadingProgressValue = Float(progress.fractionCompleted) * self.specializationProgressRatio
                    }
                }
            }
            
            loadingProgressValue = specializationProgressRatio
            modelState = .prewarming
            
            if let modelFolder = folder {
                whisperKit.modelFolder = modelFolder
                
                modelState = .prewarming
                
                // Update progress bar during prewarming
                let progressTask = Task {
                    await updateProgressBar(targetProgress: 0.9, maxTime: 240)
                }
                
                do {
                    try await whisperKit.prewarmModels()
                    progressTask.cancel()
                } catch {
                    print("Error prewarming models, retrying: \(error.localizedDescription)")
                    progressTask.cancel()
                    if !redownload {
                        await loadModel(model, redownload: true)
                        return
                    } else {
                        modelState = .unloaded
                        return
                    }
                }
                
                loadingProgressValue = specializationProgressRatio + 0.9 * (1 - specializationProgressRatio)
                modelState = .loading
                
                try await whisperKit.loadModels()
                
                if !localModels.contains(model) {
                    localModels.append(model)
                }
                
                loadingProgressValue = 1.0
                modelState = .loaded
                
                print("Model loaded successfully: \(model)")
            }
        } catch {
            print("Failed to load model: \(error)")
            modelState = .unloaded
            loadingProgressValue = 0.0
        }
    }
    
    func deleteModel(_ model: String) {
        guard localModels.contains(model) else { return }
        
        let modelFolder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
        
        do {
            try FileManager.default.removeItem(at: modelFolder)
            if let index = localModels.firstIndex(of: model) {
                localModels.remove(at: index)
            }
            
            if selectedModel == model {
                modelState = .unloaded
                whisperKit = nil
            }
            
            print("Deleted model: \(model)")
        } catch {
            print("Error deleting model: \(error)")
        }
    }
    
    private func updateProgressBar(targetProgress: Float, maxTime: TimeInterval) async {
        let initialProgress = loadingProgressValue
        let decayConstant = -log(1 - targetProgress) / Float(maxTime)
        let startTime = Date()
        
        while !Task.isCancelled {
            let elapsedTime = Date().timeIntervalSince(startTime)
            let decayFactor = exp(-decayConstant * Float(elapsedTime))
            let progressIncrement = (1 - initialProgress) * (1 - decayFactor)
            let currentProgress = initialProgress + progressIncrement
            
            loadingProgressValue = currentProgress
            
            if currentProgress >= targetProgress {
                break
            }
            
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                break
            }
        }
    }
    
    func getWhisperKit() -> WhisperKit? {
        return whisperKit
    }
    
    func isModelLoaded() -> Bool {
        return modelState == .loaded && whisperKit != nil
    }
}
