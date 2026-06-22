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
    @State private var computeUnitsChanged = false
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"
    @AppStorage("transcriptionPrompt") private var transcriptionPrompt: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    modelHeroCard

                    settingsSection(
                        title: "Language",
                        identifier: AccessibilityIdentifiers.Settings.languageSection
                    ) {
                        languageRow
                    }

                    settingsSection(
                        title: "Transcription",
                        identifier: AccessibilityIdentifiers.Settings.transcriptionSection
                    ) {
                        promptBlock
                    }

                    settingsSection(
                        title: "Compute",
                        identifier: AccessibilityIdentifiers.Settings.computeSection
                    ) {
                        encoderRow
                        Divider().background(VoicelyTheme.hairline)
                        decoderRow
                        if computeUnitsChanged {
                            Divider().background(VoicelyTheme.hairline)
                            reloadButton
                        }
                        Divider().background(VoicelyTheme.hairline)
                        NavigationLink {
                            BenchmarkView().environmentObject(modelManager)
                        } label: {
                            navRow(icon: "timer", title: "Run Benchmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityIdentifiers.Settings.runBenchmarkLink)
                    }

                    privacyNoticeCard

                    settingsSection(
                        title: "About",
                        identifier: AccessibilityIdentifiers.Settings.aboutSection
                    ) {
                        appInfoContent
                    }

                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(VoicelyTheme.groupedBackground.ignoresSafeArea())
            .accessibilityIdentifier(AccessibilityIdentifiers.Settings.screen)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier(AccessibilityIdentifiers.Settings.doneButton)
                }
            }
        }
        .tint(VoicelyTheme.accent)
        .task {
            await modelManager.fetchModels()
        }
    }

    // MARK: - Section shell

    private func settingsSection<Content: View>(
        title: String,
        identifier: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderLabel(text: title)
                .padding(.leading, 4)
            SurfaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Model hero

    private var modelHeroCard: some View {
        SurfaceCard(padding: 18, tint: VoicelyTheme.accent) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Active Model")
                            .font(.caption.weight(.semibold))
                            .tracking(0.9)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(ModelManager.displayNameWithLanguageTag(for: modelManager.selectedModel))
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            modelStateBadge
                            PillBadge(text: "On-device", systemImage: "iphone", variant: .accent)
                        }
                    }
                    Spacer(minLength: 0)
                    ZStack {
                        Circle()
                            .fill(VoicelyTheme.accentTint(0.16))
                            .frame(width: 48, height: 48)
                        Image(systemName: "waveform")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VoicelyTheme.accent)
                    }
                }

                if let errorMessage = modelManager.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous))
                }

                if modelManager.loadingProgressValue > 0 && modelManager.loadingProgressValue < 1.0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: modelManager.loadingProgressValue, total: 1.0)
                            .tint(VoicelyTheme.accent)
                        HStack {
                            Text(progressStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", modelManager.loadingProgressValue * 100))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                modelPicker
                modelActionButtons

                NavigationLink {
                    WhisperKitModelsView()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                        Text("Browse all models")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VoicelyTheme.accent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VoicelyTheme.accentTint(0.10), in: RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIdentifiers.Settings.browseModelsLink)
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Settings.activeModelCard)
    }

    private var modelStateBadge: some View {
        switch modelManager.modelState {
        case .loaded:
            if modelManager.isSelectedModelBuiltIn() {
                return PillBadge(text: "Built in", systemImage: "shippingbox.fill", variant: .success)
            }
            return PillBadge(text: "Loaded", systemImage: "checkmark.circle.fill", variant: .success)
        case .unloaded:
            if modelManager.isSelectedModelBuiltIn() {
                return PillBadge(text: "Built in", systemImage: "shippingbox", variant: .info)
            }
            return PillBadge(text: "Unloaded", systemImage: "circle", variant: .neutral)
        case .downloading:
            return PillBadge(text: "Downloading", systemImage: "arrow.down.circle", variant: .info)
        case .prewarming:
            return PillBadge(text: "Warming up", systemImage: "flame", variant: .warning)
        default:
            return PillBadge(text: modelManager.modelState.description, variant: .neutral)
        }
    }

    private var progressStatusText: String {
        switch modelManager.modelState {
        case .downloading: return "Downloading"
        case .prewarming:  return "Optimizing for device"
        default:           return "Loading"
        }
    }

    private var modelPicker: some View {
        Group {
            if modelManager.availableModels.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading available models...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text("Model")
                        .font(.subheadline)
                        .fixedSize()
                    Spacer(minLength: 12)
                    ModelQuickPicker(modelManager: modelManager)
                }
            }
        }
    }

    private var modelActionButtons: some View {
        VStack(spacing: 10) {
            if modelManager.modelState == .unloaded {
                Button {
                    Task { await modelManager.loadModel(modelManager.selectedModel) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                        Text("Load Model")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(VoicelyTheme.accent, in: RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if modelManager.isSelectedModelDownloaded() {
                Button(role: .destructive) {
                    showingModelDeletion = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text("Delete Downloaded Model")
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous))
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .alert("Delete Model", isPresented: $showingModelDeletion) {
            Button("Delete", role: .destructive) {
                modelManager.deleteModel(modelManager.selectedModel)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete the model '\(ModelManager.displayName(for: modelManager.selectedModel))'?")
        }
    }

    // MARK: - Language

    private var languageRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech Language")
                    .font(.subheadline.weight(.medium))
                Text("Expected language of your recordings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $selectedLanguage) {
                ForEach(LanguageConstants.availableLanguages, id: \.self) { language in
                    Text(language == "auto" ? "Auto Detect" : language.capitalized).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityIdentifiers.Settings.speechLanguagePicker)
        }
    }

    // MARK: - Transcription

    private var promptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom Prompt")
                .font(.subheadline.weight(.medium))
            Text("Optional context to improve transcription accuracy")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. names, acronyms, jargon…", text: $transcriptionPrompt, axis: .vertical)
                .lineLimit(1...3)
                .font(.subheadline)
                .padding(10)
                .background(VoicelyTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous)
                        .stroke(VoicelyTheme.subtleBorder, lineWidth: 1)
                )
                .padding(.top, 2)
                .accessibilityIdentifier(AccessibilityIdentifiers.Settings.customPromptField)
        }
    }

    // MARK: - Compute

    private var encoderRow: some View {
        computeRow(
            title: "Audio Encoder",
            subtitle: "Processes audio input",
            selection: $modelManager.encoderComputeUnits
        )
    }

    private var decoderRow: some View {
        computeRow(
            title: "Text Decoder",
            subtitle: "Generates transcription text",
            selection: $modelManager.decoderComputeUnits
        )
    }

    private func computeRow(title: String, subtitle: String, selection: Binding<MLComputeUnits>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: selection) {
                Text("CPU").tag(MLComputeUnits.cpuOnly)
                Text("GPU").tag(MLComputeUnits.cpuAndGPU)
                Text("Neural").tag(MLComputeUnits.cpuAndNeuralEngine)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: selection.wrappedValue) { computeUnitsChanged = true }
        }
    }

    private var reloadButton: some View {
        Button {
            computeUnitsChanged = false
            Task { await modelManager.loadModel(modelManager.selectedModel, redownload: false) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                Text("Reload Model to Apply")
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(VoicelyTheme.accentTint(0.14), in: RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous))
            .foregroundStyle(VoicelyTheme.accent)
        }
        .buttonStyle(.plain)
    }

    private func navRow(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(VoicelyTheme.accent)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy notice

    private var privacyNoticeCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Fully on-device")
                    .font(.subheadline.weight(.semibold))
                Text("All transcription happens on your device. Your audio and text never leave this device unless you export them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VoicelyTheme.cornerLarge, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoicelyTheme.cornerLarge, style: .continuous)
                .stroke(Color.blue.opacity(0.20), lineWidth: 1)
        )
    }

    // MARK: - About

    private var appInfoContent: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let whisperKitVersion = Bundle.main.object(forInfoDictionaryKey: "WhisperKitVersion") as? String ?? "—"

        return VStack(spacing: 10) {
            infoRow(label: "App Version", value: "\(version) (\(build))")
            Divider().background(VoicelyTheme.hairline)
            infoRow(label: "Device", value: WhisperKit.deviceName())
            Divider().background(VoicelyTheme.hairline)
            infoRow(label: "WhisperKit", value: whisperKitVersion)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Model Quick Picker (custom dropdown with a single-column status icon)

/// Model quick-picker that replaces the system Menu in Settings.
/// One left column conveys both download and selection state, see ModelSelectionIndicator.
private struct ModelQuickPicker: View {
    @ObservedObject var modelManager: ModelManager
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 4) {
                Text(ModelManager.displayNameWithLanguageTag(for: modelManager.selectedModel))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline)
            .foregroundStyle(VoicelyTheme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityIdentifiers.Settings.modelPicker)
        .popover(isPresented: $isExpanded) {
            modelList
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: modelManager.selectedModel) { _, newValue in
            let nextState = ModelManager.selectionStateAfterPickingModel(
                newValue,
                loadedModelIdentifier: modelManager.loadedModelIdentifierInMemory
            )
            if modelManager.modelState != nextState {
                modelManager.modelState = nextState
            }
            modelManager.errorMessage = nil
        }
    }

    private var modelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(modelManager.availableModels, id: \.self) { model in
                    Button {
                        if modelManager.selectedModel != model {
                            modelManager.selectedModel = model
                        }
                        isExpanded = false
                    } label: {
                        ModelQuickPickerRow(
                            title: ModelManager.displayNameWithLanguageTag(for: model),
                            indicator: ModelSelectionIndicator(
                                isDownloaded: modelManager.isModelAvailableOffline(model),
                                isSelected: modelManager.selectedModel == model
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 280, maxHeight: 420)
    }
}

/// A row in the quick-picker dropdown: single-column status icon + model name.
private struct ModelQuickPickerRow: View {
    let title: String
    let indicator: ModelSelectionIndicator

    var body: some View {
        HStack(spacing: 10) {
            indicatorIcon
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var indicatorIcon: some View {
        if let symbol = indicator.symbolName {
            Image(systemName: symbol)
                .foregroundStyle(iconColor)
                // The filled dot reads heavier than the hollow-ring glyphs; shrink it ~30% to balance.
                .scaleEffect(indicator == .downloaded ? 0.7 : 1.0)
        } else {
            // Neither downloaded nor selected: no circle, just a hidden placeholder to keep alignment
            Image(systemName: "circle")
                .hidden()
        }
    }

    private var iconColor: Color {
        switch indicator {
        case .downloadedSelected: return .green
        case .downloaded: return .blue
        case .selectedNotDownloaded: return .orange
        case .hidden: return .clear
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ModelManager())
}
