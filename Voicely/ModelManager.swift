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
    @Published var modelState: ModelState = .unloaded {
        didSet {
            if modelState == .loaded && oldValue != .loaded {
                // Send notification when model is loaded successfully
                NotificationCenter.default.post(name: .modelLoadedNotification, object: nil)
            }
        }
    }
    @Published var localModels: [String] = []
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = "small" {
        didSet {
            // Save selected model to UserDefaults
            UserDefaults.standard.set(selectedModel, forKey: .selectedModelKey)
        }
    }
    @Published var loadingProgressValue: Float = 0.0
    @Published var encoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @Published var decoderComputeUnits: MLComputeUnits = .cpuAndNeuralEngine
    @Published var errorMessage: String?
    
    private let modelStorage = "huggingface/models/argmaxinc/whisperkit-coreml"
    private let repoName = "argmaxinc/whisperkit-coreml"
    private var localModelPath = ""
    private var disabledModels: [String] = []
    private let specializationProgressRatio: Float = 0.7
    
    init() {
        // Read selected model from UserDefaults if available
        if let savedModel = UserDefaults.standard.string(forKey: .selectedModelKey) {
            selectedModel = savedModel
            print("Loaded saved model selection from UserDefaults: \(savedModel)")
        } else {
            var defaultModel = WhisperKit.recommendedModels().default
            // If recommended default contains "base", use "openai_whisper-small" instead
            if defaultModel.contains("base") {
                defaultModel = "openai_whisper-small"
            }
            // Use the default model if it passes our filter, otherwise use small model
            selectedModel = shouldIncludeModel(defaultModel) ? defaultModel : selectedModel
            print("Using default model: \(selectedModel)")
            // On initialization, save the selected model to UserDefaults
            UserDefaults.standard.set(selectedModel, forKey: .selectedModelKey)
        }
    }
    
    func fetchModels(includeRemote: Bool = true) async {
        availableModels = []
        
        // Add selected model only if it passes filter
        if shouldIncludeModel(selectedModel) {
            availableModels.append(selectedModel)
        }
        
        // Check what's already downloaded locally
        await checkLocalModels()
        
        // Add local models to available models
        for model in localModels {
            if !availableModels.contains(model) && shouldIncludeModel(model) {
                availableModels.append(model)
            }
        }
        
        if includeRemote {
            // Fetch remote models
            let remoteModelSupport = await WhisperKit.recommendedRemoteModels()
            for model in remoteModelSupport.supported {
                if !availableModels.contains(model) && shouldIncludeModel(model) {
                    availableModels.append(model)
                }
            }
            for model in remoteModelSupport.disabled {
                if !disabledModels.contains(model) {
                    disabledModels.append(model)
                }
            }
            print("recommendedRemoteModels: \(remoteModelSupport.supported)")
            
            // Always include large-v3-turbo multilingual model regardless of device recommendations
            // The multilingual version uses hyphen: openai_whisper-large-v3-turbo
            // The MB suffix versions (954MB) are English-only which we filter out
            let largeTurboModel = "openai_whisper-large-v3-turbo"
            if !availableModels.contains(largeTurboModel) {
                availableModels.append(largeTurboModel)
                print("Force-added large-v3-turbo multilingual model: \(largeTurboModel)")
            }
        }

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
                localModels = ModelUtilities.formatModelFiles(downloadedModels)
                print("Found local models: \(localModels)")
            } catch {
                print("Error enumerating files at \(modelPath): \(error.localizedDescription)")
            }
        }
    }
    
    private var currentLoadedModel: String?
    
    func loadModel(_ model: String, redownload: Bool = false) async {
        print("=== loadModel called ===")
        print("Loading model: \(model)")
        print("Device: \(WhisperKit.deviceName())")
        print("Compute Options - Audio Encoder: \(encoderComputeUnits), Text Decoder: \(decoderComputeUnits)")
        
        // Clear any previous error
        errorMessage = nil
        
        // Skip if the same model is already loaded in memory and we're not forcing a redownload
        // This check is independent of modelState because user might have switched selection
        // (which sets modelState to .unloaded) but the model is still in memory
        if !redownload && whisperKit != nil && currentLoadedModel == model {
            print("Model '\(model)' is already loaded in memory, skipping reload")
            modelState = .loaded
            loadingProgressValue = 1.0
            return
        }
        
        whisperKit = nil
        currentLoadedModel = nil
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
                print("ERROR: WhisperKit initialization returned nil")
                errorMessage = "Failed to initialize WhisperKit"
                modelState = .unloaded
                return
            }
            
            var folder: URL?
            
            // Check if model is available locally
            if localModels.contains(model) && !redownload {
                folder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
                print("Using local model at: \(folder?.path ?? "nil")")
            } else {
                // Download the model
                modelState = .downloading
                print("Downloading model: \(model) from repo: \(repoName)")
                
                // Try downloading without device-specific filtering by using the exact model name
                do {
                    folder = try await WhisperKit.download(variant: model, from: repoName) { [self] progress in
                        Task { @MainActor in
                            self.loadingProgressValue = Float(progress.fractionCompleted) * self.specializationProgressRatio
                        }
                    }
                    print("Download succeeded, folder: \(folder?.path ?? "nil")")
                } catch {
                    print("Download failed with error: \(error)")
                    // If the model name doesn't work, the error will propagate
                    throw error
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
                    print("Error prewarming models: \(error.localizedDescription)")
                    progressTask.cancel()
                    if !redownload {
                        print("Retrying with redownload...")
                        await loadModel(model, redownload: true)
                        return
                    } else {
                        print("Prewarm failed after retry")
                        errorMessage = "Failed to optimize model: \(error.localizedDescription)"
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
                currentLoadedModel = model
                
                print("Model loaded successfully: \(model)")
            }
        } catch {
            print("Failed to load model: \(error)")
            errorMessage = "Failed to load model: \(error.localizedDescription)"
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
            
            if selectedModel == model || currentLoadedModel == model {
                // If deleting the currently selected/loaded model, default to an available model
                if selectedModel == model && !availableModels.isEmpty {
                    // Choose the first non-local model, or default back to "small"
                    let newModel = availableModels.first(where: { $0 != model }) ?? "small"
                    selectedModel = newModel // This triggers didSet to persist to UserDefaults
                    print("Changed selected model to \(newModel) after deletion")
                }
                
                modelState = .unloaded
                whisperKit = nil
                currentLoadedModel = nil
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
    
    func isSelectedModelDownloaded() -> Bool {
        return localModels.contains(selectedModel)
    }
    
    private func shouldIncludeModel(_ model: String) -> Bool {
        let modelLower = model.lowercased()
        
        // Remove all English-only models (including those with MB suffix like 947mb, 954mb)
        if modelLower.contains("english") || modelLower.contains(".en") {
            return false
        }
        
        // Remove English-only models with MB suffix (e.g., large-v3_947mb, large-v3-turbo_954mb)
        // These are English-only variants that don't support multilingual transcription
        if modelLower.contains("mb") && (modelLower.contains("947") || modelLower.contains("954") || modelLower.contains("_9")) {
            return false
        }
        
        // Remove tiny models
        if modelLower.contains("tiny") {
            return false
        }
        
        // Remove all distill models
        if modelLower.contains("distil") {
            return false
        }
        
        // For large models, remove v2
        if modelLower.contains("large") && modelLower.contains("v2") {
            return false
        }
        
        return true
    }
}

// Add notification name extension
extension Notification.Name {
    static let modelLoadedNotification = Notification.Name("ModelLoadedNotification")
}

// UserDefaults keys
private extension String {
    static let selectedModelKey = "selectedModel"
}
