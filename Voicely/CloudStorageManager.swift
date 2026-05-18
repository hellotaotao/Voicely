//
//  CloudStorageManager.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ImportedAudioFile {
    let filePath: String
    let title: String
    let fileURL: URL
}

enum AudioImportError: LocalizedError {
    case unsupportedFileType(URL)
    case copyFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let url):
            return "Unsupported audio file type: \(url.lastPathComponent)"
        case .copyFailed(let error):
            return "Failed to import audio file: \(error.localizedDescription)"
        }
    }
}

@MainActor
class CloudStorageManager: ObservableObject {
    static let shared = CloudStorageManager()
    private static let localToCloudMigrationDefaultsKey = "VoicelyLocalToCloudMigrationV1"
    
    @Published var isCloudEnabled = false
    @Published var isSyncing = false
    @Published var syncStatus: SyncStatus = .idle
    @Published var pendingUploads = 0
    @Published var pendingDownloads = 0
    
    private let fileManager = FileManager.default
    private let cloudContainerIdentifier = "iCloud.com.hellotaotao.Voicely"
    private let audioDirectoryName = "AudioRecordings"
    // Sync audio files via iCloud Documents to keep data consistent across devices.
    private let syncAudioFiles = true

    private var cloudContainerURL: URL?
    private var localContainerURL: URL?
    private var metadataQuery: NSMetadataQuery?
    private var syncStatusUpdateTask: Task<Void, Never>?
    
    enum SyncStatus: Equatable {
        case idle
        case checking
        case uploading(Int)
        case downloading(Int) 
        case error(String)
    }
    
    private init() {
        setupLocalContainer()
        guard !AppRuntime.isRunningTests else { return }
        setupCloudContainer()
        setupMetadataQuery()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudIdentityDidChange),
            name: .NSUbiquityIdentityDidChange,
            object: nil
        )
    }

    @objc private func iCloudIdentityDidChange() {
        Task { @MainActor in
            let wasEnabled = isCloudEnabled
            setupCloudContainer()
            if isCloudEnabled && !wasEnabled {
                setupMetadataQuery()
                await migrateLocalFilesToCloudIfNeeded()
            } else if !isCloudEnabled && wasEnabled {
                tearDownMetadataQuery()
                cloudContainerURL = nil
                UserDefaults.standard.removeObject(forKey: Self.localToCloudMigrationDefaultsKey)
            }
        }
    }

#if DEBUG
    init(
        testLocalContainerURL: URL,
        testCloudContainerURL: URL? = nil,
        testCloudEnabled: Bool = false
    ) {
        localContainerURL = testLocalContainerURL
        cloudContainerURL = testCloudContainerURL
        isCloudEnabled = testCloudEnabled
    }
#endif

    private func setupLocalContainer() {
        let localURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        localContainerURL = localURL
        if !AppRuntime.isRunningTests {
            print("Local audio directory: \(localURL.path)")
        }
    }
    
    private func setupCloudContainer() {
        guard syncAudioFiles else {
            isCloudEnabled = false
            UserDefaults.standard.removeObject(forKey: Self.localToCloudMigrationDefaultsKey)
            print("iCloud audio sync disabled - using local storage only")
            return
        }

        debugLog("🔍 [DEBUG] Attempting to setup iCloud container with identifier: \(cloudContainerIdentifier)")
        
        if let url = fileManager.url(forUbiquityContainerIdentifier: cloudContainerIdentifier) {
            let cloudURL = url.appendingPathComponent("Documents/\(audioDirectoryName)", isDirectory: true)
            cloudContainerURL = cloudURL
            isCloudEnabled = true
            
            debugLog("✅ [DEBUG] iCloud container URL obtained: \(url.path)")
            debugLog("✅ [DEBUG] Cloud audio directory path: \(cloudURL.path)")

            createDirectoryIfNeeded(at: cloudURL, excludeFromBackup: false)
            print("iCloud Documents enabled for audio files: \(cloudURL.path)")
            
            // Check iCloud account status
            checkiCloudAccountStatus()
        } else {
            debugLog("❌ [DEBUG] Failed to obtain iCloud container URL")
            debugLog("❌ [DEBUG] Possible causes:")
            print("   - iCloud Drive not enabled in System Settings")
            print("   - Not signed into iCloud account")
            print("   - App entitlements not properly configured")
            print("   - Container identifier mismatch")
            print("iCloud Documents not available - check entitlements and Apple ID")
            isCloudEnabled = false
            cloudContainerURL = nil
            UserDefaults.standard.removeObject(forKey: Self.localToCloudMigrationDefaultsKey)
        }
    }
    
    private func checkiCloudAccountStatus() {
        debugLog("🔍 [DEBUG] Checking iCloud account status...")
        
        FileManager.default.ubiquityIdentityToken != nil ?
            debugLog("✅ [DEBUG] iCloud account is available and signed in") :
            debugLog("⚠️ [DEBUG] iCloud account token is nil - user may not be signed in")
    }

    private func createDirectoryIfNeeded(at url: URL, excludeFromBackup: Bool) {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                print("Created audio directory: \(url.path)")
            } catch {
                print("Failed to create audio directory: \(error)")
            }
        }

        if excludeFromBackup {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try mutableURL.setResourceValues(values)
            } catch {
                print("Failed to exclude audio directory from backup: \(error)")
            }
        }
    }
    
    // Get the appropriate directory for storing audio files
    func getAudioStorageDirectory() -> URL {
        if syncAudioFiles, isCloudEnabled, let cloudURL = cloudContainerURL {
            createDirectoryIfNeeded(at: cloudURL, excludeFromBackup: false)
            return cloudURL
        }

        if let localURL = localContainerURL {
            createDirectoryIfNeeded(at: localURL, excludeFromBackup: false)
            return localURL
        }

        // Fallback to local documents directory
        return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    // Generate a unique filename for audio recording
    func generateAudioFilename() -> URL {
        let directory = getAudioStorageDirectory()
        let filename = "recording_\(Date().timeIntervalSince1970).m4a"
        return directory.appendingPathComponent(filename)
    }

    static func isSupportedImportedAudioURL(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        if supportedImportedAudioFileExtensions.contains(fileExtension) {
            return true
        }

        if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .audio) {
            return true
        }

        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           contentType.conforms(to: .audio) {
            return true
        }

        return false
    }

    func importAudioFile(from sourceURL: URL) throws -> ImportedAudioFile {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard Self.isSupportedImportedAudioURL(sourceURL) else {
            throw AudioImportError.unsupportedFileType(sourceURL)
        }

        let destinationDirectory = getAudioStorageDirectory()
        createDirectoryIfNeeded(at: destinationDirectory, excludeFromBackup: false)

        let destinationURL = importedAudioDestinationURL(for: sourceURL, in: destinationDirectory)
        var coordinationError: NSError?
        var copyError: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [.withoutChanges],
            error: &coordinationError
        ) { readableURL in
            do {
                try fileManager.copyItem(at: readableURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            throw AudioImportError.copyFailed(coordinationError)
        }

        if let copyError {
            throw AudioImportError.copyFailed(copyError)
        }

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            throw AudioImportError.copyFailed(CocoaError(.fileNoSuchFile))
        }

        return ImportedAudioFile(
            filePath: destinationURL.lastPathComponent,
            title: importedAudioTitle(for: sourceURL),
            fileURL: destinationURL
        )
    }

    private static let supportedImportedAudioFileExtensions: Set<String> = [
        "aac",
        "aif",
        "aiff",
        "caf",
        "m4a",
        "m4b",
        "mp3",
        "wav",
        "wave"
    ]

    private func importedAudioDestinationURL(for sourceURL: URL, in directory: URL) -> URL {
        let title = importedAudioTitle(for: sourceURL)
        let baseName = sanitizedImportedAudioBaseName(title)
        let fileExtension = normalizedAudioFileExtension(for: sourceURL)
        let filename = "\(baseName)_\(UUID().uuidString).\(fileExtension)"
        return directory.appendingPathComponent(filename)
    }

    private func importedAudioTitle(for sourceURL: URL) -> String {
        let title = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Imported Audio" : title
    }

    private func normalizedAudioFileExtension(for sourceURL: URL) -> String {
        let fileExtension = sourceURL.pathExtension.lowercased()
        return fileExtension.isEmpty ? "m4a" : fileExtension
    }

    private func sanitizedImportedAudioBaseName(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let parts = title
            .components(separatedBy: invalidCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sanitizedTitle = parts.joined(separator: " ")
        return sanitizedTitle.isEmpty ? "Imported Audio" : sanitizedTitle
    }
    
    // Move existing local files to iCloud
    func migrateLocalFilesToCloud() async {
        await migrateLocalFilesToCloudIfNeeded(force: true)
    }

    // Run local-to-cloud migration only once unless forced.
    func migrateLocalFilesToCloudIfNeeded(force: Bool = false) async {
        guard syncAudioFiles, isCloudEnabled, let cloudURL = cloudContainerURL else { return }

        if !force, UserDefaults.standard.bool(forKey: Self.localToCloudMigrationDefaultsKey) {
            return
        }

        let localURL = localContainerURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        do {
            let report = try await Task.detached(priority: .utility) {
                try Self.performLocalToCloudMigration(localURL: localURL, cloudURL: cloudURL)
            }.value

            UserDefaults.standard.set(true, forKey: Self.localToCloudMigrationDefaultsKey)

            if report.migratedCount > 0 {
                print("Migrated \(report.migratedCount) legacy local file(s) to iCloud")
            } else {
                debugLog("🔍 [DEBUG] No legacy local audio files needed migration")
            }
        } catch {
            print("Failed to migrate files: \(error)")
        }
    }
    
    // Check if a file exists in cloud storage
    func fileExistsInCloud(filename: String) -> Bool {
        guard syncAudioFiles, isCloudEnabled, let cloudURL = cloudContainerURL else { return false }
        let fileURL = cloudURL.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: fileURL.path)
    }
    
    // Get the full URL for a file
    func getFileURL(for path: String) -> URL? {
        guard !path.isEmpty else {
            debugLog("⚠️ [DEBUG] getFileURL called with empty path")
            return nil
        }
        
        debugLog("🔍 [DEBUG] Getting file URL for path: \(path)")
        
        // If it's already a full path, convert to URL
        if path.starts(with: "/") {
            let url = URL(fileURLWithPath: path)
            // Check if the file exists at this absolute path
            if fileManager.fileExists(atPath: url.path) {
                debugLog("✅ [DEBUG] File exists at absolute path: \(url.path)")
                return url
            } else {
                debugLog("⚠️ [DEBUG] File NOT found at absolute path: \(url.path)")
                debugLog("🔍 [DEBUG] Trying as filename in current storage directory...")
                // File doesn't exist at absolute path, try as filename in current storage directory
                let filename = url.lastPathComponent
                let alternativeURL = getAudioStorageDirectory().appendingPathComponent(filename)
                debugLog("🔍 [DEBUG] Alternative URL: \(alternativeURL.path)")
                return alternativeURL
            }
        }
        
        // Otherwise, construct the URL from filename
        let directory = getAudioStorageDirectory()
        let resultURL = directory.appendingPathComponent(path)
        debugLog("🔍 [DEBUG] Constructed URL from filename: \(resultURL.path)")
        
        // Check file accessibility
        do {
            let attributes = try fileManager.attributesOfItem(atPath: resultURL.path)
            debugLog("✅ [DEBUG] File accessible, size: \(attributes[.size] ?? "unknown") bytes")
        } catch {
            debugLog("⚠️ [DEBUG] File access check failed: \(error.localizedDescription)")
            if (error as NSError).code == 257 {
                debugLog("❌ [DEBUG] Permission denied (Error 257) - iCloud sync issue detected")
            }
        }
        
        return resultURL
    }
    
    // Start downloading a file from iCloud if needed
    func startDownloadingFromCloud(url: URL) {
        guard syncAudioFiles, isCloudEnabled else {
            debugLog("🔍 [DEBUG] Skipping iCloud download check (syncAudioFiles: \(syncAudioFiles), isCloudEnabled: \(isCloudEnabled))")
            return
        }

        guard isCloudManagedURL(url) else {
            return
        }
        
        debugLog("🔍 [DEBUG] Checking iCloud download status for: \(url.lastPathComponent)")
        
        do {
            var isDownloaded: AnyObject?
            try (url as NSURL).getResourceValue(&isDownloaded, forKey: .ubiquitousItemDownloadingStatusKey)
            
            if let status = isDownloaded as? String {
                debugLog("🔍 [DEBUG] iCloud download status: \(status)")
                
                if status != URLUbiquitousItemDownloadingStatus.current.rawValue {
                    debugLog("⬇️ [DEBUG] File not fully downloaded, starting download...")
                    try fileManager.startDownloadingUbiquitousItem(at: url)
                    print("Started downloading file from iCloud: \(url.lastPathComponent)")
                } else {
                    debugLog("✅ [DEBUG] File already downloaded from iCloud")
                }
            } else {
                debugLog("⚠️ [DEBUG] Could not determine iCloud download status")
            }
        } catch {
            debugLog("❌ [DEBUG] Error checking download status: \(error)")
            if (error as NSError).code == 257 {
                debugLog("❌ [DEBUG] Permission denied (Error 257) accessing iCloud file")
            }
        }
    }

    func prepareFileForReading(at path: String, timeout: TimeInterval = 90) async -> URL? {
        guard let url = getFileURL(for: path) else { return nil }

        startDownloadingFromCloud(url: url)

        guard isCloudManagedURL(url) else {
            return isFileReadyForReading(url) ? url : nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return nil
            }
            if isFileReadyForReading(url) {
                debugLog("✅ [DEBUG] File ready for reading: \(url.lastPathComponent)")
                return url
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if Task.isCancelled {
            return nil
        }

        if isFileReadyForReading(url) {
            debugLog("✅ [DEBUG] File ready for reading after wait: \(url.lastPathComponent)")
            return url
        }

        debugLog("❌ [DEBUG] Timed out waiting for file to become readable: \(url.lastPathComponent)")
        return nil
    }

    func isFileReadyForPlayback(at url: URL) -> Bool {
        isFileReadyForReading(url)
    }
    
    // Delete a file from storage
    func deleteFile(at path: String) {
        let candidateURLs = deletionCandidateURLs(for: path)
        guard !candidateURLs.isEmpty else { return }

        var deletedPaths: [String] = []
        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
                deletedPaths.append(url.path)
            } catch {
                print("Failed to delete file at \(url.path): \(error)")
            }
        }

        if deletedPaths.isEmpty {
            print("No audio file found to delete for path: \(path)")
        } else {
            print("Deleted file(s): \(deletedPaths.joined(separator: ", "))")
        }
    }
    
    // MARK: - Sync Status Monitoring
    
    private func tearDownMetadataQuery() {
        if let oldQuery = metadataQuery {
            oldQuery.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: oldQuery)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: oldQuery)
            metadataQuery = nil
        }

        syncStatusUpdateTask?.cancel()
        syncStatusUpdateTask = nil
    }

    private func setupMetadataQuery() {
        tearDownMetadataQuery()

        guard syncAudioFiles, isCloudEnabled, let cloudURL = cloudContainerURL else { return }

        metadataQuery = NSMetadataQuery()
        metadataQuery?.searchScopes = [cloudURL]
        metadataQuery?.predicate = NSPredicate(
            format: "(%K LIKE[c] '*.m4a') OR (%K LIKE[c] '*.wav')",
            NSMetadataItemFSNameKey,
            NSMetadataItemFSNameKey
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: metadataQuery
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinishGathering),
            name: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )

        metadataQuery?.start()
    }
    
    @objc private func metadataQueryDidUpdate() {
        scheduleSyncStatusUpdate()
    }
    
    @objc private func metadataQueryDidFinishGathering() {
        scheduleSyncStatusUpdate()
    }

    private func scheduleSyncStatusUpdate() {
        syncStatusUpdateTask?.cancel()
        syncStatusUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.updateSyncStatus()
        }
    }
    
    private func updateSyncStatus() {
        guard let query = metadataQuery else { return }

        query.disableUpdates()
        defer { query.enableUpdates() }

        var uploading = 0
        var downloading = 0
        var hasErrors = false

        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }

            let attrs = item.values(forAttributes: [
                NSMetadataUbiquitousItemDownloadingStatusKey,
                NSMetadataUbiquitousItemIsUploadedKey,
                NSMetadataUbiquitousItemHasUnresolvedConflictsKey
            ])

            if let downloadStatus = attrs?[NSMetadataUbiquitousItemDownloadingStatusKey] as? String,
               downloadStatus == URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue {
                downloading += 1
            }
            if let isUploaded = attrs?[NSMetadataUbiquitousItemIsUploadedKey] as? Bool, !isUploaded {
                uploading += 1
            }
            if let hasConflict = attrs?[NSMetadataUbiquitousItemHasUnresolvedConflictsKey] as? Bool, hasConflict {
                hasErrors = true
            }
        }

        let newStatus: SyncStatus
        if hasErrors {
            newStatus = .error("Sync conflicts detected")
        } else if uploading > 0 {
            newStatus = .uploading(uploading)
        } else if downloading > 0 {
            newStatus = .downloading(downloading)
        } else {
            newStatus = .idle
        }

        let newIsSyncing = uploading > 0 || downloading > 0
        guard pendingUploads != uploading
            || pendingDownloads != downloading
            || syncStatus != newStatus
            || isSyncing != newIsSyncing else {
            return
        }

        pendingUploads = uploading
        pendingDownloads = downloading
        syncStatus = newStatus
        isSyncing = newIsSyncing
    }
    
    // MARK: - Manual Sync Triggers
    
    func refreshSync() async {
        guard isCloudEnabled else { return }
        
        await MainActor.run {
            syncStatus = .checking
        }

        guard let metadataQuery else {
            syncStatus = .idle
            return
        }

        if !metadataQuery.isStarted {
            metadataQuery.start()
        }

        scheduleSyncStatusUpdate()

        // Give iCloud a short window to report fresh metadata, then force one immediate read.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        updateSyncStatus()
    }
    
    func forceDownloadAll() async {
        guard syncAudioFiles, isCloudEnabled, let containerURL = cloudContainerURL else { return }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: [
                .ubiquitousItemDownloadingStatusKey
            ])
            
            for url in contents {
                var downloadStatus: AnyObject?
                try (url as NSURL).getResourceValue(&downloadStatus, forKey: .ubiquitousItemDownloadingStatusKey)
                
                if let status = downloadStatus as? String,
                   status == URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue {
                    try fileManager.startDownloadingUbiquitousItem(at: url)
                    print("Triggered download for: \(url.lastPathComponent)")
                }
            }
        } catch {
            print("Error forcing downloads: \(error)")
        }
    }
    
    func getSyncStatusText() -> String {
        switch syncStatus {
        case .idle:
            return "Synced"
        case .checking:
            return "Checking..."
        case .uploading(let count):
            return "Uploading \(count) files"
        case .downloading(let count):
            return "Downloading \(count) files"
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    deinit {
        syncStatusUpdateTask?.cancel()
        metadataQuery?.stop()
        NotificationCenter.default.removeObserver(self)
    }
}

private extension CloudStorageManager {
    struct LocalToCloudMigrationReport: Sendable {
        let migratedCount: Int
    }

    nonisolated static func performLocalToCloudMigration(localURL: URL, cloudURL: URL) throws -> LocalToCloudMigrationReport {
        let fileManager = FileManager.default
        let localFiles = try fileManager.contentsOfDirectory(
            at: localURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var migratedCount = 0
        for file in localFiles {
            let ext = file.pathExtension.lowercased()
            guard ext == "wav" || ext == "m4a" else {
                continue
            }

            let cloudDestination = cloudURL.appendingPathComponent(file.lastPathComponent)
            if fileManager.fileExists(atPath: cloudDestination.path) {
                continue
            }

            try fileManager.moveItem(at: file, to: cloudDestination)
            migratedCount += 1
        }

        return LocalToCloudMigrationReport(migratedCount: migratedCount)
    }

    func deletionCandidateURLs(for path: String) -> [URL] {
        guard !path.isEmpty else { return [] }

        let nsPath = path as NSString
        let filename = nsPath.lastPathComponent
        var candidateURLs: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL?) {
            guard let url else { return }
            let normalizedURL = url.standardizedFileURL
            guard seenPaths.insert(normalizedURL.path).inserted else { return }
            candidateURLs.append(normalizedURL)
        }

        if nsPath.isAbsolutePath {
            append(URL(fileURLWithPath: path))
        }

        guard !filename.isEmpty else {
            return candidateURLs
        }

        append(localContainerURL?.appendingPathComponent(filename))
        append(cloudContainerURL?.appendingPathComponent(filename))
        append(getAudioStorageDirectory().appendingPathComponent(filename))

        return candidateURLs
    }

    func isCloudManagedURL(_ url: URL) -> Bool {
        guard syncAudioFiles, isCloudEnabled, let cloudContainerURL else {
            return false
        }
        return url.path.hasPrefix(cloudContainerURL.path)
    }

    func isFileReadyForReading(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            return false
        }

        guard isCloudManagedURL(url) else {
            return true
        }

        do {
            var downloadStatus: AnyObject?
            try (url as NSURL).getResourceValue(&downloadStatus, forKey: .ubiquitousItemDownloadingStatusKey)

            guard let status = downloadStatus as? String else {
                return true
            }

            return status == URLUbiquitousItemDownloadingStatus.current.rawValue
        } catch {
            debugLog("❌ [DEBUG] Failed to inspect iCloud download status for \(url.lastPathComponent): \(error)")
            return false
        }
    }
}
