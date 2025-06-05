//
//  TranscriptionService.swift
//  WhisperNotes
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

@MainActor
class TranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var loadingProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    
    private var modelManager: ModelManager?
    private var isWhisperLoaded = false
    
    init(modelManager: ModelManager? = nil) {
        self.modelManager = modelManager
        currentEngine = .notAvailable
    }
    
    func setModelManager(_ manager: ModelManager) {
        self.modelManager = manager
        updateEngineStatus()
    }
    
    func loadWhisperModel(modelName: String = "base") async -> Bool {
        guard let modelManager = modelManager else {
            print("ModelManager not available")
            return false
        }
        
        loadingProgress = 0.1
        modelManager.selectedModel = modelName
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
    
    func transcribeAudio(filePath: String) async -> String {
        isTranscribing = true
        defer { isTranscribing = false }
        
        if isWhisperLoaded {
            return await transcribeWithWhisper(filePath: filePath)
        } else {
            return "WhisperKit not loaded. Please load a model first."
        }
    }
    
    private func transcribeWithWhisper(filePath: String) async -> String {
        guard let modelManager = modelManager,
              let whisperKit = modelManager.getWhisperKit() else {
            print("WhisperKit not available")
            currentEngine = .notAvailable
            return "WhisperKit not loaded"
        }
        
        do {
            currentEngine = .whisperKit
            print("Using WhisperKit for transcription")
            let audioURL = URL(fileURLWithPath: filePath)
            
            guard FileManager.default.fileExists(atPath: filePath) else {
                return "Audio file not found"
            }
            
            // Use language from settings
            let selectedLanguageKey = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto"
            let languageCode: String?
            
            if selectedLanguageKey == "auto" {
                // Use automatic language detection
                let languageDetection = try await whisperKit.detectLanguage(audioPath: audioURL.path())
                languageCode = languageDetection.language
                print("Auto-detected language: \(languageCode ?? "unknown")")
            } else {
                languageCode = LanguageConstants.languages[selectedLanguageKey]
                print("Using selected language code: \(languageCode ?? "nil")")
            }
            
            let transcriptionResults = try await whisperKit.transcribe(
                audioPath: audioURL.path(),
                decodeOptions: DecodingOptions(
                    task: .transcribe,
                    language: languageCode,
                    temperature: 0.0,
                    temperatureFallbackCount: 5,
                    sampleLength: 224,
                    usePrefillPrompt: true,
                    usePrefillCache: true,
                    skipSpecialTokens: true,
                    withoutTimestamps: false,
                    wordTimestamps: false,
                    clipTimestamps: [0.0]
                )
            )
            
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
}
