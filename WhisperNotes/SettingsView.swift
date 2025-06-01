//
//  SettingsView.swift
//  WhisperNotes
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var transcriptionService = TranscriptionService()
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var isDownloading = false
    @State private var downloadProgress: Float = 0.0
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var alertTitle = ""
    
    private let modelSizes = [
        "openai/whisper-tiny": "39 MB",
        "openai/whisper-tiny.en": "39 MB",
        "openai/whisper-base": "142 MB",
        "openai/whisper-base.en": "142 MB",
        "openai/whisper-small": "488 MB",
        "openai/whisper-small.en": "488 MB"
    ]
    
    private let modelDescriptions = [
        "openai/whisper-tiny": "Fastest, lowest quality",
        "openai/whisper-tiny.en": "Fastest, English only",
        "openai/whisper-base": "Balanced speed and quality",
        "openai/whisper-base.en": "Balanced, English only",
        "openai/whisper-small": "Slower, higher quality",
        "openai/whisper-small.en": "Slower, higher quality, English only"
    ]
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Current Engine")
                        Spacer()
                        Text(transcriptionService.getCurrentEngineDescription())
                            .foregroundColor(.secondary)
                    }
                    
                    Text(transcriptionService.getEngineStatusMessage())
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Transcription Engine")
                }
                
                Section {
                    Picker("Select Model", selection: $settingsManager.selectedModel) {
                        ForEach(transcriptionService.getAvailableModels(), id: \.self) { model in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model)
                                    Text("\(modelDescriptions[model] ?? "") • \(modelSizes[model] ?? "")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if settingsManager.isModelDownloaded(model) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                }
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(NavigationLinkPickerStyle())
                    
                    Button(action: downloadModel) {
                        HStack {
                            if isDownloading {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Downloading...")
                            } else {
                                Image(systemName: settingsManager.isModelDownloaded(settingsManager.selectedModel) ? "arrow.clockwise.circle" : "arrow.down.circle")
                                Text(settingsManager.isModelDownloaded(settingsManager.selectedModel) ? "Reload Model" : "Download & Load Model")
                            }
                        }
                    }
                    .disabled(isDownloading)
                    
                    if isDownloading {
                        ProgressView(value: downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                    }
                    
                    if transcriptionService.isWhisperAvailable() {
                        Button(action: unloadModel) {
                            HStack {
                                Image(systemName: "trash.circle")
                                    .foregroundColor(.red)
                                Text("Unload Current Model")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                } header: {
                    Text("WhisperKit Models")
                } footer: {
                    Text("Larger models provide better accuracy but require more storage and processing time. English-only models are optimized for English transcription.")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model Sizes & Performance:")
                            .font(.headline)
                        
                        ForEach(Array(modelSizes.keys.sorted()), id: \.self) { model in
                            HStack {
                                Text(model.replacingOccurrences(of: "openai/whisper-", with: ""))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(modelSizes[model] ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Model Information")
                }
            }
            .navigationTitle("Settings")
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK") { }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private func downloadModel() {
        isDownloading = true
        downloadProgress = 0.0
        
        Task {
            let success = await transcriptionService.loadWhisperModel(modelName: settingsManager.selectedModel)
            
            await MainActor.run {
                isDownloading = false
                downloadProgress = 0.0
                
                if success {
                    settingsManager.addDownloadedModel(settingsManager.selectedModel)
                }
            }
        }
    }
    
    private func unloadModel() {
        transcriptionService.unloadWhisperModel()
        alertTitle = "Model Unloaded"
        alertMessage = "WhisperKit model has been unloaded. The app will use iOS Speech Framework for transcription."
        showAlert = true
    }
}

#Preview {
    SettingsView()
}
