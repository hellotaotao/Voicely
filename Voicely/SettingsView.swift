//
//  SettingsView.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftUI
import WhisperKit
import CoreML

// Language constants similar to WhisperKit demo
struct LanguageConstants {
    static let languages: [String: String] = [
        "auto": "auto",
        "english": "en",
        "chinese": "zh",
        "german": "de",
        "spanish": "es",
        "russian": "ru",
        "korean": "ko",
        "french": "fr",
        "japanese": "ja",
        "portuguese": "pt",
        "turkish": "tr",
        "polish": "pl",
        "catalan": "ca",
        "dutch": "nl",
        "arabic": "ar",
        "swedish": "sv",
        "italian": "it",
        "indonesian": "id",
        "hindi": "hi",
        "finnish": "fi",
        "vietnamese": "vi",
        "hebrew": "he",
        "ukrainian": "uk",
        "greek": "el",
        "malay": "ms",
        "czech": "cs",
        "romanian": "ro",
        "danish": "da",
        "hungarian": "hu",
        "tamil": "ta",
        "norwegian": "no",
        "thai": "th",
        "urdu": "ur",
        "croatian": "hr",
        "bulgarian": "bg",
        "lithuanian": "lt",
        "latin": "la",
        "maori": "mi",
        "malayalam": "ml",
        "welsh": "cy",
        "slovak": "sk",
        "telugu": "te",
        "persian": "fa",
        "latvian": "lv",
        "bengali": "bn",
        "serbian": "sr",
        "azerbaijani": "az",
        "slovenian": "sl",
        "kannada": "kn",
        "estonian": "et",
        "macedonian": "mk",
        "breton": "br",
        "basque": "eu",
        "icelandic": "is",
        "armenian": "hy",
        "nepali": "ne",
        "mongolian": "mn",
        "bosnian": "bs",
        "kazakh": "kk",
        "albanian": "sq",
        "swahili": "sw",
        "galician": "gl",
        "marathi": "mr",
        "punjabi": "pa",
        "sinhala": "si",
        "khmer": "km",
        "shona": "sn",
        "yoruba": "yo",
        "somali": "so",
        "afrikaans": "af",
        "occitan": "oc",
        "georgian": "ka",
        "belarusian": "be",
        "tajik": "tg",
        "sindhi": "sd",
        "gujarati": "gu",
        "amharic": "am",
        "yiddish": "yi",
        "lao": "lo",
        "uzbek": "uz",
        "faroese": "fo",
        "haitian creole": "ht",
        "pashto": "ps",
        "turkmen": "tk",
        "nynorsk": "nn",
        "maltese": "mt",
        "sanskrit": "sa",
        "luxembourgish": "lb",
        "myanmar": "my",
        "tibetan": "bo",
        "tagalog": "tl",
        "malagasy": "mg",
        "assamese": "as",
        "tatar": "tt",
        "hawaiian": "haw",
        "lingala": "ln",
        "hausa": "ha",
        "bashkir": "ba",
        "javanese": "jw",
        "sundanese": "su"
    ]
    
    static let defaultLanguageCode = "en"
    
    static var availableLanguages: [String] {
        // Auto detect first, then most common languages, then the rest alphabetically
        let topLanguages = [
            "auto",
            "english",
            "chinese", 
            "spanish",
            "french",
            "german",
            "japanese",
            "korean",
            "portuguese",
            "russian",
            "arabic",
            "hindi",
            "italian"
        ]
        
        let remainingLanguages = languages.keys.filter { !topLanguages.contains($0) }.sorted()
        
        return topLanguages + remainingLanguages
    }
}

struct SettingsView: View {
    @EnvironmentObject var modelManager: ModelManager
    @State private var showingModelDeletion = false
    @State private var showComputeUnits = false
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"
    @AppStorage("transcriptionPrompt") private var transcriptionPrompt: String = ""
    @AppStorage("preloadModelOnStartup") private var preloadModelOnStartup: Bool = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("Model Management") {
                    modelStatusView
                    modelSelectorView
                    modelActionsView
                }
                
                Section("Language Settings") {
                    languageSelectorView
                }
                
                Section("Transcription Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Prompt")
                            .font(.headline)
                        Text("Provide context to help with transcription accuracy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TextField("Optional prompt for transcription", text: $transcriptionPrompt)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Performance Settings") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preload Model on Startup")
                                .font(.headline)
                            Text("Load model when app starts for instant recording (slower startup)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $preloadModelOnStartup)
                    }
                    .padding(.vertical, 4)
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
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
                    Picker("", selection: $modelManager.selectedModel) {
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
    
    private var languageSelectorView: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Speech Language")
                    .font(.headline)
                Text("Select the expected speech language")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $selectedLanguage) {
                ForEach(LanguageConstants.availableLanguages, id: \.self) { language in
                    Text(language == "auto" ? "Auto Detect" : language.capitalized).tag(language)
                }
            }
            .pickerStyle(MenuPickerStyle())
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
