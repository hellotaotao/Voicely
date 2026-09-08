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

struct ModelLoadRequest: Equatable {
    let model: String
    let redownload: Bool
    let encoderComputeUnits: MLComputeUnits
    let decoderComputeUnits: MLComputeUnits

    func matchesLoadedConfiguration(_ other: Self) -> Bool {
        model == other.model && encoderComputeUnits == other.encoderComputeUnits
            && decoderComputeUnits == other.decoderComputeUnits
    }
}

struct ModelLoadResult {
    let whisperKit: WhisperKit
    let sourceKind: LocalModelSourceKind
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
    private var localModelPath = ""
    private var disabledModels: [String] = []
    private let specializationProgressRatio: Float = 0.7
    
    typealias LoadProgress = @MainActor @Sendable (ModelState, Float) -> Void
    typealias Loader = @MainActor (ModelLoadRequest, @escaping LoadProgress) async throws -> ModelLoadResult

    private let injectedLoader: Loader?
    private var activeLoad: (id: UUID, request: ModelLoadRequest, task: Task<Void, Never>)?
    private var loadedRequest: ModelLoadRequest?
    private var loadingRequests: [UUID: String] = [:]

    init(loader: Loader? = nil) {
        injectedLoader = loader
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

    nonisolated static func shouldPrewarmBeforeInitialLoad(redownload: Bool) -> Bool {
        false
    }

    nonisolated static func shouldRetryWithPrewarmAfterLoadFailure(alreadyPrewarmed: Bool) -> Bool {
        !alreadyPrewarmed
    }
    
    func loadModel(_ model: String, redownload: Bool = false) async {
        let request = ModelLoadRequest(
            model: model,
            redownload: redownload,
            encoderComputeUnits: encoderComputeUnits,
            decoderComputeUnits: decoderComputeUnits
        )
        if let activeLoad, activeLoad.request == request {
            await activeLoad.task.value
            return
        }

        activeLoad?.task.cancel()
        activeLoad = nil
        errorMessage = nil
        if !redownload, whisperKit != nil,
           let loadedRequest, request.matchesLoadedConfiguration(loadedRequest) {
            modelState = .loaded
            loadingProgressValue = 1
            return
        }

        whisperKit = nil
        currentLoadedModel = nil
        loadedRequest = nil
        modelState = .loading
        loadingProgressValue = 0
        let id = UUID()
        loadingRequests[id] = model
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.loadingRequests.removeValue(forKey: id) }
            let progress: LoadProgress = { [weak self] state, value in
                guard let self, self.activeLoad?.id == id else { return }
                self.modelState = state
                self.loadingProgressValue = value
            }
            do {
                let result: ModelLoadResult
                if let loader = self.injectedLoader {
                    result = try await loader(request, progress)
                } else {
                    result = try await self.performLoad(request, progress: progress)
                }
                try Task.checkCancellation()
                guard self.activeLoad?.id == id else { return }
                self.whisperKit = result.whisperKit
                self.currentLoadedModel = request.model
                self.loadedRequest = request
                if result.sourceKind != .bundled, !self.downloadedModels.contains(request.model) {
                    self.downloadedModels.append(request.model)
                }
                if !self.localModels.contains(request.model) {
                    self.localModels.append(request.model)
                }
                self.loadingProgressValue = 1
                self.modelState = .loaded
            } catch {
                guard self.activeLoad?.id == id else { return }
                self.errorMessage = error is CancellationError ? nil : "Failed to load model: \(error.localizedDescription)"
                self.modelState = .unloaded
                self.loadingProgressValue = 0
            }
            if self.activeLoad?.id == id {
                self.activeLoad = nil
            }
        }
        activeLoad = (id, request, task)
        await task.value
    }

    private func performLoad(_ request: ModelLoadRequest, progress: @escaping LoadProgress) async throws -> ModelLoadResult {
        // Retry within the owning request; recursively calling loadModel would join itself.
        var redownload = request.redownload
        while true {
            try Task.checkCancellation()
            let computeOptions = ModelComputeOptions(
                audioEncoderCompute: request.encoderComputeUnits,
                textDecoderCompute: request.decoderComputeUnits
            )
#if DEBUG
            let verbose = UserDefaults.standard.bool(forKey: "whisperVerboseLogging")
#else
            let verbose = false
#endif
            let kit = try await WhisperKit(WhisperKitConfig(
                computeOptions: computeOptions,
                verbose: verbose,
                logLevel: verbose ? .debug : .error,
                prewarm: false, load: false, download: false
            ))
            try Task.checkCancellation()
            let source = Self.preferredLocalModelSource(
                for: request.model,
                downloadedModels: downloadedModels,
                downloadedModelsRootPath: localModelPath,
                bundledModelsRoot: bundledModelsRoot
            )
            let sourceKind: LocalModelSourceKind
            if let source, !redownload {
                kit.modelFolder = source.url
                sourceKind = source.kind
            } else {
                progress(.downloading, 0)
                kit.modelFolder = try await WhisperKit.download(variant: request.model, from: repoName) { download in
                    let value = Float(download.fractionCompleted) * 0.7
                    Task { @MainActor in progress(.downloading, value) }
                }
                sourceKind = .downloaded
            }
            try Task.checkCancellation()
            progress(.loading, specializationProgressRatio)
            do {
                try await kit.loadModels()
                try Task.checkCancellation()
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                do {
                    try await prewarmModelsForCurrentDevice(kit, progress: progress)
                    try Task.checkCancellation()
                    progress(.loading, specializationProgressRatio + 0.9 * (1 - specializationProgressRatio))
                    try await kit.loadModels()
                    try Task.checkCancellation()
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    if !redownload {
                        redownload = true
                        continue
                    }
                    throw error
                }
            }
            return ModelLoadResult(whisperKit: kit, sourceKind: sourceKind)
        }
    }

    func deleteModel(_ model: String) {
        // Do not delete files while an active request may still be using them.
        guard !loadingRequests.values.contains(model) else { return }
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
                    loadedRequest = nil
                }
            }
            
            print("Deleted model: \(model)")
        } catch {
            print("Error deleting model: \(error)")
        }
    }
    
    private func updateProgressBar(targetProgress: Float, maxTime: TimeInterval, progress: @escaping LoadProgress) async {
        let initialProgress = loadingProgressValue
        let decayConstant = -log(1 - targetProgress) / Float(maxTime)
        let startTime = Date()
        
        while !Task.isCancelled {
            let elapsedTime = Date().timeIntervalSince(startTime)
            let decayFactor = exp(-decayConstant * Float(elapsedTime))
            let progressIncrement = (1 - initialProgress) * (1 - decayFactor)
            let currentProgress = initialProgress + progressIncrement
            
            progress(.prewarming, currentProgress)
            
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

    private func prewarmModelsForCurrentDevice(_ whisperKit: WhisperKit, progress: @escaping LoadProgress) async throws {
        progress(.prewarming, specializationProgressRatio)
        let progressTask = Task {
            await updateProgressBar(targetProgress: 0.9, maxTime: 240, progress: progress)
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
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !Self.isUnsupportedModel(trimmed)
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

    // MARK: - English-only model policy (see todo.md)

    /// User-facing suffix appended to English-only model names.
    nonisolated static let englishOnlySuffix = " (English Only)"

    /// Whether the model is English-only (the distil family and the .en suffix family).
    /// Uses contains(".en") rather than hasSuffix — quantized variants look like small.en_217MB.
    nonisolated static func isEnglishOnly(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("distil") || lower.contains(".en")
    }

    /// Whether the model should be hidden from the model list.
    ///
    /// - distil: large but English-only; a device that can run it is better served by multilingual large-v3.
    /// - medium.en: the largest English-only model, with a negligible English edge over multilingual — poor value.
    ///
    /// The only English-only models kept are tiny.en / base.en / small.en, which get tagged.
    nonisolated static func isUnsupportedModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("distil") || lower.contains("medium.en")
    }

    /// Display name with an English-only tag appended, for direct use in list UI.
    nonisolated static func displayNameWithLanguageTag(for model: String) -> String {
        let base = displayName(for: model)
        return isEnglishOnly(model) ? base + englishOnlySuffix : base
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
