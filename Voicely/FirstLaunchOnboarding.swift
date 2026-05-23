//
//  FirstLaunchOnboarding.swift
//  Voicely
//
//  Created by Codex on 5/23/2026.
//

import Foundation
import SwiftUI

struct FirstLaunchOnboardingPage: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let accentColor: Color
}

enum FirstLaunchOnboarding {
    static let completionKey = "VoicelyDidCompleteFirstLaunchOnboardingV1"

    static let pages: [FirstLaunchOnboardingPage] = [
        FirstLaunchOnboardingPage(
            id: "capture",
            title: "Capture every thought",
            subtitle: "Open a note, start recording, and keep your audio and transcript together.",
            systemImage: "waveform.circle.fill",
            accentColor: .blue
        ),
        FirstLaunchOnboardingPage(
            id: "private",
            title: "Transcribe privately",
            subtitle: "Offline Whisper runs on this device, so meetings, ideas, and journals stay local.",
            systemImage: "lock.shield.fill",
            accentColor: .green
        ),
        FirstLaunchOnboardingPage(
            id: "metrics",
            title: "Compare model performance",
            subtitle: "Compare the selected compute route, processing time ratio, and realtime speed after each note.",
            systemImage: "cpu.fill",
            accentColor: .purple
        ),
        FirstLaunchOnboardingPage(
            id: "prepare",
            title: "Ready when you are",
            subtitle: "The first model setup can take a moment. This tour gives Voicely time to prepare.",
            systemImage: "sparkles",
            accentColor: .orange
        )
    ]

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
}

struct FirstLaunchOnboardingView: View {
    var onComplete: () -> Void
    @State private var selectedPage = 0

    private var isLastPage: Bool {
        selectedPage >= FirstLaunchOnboarding.pages.count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 22)

            VStack(spacing: 10) {
                Text("Voicely")
                    .font(.largeTitle.weight(.bold))
                Text("Private voice notes with offline transcription")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            TabView(selection: $selectedPage) {
                ForEach(Array(FirstLaunchOnboarding.pages.enumerated()), id: \.element.id) { index, page in
                    onboardingPage(page)
                        .tag(index)
                        .padding(.horizontal, 24)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: 430)

            pageDots
                .padding(.bottom, 18)

            setupStatus
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Text(isLastPage ? "Start using Voicely" : "Next")
                    Image(systemName: isLastPage ? "checkmark" : "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(VoicelyTheme.accent, in: Capsule())
                .shadow(color: VoicelyTheme.accent.opacity(0.28), radius: 14, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                isLastPage
                ? AccessibilityIdentifiers.Onboarding.finishButton
                : AccessibilityIdentifiers.Onboarding.nextButton
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundView)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.screen)
    }

    private func onboardingPage(_ page: FirstLaunchOnboardingPage) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(page.accentColor.opacity(0.16))
                    .frame(width: 148, height: 148)
                Image(systemName: page.systemImage)
                    .font(.system(size: 70, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(page.accentColor)
            }

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(AccessibilityIdentifiers.Onboarding.pageTitle)
                Text(page.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 330)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<FirstLaunchOnboarding.pages.count, id: \.self) { index in
                Capsule()
                    .fill(index == selectedPage ? VoicelyTheme.accent : Color.secondary.opacity(0.28))
                    .frame(width: index == selectedPage ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: selectedPage)
            }
        }
        .accessibilityLabel("Page \(selectedPage + 1) of \(FirstLaunchOnboarding.pages.count)")
    }

    private var setupStatus: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing offline transcription")
                    .font(.caption.weight(.semibold))
                Text("Model optimization can continue while you read this tour.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var backgroundView: some View {
        ZStack {
            VoicelyTheme.groupedBackground.ignoresSafeArea()
            LinearGradient(
                colors: [
                    VoicelyTheme.accent.opacity(0.20),
                    Color.clear,
                    Color.orange.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private func primaryAction() {
        if isLastPage {
            onComplete()
        } else {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                selectedPage += 1
            }
        }
    }
}

#Preview("First Launch Onboarding") {
    FirstLaunchOnboardingView(onComplete: {})
}
