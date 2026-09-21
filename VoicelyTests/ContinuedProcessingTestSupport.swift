import Foundation
@testable import Voicely

/// Records the same Foundation progress mutations as the iOS system handle.
/// It deliberately does not emulate iOS scheduling or expiration policy.
@MainActor
final class RecordingProgressHandle: ContinuedProcessingHandle {
    struct Sample {
        let time: TimeInterval
        let completed: Int64
        let total: Int64
    }

    var expirationHandler: (() -> Void)?
    let reporter = ContinuedProcessingProgress()
    private(set) var samples: [Sample] = []
    private(set) var completions: [Bool] = []

    init() { record() }

    func update(progress: Double, subtitle: String) {
        reporter.update(progress)
        record()
    }

    func advanceForWork() {
        reporter.advanceForWork()
        record()
    }

    func complete(success: Bool) {
        completions.append(success)
        reporter.complete(success: success)
        record()
    }

    private func record() {
        let progress = reporter.progress
        guard samples.last?.completed != progress.completedUnitCount
            || samples.last?.total != progress.totalUnitCount else { return }
        samples.append(Sample(time: ProcessInfo.processInfo.systemUptime,
                              completed: progress.completedUnitCount, total: progress.totalUnitCount))
    }
}

@MainActor
final class RecordingProgressDriver: ContinuedProcessingDriver {
    let handle = RecordingProgressHandle()
    private(set) var submissions = 0

    func submit(title: String, subtitle: String,
                launch: @escaping (any ContinuedProcessingHandle) -> Void) -> String? {
        submissions += 1
        launch(handle)
        return "replay-\(submissions)"
    }

    func cancel(identifier: String) {}
}
