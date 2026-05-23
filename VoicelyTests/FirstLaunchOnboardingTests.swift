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
            "Compare model performance",
            "Ready when you are"
        ])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "FirstLaunchOnboardingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
