import Combine
import Foundation
import Network
import os

/// What the app shows about the English & European model while it is not on
/// the device yet.
enum EnglishModelDownloadDisplay: Equatable {
    /// The model is in, or this device cannot download it: nothing to show.
    case hidden
    case downloading(percent: Int)
    /// Waits for Wi‑Fi, with a button to download now over any network.
    case waitingForWiFi(bytes: Int64)
}

/// The rules for the English & European model's download.
enum EnglishModelDownloadPolicy {
    /// Automatic downloads take Wi‑Fi or Ethernet only: never cellular or a
    /// personal hotspot (an expensive path), nor anything in Low Data Mode (a
    /// constrained path). Downloading now on the user's word takes any network.
    static func allowsAutomaticDownload(isOnline: Bool, isExpensive: Bool, isConstrained: Bool) -> Bool {
        isOnline && !isExpensive && !isConstrained
    }

    /// `progress` is non-nil while a download runs.
    static func display(isSupported: Bool, isReady: Bool, progress: Double?, downloadSize: Int64?) -> EnglishModelDownloadDisplay {
        guard isSupported, !isReady else { return .hidden }
        if let progress {
            // Never 100% before the files are usable.
            let percent = Int((min(max(progress, 0), 1) * 100).rounded(.down))
            return .downloading(percent: min(percent, 99))
        }
        return .waitingForWiFi(bytes: downloadSize ?? EnglishModelAssetPack.fallbackDownloadSize)
    }

    /// The download size the way the waiting line shows it: in tens of MB
    /// ("630 MB"), as an exact figure only suggests a precision it lacks.
    static func sizeText(bytes: Int64) -> String {
        let roundedBytes = Int64((Double(bytes) / 10_000_000).rounded()) * 10_000_000
        return ByteCountFormatter.string(fromByteCount: max(roundedBytes, 10_000_000), countStyle: .file)
    }
}

/// Follows and asks for the download of the English & European model
/// (Parakeet Ultra) on iPhone and iPad, where it is an Apple-hosted asset
/// pack (`EnglishModelAssetPack`). The system starts it while the app
/// installs; when that did not happen or broke off, the app asks again on
/// Wi‑Fi, or on any network when the user taps Download now. Until the model
/// is in, Qwen3-ASR does its work; notes already written are not
/// transcribed again once it arrives.
@MainActor
final class EnglishModelDownload: ObservableObject {
    static let shared = EnglishModelDownload()

    nonisolated private static let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "EnglishModelPack")

    @Published private(set) var isReady: Bool
    /// 0...1 while a download runs, nil otherwise.
    @Published private(set) var progress: Double?
    @Published private(set) var downloadSize: Int64?

    let isSupported: Bool
    private let isModelAvailable: () -> Bool
    private let ensureAvailability: () async throws -> Void
    private let setUserRequested: (Bool) -> Void

    private var isOnline = false
    private var isExpensive = true
    private var isConstrained = true
    private var request: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    /// An automatic request already failed on this network; the next one
    /// waits for the network to change or the app to come back.
    private var automaticAttemptFailed = false

    var display: EnglishModelDownloadDisplay {
        EnglishModelDownloadPolicy.display(
            isSupported: isSupported, isReady: isReady, progress: progress, downloadSize: downloadSize)
    }

    init(
        isSupported: Bool = EnglishModelAssetPack.isSupported,
        isModelAvailable: @escaping () -> Bool = { ParakeetEnglishEngine.isAvailable },
        ensureAvailability: @escaping () async throws -> Void = EnglishModelDownload.systemEnsureAvailability,
        setUserRequested: @escaping (Bool) -> Void = EnglishModelAssetPack.setUserRequestedDownload
    ) {
        self.isSupported = isSupported
        self.isModelAvailable = isModelAvailable
        self.ensureAvailability = ensureAvailability
        self.setUserRequested = setUserRequested
        self.isReady = isModelAvailable()
    }

    nonisolated static func systemEnsureAvailability() async throws {
        #if canImport(BackgroundAssets) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) {
            try await EnglishModelAssetPack.ensureLocalAvailability()
            return
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }

    /// Starts following the download: at launch and whenever the app comes
    /// back to the foreground. Does nothing once the model is in.
    func start() {
        guard isSupported, !AppRuntime.isRunningTests else { return }
        refreshReady()
        guard !isReady else { return }
        automaticAttemptFailed = false
        watchSystemDownload()
        watchNetwork()
        requestAutomaticallyIfAllowed()
    }

    /// The user asked for the model now, on whatever network there is.
    func downloadNow() {
        guard isSupported, !isReady else { return }
        setUserRequested(true)
        request(byUser: true)
    }

    // MARK: Network

    /// The network changed. Tests call it directly.
    func networkChanged(isOnline: Bool, isExpensive: Bool, isConstrained: Bool) {
        let changed = (isOnline, isExpensive, isConstrained) != (self.isOnline, self.isExpensive, self.isConstrained)
        self.isOnline = isOnline
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        if changed { automaticAttemptFailed = false }
        requestAutomaticallyIfAllowed()
    }

    private func watchNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                EnglishModelDownload.shared.networkChanged(
                    isOnline: online, isExpensive: expensive, isConstrained: constrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.hellotaotao.Voicely.englishModelNetwork"))
        self.monitor = monitor
    }

    // MARK: Requests

    private func requestAutomaticallyIfAllowed() {
        guard isSupported, !isReady, request == nil, !automaticAttemptFailed,
              EnglishModelDownloadPolicy.allowsAutomaticDownload(
                isOnline: isOnline, isExpensive: isExpensive, isConstrained: isConstrained) else { return }
        request(byUser: false)
    }

    private func request(byUser: Bool) {
        guard request == nil else { return }
        if progress == nil { progress = 0 }
        Self.log.notice("event=request byUser=\(byUser) online=\(self.isOnline) expensive=\(self.isExpensive) constrained=\(self.isConstrained)")
        request = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureAvailability()
                Self.log.notice("event=requestFinished")
            } catch {
                Self.log.error("event=requestFailed error=\(String(describing: error), privacy: .public)")
                if !byUser { self.automaticAttemptFailed = true }
            }
            self.request = nil
            self.refreshReady()
            if !self.isReady { self.progress = nil }
        }
    }

    /// Waits for the request in flight. Tests only.
    func waitForRequest() async {
        await request?.value
    }

    // MARK: System status

    private func watchSystemDownload() {
        #if canImport(BackgroundAssets) && !targetEnvironment(macCatalyst)
        guard #available(iOS 26, *), watching == nil else { return }
        watching = Task { [weak self] in
            if let size = await EnglishModelAssetPack.downloadSize() {
                self?.downloadSize = size
            }
            for await event in EnglishModelAssetPack.statusUpdates() {
                self?.apply(event)
            }
        }
        #endif
    }

    /// One step the system reported. Tests call it directly.
    func apply(_ event: EnglishModelDownloadEvent) {
        switch event {
        case .progress(let fraction):
            if !isReady { progress = fraction }
        case .paused, .failed:
            // A request in flight still shows as downloading.
            if request == nil { progress = nil }
        case .finished:
            refreshReady()
        }
    }

    private func refreshReady() {
        guard !isReady else { return }
        guard isModelAvailable() else { return }
        isReady = true
        progress = nil
        setUserRequested(false)
        monitor?.cancel()
        monitor = nil
        watching?.cancel()
        watching = nil
        Self.log.notice("event=modelReady")
    }
}
