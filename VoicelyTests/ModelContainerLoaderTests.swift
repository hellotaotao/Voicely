//
//  ModelContainerLoaderTests.swift
//  VoicelyTests
//

import Foundation
import SwiftData
import Testing
import UIKit
@testable import Voicely

@MainActor
struct ModelContainerLoaderTests {
    private struct StoreLocked: Error {}

    private static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([VoiceNote.self, NoteFolder.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @Test func opensTheStoreRightAwayWhenItCan() {
        let loader = ModelContainerLoader(
            make: Self.makeInMemoryContainer,
            isProtectedDataAvailable: { true },
            notificationCenter: NotificationCenter(),
            onUnrecoverableError: { Issue.record("unexpected failure: \($0)") }
        )

        #expect(loader.container != nil)
    }

    @Test func waitsForTheFirstUnlockInsteadOfCrashing() {
        let center = NotificationCenter()
        var unlocked = false
        var attempts = 0
        let loader = ModelContainerLoader(
            make: {
                attempts += 1
                guard unlocked else { throw StoreLocked() }
                return try Self.makeInMemoryContainer()
            },
            isProtectedDataAvailable: { unlocked },
            notificationCenter: center,
            onUnrecoverableError: { Issue.record("a locked store must not be fatal: \($0)") }
        )

        #expect(loader.container == nil)
        #expect(attempts == 1)

        unlocked = true
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

        #expect(loader.container != nil)
        #expect(attempts == 2)

        // Later unlocks leave the open store alone.
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(attempts == 2)
    }

    @Test func opensWhenTheUnlockLandsBeforeTheObserver() {
        var attempts = 0
        var availabilityChecks = 0
        let loader = ModelContainerLoader(
            make: {
                attempts += 1
                guard attempts > 1 else { throw StoreLocked() }
                return try Self.makeInMemoryContainer()
            },
            isProtectedDataAvailable: {
                // Locked when the open fails, unlocked by the time the observer is in place.
                availabilityChecks += 1
                return availabilityChecks > 1
            },
            notificationCenter: NotificationCenter(),
            onUnrecoverableError: { Issue.record("unexpected failure: \($0)") }
        )

        #expect(loader.container != nil)
    }

    @Test func otherFailuresStayFatal() {
        var failures: [Error] = []
        let loader = ModelContainerLoader(
            make: { throw StoreLocked() },
            isProtectedDataAvailable: { true },
            notificationCenter: NotificationCenter(),
            onUnrecoverableError: { failures.append($0) }
        )

        #expect(loader.container == nil)
        #expect(failures.count == 1)
    }
}
