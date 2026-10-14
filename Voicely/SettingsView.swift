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
    @State private var showingModelDeletion = false
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"
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

                    privacyNoticeCard

                    settingsSection(
                        title: "About",
                        identifier: AccessibilityIdentifiers.Settings.aboutSection
                    ) {
                        appInfoContent
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
        .alert(
            "Download Over Cellular?",
            isPresented: Binding(
                get: { modelManager.awaitingCellularApproval },
                set: { isPresented in
                    if !isPresented, modelManager.awaitingCellularApproval {
                        modelManager.waitForInexpensiveNetwork()
                    }
                }
            )
        ) {
            Button("Download Now") {
                Task { await modelManager.approveCellularDownload() }
            }
            Button("Wait for Wi-Fi", role: .cancel) {
                modelManager.waitForInexpensiveNetwork()
            }
        } message: {
            Text("The speech model is \(modelManager.backend.approximateDownloadSizeText). Download it now, or wait for Wi-Fi and Voicely will start the download by itself.")
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
            if modelManager.isModelDownloaded {
                return PillBadge(text: "Unloaded", systemImage: "circle", variant: .neutral)
            }
            return PillBadge(text: "Not downloaded", systemImage: "arrow.down.circle", variant: .info)
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

    private var modelActionButtons: some View {
        VStack(spacing: 10) {
            if modelManager.modelState == .unloaded {
                Button {
                    Task { await modelManager.loadModel() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: modelManager.isModelDownloaded ? "bolt.fill" : "arrow.down.circle.fill")
                        Text(modelManager.isModelDownloaded
                             ? "Load Model"
                             : "Download Model (\(modelManager.backend.approximateDownloadSizeText))")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(VoicelyTheme.accent, in: RoundedRectangle(cornerRadius: VoicelyTheme.cornerSmall, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if modelManager.isModelDownloaded {
                Button(role: .destructive) {
                    showingModelDeletion = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text(modelManager.isDeletingModel ? "Deleting..." : "Delete Downloaded Model")
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
        .disabled(modelManager.isDeletingModel)
        .alert("Delete Model", isPresented: $showingModelDeletion) {
            Button("Delete", role: .destructive) {
                Task { await modelManager.deleteModel() }
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
