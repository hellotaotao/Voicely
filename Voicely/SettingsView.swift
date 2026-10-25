//
//  SettingsView.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftUI
import CoreML

/// Languages offered in Settings: auto-detect plus what Qwen3-ASR supports.
struct LanguageConstants {
    static var availableLanguages: [String] {
        let topLanguages = ["auto", "english", "chinese", "cantonese", "spanish", "french", "german", "japanese", "korean"]
        let remainingLanguages = Qwen3ASRDefaults.languageNames.keys.filter { !topLanguages.contains($0) }.sorted()
        return topLanguages + remainingLanguages
    }
}

struct SettingsView: View {
    @EnvironmentObject var modelManager: ModelManager
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    modelHeroCard

                    privacyNoticeCard

                    settingsSection(
                        title: "About",
                        identifier: AccessibilityIdentifiers.Settings.aboutSection
                    ) {
                        appInfoContent
                    }

                    settingsSection(
                        title: "Advanced",
                        identifier: AccessibilityIdentifiers.Settings.languageSection
                    ) {
                        languageRow
                    }

                    settingsSection(
                        title: "Diagnostics",
                        identifier: "settings.diagnosticsSection"
                    ) {
                        DiagnosticsContent()
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
                        Text(ModelManager.displayName(for: modelManager.selectedModel))
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

                modelActionButtons
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Settings.activeModelCard)
    }

    private var modelStateBadge: some View {
        switch modelManager.modelState {
        case .loaded:
            return PillBadge(text: "Loaded", systemImage: "checkmark.circle.fill", variant: .success)
        case .unloaded:
            return PillBadge(text: "Unloaded", systemImage: "circle", variant: .neutral)
        case .prewarming:
            return PillBadge(text: "Warming up", systemImage: "flame", variant: .warning)
        default:
            return PillBadge(text: modelManager.modelState.description, variant: .neutral)
        }
    }

    private var progressStatusText: String {
        switch modelManager.modelState {
        case .prewarming:  return "Optimizing for device"
        default:           return "Loading"
        }
    }

    /// The model ships with the app, so the only action left is loading it
    /// again after a failure.
    @ViewBuilder
    private var modelActionButtons: some View {
        if modelManager.modelState == .unloaded {
            Button {
                Task { await modelManager.loadModel() }
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
    }

    // MARK: - Language

    private var languageRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech Language")
                    .font(.subheadline.weight(.medium))
                Text("Auto Detect handles mixed languages, such as Chinese with English. Choose a language only if Auto Detect keeps getting it wrong; while one is chosen, the recording screen shows it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

        return VStack(spacing: 10) {
            infoRow(label: "App Version", value: "\(version) (\(build))")
            Divider().background(VoicelyTheme.hairline)
            infoRow(label: "Device", value: DeviceIdentity.hardwareModel)
            Divider().background(VoicelyTheme.hairline)
            infoRow(label: "Speech Engine", value: modelManager.backend == .mlx ? "Qwen3-ASR (MLX)" : "Qwen3-ASR (CoreML)")
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

#Preview {
    SettingsView()
        .environmentObject(ModelManager())
}
