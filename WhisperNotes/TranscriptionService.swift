//
//  TranscriptionService.swift
//  WhisperNotes
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import Speech

@MainActor
class TranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    func transcribeAudio(filePath: String) async -> String {
        // For now, we'll use iOS Speech framework as a fallback
        // TODO: Replace with whisper.cpp implementation
        return await transcribeWithSpeechFramework(filePath: filePath)
    }
    
    private func transcribeWithSpeechFramework(filePath: String) async -> String {
        guard let speechRecognizer = speechRecognizer,
              speechRecognizer.isAvailable else {
            return "Speech recognition not available"
        }
        
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
    
    // TODO: Implement whisper.cpp transcription
    // This method will be implemented once whisper.cpp is integrated
    private func transcribeWithWhisper(filePath: String) async -> String {
        // Placeholder for whisper.cpp implementation
        // Will need to:
        // 1. Load the whisper model
        // 2. Process the audio file
        // 3. Return transcribed text
        return "Whisper transcription not yet implemented"
    }
}