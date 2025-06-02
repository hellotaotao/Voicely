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
    
    private var whisperKit: WhisperKit?
    private var isWhisperLoaded = false
    
    init() {
        currentEngine = .notAvailable
    }
    
    func loadWhisperModel(modelName: String = "base") async -> Bool {
        loadingProgress = 0.1
        do {
            whisperKit = try await WhisperKit(
            )
            isWhisperLoaded = true
            currentEngine = .whisperKit
            loadingProgress = 1.0
            print("WhisperKit loaded successfully with model: \(modelName)")
            return true
        } catch {
            print("Failed to load WhisperKit: \(error)")
            isWhisperLoaded = false
            currentEngine = .notAvailable
            loadingProgress = 0.0
            return false
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
        guard let whisperKit = whisperKit else {
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
            
            let transcriptionResults = try await whisperKit.transcribe(
                audioPath: audioURL.path()
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
        whisperKit = nil
        isWhisperLoaded = false
        currentEngine = .notAvailable
        loadingProgress = 0.0
        print("WhisperKit model unloaded")
    }
    
    func getAvailableModels() -> [String] {
        return [
            "tiny",
            "tiny.en",
            "base",
            "base.en",
            "small",
            "small.en"
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
