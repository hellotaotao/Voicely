import Foundation
import os
import UIKit

/// The first load of a CoreML model after the app or the system changes
/// compiles it for the Neural Engine: Qwen3-ASR about 20 s and Parakeet
/// 14 s in the foreground on an iPhone 17 Pro, Parakeet about 100 s while
/// locked. Each model is loaded once while the app is open and idle, from
/// the first launch's onboarding on, so that compile never falls to a
/// transcription on the lock screen. Any successful load counts, such as
/// Qwen3-ASR's at launch.
enum ModelWarmUp {
    enum Model: String, CaseIterable {
        case qwen3
        case parakeet
    }

    /// Nil in tests, which never warm up and must not touch the app's settings.
    nonisolated(unsafe) private static let defaults: UserDefaults? = AppRuntime.isRunningTests ? nil : .standard

    nonisolated static func defaultsKey(_ model: Model) -> String {
        "VoicelyModelWarmedFor.\(model.rawValue)"
    }

    /// The app build and system build a compiled model belongs to.
    nonisolated static var currentStamp: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)(\(build))|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// Records that `model` loaded under the current app and system.
    nonisolated static func markLoaded(_ model: Model) {
        guard let defaults, defaults.string(forKey: defaultsKey(model)) != currentStamp else { return }
        defaults.set(currentStamp, forKey: defaultsKey(model))
    }

    /// Whether `model` has not loaded since the app or the system changed.
    /// The system may still drop a compiled model on its own; that load is
    /// then slow once, as before.
    nonisolated static func needsWarmUp(_ model: Model) -> Bool {
        guard let defaults else { return false }
        return defaults.string(forKey: defaultsKey(model)) != currentStamp
    }
}

/// Runs the warm-up loads one model at a time, only while the app is in the
/// foreground and nothing records, transcribes or loads. A recording that
/// starts meanwhile goes first: no new load starts until it is done, and a
/// load already running finishes and is let go.
@MainActor
final class ModelWarmUpRunner {
    static let shared = ModelWarmUpRunner()

    nonisolated private static let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "Memory")

    private var task: Task<Void, Never>?

    /// Starts the warm-up unless it runs or has nothing to do. Called at
    /// launch and whenever the app comes back to the foreground.
    func start(transcriptionService: TranscriptionService, isRecordingBusy: @escaping @MainActor () -> Bool) {
        guard task == nil, !AppRuntime.isIsolatedFromUserData else { return }
        guard !pendingModels(transcriptionService).isEmpty else { return }
        task = Task { @MainActor [weak self] in
            await self?.run(transcriptionService: transcriptionService, isRecordingBusy: isRecordingBusy)
            self?.task = nil
        }
    }

    /// Qwen3-ASR only on CoreML: MLX on the Mac compiles nothing ahead.
    private func pendingModels(_ service: TranscriptionService) -> [ModelWarmUp.Model] {
        ModelWarmUp.Model.allCases.filter { model in
            switch model {
            case .qwen3:
                return service.modelManager?.backend == .coreML && ModelWarmUp.needsWarmUp(.qwen3)
            case .parakeet:
                return ParakeetEnglishEngine.isAvailable && ModelWarmUp.needsWarmUp(.parakeet)
            }
        }
    }

    private func run(transcriptionService: TranscriptionService, isRecordingBusy: @escaping @MainActor () -> Bool) async {
        while let model = pendingModels(transcriptionService).first {
            // Waits for a quiet moment in the foreground.
            while !(UIApplication.shared.applicationState == .active
                    && transcriptionService.isIdleForWarmUp && !isRecordingBusy()) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
            }
            let started = ProcessInfo.processInfo.systemUptime
            switch model {
            case .qwen3:
                await transcriptionService.warmUpQwen()
            case .parakeet:
                await ParakeetEnglishEngine.shared.warmUp()
            }
            Self.log.notice("event=warmUp model=\(model.rawValue, privacy: .public) seconds=\(ProcessInfo.processInfo.systemUptime - started) done=\(!ModelWarmUp.needsWarmUp(model)) \(MemoryFootprint.summary, privacy: .public)")
            // A load that failed is not retried until the next launch or return.
            if ModelWarmUp.needsWarmUp(model) { return }
        }
    }
}
