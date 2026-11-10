import Foundation
import os
import Testing
@testable import Voicely

/// A recording whose file cannot take more audio (a full disk) ends, once,
/// instead of running on with nothing being saved.
struct RecordingWriteFailureTests {
    /// How often the service asks for the recording to be ended after
    /// `failures` failed writes reported from off the main actor.
    @MainActor private static func stopRequests(whileRecording: Bool, failures: Int) async -> Int {
        let service = AudioRecordingService()
        service.isRecording = whileRecording
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .recordingStoppedAfterWriteFailure, object: service, queue: nil
        ) { _ in requests.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        await Task.detached {
            for _ in 0..<failures { service.reportWriteFailure() }
        }.value
        // The report reaches the main actor in a task of its own.
        try? await Task.sleep(nanoseconds: 100_000_000)
        return requests.withLock { $0 }
    }

    @Test @MainActor func repeatedFailedWritesEndTheRecordingOnce() async {
        #expect(await Self.stopRequests(whileRecording: true, failures: 3) == 1)
    }

    @Test @MainActor func aFailureAfterTheRecordingEndedAsksForNothing() async {
        #expect(await Self.stopRequests(whileRecording: false, failures: 1) == 0)
    }
}
