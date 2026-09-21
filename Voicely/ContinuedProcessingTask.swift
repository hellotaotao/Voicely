//
//  ContinuedProcessingTask.swift
//  Voicely
//

import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

/// A running system task that lets user-started work continue after the app
/// leaves the foreground (iOS 26 continued processing).
@MainActor
protocol ContinuedProcessingHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func update(progress: Double, subtitle: String)
    func complete(success: Bool)
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
            guard registered else { return nil }

            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            pendingLaunches[identifier] = launch
            do {
                try BGTaskScheduler.shared.submit(request)
                return identifier
            } catch {
                pendingLaunches.removeValue(forKey: identifier)
                return nil
            }
        }
        #endif
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
    var expirationHandler: (() -> Void)?

    init(task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = 10_000
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expirationHandler?() }
        }
    }

    func update(progress: Double, subtitle: String) {
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, Int64(progress * 10_000))
        task.updateTitle(task.title, subtitle: subtitle)
    }

    func complete(success: Bool) {
        task.expirationHandler = nil
        if success {
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
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
    var isAvailable: Bool { !finished && (identifier != nil || handle != nil) }

    init(driver: (any ContinuedProcessingDriver)?, title: String, onExpiration: @escaping () -> Void) {
        self.driver = driver
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
        }
        if handle == nil, !finished { identifier = submitted }
        debugLog("Saved transcription background request accepted: \(isAvailable)")
    }

    func update(progress: Double) {
        self.progress = progress.isFinite ? min(max(progress, 0), 0.99) : 0
        handle?.update(progress: self.progress, subtitle: "\(Int(self.progress * 100))% transcribed")
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if let identifier { driver?.cancel(identifier: identifier) }
        identifier = nil
        handle?.expirationHandler = nil
        handle?.complete(success: success)
        handle = nil
        debugLog("Saved transcription background task finished; success: \(success)")
    }
}
