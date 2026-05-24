//
//  ModelManager.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import WhisperKit
import CoreML

enum LocalModelSourceKind: Equatable {
    case bundled
    case downloaded
}

struct LocalModelSource: Equatable {
    let kind: LocalModelSourceKind
    let url: URL
}

struct ModelPreparationSignature: Codable, Equatable {
    let version: Int
    let modelIdentifier: String
    let encoderComputeUnits: String
    let decoderComputeUnits: String
    let sourceKind: String
    let modelFolderPath: String
}

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
    private static let oldIPhoneModelThreshold = 12
    private static let oldIPadModelThreshold = 12

    static var platformDefaultModel: String {
#if targetEnvironment(macCatalyst)
        return "openai_whisper-large-v3_turbo_954MB"
#else
        let deviceIdentifier = WhisperKit.deviceName()

        if isOldAndWeakIOSDevice(deviceIdentifier) {
            return "openai_whisper-base"
        }

        return "openai_whisper-small"
#endif
    }

    private static func isOldAndWeakIOSDevice(_ deviceIdentifier: String) -> Bool {
        if let iPhoneGeneration = numericGeneration(from: deviceIdentifier, prefix: "iPhone") {
            return iPhoneGeneration <= oldIPhoneModelThreshold
        }

        if let iPadGeneration = numericGeneration(from: deviceIdentifier, prefix: "iPad") {
            return iPadGeneration <= oldIPadModelThreshold
        }

        return false
    }

    private static func numericGeneration(from deviceIdentifier: String, prefix: String) -> Int? {
        guard deviceIdentifier.hasPrefix(prefix) else {
            return nil
        }

        let suffix = deviceIdentifier.dropFirst(prefix.count)
        let digits = suffix.prefix { $0.isNumber }

        guard !digits.isEmpty else {
            return nil
        }

        return Int(digits)
    }

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
    @Published private(set) var downloadedModels: [String] = []
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = ModelManager.platformDefaultModel {
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
    private let bundledModelsDirectory = "BundledModels"
    nonisolated private static let modelPreparationSignatureDefaultsKey = "VoicelyModelPreparationSignatureV1"
    nonisolated private static let modelPreparationPolicyVersion = 1
    private var localModelPath = ""
    private var disabledModels: [String] = []
    private let specializationProgressRatio: Float = 0.7
    
    init() {
        // Preserve user's previous selection. Apply platform default only when no saved model exists.
        if let savedModel = UserDefaults.standard.string(forKey: .selectedModelKey) {
            if !savedModel.isEmpty {
                selectedModel = savedModel
                print("Loaded saved model selection from UserDefaults: \(savedModel)")
            } else {
                selectedModel = Self.platformDefaultModel
                UserDefaults.standard.set(selectedModel, forKey: .selectedModelKey)
                print("Saved model is empty. Falling back to default: \(selectedModel)")
            }
        } else {
            selectedModel = Self.platformDefaultModel
            print("Using default model: \(selectedModel)")
            UserDefaults.standard.set(selectedModel, forKey: .selectedModelKey)
        }
    }
    
    func fetchModels(includeRemote: Bool = true) async {
        await checkLocalModels()
        var orderedModels: [String] = []
        var seenModels = Set<String>()

        func addModel(_ model: String) {
            guard shouldIncludeModel(model), !seenModels.contains(model) else {
                return
            }

            seenModels.insert(model)
            orderedModels.append(model)
        }

        if includeRemote {
            let remoteModelSupport = await WhisperKit.recommendedRemoteModels()
            for model in remoteModelSupport.supported {
                addModel(model)
            }
            disabledModels = remoteModelSupport.disabled
            print("recommendedRemoteModels: \(remoteModelSupport.supported)")
        } else {
            disabledModels = []
        }

        for model in localModels {
            addModel(model)
        }

        // Keep selected model visible even if it is outside current recommendation set.
        addModel(selectedModel)

        availableModels = orderedModels

        print("Available models: \(availableModels)")
    }
    
    private func checkLocalModels() async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let modelPath = documents.appendingPathComponent(modelStorage).path
        localModelPath = modelPath
        var models: [String] = []
        
        if FileManager.default.fileExists(atPath: modelPath) {
            do {
                let downloadedModels = try FileManager.default.contentsOfDirectory(atPath: modelPath)
                self.downloadedModels = ModelUtilities.formatModelFiles(downloadedModels)
                models.append(contentsOf: self.downloadedModels)
                print("Found downloaded models: \(self.downloadedModels)")
            } catch {
                print("Error enumerating files at \(modelPath): \(error.localizedDescription)")
            }
        } else {
            downloadedModels = []
        }

        let bundledModels = Self.bundledModelIdentifiers(
            in: bundledModelsRoot,
            directoryName: bundledModelsDirectory
        )
        if !bundledModels.isEmpty {
            models.append(contentsOf: bundledModels)
            print("Found bundled models: \(bundledModels)")
        }

        localModels = Array(Set(models)).sorted { lhs, rhs in
            ModelManager.displayName(for: lhs).localizedCaseInsensitiveCompare(ModelManager.displayName(for: rhs)) == .orderedAscending
        }
    }
    
    private var currentLoadedModel: String?
    private var bundledModelsRoot: URL? {
        Bundle.main.resourceURL
    }

    var loadedModelIdentifierInMemory: String? {
        currentLoadedModel
    }

    nonisolated static func selectionStateAfterPickingModel(
        _ selectedModel: String,
        loadedModelIdentifier: String?
    ) -> ModelState {
        guard loadedModelIdentifier == selectedModel else {
            return .unloaded
        }
        return .loaded
    }

    nonisolated static func modelPreparationSignature(
        for model: String,
        encoderComputeUnits: MLComputeUnits,
        decoderComputeUnits: MLComputeUnits,
        sourceKind: LocalModelSourceKind,
        modelFolder: URL
    ) -> ModelPreparationSignature {
        ModelPreparationSignature(
            version: modelPreparationPolicyVersion,
            modelIdentifier: model,
            encoderComputeUnits: computeUnitsIdentifier(encoderComputeUnits),
            decoderComputeUnits: computeUnitsIdentifier(decoderComputeUnits),
            sourceKind: sourceKindIdentifier(sourceKind),
            modelFolderPath: modelFolder.standardizedFileURL.path
        )
    }

    nonisolated static func shouldPrewarmBeforeLoad(
        currentSignature: ModelPreparationSignature,
        storedSignature: ModelPreparationSignature?
    ) -> Bool {
        storedSignature != currentSignature
    }
    
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

#if DEBUG
            let enableVerboseWhisperLogs = UserDefaults.standard.bool(forKey: "whisperVerboseLogging")
#else
            let enableVerboseWhisperLogs = false
#endif
            
            let config = WhisperKitConfig(
                computeOptions: computeOptions,
                verbose: enableVerboseWhisperLogs,
                logLevel: {
#if DEBUG
                    return enableVerboseWhisperLogs ? .debug : .error
#else
                    return .error
#endif
                }(),
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
            let localSource = Self.preferredLocalModelSource(
                for: model,
                downloadedModels: downloadedModels,
                downloadedModelsRootPath: localModelPath,
                bundledModelsRoot: bundledModelsRoot
            )

            // Check if model is available locally
            if let localSource, !redownload {
                folder = localSource.url
                print("Using \(localSource.kind) model at: \(folder?.path ?? "nil")")
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
            
            if let modelFolder = folder {
                whisperKit.modelFolder = modelFolder

                let resolvedSourceKind: LocalModelSourceKind
                if let localSource, !redownload {
                    resolvedSourceKind = localSource.kind
                } else {
                    resolvedSourceKind = .downloaded
                }
                let preparationSignature = Self.modelPreparationSignature(
                    for: model,
                    encoderComputeUnits: encoderComputeUnits,
                    decoderComputeUnits: decoderComputeUnits,
                    sourceKind: resolvedSourceKind,
                    modelFolder: modelFolder
                )
                let shouldPrewarm = redownload || Self.shouldPrewarmBeforeLoad(
                    currentSignature: preparationSignature,
                    storedSignature: storedModelPreparationSignature()
                )

                if shouldPrewarm {
                    do {
                        try await prewarmModelsForCurrentDevice(whisperKit)
                        storeModelPreparationSignature(preparationSignature)
                        loadingProgressValue = specializationProgressRatio + 0.9 * (1 - specializationProgressRatio)
                    } catch {
                        print("Error prewarming models: \(error.localizedDescription)")
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
                } else {
                    print("Skipping model prewarm because the preparation signature matches the selected model and compute route.")
                }
                
                modelState = .loading
                do {
                    try await whisperKit.loadModels()
                } catch {
                    guard !shouldPrewarm, !redownload else {
                        throw error
                    }

                    print("Loading failed after skipping prewarm: \(error.localizedDescription)")
                    print("Retrying once with prewarm before loading...")
                    try await prewarmModelsForCurrentDevice(whisperKit)
                    storeModelPreparationSignature(preparationSignature)
                    loadingProgressValue = specializationProgressRatio + 0.9 * (1 - specializationProgressRatio)
                    modelState = .loading
                    try await whisperKit.loadModels()
                }
                
                if !downloadedModels.contains(model), resolvedSourceKind != .bundled {
                    downloadedModels.append(model)
                }

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
        guard downloadedModels.contains(model) else { return }
        
        let modelFolder = URL(fileURLWithPath: localModelPath).appendingPathComponent(model)
        
        do {
            try FileManager.default.removeItem(at: modelFolder)
            if let index = downloadedModels.firstIndex(of: model) {
                downloadedModels.remove(at: index)
            }

            if !Self.isBundledModel(
                model,
                bundledModelsRoot: bundledModelsRoot,
                directoryName: bundledModelsDirectory
            ), let index = localModels.firstIndex(of: model) {
                localModels.remove(at: index)
            }
            
            let stillAvailableAsBuiltIn = Self.isBundledModel(
                model,
                bundledModelsRoot: bundledModelsRoot,
                directoryName: bundledModelsDirectory
            )

            if selectedModel == model || currentLoadedModel == model {
                // If deleting the currently selected/loaded model, default to an available model
                if selectedModel == model && !stillAvailableAsBuiltIn && !availableModels.isEmpty {
                    let newModel = availableModels.first(where: { $0 != model }) ?? Self.platformDefaultModel
                    selectedModel = newModel // This triggers didSet to persist to UserDefaults
                    print("Changed selected model to \(newModel) after deletion")
                }

                if !stillAvailableAsBuiltIn {
                    modelState = .unloaded
                    whisperKit = nil
                    currentLoadedModel = nil
                }
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
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                break
            }
        }
    }

    private func storedModelPreparationSignature() -> ModelPreparationSignature? {
        guard let data = UserDefaults.standard.data(forKey: Self.modelPreparationSignatureDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ModelPreparationSignature.self, from: data)
    }

    private func storeModelPreparationSignature(_ signature: ModelPreparationSignature) {
        guard let data = try? JSONEncoder().encode(signature) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.modelPreparationSignatureDefaultsKey)
    }

    private func prewarmModelsForCurrentDevice(_ whisperKit: WhisperKit) async throws {
        modelState = .prewarming
        let progressTask = Task {
            await updateProgressBar(targetProgress: 0.9, maxTime: 240)
        }
        defer {
            progressTask.cancel()
        }
        try await whisperKit.prewarmModels()
    }
    
    func getWhisperKit() -> WhisperKit? {
        return whisperKit
    }

    func currentModelIdentifier() -> String? {
        if let currentLoadedModel {
            return currentLoadedModel
        }

        guard isModelLoaded() else {
            return nil
        }

        return selectedModel
    }

    func isModelLoaded() -> Bool {
        return modelState == .loaded && whisperKit != nil
    }
    
    func isSelectedModelDownloaded() -> Bool {
        return downloadedModels.contains(selectedModel)
    }

    func isSelectedModelBuiltIn() -> Bool {
        Self.isBundledModel(
            selectedModel,
            bundledModelsRoot: bundledModelsRoot,
            directoryName: bundledModelsDirectory
        )
    }

    func isModelAvailableOffline(_ model: String) -> Bool {
        localModels.contains(model) || Self.isBundledModel(
            model,
            bundledModelsRoot: bundledModelsRoot,
            directoryName: bundledModelsDirectory
        )
    }
    
    private func shouldIncludeModel(_ model: String) -> Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func computeUnitsIdentifier(_ computeUnits: MLComputeUnits) -> String {
        switch computeUnits {
        case .cpuOnly:
            return "cpuOnly"
        case .cpuAndGPU:
            return "cpuAndGPU"
        case .cpuAndNeuralEngine:
            return "cpuAndNeuralEngine"
        case .all:
            return "all"
        @unknown default:
            return String(describing: computeUnits)
        }
    }

    nonisolated private static func sourceKindIdentifier(_ sourceKind: LocalModelSourceKind) -> String {
        switch sourceKind {
        case .bundled:
            return "bundled"
        case .downloaded:
            return "downloaded"
        }
    }

    nonisolated static func preferredLocalModelSource(
        for model: String,
        downloadedModels: [String],
        downloadedModelsRootPath: String,
        bundledModelsRoot: URL?,
        fileManager: FileManager = .default
    ) -> LocalModelSource? {
        if let bundledURL = bundledModelURL(
            for: model,
            bundledModelsRoot: bundledModelsRoot,
            directoryName: "BundledModels",
            fileManager: fileManager
        ) {
            return LocalModelSource(kind: .bundled, url: bundledURL)
        }

        if downloadedModels.contains(model) {
            let downloadedURL = URL(fileURLWithPath: downloadedModelsRootPath).appendingPathComponent(model)
            if isWhisperKitModelFolder(downloadedURL, fileManager: fileManager) {
                return LocalModelSource(kind: .downloaded, url: downloadedURL)
            }
        }

        return nil
    }

    nonisolated static func bundledModelIdentifiers(
        in bundledModelsRoot: URL?,
        directoryName: String = "BundledModels",
        fileManager: FileManager = .default
    ) -> [String] {
        guard let bundledModelsRoot else {
            return []
        }

        let bundledModelsURL = bundledModelsRoot.appendingPathComponent(directoryName)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: bundledModelsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url in
            guard isWhisperKitModelFolder(url, fileManager: fileManager) else {
                return nil
            }
            if url.pathExtension == "bundle" {
                return url.deletingPathExtension().lastPathComponent
            }
            return url.lastPathComponent
        }
    }

    nonisolated private static func isBundledModel(
        _ model: String,
        bundledModelsRoot: URL?,
        directoryName: String,
        fileManager: FileManager = .default
    ) -> Bool {
        bundledModelURL(
            for: model,
            bundledModelsRoot: bundledModelsRoot,
            directoryName: directoryName,
            fileManager: fileManager
        ) != nil
    }

    nonisolated private static func bundledModelURL(
        for model: String,
        bundledModelsRoot: URL?,
        directoryName: String,
        fileManager: FileManager
    ) -> URL? {
        guard let bundledModelsRoot else {
            return nil
        }

        let candidates = [
            bundledModelsRoot.appendingPathComponent(directoryName).appendingPathComponent(model),
            bundledModelsRoot.appendingPathComponent(directoryName).appendingPathComponent("\(model).bundle"),
            bundledModelsRoot.appendingPathComponent(model),
            bundledModelsRoot.appendingPathComponent("\(model).bundle"),
            bundledModelsRoot
        ]

        return candidates.first { isWhisperKitModelFolder($0, fileManager: fileManager) }
    }

    nonisolated private static func isWhisperKitModelFolder(_ url: URL, fileManager: FileManager) -> Bool {
        guard isDirectory(url, fileManager: fileManager) else {
            return false
        }

        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { component in
            modelComponentExists(named: component, in: url, fileManager: fileManager)
        }
    }

    nonisolated private static func modelComponentExists(
        named component: String,
        in folder: URL,
        fileManager: FileManager
    ) -> Bool {
        let compiledURL = folder.appendingPathComponent("\(component).mlmodelc")
        if isDirectory(compiledURL, fileManager: fileManager) {
            return true
        }

        let packageURL = folder.appendingPathComponent("\(component).mlpackage")
        if isDirectory(packageURL, fileManager: fileManager) {
            return true
        }

        let packageModelURL = packageURL
            .appendingPathComponent("Data")
            .appendingPathComponent("com.apple.CoreML")
            .appendingPathComponent("model.mlmodel")
        return fileManager.fileExists(atPath: packageModelURL.path)
    }

    nonisolated private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    nonisolated static func displayName(for modelIdentifier: String) -> String {
        let normalized = modelIdentifier
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "whisper-", with: "")
            .replacingOccurrences(of: "_", with: "-")

        let tokens = normalized.split(separator: "-").map { token -> String in
            let lower = token.lowercased()

            if lower.hasPrefix("v") && lower.dropFirst().allSatisfy({ $0.isNumber }) {
                return lower
            }

            if lower.allSatisfy({ $0.isNumber }) {
                return lower
            }

            return lower.capitalized
        }

        guard !tokens.isEmpty else {
            return modelIdentifier
        }

        return tokens.joined(separator: " ")
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
