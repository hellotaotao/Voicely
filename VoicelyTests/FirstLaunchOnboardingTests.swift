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

    @Test func welcomeFeaturesNameTheDevice() {
        let features = FirstLaunchOnboarding.features(deviceName: "Mac")

        #expect(features.map(\.title) == [
            "Records the whole meeting",
            "Stays on this Mac",
            "Ready when it ends"
        ])
    }

    @Test func modelSetupStatusReflectsActualPreparationState() {
        let optimizing = FirstLaunchOnboarding.modelSetupStatus(
            for: .prewarming,
            progress: 0.82,
            errorMessage: nil
        )

        #expect(optimizing.visualState == .active)
        #expect(optimizing.title == "Preparing speech model")
        #expect(optimizing.detail == nil)
        #expect(optimizing.progress == 0.82)

        let ready = FirstLaunchOnboarding.modelSetupStatus(
            for: .loaded,
            progress: 1,
            errorMessage: nil
        )

        #expect(ready.visualState == .ready)
        #expect(ready.title == "Ready · works offline")
        #expect(ready.detail == nil)
        #expect(ready.progress == nil)

        let failed = FirstLaunchOnboarding.modelSetupStatus(
            for: .loading,
            progress: 0.4,
            errorMessage: "Out of memory"
        )

        #expect(failed.visualState == .failed)
        #expect(failed.detail == "Out of memory")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "FirstLaunchOnboardingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
