//
//  ModelManager.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import SwiftUI

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

/// Downloads, loads and deletes the Qwen3-ASR model and publishes its state to
/// the UI. There is one model per device, picked by `Qwen3Backend`.
@MainActor
class ModelManager: ObservableObject {
    typealias LoadProgress = @MainActor @Sendable (ModelState, Float) -> Void
    /// Loads the model, downloading it first when `allowDownload` is set.
    typealias Loader = @MainActor (_ allowDownload: Bool, _ progress: @escaping LoadProgress) async throws -> Void

    @Published var modelState: ModelState = .unloaded {
        didSet {
            if modelState == .loaded && oldValue != .loaded {
                NotificationCenter.default.post(name: .modelLoadedNotification, object: nil)
            }
        }
    }
    @Published var loadingProgressValue: Float = 0.0
    @Published var errorMessage: String?
    @Published private(set) var isModelDownloaded: Bool
    @Published private(set) var isDeletingModel = false

    let backend: Qwen3Backend
    /// The model this device runs. Kept as a property because notes record it.
    var selectedModel: String { backend.modelIdentifier }

    /// MLX decodes on the GPU, which iOS denies to a backgrounded app.
    var loadedModelSupportsBackgroundTranscription: Bool { backend == .coreML }

    private let store: Qwen3ASRModelStore
    private let injectedLoader: Loader?
    private var activeLoad: Task<Void, Never>?

    init(
        backend: Qwen3Backend = .current,
        store: Qwen3ASRModelStore = .shared,
        loader: Loader? = nil
    ) {
        self.backend = backend
        self.store = store
        injectedLoader = loader
        isModelDownloaded = loader == nil && Qwen3ASRModelStore.isModelDownloaded(backend: backend)
    }

    /// Loads the model into memory, downloading it first if it isn't on disk.
    /// Concurrent callers share one load.
    func loadModel() async {
        if let activeLoad {
            await activeLoad.value
            return
        }
        guard !isDeletingModel else {
            errorMessage = "Cannot load the model while its files are being deleted. Please try again when deletion finishes."
            return
        }
        guard modelState != .loaded else { return }

        errorMessage = nil
        modelState = isModelDownloaded ? .loading : .downloading
        loadingProgressValue = 0
        let task = Task { [weak self] in
            guard let self else { return }
            let progress: LoadProgress = { [weak self] state, value in
                guard let self, self.modelState != .loaded else { return }
                self.modelState = state
                self.loadingProgressValue = value
            }
            do {
                if let injectedLoader = self.injectedLoader {
                    try await injectedLoader(true, progress)
                } else {
                    try await self.performLoad(progress: progress)
                }
                self.isModelDownloaded = true
                self.loadingProgressValue = 1
                self.modelState = .loaded
            } catch {
                self.errorMessage = error is CancellationError
                    ? nil : "Failed to load model: \(error.localizedDescription)"
                self.modelState = .unloaded
                self.loadingProgressValue = 0
            }
            self.activeLoad = nil
        }
        activeLoad = task
        await task.value
    }

    private func performLoad(progress: @escaping LoadProgress) async throws {
        let wasDownloaded = isModelDownloaded
        let report: Qwen3ASRModelStore.ProgressHandler = { fraction, status in
            let state = Self.modelState(forLoadStatus: status, wasDownloaded: wasDownloaded)
            Task { @MainActor in progress(state, Float(fraction)) }
        }
        if wasDownloaded {
            // A model already on disk must load without the network, or the
            // app could not transcribe offline.
            do {
                try await store.prepareDownloadedModel(progressHandler: report)
                return
            } catch {
                print("⚠️ Downloaded model failed to load, fetching it again: \(error)")
            }
        }
        try await store.downloadAndLoadModel(progressHandler: report)
    }

    /// The package reports progress as a fraction plus a free-form status line.
    nonisolated static func modelState(forLoadStatus status: String, wasDownloaded: Bool) -> ModelState {
        if status.localizedCaseInsensitiveContains("warming") { return .prewarming }
        if !wasDownloaded, status.localizedCaseInsensitiveContains("download") { return .downloading }
        return wasDownloaded ? .loading : .downloading
    }

    /// Frees the model's memory; the files stay on disk.
    func unloadModel() async {
        guard activeLoad == nil else { return }
        await store.unloadModel()
        modelState = .unloaded
        loadingProgressValue = 0
    }

    func deleteModel() async {
        guard activeLoad == nil else {
            errorMessage = "The model is still loading. Please try deleting it again when loading finishes."
            return
        }
        guard !isDeletingModel, isModelDownloaded else { return }

        errorMessage = nil
        isDeletingModel = true
        defer { isDeletingModel = false }
        do {
            try await store.deleteDownloadedModel()
            isModelDownloaded = false
            modelState = .unloaded
            loadingProgressValue = 0
        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
        }
    }

    func currentModelIdentifier() -> String? {
        isModelLoaded() ? selectedModel : nil
    }

    func isModelLoaded() -> Bool {
        !isDeletingModel && modelState == .loaded
    }

    /// Display name for a model identifier stored on a note. Notes transcribed
    /// before the switch to Qwen3 still carry Whisper identifiers.
    nonisolated static func displayName(for modelIdentifier: String) -> String {
        if modelIdentifier.hasPrefix("qwen3-asr") {
            return Qwen3ASRDefaults.modelDisplayName
        }
        let normalized = modelIdentifier
            .replacingOccurrences(of: "openai_whisper-", with: "Whisper-")
            .replacingOccurrences(of: "_", with: "-")

        let tokens = normalized.split(separator: "-").map { token -> String in
            let lower = token.lowercased()
            if lower.hasPrefix("v") && lower.dropFirst().allSatisfy({ $0.isNumber }) {
                return lower
            }
            // Sizes such as "954MB" read wrong once capitalized.
            if lower.first?.isNumber == true {
                return String(token)
            }
            return lower.capitalized
        }

        guard !tokens.isEmpty else {
            return modelIdentifier
        }
        return tokens.joined(separator: " ")
    }
}

// MARK: - Retired Whisper models

enum RetiredWhisperModels {
    /// Whisper models downloaded by earlier versions, roughly 0.2–1.6 GB each.
    /// Nothing reads them any more.
    nonisolated static func removeDownloadedFiles(
        documentsDirectory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
        fileManager: FileManager = .default
    ) {
        // WhisperKit kept its models and tokenizers under Documents/huggingface;
        // Qwen3 lives in Application Support.
        guard let root = documentsDirectory?.appendingPathComponent("huggingface", isDirectory: true),
              fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }
}

extension Notification.Name {
    static let modelLoadedNotification = Notification.Name("ModelLoadedNotification")
}
