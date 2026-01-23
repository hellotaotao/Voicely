//
//  CloudKitSyncMonitorTests.swift
//  VoicelyTests
//
//  Created by Codex on 1/22/2026.
//

import CloudKit
import Testing
@testable import Voicely

struct CloudKitSyncMonitorTests {

    @Test @MainActor func userFriendlyErrorMessageMapsKnownErrors() {
        let monitor = CloudKitSyncMonitor()

        let networkError = CKError(.networkUnavailable)
        #expect(monitor.userFriendlyErrorMessage(for: networkError) == "No internet connection. Sync will resume when connected.")

        let authError = CKError(.notAuthenticated)
        #expect(monitor.userFriendlyErrorMessage(for: authError) == "Please sign in to iCloud in Settings to enable sync.")
    }
}

struct ModelStateTests {

    @Test func modelStateDescriptionMatchesExpectedText() {
        #expect(ModelState.unloaded.description == "Not Loaded")
        #expect(ModelState.loading.description == "Loading...")
        #expect(ModelState.downloading.description == "Downloading...")
        #expect(ModelState.prewarming.description == "Optimizing...")
        #expect(ModelState.loaded.description == "Ready")
    }
}
