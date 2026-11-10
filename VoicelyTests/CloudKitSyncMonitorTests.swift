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
    @Test @MainActor func applyAccountStatusMarksAvailabilityAndTimestamp() {
        let monitor = CloudKitSyncMonitor()
        let checkedAt = Date(timeIntervalSince1970: 42)

        monitor.applyAccountStatus(.available, checkedAt: checkedAt)

        #expect(monitor.accountStatus == .available)
        #expect(monitor.syncStatus == .available)
        #expect(monitor.lastStatusCheck == checkedAt)
        #expect(monitor.statusDescription.contains("iCloud account available"))
    }

    @Test @MainActor func applyAccountStatusMapsNoAccountToError() {
        let monitor = CloudKitSyncMonitor()

        monitor.applyAccountStatus(.noAccount, checkedAt: Date(timeIntervalSince1970: 42))

        #expect(monitor.accountStatus == .noAccount)
        #expect(monitor.syncStatus == .error("No iCloud account found"))
    }
}

struct ModelStateTests {

    @Test func modelStateDescriptionMatchesExpectedText() {
        #expect(ModelState.unloaded.description == "Not Loaded")
        #expect(ModelState.loading.description == "Loading...")
        #expect(ModelState.prewarming.description == "Optimizing...")
        #expect(ModelState.loaded.description == "Ready")
    }
}
