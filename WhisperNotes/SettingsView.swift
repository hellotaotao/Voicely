//
//  SettingsView.swift
//  WhisperNotes
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftUI
import WhisperKit
import CoreML

struct SettingsView: View {
    @EnvironmentObject var modelManager: ModelManager
    @State private var showingModelDeletion = false
    @State private var showComputeUnits = false
    
    var body: some View {
        NavigationView {
            List {
                Section("Model Management") {
                    modelStatusView
                    modelSelectorView
                    modelActionsView
                }
                
                Section("Compute Settings") {
                    computeUnitsView
                }
                
                Section("Info") {
                    appInfoView
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            await modelManager.fetchModels()
        }
    }
    
    private var modelStatusView: some View {
        HStack {
            Image(systemName: "circle.fill")
                .foregroundStyle(modelManager.modelState == .loaded ? .green : (modelManager.modelState == .unloaded ? .red : .yellow))
                .symbolEffect(.variableColor, isActive: modelManager.modelState != .loaded && modelManager.modelState != .unloaded)
            
            VStack(alignment: .leading) {
                Text("Model Status")
                    .font(.headline)
                Text(modelManager.modelState.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    private var modelSelectorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !modelManager.availableModels.isEmpty {
                HStack {
                    Text("Selected Model")
                        .font(.headline)
                    Spacer()
                    Picker("Model", selection: $modelManager.selectedModel) {
                        ForEach(modelManager.availableModels, id: \.self) { model in
                            HStack {
                                let isLocal = modelManager.localModels.contains(model)
                                let modelIcon = isLocal ? "checkmark.circle" : "arrow.down.circle.dotted"
                                Text("\(Image(systemName: modelIcon)) \(model.replacingOccurrences(of: "_", with: " ").capitalized)")
                                    .tag(model)
                            }
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .onChange(of: modelManager.selectedModel) { _, _ in
                        modelManager.modelState = .unloaded
                    }
                }
                
                if modelManager.loadingProgressValue > 0 && modelManager.loadingProgressValue < 1.0 {
                    VStack(spacing: 8) {
                        ProgressView(value: modelManager.loadingProgressValue, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle())
                        
                        HStack {
                            Text(String(format: "%.1f%%", modelManager.loadingProgressValue * 100))
                                .font(.caption)
                                .foregroundColor(.gray)
                            Spacer()
                            if modelManager.modelState == .downloading {
                                Text("Downloading...")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            } else if modelManager.modelState == .prewarming {
                                Text("Optimizing for device...")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }
            } else {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading available models...")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var modelActionsView: some View {
        VStack(spacing: 12) {
            if modelManager.modelState == .unloaded {
                Button {
                    Task {
                        await modelManager.loadModel(modelManager.selectedModel)
                    }
                } label: {
                    Text("Load Model")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            
            HStack {
                Button {
                    showingModelDeletion = true
                } label: {
                    Label("Delete Model", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .disabled(!modelManager.localModels.contains(modelManager.selectedModel))
                .confirmationDialog("Delete Model", isPresented: $showingModelDeletion) {
                    Button("Delete", role: .destructive) {
                        modelManager.deleteModel(modelManager.selectedModel)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to delete the model '\(modelManager.selectedModel)'?")
                }
                
                Spacer()
                
                Button {
                    if let url = URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml") {
                        #if os(iOS)
                        UIApplication.shared.open(url)
                        #elseif os(macOS)
                        NSWorkspace.shared.open(url)
                        #endif
                    }
                } label: {
                    Label("View Models", systemImage: "link.circle")
                }
            }
        }
    }
    
    private var computeUnitsView: some View {
        DisclosureGroup(isExpanded: $showComputeUnits) {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Audio Encoder")
                            .font(.subheadline)
                        Text("Processes audio input")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("Audio Encoder", selection: $modelManager.encoderComputeUnits) {
                        Text("CPU").tag(MLComputeUnits.cpuOnly)
                        Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                        Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 200)
                }
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("Text Decoder")
                            .font(.subheadline)
                        Text("Generates transcription text")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("Text Decoder", selection: $modelManager.decoderComputeUnits) {
                        Text("CPU").tag(MLComputeUnits.cpuOnly)
                        Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                        Text("Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 200)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Compute Units", systemImage: "cpu")
                .font(.headline)
        }
    }
    
    private var appInfoView: some View {
        VStack(alignment: .leading, spacing: 8) {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
            
            HStack {
                Text("App Version")
                Spacer()
                Text("\(version) (\(build))")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Device")
                Spacer()
                Text(WhisperKit.deviceName())
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("WhisperKit Version")
                Spacer()
                Text("Latest")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}

#Preview {
    SettingsView()
}
