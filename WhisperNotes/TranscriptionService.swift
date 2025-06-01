//
//  TranscriptionService.swift
//  WhisperNotes
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import Speech
import WhisperKit
import AVFoundation

enum TranscriptionEngine {
    case whisperKit
    case speechFramework
    case notAvailable
}

@MainActor
class TranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var loadingProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    
    private var whisperKit: WhisperKit?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var isWhisperLoaded = false
    
    init() {
        Task {
            await loadWhisperModel()
        }
    }
    
    private func loadWhisperModel() async {
        loadingProgress = 0.1
        do {
            whisperKit = try await WhisperKit()
            isWhisperLoaded = true
            currentEngine = .whisperKit
            loadingProgress = 1.0
            print("WhisperKit loaded successfully")
        } catch {
            print("Failed to load WhisperKit: \(error)")
            isWhisperLoaded = false
            currentEngine = speechRecognizer?.isAvailable == true ? .speechFramework : .notAvailable
        }
    }
    
    func transcribeAudio(filePath: String) async -> String {
        isTranscribing = true
        defer { isTranscribing = false }
        
        if isWhisperLoaded {
            return await transcribeWithWhisper(filePath: filePath)
        } else {
            return await transcribeWithSpeechFramework(filePath: filePath)
        }
    }
    
    private func transcribeWithWhisper(filePath: String) async -> String {
        guard let whisperKit = whisperKit else {
            print("WhisperKit not available, falling back to Speech Framework")
            currentEngine = .speechFramework
            return await transcribeWithSpeechFramework(filePath: filePath)
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
            print("WhisperKit transcription error: \(error), falling back to Speech Framework")
            currentEngine = .speechFramework
            return await transcribeWithSpeechFramework(filePath: filePath)
        }
    }
    
    private func transcribeWithSpeechFramework(filePath: String) async -> String {
        guard let speechRecognizer = speechRecognizer,
              speechRecognizer.isAvailable else {
            currentEngine = .notAvailable
            return "Speech recognition not available"
        }
        
        currentEngine = .speechFramework
        print("Using iOS Speech Framework for transcription")
        
        return await withCheckedContinuation { continuation in
            let url = URL(fileURLWithPath: filePath)
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            
            speechRecognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    print("Speech recognition error: \(error)")
                    continuation.resume(returning: "Transcription failed: \(error.localizedDescription)")
                    return
                }
                
                if let result = result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
    
    func isWhisperAvailable() -> Bool {
        return isWhisperLoaded
    }
    
    func getCurrentEngineDescription() -> String {
        switch currentEngine {
        case .whisperKit:
            return "WhisperKit (Local AI)"
        case .speechFramework:
            return "iOS Speech Framework"
        case .notAvailable:
            return "No transcription available"
        }
    }
    
    func getEngineStatusMessage() -> String {
        switch currentEngine {
        case .whisperKit:
            return "Using WhisperKit for high-quality offline transcription"
        case .speechFramework:
            return "Using iOS Speech Framework (requires internet connection)"
        case .notAvailable:
            return "Speech recognition not available on this device"
        }
    }
}
