//
//  TranscriptionService.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import WhisperKit
import AVFoundation

enum TranscriptionEngine {
    case whisperKit
    case notAvailable
}

struct TranscriptionResult {
    let text: String
    let duration: TimeInterval
    let modelIdentifier: String?
}

@MainActor
class TranscriptionService: ObservableObject {
    typealias TranscribeImpl = (String, @escaping (Float) -> Void) async -> String?

    @Published var isTranscribing = false
    @Published var loadingProgress: Float = 0.0
    @Published var transcriptionProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    
    var modelManager: ModelManager?
    private var isWhisperLoaded = false
    var transcribeImpl: TranscribeImpl = { _, _ in nil }
    
    // Cancellation support
    private var currentTranscriptionTask: Task<String?, Never>?
    private var cancelRequested = false
    private var lastCancellationHandled = false
    private var progressSmoothingTask: Task<Void, Never>?
    private var progressSmoothingTarget: Float = 0.0
    private var isProcessingPendingTranscriptions = false
    private var pendingTranscriptionQueue: [UUID: VoiceNote] = [:]
    private var pendingTranscriptionOrder: [UUID] = []
    
    init(modelManager: ModelManager? = nil) {
        self.modelManager = modelManager
        currentEngine = .notAvailable
        self.transcribeImpl = { [weak self] filePath, progressCallback in
            await self?.transcribeWithWhisper(
                filePath: filePath,
                progressCallback: progressCallback
            )
        }
    }
    
    func setModelManager(_ manager: ModelManager) {
        self.modelManager = manager
        updateEngineStatus()
    }
    
    func loadWhisperModel() async -> Bool {
        guard let modelManager = modelManager else {
            print("ModelManager not available")
            return false
        }

        let modelName = modelManager.selectedModel
        
        loadingProgress = 0.1
        await modelManager.loadModel(modelName)
        
        updateEngineStatus()
        loadingProgress = modelManager.loadingProgressValue
        
        let success = modelManager.isModelLoaded()
        if success {
            print("WhisperKit loaded successfully with model: \(modelName)")
        } else {
            print("Failed to load WhisperKit model: \(modelName)")
        }
        return success
    }
    
    private func updateEngineStatus() {
        if let modelManager = modelManager, modelManager.isModelLoaded() {
            isWhisperLoaded = true
            currentEngine = .whisperKit
        } else {
            isWhisperLoaded = false
            currentEngine = .notAvailable
        }
    }
    
    func transcribeAudio(
        filePath: String,
        progressCallback: @escaping (Float) -> Void = { _ in }
    ) async -> TranscriptionResult? {
        while isTranscribing {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        lastCancellationHandled = false
        if cancelRequested {
            cancelRequested = false
            lastCancellationHandled = true
            return nil
        }
        isTranscribing = true
        transcriptionProgress = 0.0
        resetProgressSmoothing()
        let startTime = Date()
        defer { 
            isTranscribing = false
            currentTranscriptionTask = nil
            resetProgressSmoothing()
            transcriptionProgress = 0.0
        }
        
        guard isWhisperLoaded else {
            return nil
        }

        let task = Task { [weak self] in
            await self?.transcribeImpl(filePath, progressCallback)
        }
        currentTranscriptionTask = task

        guard let text = await task.value else {
            return nil
        }

        if cancelRequested || Task.isCancelled {
            cancelRequested = false
            lastCancellationHandled = true
            return nil
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let modelIdentifier = modelManager?.currentModelIdentifier() ?? modelManager?.selectedModel
        return TranscriptionResult(
            text: text,
            duration: elapsed,
            modelIdentifier: modelIdentifier
        )
    }
    
    private func transcribeWithWhisper(filePath: String, progressCallback: @escaping (Float) -> Void) async -> String? {
        guard let modelManager = modelManager,
              let whisperKit = modelManager.getWhisperKit() else {
            print("WhisperKit not available")
            currentEngine = .notAvailable
            return nil
        }

        if cancelRequested || Task.isCancelled {
            return nil
        }
        
        do {
            currentEngine = .whisperKit
            print("Using WhisperKit for transcription")
            
            guard let audioURL = await CloudStorageManager.shared.prepareFileForReading(at: filePath) else {
                print("Failed to prepare audio file for transcription: \(filePath)")
                return nil
            }

#if DEBUG
            let windowSamples = whisperKit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
            let windowSeconds = Double(windowSamples) / Double(WhisperKit.sampleRate)
            print("WhisperKit windowSamples=\(windowSamples) (~\(String(format: "%.2f", windowSeconds))s) sampleRate=\(WhisperKit.sampleRate)")
#endif

            let updateProgressOnMain: (Float) -> Void = { [weak self] value in
                guard let self else { return }
                self.smoothProgress(to: value, progressCallback: progressCallback)
            }

            // Set up callbacks for real progress reporting
            whisperKit.transcriptionStateCallback = { state in
                Task { @MainActor in
                    switch state {
                    case .convertingAudio:
                        updateProgressOnMain(0.05)
                    case .transcribing:
                        updateProgressOnMain(0.1)
                    case .finished:
                        break
                    }
                }
            }
            defer {
                whisperKit.segmentDiscoveryCallback = nil
                whisperKit.transcriptionStateCallback = nil
            }
            
            // Use language from settings
            let selectedLanguageKey = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto"
            let languageCode: String?
            
            // Get custom prompt from settings
            let customPrompt = UserDefaults.standard.string(forKey: "transcriptionPrompt") ?? ""
            
            updateProgressOnMain(0.02)
            
            let audioPath = audioURL.path
            
            if selectedLanguageKey == "auto" {
                // Use automatic language detection
                let languageDetection = try await whisperKit.detectLanguage(audioPath: audioPath)
                languageCode = languageDetection.language
                print("Auto-detected language: \(languageCode ?? "unknown")")
                updateProgressOnMain(0.08)
            } else {
                languageCode = LanguageConstants.languages[selectedLanguageKey]
                print("Using selected language code: \(languageCode ?? "nil")")
                updateProgressOnMain(0.06)
            }
            updateProgressOnMain(0.1)
            
            // Create decode options and include custom prompt if available
            var decodeOptions = DecodingOptions(
                task: .transcribe,
                language: languageCode,
                temperature: 0.0,
                temperatureFallbackCount: 5,
                sampleLength: 224,
                usePrefillPrompt: true,
                usePrefillCache: false,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: false,
                clipTimestamps: [0.0]
            )
            
            // Add custom prompt if provided
            if !customPrompt.isEmpty {
                if let tokenizer = whisperKit.tokenizer {
                    let promptText = " " + customPrompt.trimmingCharacters(in: .whitespaces)
                    let encoded = tokenizer.encode(text: promptText)
                    decodeOptions.promptTokens = encoded
                    print("Using custom prompt: \(customPrompt)")
                }
            }
            
            let transcriptionResults = try await whisperKit.transcribe(
                audioPath: audioPath,
                decodeOptions: decodeOptions
            ) { [weak self] _ in
                guard let self else { return nil }
                if self.cancelRequested || Task.isCancelled {
                    return false
                }
                let fraction = Float(whisperKit.progress.fractionCompleted)
                Task { @MainActor in
                    updateProgressOnMain(fraction)
                }
                return nil
            }

            updateProgressOnMain(1.0)

            if cancelRequested || Task.isCancelled {
                return nil
            }
            
            guard let result = transcriptionResults.first else {
                return nil
            }
            
            return result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
        } catch {
            print("WhisperKit transcription error: \(error)")
            currentEngine = .notAvailable
            return nil
        }
    }
    
    // Cancel the current transcription
    func cancelTranscription() {
        print("Cancelling current transcription...")
        cancelRequested = true
        currentTranscriptionTask?.cancel()
        currentTranscriptionTask = nil
        resetProgressSmoothing()
        isTranscribing = false
        transcriptionProgress = 0.0
    }
    
    // Check if transcription was cancelled
    func wasTranscriptionCancelled() -> Bool {
        return lastCancellationHandled
    }
    
    func unloadWhisperModel() {
        if let modelManager = modelManager {
            modelManager.whisperKit = nil
            modelManager.modelState = .unloaded
        }
        isWhisperLoaded = false
        currentEngine = .notAvailable
        loadingProgress = 0.0
        print("WhisperKit model unloaded")
    }
    
    func getAvailableModels() -> [String] {
        return [
            "tiny",
            "base",
            "small"
        ]
    }
    
    func isWhisperAvailable() -> Bool {
        return isWhisperLoaded
    }
    
    func getCurrentEngineDescription() -> String {
        switch currentEngine {
        case .whisperKit:
            return "WhisperKit (Local AI)"
        case .notAvailable:
            return "No transcription available"
        }
    }
    
    func getEngineStatusMessage() -> String {
        switch currentEngine {
        case .whisperKit:
            return "Using WhisperKit for high-quality offline transcription"
        case .notAvailable:
            return "WhisperKit not loaded. Please load a model first."
        }
    }
    
    // New method: Process all pending transcription notes
    @MainActor
    func processPendingTranscriptions(notes: [VoiceNote]) async {
        guard isWhisperLoaded else { 
            print("Model not loaded, cannot process pending transcriptions")
            return 
        }

        enqueuePendingTranscriptions(notes)

        guard !isProcessingPendingTranscriptions else {
            print("Pending transcription processing already running")
            return
        }

        isProcessingPendingTranscriptions = true
        defer { isProcessingPendingTranscriptions = false }

        print("Processing \(pendingTranscriptionOrder.count) pending transcriptions")
        while let note = dequeueNextPendingTranscription() {
            while isTranscribing {
                print("Another transcription is in progress, waiting...")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            guard note.pendingTranscription && !note.audioFilePath.isEmpty else {
                continue
            }

            print("Transcribing note: \(note.title)")
            note.isTranscribing = true
            note.transcriptionProgress = 0.0
            
            let transcription = await transcribeAudio(filePath: note.audioFilePath) { progress in
                Task { @MainActor in
                    note.transcriptionProgress = progress
                }
            }
            
            if let result = transcription {
                note.transcription = result.text
                note.lastTranscriptionDuration = result.duration
                note.transcriptionModelIdentifier = result.modelIdentifier
                note.pendingTranscription = false
            } else if !wasTranscriptionCancelled() {
                note.pendingTranscription = true
            }
            
            note.isTranscribing = false
            note.transcriptionProgress = 0.0
            
            // Add a brief delay between transcriptions to avoid system overload
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}

private extension TranscriptionService {
    @MainActor
    func enqueuePendingTranscriptions(_ notes: [VoiceNote]) {
        for note in notes where note.pendingTranscription && !note.audioFilePath.isEmpty {
            pendingTranscriptionQueue[note.id] = note
            if !pendingTranscriptionOrder.contains(note.id) {
                pendingTranscriptionOrder.append(note.id)
            }
        }
    }

    @MainActor
    func dequeueNextPendingTranscription() -> VoiceNote? {
        while !pendingTranscriptionOrder.isEmpty {
            let noteID = pendingTranscriptionOrder.removeFirst()
            guard let note = pendingTranscriptionQueue.removeValue(forKey: noteID) else {
                continue
            }
            return note
        }
        return nil
    }

    @MainActor
    func resetProgressSmoothing() {
        progressSmoothingTask?.cancel()
        progressSmoothingTask = nil
        progressSmoothingTarget = 0.0
    }

    @MainActor
    func smoothProgress(to target: Float, progressCallback: @escaping (Float) -> Void) {
        let clamped = min(1.0, max(0.0, target))
        if clamped <= transcriptionProgress {
            return
        }

        progressSmoothingTarget = max(progressSmoothingTarget, clamped)

        if progressSmoothingTask != nil {
            return
        }

        progressSmoothingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let current = self.transcriptionProgress
                let target = self.progressSmoothingTarget
                if current >= target {
                    break
                }
                let delta = target - current
                let step = min(0.05, max(0.01, delta * 0.25))
                let next = min(target, current + step)
                self.transcriptionProgress = next
                progressCallback(next)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.progressSmoothingTask = nil
        }
    }
}

extension TranscriptionService {
    func annotatedText(for result: TranscriptionResult) -> String {
        annotatedText(text: result.text, duration: result.duration)
    }

    func annotatedText(text: String, duration: TimeInterval) -> String {
        let formatted = formatTranscriptionDuration(duration)
        let header = "Transcription completed in \(formatted)."
        if text.isEmpty {
            return header
        }
        return header + "\n\n" + text
    }

    func formatTranscriptionDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.2f seconds", duration)
        }

        if duration < 60 {
            return String(format: "%.2f seconds", duration)
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropTrailing

        if let formatted = formatter.string(from: duration), !formatted.isEmpty {
            return formatted
        }

        return String(format: "%.2f seconds", duration)
    }
}
