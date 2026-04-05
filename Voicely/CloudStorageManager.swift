//
//  CloudStorageManager.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import SwiftUI

@MainActor
class CloudStorageManager: ObservableObject {
    static let shared = CloudStorageManager()
    
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
    
    enum SyncStatus {
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
            guard !isCloudEnabled else { return }
            setupCloudContainer()
            if isCloudEnabled {
                setupMetadataQuery()
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
            print("iCloud audio sync disabled - using local storage only")
            return
        }

        print("🔍 [DEBUG] Attempting to setup iCloud container with identifier: \(cloudContainerIdentifier)")
        
        if let url = fileManager.url(forUbiquityContainerIdentifier: cloudContainerIdentifier) {
            let cloudURL = url.appendingPathComponent("Documents/\(audioDirectoryName)", isDirectory: true)
            cloudContainerURL = cloudURL
            isCloudEnabled = true
            
            print("✅ [DEBUG] iCloud container URL obtained: \(url.path)")
            print("✅ [DEBUG] Cloud audio directory path: \(cloudURL.path)")

            createDirectoryIfNeeded(at: cloudURL, excludeFromBackup: false)
            print("iCloud Documents enabled for audio files: \(cloudURL.path)")
            
            // Check iCloud account status
            checkiCloudAccountStatus()
        } else {
            print("❌ [DEBUG] Failed to obtain iCloud container URL")
            print("❌ [DEBUG] Possible causes:")
            print("   - iCloud Drive not enabled in System Settings")
            print("   - Not signed into iCloud account")
            print("   - App entitlements not properly configured")
            print("   - Container identifier mismatch")
            print("iCloud Documents not available - check entitlements and Apple ID")
            isCloudEnabled = false
        }
    }
    
    private func checkiCloudAccountStatus() {
        print("🔍 [DEBUG] Checking iCloud account status...")
        
        FileManager.default.ubiquityIdentityToken != nil ?
            print("✅ [DEBUG] iCloud account is available and signed in") :
            print("⚠️ [DEBUG] iCloud account token is nil - user may not be signed in")
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
    
    // Move existing local files to iCloud
    func migrateLocalFilesToCloud() async {
        guard syncAudioFiles, isCloudEnabled, let cloudURL = cloudContainerURL else { return }
        
        let localURL = localContainerURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let localFiles = try fileManager.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil)
            
            for file in localFiles where file.pathExtension == "wav" || file.pathExtension == "m4a" {
                let cloudDestination = cloudURL.appendingPathComponent(file.lastPathComponent)
                
                if !fileManager.fileExists(atPath: cloudDestination.path) {
                    try fileManager.moveItem(at: file, to: cloudDestination)
                    print("Migrated file to iCloud: \(file.lastPathComponent)")
                }
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
            print("⚠️ [DEBUG] getFileURL called with empty path")
            return nil
        }
        
        print("🔍 [DEBUG] Getting file URL for path: \(path)")
        
        // If it's already a full path, convert to URL
        if path.starts(with: "/") {
            let url = URL(fileURLWithPath: path)
            // Check if the file exists at this absolute path
            if fileManager.fileExists(atPath: url.path) {
                print("✅ [DEBUG] File exists at absolute path: \(url.path)")
                return url
            } else {
                print("⚠️ [DEBUG] File NOT found at absolute path: \(url.path)")
                print("🔍 [DEBUG] Trying as filename in current storage directory...")
                // File doesn't exist at absolute path, try as filename in current storage directory
                let filename = url.lastPathComponent
                let alternativeURL = getAudioStorageDirectory().appendingPathComponent(filename)
                print("🔍 [DEBUG] Alternative URL: \(alternativeURL.path)")
                return alternativeURL
            }
        }
        
        // Otherwise, construct the URL from filename
        let directory = getAudioStorageDirectory()
        let resultURL = directory.appendingPathComponent(path)
        print("🔍 [DEBUG] Constructed URL from filename: \(resultURL.path)")
        
        // Check file accessibility
        do {
            let attributes = try fileManager.attributesOfItem(atPath: resultURL.path)
            print("✅ [DEBUG] File accessible, size: \(attributes[.size] ?? "unknown") bytes")
        } catch {
            print("⚠️ [DEBUG] File access check failed: \(error.localizedDescription)")
            if (error as NSError).code == 257 {
                print("❌ [DEBUG] Permission denied (Error 257) - iCloud sync issue detected")
            }
        }
        
        return resultURL
    }
    
    // Start downloading a file from iCloud if needed
    func startDownloadingFromCloud(url: URL) {
        guard syncAudioFiles, isCloudEnabled else {
            print("🔍 [DEBUG] Skipping iCloud download check (syncAudioFiles: \(syncAudioFiles), isCloudEnabled: \(isCloudEnabled))")
            return
        }
        
        print("🔍 [DEBUG] Checking iCloud download status for: \(url.lastPathComponent)")
        
        do {
            var isDownloaded: AnyObject?
            try (url as NSURL).getResourceValue(&isDownloaded, forKey: .ubiquitousItemDownloadingStatusKey)
            
            if let status = isDownloaded as? String {
                print("🔍 [DEBUG] iCloud download status: \(status)")
                
                if status != URLUbiquitousItemDownloadingStatus.current.rawValue {
                    print("⬇️ [DEBUG] File not fully downloaded, starting download...")
                    try fileManager.startDownloadingUbiquitousItem(at: url)
                    print("Started downloading file from iCloud: \(url.lastPathComponent)")
                } else {
                    print("✅ [DEBUG] File already downloaded from iCloud")
                }
            } else {
                print("⚠️ [DEBUG] Could not determine iCloud download status")
            }
        } catch {
            print("❌ [DEBUG] Error checking download status: \(error)")
            if (error as NSError).code == 257 {
                print("❌ [DEBUG] Permission denied (Error 257) accessing iCloud file")
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
                print("✅ [DEBUG] File ready for reading: \(url.lastPathComponent)")
                return url
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if Task.isCancelled {
            return nil
        }

        if isFileReadyForReading(url) {
            print("✅ [DEBUG] File ready for reading after wait: \(url.lastPathComponent)")
            return url
        }

        print("❌ [DEBUG] Timed out waiting for file to become readable: \(url.lastPathComponent)")
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
    
    private func setupMetadataQuery() {
        if let oldQuery = metadataQuery {
            oldQuery.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: oldQuery)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: oldQuery)
            metadataQuery = nil
        }

        guard syncAudioFiles, isCloudEnabled, cloudContainerURL != nil else { return }

        metadataQuery = NSMetadataQuery()
        metadataQuery?.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery?.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        
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
        updateSyncStatus()
    }
    
    @objc private func metadataQueryDidFinishGathering() {
        updateSyncStatus()
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingUploads = uploading
            self.pendingDownloads = downloading

            if hasErrors {
                self.syncStatus = .error("Sync conflicts detected")
            } else if uploading > 0 {
                self.syncStatus = .uploading(uploading)
            } else if downloading > 0 {
                self.syncStatus = .downloading(downloading)
            } else {
                self.syncStatus = .idle
            }

            self.isSyncing = uploading > 0 || downloading > 0
        }
    }
    
    // MARK: - Manual Sync Triggers
    
    func refreshSync() async {
        guard isCloudEnabled else { return }
        
        await MainActor.run {
            syncStatus = .checking
        }
        
        // Start metadata query to refresh status
        metadataQuery?.start()
        
        // Wait briefly for query to populate
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Stop and restart to force refresh
        metadataQuery?.stop()
        metadataQuery?.start()
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
        metadataQuery?.stop()
        NotificationCenter.default.removeObserver(self)
    }
}

private extension CloudStorageManager {
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
            print("❌ [DEBUG] Failed to inspect iCloud download status for \(url.lastPathComponent): \(error)")
            return false
        }
    }
}
