//
//  FirstLaunchOnboardingTests.swift
//  VoicelyTests
//
//  Created by Codex on 5/23/2026.
//

import Foundation
import Testing
@testable import Voicely

struct FirstLaunchOnboardingTests {
    @Test func onboardingShowsUntilUserCompletesIt() {
        let defaults = makeDefaults()

        #expect(FirstLaunchOnboarding.shouldPresent(defaults: defaults, isRunningTests: false) == true)

        FirstLaunchOnboarding.markCompleted(defaults: defaults)

        #expect(FirstLaunchOnboarding.shouldPresent(defaults: defaults, isRunningTests: false) == false)
    }

    @Test func onboardingIsSuppressedDuringAutomatedTests() {
        let defaults = makeDefaults()

        #expect(FirstLaunchOnboarding.shouldPresent(defaults: defaults, isRunningTests: true) == false)
    }

    @Test func onboardingContainsFourIntroPages() {
        #expect(FirstLaunchOnboarding.pages.count == 4)
        #expect(FirstLaunchOnboarding.pages.map(\.title) == [
            "Capture every thought",
            "Transcribe privately",
            "Choose the right model",
            "Ready when you are"
        ])
    }

    @Test func modelSetupStatusReflectsActualPreparationState() {
        let optimizing = FirstLaunchOnboarding.modelSetupStatus(
            for: .prewarming,
            progress: 0.82,
            errorMessage: nil
        )

        #expect(optimizing.visualState == .active)
        #expect(optimizing.title == "Optimizing offline transcription")
        #expect(optimizing.detail == "Core ML is preparing the selected model for this device.")
        #expect(optimizing.progress == 0.82)

        let ready = FirstLaunchOnboarding.modelSetupStatus(
            for: .loaded,
            progress: 1,
            errorMessage: nil
        )

        #expect(ready.visualState == .ready)
        #expect(ready.title == "Offline transcription ready")
        #expect(ready.detail == "The selected model is loaded and ready to use.")
        #expect(ready.progress == nil)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "FirstLaunchOnboardingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
