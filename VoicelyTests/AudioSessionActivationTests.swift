//
//  AudioSessionActivationTests.swift
//  VoicelyTests
//

import Foundation
import os
import Testing
@testable import Voicely

struct AudioSessionActivationTests {
    @Test @MainActor func sessionChangesRunOffTheMainThreadInRequestOrder() async throws {
        let log = OSAllocatedUnfairLock(initialState: [String]())
        // A deactivation queued without waiting must still land before a later activation.
        AudioSessionActivation.enqueue { _ in
            log.withLock { $0.append("deactivate main=\(Thread.isMainThread)") }
        }
        try await AudioSessionActivation.perform { _ in
            log.withLock { $0.append("activate main=\(Thread.isMainThread)") }
        }

        #expect(log.withLock { $0 } == ["deactivate main=false", "activate main=false"])
    }

    @Test func activationErrorsReachTheCaller() async {
        struct Refused: Error {}
        await #expect(throws: Refused.self) {
            try await AudioSessionActivation.perform { _ in throw Refused() }
        }
    }
}
