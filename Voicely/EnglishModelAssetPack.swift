import Foundation
import os
#if canImport(BackgroundAssets) && !targetEnvironment(macCatalyst)
import BackgroundAssets
import System
#endif

/// Parakeet Ultra as an Apple-hosted asset pack on iPhone and iPad (iOS 26
/// and later). The Mac app and every Debug build still carry the model in
/// their resources (scripts/embed-speech-model.sh), so this only matters to
/// iOS Release builds. The pack is uploaded to App Store Connect separately
/// from the app (scripts/package-english-model-pack.sh) with a prefetch
/// policy: the system starts downloading it while the app installs, and the
/// app's downloader extension (VoicelyAssetDownloader) holds automatic
/// downloads back from cellular and Low Data Mode.
enum EnglishModelAssetPack {
    nonisolated private static let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "EnglishModelPack")

    /// The pack's ID in App Store Connect and in the manifest.
    nonisolated static let id = "EnglishSpeechModel"
    /// The folder the pack's files sit in, the same name as the bundled folder.
    nonisolated static let folderName = "EnglishSpeechModel"
    /// The app group the app and the downloader extension share
    /// (`BAAppGroupID` in Info.plist).
    nonisolated static let appGroupID = "group.com.hellotaotao.Voicely"
    /// Set in the app group's defaults when the user asks to download now, so
    /// the downloader extension lets that download use cellular.
    nonisolated static let userRequestedKey = "EnglishModelDownloadRequestedByUser"
    /// The pack's download size when the system has not said, in bytes: the
    /// archive scripts/package-english-model-pack.sh made of the 632 MB
    /// model folder on 2026-11-23.
    nonisolated static let fallbackDownloadSize: Int64 = 562_770_559

    /// Whether this device gets the model as an asset pack at all.
    nonisolated static var isSupported: Bool {
        #if canImport(BackgroundAssets) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }

    nonisolated private static let resolvedDirectory = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// The downloaded model folder, nil until the pack is on the device.
    nonisolated static func localDirectory() -> URL? {
        if let cached = resolvedDirectory.withLock({ $0 }) { return cached }
        #if canImport(BackgroundAssets) && !targetEnvironment(macCatalyst)
        guard #available(iOS 26, *) else { return nil }
        // The system hands the app only the items it asks for: asking for
        // one file of the folder stages that file alone (seen on an iPhone,
        // 1.3.0 build 14), so ask for the whole folder.
        let directory: URL
        do {
            directory = try AssetPackManager.shared.url(for: FilePath(folderName))
        } catch {
            log.notice("event=localDirectoryMissing error=\(String(describing: error), privacy: .public)")
            return nil
        }
        guard ParakeetEnglishEngine.isComplete(directory) else {
            let present = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            log.error("event=localDirectoryIncomplete path=\(directory.path, privacy: .public) items=\(present.sorted().joined(separator: ","), privacy: .public)")
            return nil
        }
        resolvedDirectory.withLock { $0 = directory }
        return directory
        #else
        return nil
        #endif
    }

    /// Forgets the folder found before, after the pack was removed or updated.
    nonisolated static func forgetLocalDirectory() {
        resolvedDirectory.withLock { $0 = nil }
    }

    nonisolated private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Lets the downloader extension take cellular for this pack (true), or
    /// back to Wi‑Fi only once the model is in (false).
    nonisolated static func setUserRequestedDownload(_ requested: Bool) {
        sharedDefaults?.set(requested, forKey: userRequestedKey)
    }

    #if canImport(BackgroundAssets) && !targetEnvironment(macCatalyst)
    /// The pack's download size as App Store Connect lists it.
    @available(iOS 26, *)
    static func downloadSize() async -> Int64? {
        guard let pack = try? await assetPack() else { return nil }
        return Int64(pack.downloadSize)
    }

    @available(iOS 26, *)
    private static func assetPack() async throws -> AssetPack {
        if #available(iOS 27, *) {
            guard let pack = try await AssetPackManager.shared.manifest.assetPack(withID: id) else {
                throw ManagedBackgroundAssetsError.assetPackNotFound(withID: id)
            }
            return pack
        }
        return try await AssetPackManager.shared.assetPack(withID: id)
    }

    /// Downloads the pack unless it is already on the device, and returns
    /// once it is. A download the system already runs is joined, not started again.
    @available(iOS 26, *)
    static func ensureLocalAvailability() async throws {
        let pack = try await assetPack()
        if #available(iOS 26.4, *) {
            try await AssetPackManager.shared.ensureLocalAvailability(of: pack, requireLatestVersion: false)
        } else {
            try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
        }
        forgetLocalDirectory()
    }

    /// What the system reports about the pack's download, as it happens.
    @available(iOS 26, *)
    static func statusUpdates() -> AsyncStream<EnglishModelDownloadEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: id) {
                    switch update {
                    case .began:
                        continuation.yield(.progress(0))
                    case .downloading(_, let progress):
                        continuation.yield(.progress(progress.fractionCompleted))
                    case .paused:
                        continuation.yield(.paused)
                    case .finished:
                        forgetLocalDirectory()
                        continuation.yield(.finished)
                    case .failed(_, let error):
                        log.error("download failed: \(String(describing: error), privacy: .public)")
                        continuation.yield(.failed)
                    @unknown default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}

/// A step of the pack's download as the app sees it.
enum EnglishModelDownloadEvent: Equatable, Sendable {
    case progress(Double)
    case paused
    case finished
    case failed
}
