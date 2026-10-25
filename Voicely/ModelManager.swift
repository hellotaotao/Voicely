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
    case prewarming
    case loaded

    var description: String {
        switch self {
        case .unloaded:
            return "Not Loaded"
        case .loading:
            return "Loading..."
        case .prewarming:
            return "Optimizing..."
        case .loaded:
            return "Ready"
        }
    }
}

/// Loads the Qwen3-ASR model that ships inside the app and publishes its
/// state to the UI. There is one model per device, picked by `Qwen3Backend`.
@MainActor
class ModelManager: ObservableObject {
    typealias LoadProgress = @MainActor @Sendable (ModelState, Float) -> Void
    /// Loads the model, reporting progress as it goes.
    typealias Loader = @MainActor (_ progress: @escaping LoadProgress) async throws -> Void

    @Published var modelState: ModelState = .unloaded {
        didSet {
            if modelState == .loaded && oldValue != .loaded {
                NotificationCenter.default.post(name: .modelLoadedNotification, object: nil)
            }
        }
    }
    @Published var loadingProgressValue: Float = 0.0
    @Published var errorMessage: String?

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
    }

    /// Loads the model into memory. Concurrent callers share one load.
    func loadModel() async {
        if let activeLoad {
            await activeLoad.value
            return
        }
        guard modelState != .loaded else { return }

        errorMessage = nil
        modelState = .loading
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
                    try await injectedLoader(progress)
                } else {
                    try await self.store.prepareModel { fraction, status in
                        let state: ModelState = status.localizedCaseInsensitiveContains("warming") ? .prewarming : .loading
                        Task { @MainActor in progress(state, Float(fraction)) }
                    }
                }
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

    func currentModelIdentifier() -> String? {
        isModelLoaded() ? selectedModel : nil
    }

    func isModelLoaded() -> Bool {
        modelState == .loaded
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

// MARK: - Retired model files

enum RetiredModelFiles {
    /// Models earlier versions downloaded and nothing reads any more: Whisper's
    /// under Documents/huggingface (0.2–1.6 GB each) and Qwen3's under
    /// Application Support/Qwen3ASR (about 1 GB), now that the model ships in
    /// the app.
    nonisolated static func remove(
        documentsDirectory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        fileManager: FileManager = .default
    ) {
        let retired = [
            documentsDirectory?.appendingPathComponent("huggingface", isDirectory: true),
            applicationSupportDirectory?.appendingPathComponent("Qwen3ASR", isDirectory: true),
        ]
        for directory in retired.compactMap({ $0 }) where fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
    }
}

extension Notification.Name {
    static let modelLoadedNotification = Notification.Name("ModelLoadedNotification")
}
