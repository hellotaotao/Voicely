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

@MainActor
class ModelManager: ObservableObject {
    // MARK: - Curated catalog & device defaults
    //
    // Performance tiers shown to users, low -> high: Lite (Base) / Standard (Small) / Pro (Turbo).
    // Per WhisperKit's device table, large-v3 turbo needs A14+ (iPhone 12 and up) / Apple Silicon.
    // Defaults: strong devices (A16+ iPhone / Mac) -> Pro; everything else -> Standard (Small).
    // Lite (Base) is always selectable but is never an automatic default.

    enum PerformanceTier: Int, CaseIterable {
        case lite = 1
        case standard = 2
        case pro = 3
        case proFast = 4

        var label: String {
            switch self {
            case .lite:     return "LITE"
            case .standard: return "STANDARD"
            case .pro:      return "PRO"
            case .proFast:  return "PRO FAST"
            }
        }

        /// Filled dots in the performance indicator (max 3). Pro and Pro Fast are both
        /// top-tier turbo builds, so both fill all three.
        var filledDots: Int {
            switch self {
            case .lite:          return 1
            case .standard:      return 2
            case .pro, .proFast: return 3
            }
        }

        /// Title-case name for inline text, e.g. "Standard" (vs. the uppercase badge `label`).
        var displayName: String {
            switch self {
            case .lite:     return "Lite"
            case .standard: return "Standard"
            case .pro:      return "Pro"
            case .proFast:  return "Pro Fast"
            }
        }
    }

    struct CuratedModel: Sendable {
        let identifier: String
        let tier: PerformanceTier
        let isEnglishOnly: Bool
        /// Short, product-facing name for compact UI (e.g. "Large v3 Turbo"),
        /// distinct from the mechanical `displayName(for:)` derived from the identifier.
        let displayName: String
        /// Approximate download size, measured from the model's HuggingFace folder.
        let sizeLabel: String
        let suitability: String
    }

    // The large-v3-v20240930 turbo builds were retired in 2026-07: on Apple
    // Silicon Macs every slice blank-decodes (0 segments in well under a second).
    // A/B testing ruled out quantization — the full-precision 1.62 GB original
    // fails the same way while the previous-generation 954 MB build transcribes
    // the same file perfectly. With Qwen3-ASR now the primary engine, WhisperKit
    // serves as the fallback, so the large tier was dropped rather than kept
    // alive with a platform special case.
    nonisolated static let curatedModels: [CuratedModel] = [
        CuratedModel(identifier: "openai_whisper-small",
                     tier: .standard, isEnglishOnly: false, displayName: "Small",
                     sizeLabel: "486 MB",
                     suitability: "Recommended for most devices"),
        CuratedModel(identifier: "openai_whisper-base",
                     tier: .lite, isEnglishOnly: false, displayName: "Base",
                     sizeLabel: "147 MB",
                     suitability: "For older devices or saving space"),
        CuratedModel(identifier: "openai_whisper-small.en_217MB",
                     tier: .standard, isEnglishOnly: true, displayName: "Small",
                     sizeLabel: "218 MB",
                     suitability: "English audio only / smaller download"),
    ]

    nonisolated static var curatedIdentifiers: Set<String> {
        Set(curatedModels.map(\.identifier))
    }

    nonisolated static func curatedModel(for identifier: String) -> CuratedModel? {
        curatedModels.first { $0.identifier == identifier }
    }

    private static let standardDefaultIdentifier = "openai_whisper-small"

    /// Models that shipped previously but are no longer offered. A saved
    /// selection pointing at one is migrated on launch instead of being left
    /// active — see `curatedModels` for why these were pulled.
    nonisolated static let retiredIdentifiers: Set<String> = [
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-large-v3-v20240930_turbo_632MB",
    ]

    nonisolated static func isRetiredModel(_ identifier: String) -> Bool {
        retiredIdentifiers.contains(identifier)
    }

    /// The model an install should actually use, given whatever is in
    /// UserDefaults: empty, missing, or retired selections fall back to the
    /// platform default; anything else is the user's own choice and is kept.
    nonisolated static func migratedSelection(saved: String?) -> String {
        guard let saved, !saved.isEmpty, !isRetiredModel(saved) else {
            return platformDefaultModel
        }
        return saved
    }

    nonisolated static var platformDefaultModel: String {
        // Every supported device runs Standard (Small) now that the large tier
        // is gone; Qwen3-ASR covers high-end quality on MLX-capable hardware.
        standardDefaultIdentifier
    }

    static func isRecommendedForCurrentDevice(_ model: String) -> Bool {
        model == platformDefaultModel
    }

    nonisolated private static func numericGeneration(from deviceIdentifier: String, prefix: String) -> Int? {
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
    
    init() {
        // Preserve the user's own choice; fall back to the platform default when
        // nothing is saved, the value is empty, or it names a retired model.
        let savedModel = UserDefaults.standard.string(forKey: .selectedModelKey)
        let resolved = Self.migratedSelection(saved: savedModel)
        selectedModel = resolved

        if savedModel != resolved {
            UserDefaults.standard.set(resolved, forKey: .selectedModelKey)
            if let savedModel, Self.isRetiredModel(savedModel) {
                print("Model '\(savedModel)' is no longer offered. Switched to: \(resolved)")
            } else {
                print("No usable saved model. Using default: \(resolved)")
            }
        } else {
            print("Loaded saved model selection from UserDefaults: \(resolved)")
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
            // recommendedRemoteModels only gates *availability*: a curated model is
            // hidden only when WhisperKit explicitly disables it for this device. It is
            // NOT the visibility source — WhisperKit may recommend a different variant
            // name than the one we ship (e.g. it lists `small.en` while we curate the
            // smaller `small.en_217MB`), which previously hid that model entirely.
            disabledModels = remoteModelSupport.disabled.filter { Self.curatedIdentifiers.contains($0) }
        } else {
            disabledModels = []
        }

        // Surface the full curated catalog this device can run, in picker order:
        // multilingual tiers ascending (Lite → Standard → Pro), English-only last.
        let displayOrder = Self.curatedModels.sorted { lhs, rhs in
            if lhs.isEnglishOnly != rhs.isEnglishOnly { return !lhs.isEnglishOnly }
            return lhs.tier.rawValue < rhs.tier.rawValue
        }
        for model in displayOrder.map(\.identifier) where !disabledModels.contains(model) {
            addModel(model)
        }

        // Keep any locally downloaded curated model and the active selection visible.
        for model in localModels where Self.curatedIdentifiers.contains(model) {
            addModel(model)
        }
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

                modelState = .loading
                do {
                    try await whisperKit.loadModels()
                } catch {
                    print("Loading failed before prewarm fallback: \(error.localizedDescription)")

                    guard Self.shouldRetryWithPrewarmAfterLoadFailure(alreadyPrewarmed: false) else {
                        throw error
                    }

                    do {
                        print("Retrying once with prewarm before loading...")
                        try await prewarmModelsForCurrentDevice(whisperKit)
                        loadingProgressValue = specializationProgressRatio + 0.9 * (1 - specializationProgressRatio)
                        modelState = .loading
                        try await whisperKit.loadModels()
                    } catch {
                        if !redownload {
                            print("Loading failed after prewarm fallback. Retrying with redownload...")
                            await loadModel(model, redownload: true)
                            return
                        }
                        throw error
                    }
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

    /// Reclaims disk space from models that were retired (see `retiredIdentifiers`).
    /// The selection migration in `init` only rewrites UserDefaults; the retired
    /// CoreML weights (hundreds of MB each) stay on disk, and the picker's curated
    /// allow-list never surfaces them for a manual delete — so nothing else can
    /// remove them. Idempotent: only acts when a retired folder is actually present.
    func purgeRetiredModelsFromDisk() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let root = documents.appendingPathComponent(modelStorage)
        for identifier in Self.retiredIdentifiers {
            let folder = root.appendingPathComponent(identifier)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                downloadedModels.removeAll { $0 == identifier }
                localModels.removeAll { $0 == identifier }
                print("🗑️ Removed retired model from disk: \(identifier)")
            } catch {
                print("⚠️ Failed to remove retired model \(identifier): \(error.localizedDescription)")
            }
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
        // Empty guard only. The curated allow-list is enforced at the call sites in
        // fetchModels; local/selected entries are always allowed through.
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // Qwen3 (MLX) identifiers aren't whisper-style; give them their own name.
        if modelIdentifier == Qwen3ASRDefaults.modelId || modelIdentifier.contains("Qwen3-ASR") {
            return Qwen3ASRDefaults.modelDisplayName
        }
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

    /// Display name with an English-only tag appended, for direct use in list UI.
    nonisolated static func displayNameWithLanguageTag(for model: String) -> String {
        let base = displayName(for: model)
        return isEnglishOnly(model) ? base + englishOnlySuffix : base
    }

    /// Compact picker label: the performance tier with the model's short name in
    /// parens, e.g. "Standard (Small)" or "Standard (Small, English)". Non-curated
    /// models (e.g. a legacy selection) fall back to the plain tagged display name.
    nonisolated static func pickerTitle(for model: String) -> String {
        guard let curated = curatedModel(for: model) else {
            return displayNameWithLanguageTag(for: model)
        }
        let name = curated.isEnglishOnly ? "\(curated.displayName), English" : curated.displayName
        return "\(curated.tier.displayName) (\(name))"
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
