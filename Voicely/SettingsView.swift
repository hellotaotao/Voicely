//
//  SettingsView.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftUI
import CoreML

struct SettingsView: View {
    @EnvironmentObject var modelManager: ModelManager
    @AppStorage("selectedLanguage") private var selectedLanguage: String = "auto"
    @Environment(\.dismiss) private var dismiss
    /// Quitting to apply a new interface language is held off while recording.
    var isRecording = false
    @State private var appLanguage = AppLanguageSettings.storedSelection
    @State private var showingLanguageRestartAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    modelHeroCard

                    privacyNoticeCard

                    settingsSection(
                        title: String(localized: "About"),
                        identifier: AccessibilityIdentifiers.Settings.aboutSection
                    ) {
                        appInfoContent
                    }

                    settingsSection(
                        title: String(localized: "Advanced"),
                        identifier: AccessibilityIdentifiers.Settings.languageSection
                    ) {
                        VStack(spacing: 14) {
                            appLanguageRow
                            Divider()
                            languageRow
                            Divider()
                            chineseScriptRow
                        }
                    }

                    settingsSection(
                        title: String(localized: "Diagnostics"),
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
                        Text(activeModelName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if usesEnglishEngine {
                                PillBadge(text: String(localized: "Loads when needed"), systemImage: "circle", variant: .neutral)
                            } else {
                                modelStateBadge
                            }
                            PillBadge(text: String(localized: "On-device"), systemImage: "iphone", variant: .accent)
                        }
                    }
                    // Without the priority the row splits its width with the
                    // spacer and a short model name wraps onto two lines.
                    .layoutPriority(1)
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

                if !usesEnglishEngine, let errorMessage = modelManager.errorMessage {
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

                if !usesEnglishEngine && modelManager.loadingProgressValue > 0 && modelManager.loadingProgressValue < 1.0 {
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

    /// With English chosen every recording is transcribed by Parakeet, so the
    /// card names it instead of Qwen3-ASR, which then only waits unloaded.
    private var usesEnglishEngine: Bool {
        EnglishStretchRouting.Mode(languageHint: Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: selectedLanguage)) == .english
    }

    private var activeModelName: String {
        usesEnglishEngine
            ? SpeechModelKind.parakeet.displayName
            : ModelManager.displayName(for: modelManager.selectedModel)
    }

    private var speechEngineLabel: String {
        if usesEnglishEngine { return "Parakeet (CoreML)" }
        return modelManager.backend == .mlx ? "Qwen3-ASR (MLX)" : "Qwen3-ASR (CoreML)"
    }

    private var modelStateBadge: some View {
        switch modelManager.modelState {
        case .loaded:
            return PillBadge(text: String(localized: "Loaded"), systemImage: "checkmark.circle.fill", variant: .success)
        case .unloaded:
            return PillBadge(text: waitsForWork ? String(localized: "Loads when needed") : String(localized: "Unloaded"), systemImage: "circle", variant: .neutral)
        case .prewarming:
            return PillBadge(text: String(localized: "Warming up"), systemImage: "flame", variant: .warning)
        default:
            return PillBadge(text: modelManager.modelState.description, variant: .neutral)
        }
    }

    private var progressStatusText: String {
        switch modelManager.modelState {
        case .prewarming:  return String(localized: "Optimizing for device")
        default:           return String(localized: "Loading")
        }
    }

    /// The model is left unloaded until something needs it.
    private var waitsForWork: Bool {
        TranscriptionService.loadsQwenOnDemand(selectedLanguageKey: selectedLanguage)
            && modelManager.errorMessage == nil
    }

    /// The model ships with the app, so the only action left is loading it
    /// again after a failure.
    @ViewBuilder
    private var modelActionButtons: some View {
        if modelManager.modelState == .unloaded && !waitsForWork {
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

    /// On iPhone and iPad the system gives Voicely a Language row on its own
    /// page in Settings, so the row links there. The Mac has no per-app page,
    /// so the language is picked here and applies on the next launch.
    @ViewBuilder
    private var appLanguageRow: some View {
        #if targetEnvironment(macCatalyst)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Language")
                        .font(.subheadline.weight(.medium))
                    Text("Language of Voicely's menus and buttons. Transcripts are not affected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { appLanguage },
                    set: { newValue in
                        appLanguage = newValue
                        AppLanguageSettings.storedSelection = newValue
                        showingLanguageRestartAlert = newValue != AppLanguageSettings.selectionAtLaunch
                    }
                )) {
                    Text("Follow System").tag(AppLanguageSettings.followSystem)
                    ForEach(AppLanguageSettings.options, id: \.self) { code in
                        Text(verbatim: AppLanguageSettings.displayName(code)).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("settings.appLanguagePicker")
            }
            .alert("Reopen Voicely to Switch Language", isPresented: $showingLanguageRestartAlert) {
                if isRecording {
                    Button("OK", role: .cancel) {}
                } else {
                    Button("Quit Now") { AppLanguageSettings.quit() }
                    Button("Later", role: .cancel) {}
                }
            } message: {
                Text(isRecording
                     ? "The new language appears after you stop recording, quit Voicely and open it again."
                     : "The new language appears after you quit Voicely and open it again.")
            }

            if appLanguage != AppLanguageSettings.selectionAtLaunch {
                HStack(alignment: .center, spacing: 10) {
                    Text(isRecording
                         ? "Stop recording, then quit and reopen Voicely to switch the language."
                         : "Quit and reopen Voicely to switch the language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Quit Voicely") {
                        AppLanguageSettings.quit()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRecording)
                    .accessibilityIdentifier("settings.quitForLanguageButton")
                }
            }
        }
        #else
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("App Language")
                    .font(.subheadline.weight(.medium))
                Text("Follows your device language. You can pick a different one for Voicely in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                AppLanguageSettings.openSystemSettings()
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: AppLanguageSettings.currentLanguageName)
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings.appLanguageButton")
        }
        #endif
    }

    private var languageRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech Language")
                    .font(.subheadline.weight(.medium))
                Text("Choose English only if all your recordings are in English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { Qwen3ASRDefaults.languageKey(selectedLanguage) },
                set: { selectedLanguage = $0 }
            )) {
                ForEach(Qwen3ASRDefaults.languageKeys, id: \.self) { language in
                    Text(language == "english" ? String(localized: "English") : String(localized: "Auto Detect")).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityIdentifiers.Settings.speechLanguagePicker)
        }
    }

    private var chineseScriptRow: some View {
        @Bindable var setting = ChineseScriptSetting.shared
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chinese Characters")
                    .font(.subheadline.weight(.medium))
                Text("How Chinese transcripts are shown, copied and shared. Only the characters change, never the words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: $setting.script) {
                ForEach(ChineseScript.allCases) { script in
                    Text(script.label).tag(script)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityIdentifiers.Settings.chineseScriptPicker)
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
                Text("All transcription happens on your device. Your audio and text stay on your devices and in your own iCloud account unless you share them.")
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
            infoRow(label: String(localized: "App Version"), value: "\(version) (\(build))")
            Divider().background(VoicelyTheme.hairline)
            infoRow(label: String(localized: "Device"), value: DeviceIdentity.hardwareModel)
            Divider().background(VoicelyTheme.hairline)
            infoRow(label: String(localized: "Speech Engine"), value: speechEngineLabel)
            Divider().background(VoicelyTheme.hairline)
            NavigationLink {
                AcknowledgementsView()
            } label: {
                HStack {
                    Text("Acknowledgements")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityIdentifiers.Settings.acknowledgementsLink)
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

/// The interface language. It follows the system's preferred languages unless
/// an app-level `AppleLanguages` override is set, which is what both System
/// Settings (Language & Region > Applications on the Mac, the app's page on
/// iPhone) and the in-app picker write. The bundle reads it only at launch.
enum AppLanguageSettings {
    static let followSystem = ""
    /// The localizations the app ships, in menu order.
    ///
    /// zh-HK ships too, for Hong Kong wording such as the Settings path to the
    /// microphone switch, but the system picks it on its own: in the menu it
    /// would read as a second Traditional Chinese.
    static let options = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR"]

    static func displayName(_ code: String) -> String {
        switch code {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "zh-HK": return "繁體中文（香港）"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "es": return "Español"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "pt-BR": return "Português (Brasil)"
        default: return code
        }
    }

    /// The localization the app is running in, named in that language.
    static var currentLanguageName: String {
        displayName(Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// The app-level override mapped onto a shipped localization, or
    /// `followSystem` when there is none. Reads only Voicely's own defaults
    /// domain, since `UserDefaults.standard` also returns the global list.
    static var storedSelection: String {
        get {
            guard let domain = Bundle.main.bundleIdentifier,
                  let languages = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
                  !languages.isEmpty
            else { return followSystem }
            return Bundle.preferredLocalizations(from: options, forPreferences: languages).first ?? followSystem
        }
        set {
            if newValue == followSystem {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    /// The selection this process launched with, captured on first use,
    /// which is before the picker can change it.
    static let selectionAtLaunch = storedSelection

    @MainActor static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Mac Catalyst apps cannot relaunch themselves, so the user reopens it.
    static func quit() {
        UserDefaults.standard.synchronize()
        exit(0)
    }
}
