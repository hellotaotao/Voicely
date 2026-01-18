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
}

@MainActor
class TranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var loadingProgress: Float = 0.0
    @Published var transcriptionProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    
    var modelManager: ModelManager?
    private var isWhisperLoaded = false
    
    init(modelManager: ModelManager? = nil) {
        self.modelManager = modelManager
        currentEngine = .notAvailable
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
        isTranscribing = true
        transcriptionProgress = 0.0
        let startTime = Date()
        defer { 
            isTranscribing = false
            transcriptionProgress = 0.0
        }
        
        guard isWhisperLoaded else {
            return nil
        }

        guard let text = await transcribeWithWhisper(
            filePath: filePath,
            progressCallback: progressCallback
        ) else {
            return nil
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return TranscriptionResult(text: text, duration: elapsed)
    }
    
    private func transcribeWithWhisper(filePath: String, progressCallback: @escaping (Float) -> Void) async -> String? {
        guard let modelManager = modelManager,
              let whisperKit = modelManager.getWhisperKit() else {
            print("WhisperKit not available")
            currentEngine = .notAvailable
            return nil
        }
        
        do {
            currentEngine = .whisperKit
            print("Using WhisperKit for transcription")
            
            guard let audioURL = CloudStorageManager.shared.getFileURL(for: filePath) else {
                print("Failed to get file URL for: \(filePath)")
                return "Audio file not found"
            }
            
            // Files are recorded locally to iCloud Documents, so they should exist immediately
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                print("Audio file not found at: \(audioURL.path)")
                return "Audio file not found"
            }
            
            // Start progress simulation
            let progressTask = Task {
                await simulateTranscriptionProgress(progressCallback: progressCallback)
            }
            
            // Use language from settings
            let selectedLanguageKey = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto"
            let languageCode: String?
            
            // Get custom prompt from settings
            let customPrompt = UserDefaults.standard.string(forKey: "transcriptionPrompt") ?? ""
            
            progressCallback(0.1)
            transcriptionProgress = 0.1
            
            let audioPath = audioURL.path
            
            if selectedLanguageKey == "auto" {
                // Use automatic language detection
                let languageDetection = try await whisperKit.detectLanguage(audioPath: audioPath)
                languageCode = languageDetection.language
                print("Auto-detected language: \(languageCode ?? "unknown")")
                progressCallback(0.2)
                transcriptionProgress = 0.2
            } else {
                languageCode = LanguageConstants.languages[selectedLanguageKey]
                print("Using selected language code: \(languageCode ?? "nil")")
                progressCallback(0.15)
                transcriptionProgress = 0.15
            }
            
            progressCallback(0.3)
            transcriptionProgress = 0.3
            
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
            )
            
            progressTask.cancel()
            progressCallback(1.0)
            transcriptionProgress = 1.0
            
            guard let result = transcriptionResults.first else {
                return "No transcription result"
            }
            
            return result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
        } catch {
            print("WhisperKit transcription error: \(error)")
            currentEngine = .notAvailable
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
    
    private func simulateTranscriptionProgress(progressCallback: @escaping (Float) -> Void) async {
        let startProgress: Float = 0.3
        let endProgress: Float = 0.9
        let duration: TimeInterval = 5.0 // Simulate 5 seconds of progress
        let steps = 50
        
        for i in 0...steps {
            let progress = startProgress + (endProgress - startProgress) * Float(i) / Float(steps)
            progressCallback(progress)
            transcriptionProgress = progress
            
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000 / Double(steps)))
            } catch {
                break
            }
        }
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
        
        print("Processing \(notes.count) pending transcriptions")
        for note in notes where note.pendingTranscription && !note.audioFilePath.isEmpty {
            // Avoid processing multiple transcriptions simultaneously, which might consume too many resources
            guard !isTranscribing else {
                print("Another transcription is in progress, waiting...")
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                continue
            }
            
            print("Transcribing note: \(note.title)")
            note.isTranscribing = true
            
            let transcription = await transcribeAudio(filePath: note.audioFilePath) { progress in
                Task { @MainActor in
                    note.transcriptionProgress = progress
                }
            }
            
            if let result = transcription {
                note.transcription = result.text
                note.lastTranscriptionDuration = result.duration
                note.pendingTranscription = false
            }
            
            note.isTranscribing = false
            note.transcriptionProgress = 0.0
            
            // Add a brief delay between transcriptions to avoid system overload
            try? await Task.sleep(nanoseconds: 200_000_000)
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
