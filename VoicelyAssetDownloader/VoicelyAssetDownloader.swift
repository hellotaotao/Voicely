import BackgroundAssets
import ExtensionFoundation
import Foundation
import Network
import os
import StoreKit

/// Schedules the Apple-hosted asset packs (the English & European speech
/// model, see `EnglishModelAssetPack` in the app) while Voicely is not
/// running. The system downloads the pack on its own while the app installs;
/// this only holds that back from cellular and Low Data Mode, unless the user
/// tapped Download now in the app.
@main
struct VoicelyAssetDownloader: StoreDownloaderExtension {
    private static let log = Logger(subsystem: "com.hellotaotao.Voicely.AssetDownloader", category: "Download")
    /// Same as `EnglishModelAssetPack.appGroupID` and `.userRequestedKey`.
    private static let appGroupID = "group.com.hellotaotao.Voicely"
    private static let userRequestedKey = "EnglishModelDownloadRequestedByUser"

    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        if UserDefaults(suiteName: Self.appGroupID)?.bool(forKey: Self.userRequestedKey) == true {
            Self.log.notice("event=shouldDownload pack=\(assetPack.id, privacy: .public) allowed=true reason=userRequested")
            return true
        }
        let path = Self.currentPath()
        // Unknown counts as not allowed: the app asks again once it is open on Wi‑Fi.
        let allowed = path.map { $0.status == .satisfied && !$0.isExpensive && !$0.isConstrained } ?? false
        Self.log.notice("event=shouldDownload pack=\(assetPack.id, privacy: .public) allowed=\(allowed) expensive=\(path?.isExpensive ?? true) constrained=\(path?.isConstrained ?? true)")
        return allowed
    }

    /// The network path right now, or nil when none arrives within `timeout`.
    private static func currentPath(timeout: TimeInterval = 2) -> NWPath? {
        let monitor = NWPathMonitor()
        let found = OSAllocatedUnfairLock<NWPath?>(initialState: nil)
        let arrived = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            found.withLock { if $0 == nil { $0 = path } }
            arrived.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.hellotaotao.Voicely.AssetDownloader.network"))
        _ = arrived.wait(timeout: .now() + timeout)
        monitor.cancel()
        return found.withLock { $0 }
    }
}
