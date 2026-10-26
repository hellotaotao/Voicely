//
//  FirstLaunchOnboarding.swift
//  Voicely
//
//  Created by Codex on 5/23/2026.
//

import Foundation
import SwiftUI

struct FirstLaunchOnboardingFeature: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
}

struct FirstLaunchModelSetupStatus: Equatable {
    enum VisualState: Equatable {
        case idle
        case active
        case ready
        case failed
    }

    let visualState: VisualState
    let title: String
    /// The error behind a failed setup; nil otherwise.
    let detail: String?
    let progress: Float?
}

enum FirstLaunchOnboarding {
    static let completionKey = "VoicelyDidCompleteFirstLaunchOnboardingV1"

    /// What the welcome step promises, in a few words each so it can be read
    /// at a glance. `deviceName` is "Mac", "iPhone" or "iPad".
    static func features(deviceName: String) -> [FirstLaunchOnboardingFeature] {
        [
            FirstLaunchOnboardingFeature(
                id: "capture",
                title: "Records the whole meeting",
                detail: "Even with the screen locked",
                systemImage: "waveform"
            ),
            FirstLaunchOnboardingFeature(
                id: "private",
                title: "Stays on this \(deviceName)",
                detail: "Transcribed offline, never uploaded",
                systemImage: "lock.fill"
            ),
            FirstLaunchOnboardingFeature(
                id: "use",
                title: "Ready when it ends",
                detail: "Copy, share, or replay any sentence",
                systemImage: "doc.text"
            )
        ]
    }

    static func shouldPresent(
        defaults: UserDefaults = .standard,
        isRunningTests: Bool = AppRuntime.isRunningTests
    ) -> Bool {
        guard !isRunningTests else {
            return false
        }
        return !defaults.bool(forKey: completionKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
    }

    static func modelSetupStatus(
        for modelState: ModelState,
        progress: Float,
        errorMessage: String?
    ) -> FirstLaunchModelSetupStatus {
        if let errorMessage, !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FirstLaunchModelSetupStatus(
                visualState: .failed,
                title: "Speech model didn’t load",
                detail: errorMessage,
                progress: nil
            )
        }

        switch modelState {
        case .unloaded:
            return FirstLaunchModelSetupStatus(
                visualState: .idle,
                title: "Checking speech model",
                detail: nil,
                progress: nil
            )
        case .loading, .prewarming:
            return FirstLaunchModelSetupStatus(
                visualState: .active,
                title: "Preparing speech model",
                detail: nil,
                progress: clampedProgress(progress)
            )
        case .loaded:
            return FirstLaunchModelSetupStatus(
                visualState: .ready,
                title: "Ready · works offline",
                detail: nil,
                progress: nil
            )
        }
    }

    private static func clampedProgress(_ progress: Float) -> Float? {
        guard progress.isFinite, progress > 0, progress < 1 else {
            return nil
        }
        return min(max(progress, 0), 1)
    }
}

struct FirstLaunchOnboardingView: View {
    var modelSetupStatus: FirstLaunchModelSetupStatus = FirstLaunchOnboarding.modelSetupStatus(
        for: .unloaded,
        progress: 0,
        errorMessage: nil
    )
    var microphonePermission: MicrophonePermission = .undetermined
    /// Shows the system microphone prompt.
    var requestMicrophone: () async -> Void = {}
    var onComplete: () -> Void
    @State private var step: Step = .welcome
    @State private var isRequestingMicrophone = false

    private enum Step {
        case welcome
        case microphone
    }

    /// Dark text on the accent fill; white on the light purple fails contrast.
    private static let accentInk = Color(red: 0.10, green: 0.08, blue: 0.14)

    private static let previewLevels: [CGFloat] = [
        0.3, 0.5, 0.4, 0.7, 0.9, 0.6, 0.4, 0.8, 1, 0.7,
        0.5, 0.3, 0.45, 0.6, 0.85, 0.95, 0.7, 0.5, 0.35, 0.55,
        0.75, 0.6, 0.4, 0.3, 0.5, 0.8, 0.65, 0.45, 0.7, 0.9,
        0.75, 0.5, 0.35, 0.6, 0.4, 0.3, 0.25, 0.2, 0.15, 0.12
    ]

    /// Mac Catalyst in the iPad idiom draws the whole window at 77 %, so the
    /// design's sizes are scaled back up there to read at their intended size.
    private var scale: CGFloat {
        #if targetEnvironment(macCatalyst)
        UIDevice.current.userInterfaceIdiom == .pad ? 1 / 0.77 : 1
        #else
        1
        #endif
    }

    private var deviceName: String {
        #if targetEnvironment(macCatalyst)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    private var settingsName: String {
        #if targetEnvironment(macCatalyst)
        "System Settings"
        #else
        "Settings"
        #endif
    }

    private func m(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    /// Fixed design sizes that still follow Dynamic Type on iPhone and iPad.
    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: UIFontMetrics.default.scaledValue(for: m(size)), weight: weight)
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= m(820)
            Group {
                switch step {
                case .welcome:
                    fitted(isWide: isWide, height: proxy.size.height) {
                        welcome(isWide: isWide)
                    }
                case .microphone:
                    fitted(isWide: isWide, height: proxy.size.height) {
                        microphone(isWide: isWide)
                    }
                }
            }
            // The outgoing step leaves at once so the two layouts never overlap.
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
        .background(VoicelyTheme.groupedBackground.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.screen)
    }

    /// A wide window shows the step as laid out; a narrow one scrolls, so
    /// large Dynamic Type or a short phone never clips the buttons.
    @ViewBuilder
    private func fitted<Content: View>(
        isWide: Bool,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isWide {
            content()
        } else {
            ScrollView {
                content()
                    .frame(minHeight: height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Welcome

    @ViewBuilder
    private func welcome(isWide: Bool) -> some View {
        if isWide {
            HStack(alignment: .center, spacing: m(56)) {
                // Kept together and centered, so a tall window does not strand
                // the button at the bottom.
                VStack(alignment: .leading, spacing: 0) {
                    welcomeIntro(isWide: true)
                    HStack(spacing: m(22)) {
                        continueButton(fullWidth: false)
                        statusLine
                    }
                    .padding(.top, m(56))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                previewCard
                    .frame(width: m(400))
            }
            .frame(maxWidth: m(1100))
            .padding(.top, m(56))
            .padding(.leading, m(64))
            .padding(.trailing, m(56))
            .padding(.bottom, m(52))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                welcomeIntro(isWide: false)
                Spacer(minLength: m(40))
                VStack(spacing: m(16)) {
                    statusLine
                        .frame(maxWidth: .infinity)
                    continueButton(fullWidth: true)
                }
            }
            .padding(.horizontal, m(24))
            .padding(.top, m(40))
            .padding(.bottom, m(24))
        }
    }

    private func welcomeIntro(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: m(10)) {
                RoundedRectangle(cornerRadius: m(9), style: .continuous)
                    .fill(VoicelyTheme.accent)
                    .frame(width: m(32), height: m(32))
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: m(17), weight: .bold))
                            .foregroundStyle(Self.accentInk)
                    )
                    .accessibilityHidden(true)
                Text("Voicely")
                    .font(font(isWide ? 19 : 18, .semibold))
            }

            Text("Record the meeting.\nRead it when it ends.")
                .font(font(isWide ? 46 : 36, .bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.pageTitle)
                .padding(.top, m(isWide ? 48 : 36))

            VStack(alignment: .leading, spacing: m(isWide ? 28 : 26)) {
                ForEach(FirstLaunchOnboarding.features(deviceName: deviceName)) { feature in
                    featureRow(feature, isWide: isWide)
                }
            }
            .padding(.top, m(isWide ? 48 : 44))
        }
    }

    private func featureRow(_ feature: FirstLaunchOnboardingFeature, isWide: Bool) -> some View {
        HStack(spacing: m(isWide ? 18 : 16)) {
            iconTile(
                feature.systemImage,
                tint: VoicelyTheme.accent,
                size: isWide ? 48 : 46,
                symbolSize: 22,
                cornerRadius: 12
            )
            VStack(alignment: .leading, spacing: m(4)) {
                Text(feature.title)
                    .font(font(isWide ? 20 : 19, .semibold))
                Text(feature.detail)
                    .font(font(16))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func continueButton(fullWidth: Bool) -> some View {
        primaryButton("Continue", trailingImage: "arrow.right", fullWidth: fullWidth) {
            withAnimation(.easeInOut(duration: 0.25)) {
                step = .microphone
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.nextButton)
    }

    private var statusLine: some View {
        Group {
            switch modelSetupStatus.visualState {
            case .ready:
                HStack(spacing: m(8)) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: m(9), height: m(9))
                    Text(modelSetupStatus.title)
                }
            case .idle:
                HStack(spacing: m(8)) {
                    ProgressView()
                        .controlSize(.small)
                    Text(modelSetupStatus.title)
                }
            case .active:
                if let progress = modelSetupStatus.progress {
                    VStack(alignment: .leading, spacing: m(7)) {
                        Text("\(modelSetupStatus.title) · \(Int(progress * 100))%")
                        ProgressView(value: progress, total: 1)
                            .tint(VoicelyTheme.accent)
                            .frame(width: m(200))
                    }
                } else {
                    HStack(spacing: m(8)) {
                        ProgressView()
                            .controlSize(.small)
                        Text(modelSetupStatus.title)
                    }
                }
            case .failed:
                Label(modelSetupStatus.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(modelSetupStatus.detail ?? "")
            }
        }
        .font(font(15))
        .foregroundStyle(.secondary)
    }

    /// A still of a meeting being transcribed, so the welcome step shows the
    /// product instead of describing it.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: m(20)) {
            HStack(spacing: m(10)) {
                Circle()
                    .fill(Color.red)
                    .frame(width: m(10), height: m(10))
                Text("Recording")
                    .font(font(16, .semibold))
                Spacer(minLength: 0)
                Text("18:42")
                    .font(font(16))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: m(3)) {
                ForEach(Array(Self.previewLevels.enumerated()), id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: m(2), style: .continuous)
                        .fill(index < 34 ? VoicelyTheme.accent : Color.secondary.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .frame(height: m(6 + level * 42))
                }
            }
            .frame(height: m(48))

            VStack(alignment: .leading, spacing: m(6)) {
                Text("Design is done. The build is in review.")
                    .padding(.horizontal, m(12))
                    .padding(.vertical, m(10))
                HStack(alignment: .firstTextBaseline, spacing: m(10)) {
                    Image(systemName: "play.fill")
                        .font(.system(size: m(12)))
                        .foregroundStyle(VoicelyTheme.accent)
                    Text("If it passes, we ship Monday.")
                }
                .padding(.horizontal, m(12))
                .padding(.vertical, m(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    VoicelyTheme.accent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: m(12), style: .continuous)
                )
                HStack(spacing: m(3)) {
                    Text("I’ll send the copy tonight")
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(VoicelyTheme.accent)
                        .frame(width: m(2), height: m(18))
                }
                .padding(.horizontal, m(12))
                .padding(.vertical, m(10))
            }
            .font(font(17))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(m(24))
        .background(VoicelyTheme.surface, in: RoundedRectangle(cornerRadius: m(20), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: m(20), style: .continuous)
                .stroke(VoicelyTheme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example of a meeting being transcribed")
    }

    // MARK: - Microphone

    private func microphone(isWide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        step = .welcome
                    }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(font(17))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: m(44))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRequestingMicrophone)
                Spacer()
            }

            Spacer(minLength: m(24))
            microphoneContent(isWide: isWide)
            Spacer(minLength: m(24))

            Text("Change it anytime in \(settingsName) › Privacy & Security › Microphone")
                .font(font(15))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, m(isWide ? 56 : 24))
        .padding(.top, m(isWide ? 40 : 16))
        .padding(.bottom, m(isWide ? 52 : 24))
    }

    private func microphoneContent(isWide: Bool) -> some View {
        let symbol: String
        let tint: Color
        let title: String
        let message: String
        switch microphonePermission {
        case .undetermined:
            symbol = "mic.fill"
            tint = VoicelyTheme.accent
            title = "Allow the microphone"
            message = "Voicely only listens while you record."
        case .denied:
            symbol = "mic.slash.fill"
            tint = .orange
            title = "Microphone is off"
            message = "Turn it on in \(settingsName) to record."
        case .granted:
            symbol = "checkmark"
            tint = .green
            title = "You’re all set"
            message = "Press Record when a meeting starts."
        }

        return VStack(spacing: 0) {
            iconTile(
                symbol,
                tint: tint,
                size: isWide ? 96 : 88,
                symbolSize: isWide ? 42 : 38,
                cornerRadius: 26
            )

            Text(title)
                .font(font(isWide ? 42 : 32, .bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.pageTitle)
                .padding(.top, m(32))

            Text(message)
                .font(font(isWide ? 20 : 18))
                .foregroundStyle(.secondary)
                .padding(.top, m(14))

            VStack(spacing: m(8)) {
                microphoneButtons(fullWidth: !isWide)
            }
            .padding(.top, m(40))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func microphoneButtons(fullWidth: Bool) -> some View {
        switch microphonePermission {
        case .undetermined:
            primaryButton("Allow Microphone", leadingImage: "mic.fill", fullWidth: fullWidth) {
                isRequestingMicrophone = true
                Task {
                    await requestMicrophone()
                    isRequestingMicrophone = false
                    // Either answer finishes onboarding; recording explains a refusal.
                    onComplete()
                }
            }
            .disabled(isRequestingMicrophone)
            .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.allowMicrophoneButton)

            secondaryButton("Not now", action: onComplete)
                .disabled(isRequestingMicrophone)
                .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.skipMicrophoneButton)
        case .denied:
            primaryButton("Open \(settingsName)", fullWidth: fullWidth) {
                MicrophoneSettings.open()
            }
            secondaryButton("Continue without it", action: onComplete)
                .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.skipMicrophoneButton)
        case .granted:
            primaryButton("Start using Voicely", fullWidth: fullWidth, action: onComplete)
                .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.finishButton)
        }
    }

    // MARK: - Building blocks

    private func iconTile(
        _ systemImage: String,
        tint: Color,
        size: CGFloat,
        symbolSize: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        RoundedRectangle(cornerRadius: m(cornerRadius), style: .continuous)
            .fill(tint.opacity(0.14))
            .frame(width: m(size), height: m(size))
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: m(symbolSize), weight: .semibold))
                    .foregroundStyle(tint)
            )
            .accessibilityHidden(true)
    }

    private func primaryButton(
        _ title: String,
        leadingImage: String? = nil,
        trailingImage: String? = nil,
        fullWidth: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: m(10)) {
                if let leadingImage {
                    Image(systemName: leadingImage)
                }
                Text(title)
                if let trailingImage {
                    Image(systemName: trailingImage)
                }
            }
            .font(font(18, .semibold))
            .foregroundStyle(Self.accentInk)
            .padding(.horizontal, m(30))
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: m(fullWidth ? 54 : 50))
            .background(VoicelyTheme.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(font(17))
                .foregroundStyle(.secondary)
                .padding(.horizontal, m(16))
                .frame(minHeight: m(44))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("First Launch Onboarding") {
    FirstLaunchOnboardingView(onComplete: {})
}
