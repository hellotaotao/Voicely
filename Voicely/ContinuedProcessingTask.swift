//
//  ContinuedProcessingTask.swift
//  Voicely
//

import Foundation
import os
#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

/// A running system task that lets user-started work continue after the app
/// leaves the foreground (iOS 26 continued processing).
@MainActor
protocol ContinuedProcessingHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func update(progress: Double, subtitle: String)
    /// Records observed decode work, including retries at the same audio position.
    /// The system bar advances; the audio-position subtitle is unchanged.
    func advanceForWork()
    func complete(success: Bool)
}

/// The exact Foundation progress operations used by the system handle and replay tests.
@MainActor
final class ContinuedProcessingProgress {
    let progress: Progress
    private var completed = false
    private static let audioUnits: Int64 = 10_000
    private static let remainingWorkUnits: Int64 = 100

    init(progress: Progress = Progress(totalUnitCount: 10_000)) {
        self.progress = progress
        progress.totalUnitCount = 10_000
    }

    func update(_ fraction: Double) {
        guard !completed else { return }
        let position = fraction.isFinite ? min(max(fraction, 0), 0.99) : 0
        progress.completedUnitCount = max(progress.completedUnitCount, Int64(position * Double(Self.audioUnits)))
    }

    func advanceForWork() {
        guard !completed else { return }
        // Retries discover additional work, including at the end of the file.
        // Keep a remaining-work reserve rather than hitting a fixed 99% ceiling.
        // Both the completed count and the final fraction continue increasing;
        // only complete(success:) can report 100%.
        let next = progress.completedUnitCount + 1
        progress.totalUnitCount = max(progress.totalUnitCount, next + Self.remainingWorkUnits)
        progress.completedUnitCount += 1
    }

    func complete(success: Bool) {
        guard !completed else { return }
        completed = true
        if success { progress.completedUnitCount = progress.totalUnitCount }
    }
}

/// Device logs show iOS expiring tasks after extended gaps in progress updates;
/// the allowed cadence is not an API guarantee. Audio position stands still while
/// Whisper re-decodes the same window: up to three temperature fallbacks plus a
/// prompt-free pass, over a minute on a phone for hard far-field audio. While
/// the decoder keeps producing tokens the task is working, not hung, so each
/// check that sees new tokens moves the task one step. The steps stop short of
/// completion, and a decoder that stops producing tokens is still expired.
@MainActor
struct DecodeWorkHeartbeat {
    private let decodeWork: () -> UInt64
    private var lastSeen: UInt64

    init(decodeWork: @escaping () -> UInt64) {
        self.decodeWork = decodeWork
        lastSeen = decodeWork()
    }

    /// True when the decoder took at least one step since the last check.
    mutating func decoderAdvanced() -> Bool {
        let current = decodeWork()
        defer { lastSeen = current }
        return current != lastSeen
    }
}

@MainActor
protocol ContinuedProcessingDriver: AnyObject {
    /// Asks the system to run a continued processing task. Returns the request
    /// identifier, or nil when the system declines (older iOS, Simulator, Mac, or
    /// the app is not in the foreground); `launch` is then never called.
    func submit(
        title: String,
        subtitle: String,
        launch: @escaping (any ContinuedProcessingHandle) -> Void
    ) -> String?

    /// Withdraws a request that has not launched yet.
    func cancel(identifier: String)
}

@MainActor
final class SystemContinuedProcessingDriver: ContinuedProcessingDriver {
    static let shared = SystemContinuedProcessingDriver()

    /// Must match a `BGTaskSchedulerPermittedIdentifiers` wildcard in Info.plist.
    static let identifierContext = "finalizeRecording"

    private var pendingLaunches: [String: (any ContinuedProcessingHandle) -> Void] = [:]
    private let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "ContinuedProcessing")

    func submit(
        title: String,
        subtitle: String,
        launch: @escaping (any ContinuedProcessingHandle) -> Void
    ) -> String? {
        #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.hellotaotao.Voicely"
            // Registering the same identifier twice kills the app, so every
            // request gets a fresh suffix under the permitted wildcard.
            let identifier = "\(bundleID).\(Self.identifierContext).\(UUID().uuidString)"
            log.notice("task=\(identifier, privacy: .public) event=registrationStarted")
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier,
                using: .main
            ) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let task = task as? BGContinuedProcessingTask,
                          let launch = self?.pendingLaunches.removeValue(forKey: identifier) else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    launch(SystemContinuedProcessingHandle(task: task))
                }
            }
            guard registered else {
                log.error("task=\(identifier, privacy: .public) event=registrationRejected")
                return nil
            }

            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            pendingLaunches[identifier] = launch
            do {
                log.notice("task=\(identifier, privacy: .public) event=submissionStarted")
                try BGTaskScheduler.shared.submit(request)
                log.notice("task=\(identifier, privacy: .public) event=submissionAccepted")
                return identifier
            } catch {
                pendingLaunches.removeValue(forKey: identifier)
                let failure = error as NSError
                log.error("task=\(identifier, privacy: .public) event=submissionRejected domain=\(failure.domain, privacy: .public) code=\(failure.code)")
                return nil
            }
        }
        #endif
        log.notice("event=submissionSkipped reason=unsupportedPlatform")
        return nil
    }

    func cancel(identifier: String) {
        guard pendingLaunches.removeValue(forKey: identifier) != nil else { return }
        #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        #endif
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
@MainActor
private final class SystemContinuedProcessingHandle: ContinuedProcessingHandle {
    private let task: BGContinuedProcessingTask
    private let reportedProgress: ContinuedProcessingProgress
    private let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "ContinuedProcessing")
    private var lastProgressLogTime: TimeInterval = 0
    var expirationHandler: (() -> Void)?

    init(task: BGContinuedProcessingTask) {
        self.task = task
        reportedProgress = ContinuedProcessingProgress(progress: task.progress)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.log.notice("task=\(self.task.identifier, privacy: .public) event=expired")
                self.expirationHandler?()
            }
        }
        log.notice("task=\(task.identifier, privacy: .public) event=launched")
    }

    func update(progress: Double, subtitle: String) {
        reportedProgress.update(progress)
        task.updateTitle(task.title, subtitle: subtitle)
        logProgressIfNeeded()
    }

    func advanceForWork() {
        reportedProgress.advanceForWork()
        logProgressIfNeeded()
    }

    private func logProgressIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgressLogTime >= 10 else { return }
        lastProgressLogTime = now
        log.notice("task=\(self.task.identifier, privacy: .public) event=progress completed=\(self.task.progress.completedUnitCount) total=\(self.task.progress.totalUnitCount)")
    }

    func complete(success: Bool) {
        task.expirationHandler = nil
        reportedProgress.complete(success: success)
        log.notice("task=\(self.task.identifier, privacy: .public) event=completed success=\(success)")
        task.setTaskCompleted(success: success)
    }
}
#endif

/// A saved-audio job owns one assertion independently of the recording final flush.
@MainActor
final class SavedTranscriptionContinuation {
    private let driver: (any ContinuedProcessingDriver)?
    private var identifier: String?
    private var handle: (any ContinuedProcessingHandle)?
    private var finished = false
    private var progress: Double = 0
    private var heartbeat: DecodeWorkHeartbeat
    private let heartbeatInterval: Duration
    private var heartbeatTask: Task<Void, Never>?
    var isAvailable: Bool { !finished && (identifier != nil || handle != nil) }

    init(
        driver: (any ContinuedProcessingDriver)?,
        title: String,
        decodeWork: @escaping () -> UInt64 = { 0 },
        heartbeatInterval: Duration = .seconds(1),
        onExpiration: @escaping () -> Void
    ) {
        self.driver = driver
        heartbeat = DecodeWorkHeartbeat(decodeWork: decodeWork)
        self.heartbeatInterval = heartbeatInterval
        let submitted = driver?.submit(title: "Transcribing saved audio", subtitle: title) { [weak self] handle in
            guard let self, !self.finished else {
                handle.complete(success: false)
                return
            }
            debugLog("Saved transcription background task launched")
            self.identifier = nil
            self.handle = handle
            handle.expirationHandler = { [weak self] in
                guard let self, !self.finished else { return }
                debugLog("Saved transcription background task expired")
                onExpiration()
                self.finish(success: false)
            }
            self.update(progress: self.progress)
            self.startHeartbeat()
        }
        if handle == nil, !finished { identifier = submitted }
        debugLog("Saved transcription background request accepted: \(isAvailable)")
    }

    func update(progress: Double) {
        self.progress = progress.isFinite ? min(max(progress, 0), 0.99) : 0
        handle?.update(progress: self.progress, subtitle: "\(Int(self.progress * 100))% transcribed")
    }

    private func startHeartbeat() {
        heartbeatTask = Task { @MainActor [weak self, heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                if self.heartbeat.decoderAdvanced() { self.handle?.advanceForWork() }
            }
        }
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let identifier { driver?.cancel(identifier: identifier) }
        identifier = nil
        handle?.expirationHandler = nil
        handle?.complete(success: success)
        handle = nil
        debugLog("Saved transcription background task finished; success: \(success)")
    }
}
