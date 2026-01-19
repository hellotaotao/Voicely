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
        setupCloudContainer()
        setupMetadataQuery()
    }

    private func setupLocalContainer() {
        let localURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        localContainerURL = localURL
        print("Local audio directory: \(localURL.path)")
    }
    
    private func setupCloudContainer() {
        guard syncAudioFiles else {
            isCloudEnabled = false
            print("iCloud audio sync disabled - using local storage only")
            return
        }

        if let url = fileManager.url(forUbiquityContainerIdentifier: cloudContainerIdentifier) {
            let cloudURL = url.appendingPathComponent("Documents/\(audioDirectoryName)", isDirectory: true)
            cloudContainerURL = cloudURL
            isCloudEnabled = true

            createDirectoryIfNeeded(at: cloudURL, excludeFromBackup: false)
            print("iCloud Documents enabled for audio files: \(cloudURL.path)")
        } else {
            print("iCloud Documents not available - check entitlements and Apple ID")
            isCloudEnabled = false
        }
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
        guard !path.isEmpty else { return nil }
        
        // If it's already a full path, convert to URL
        if path.starts(with: "/") {
            let url = URL(fileURLWithPath: path)
            // Check if the file exists at this absolute path
            if fileManager.fileExists(atPath: url.path) {
                return url
            } else {
                // File doesn't exist at absolute path, try as filename in current storage directory
                let filename = url.lastPathComponent
                return getAudioStorageDirectory().appendingPathComponent(filename)
            }
        }
        
        // Otherwise, construct the URL from filename
        let directory = getAudioStorageDirectory()
        return directory.appendingPathComponent(path)
    }
    
    // Start downloading a file from iCloud if needed
    func startDownloadingFromCloud(url: URL) {
        guard syncAudioFiles, isCloudEnabled else { return }
        
        do {
            var isDownloaded: AnyObject?
            try (url as NSURL).getResourceValue(&isDownloaded, forKey: .ubiquitousItemDownloadingStatusKey)
            
            if let status = isDownloaded as? String, status != URLUbiquitousItemDownloadingStatus.current.rawValue {
                try fileManager.startDownloadingUbiquitousItem(at: url)
                print("Started downloading file from iCloud: \(url.lastPathComponent)")
            }
        } catch {
            print("Error checking download status: \(error)")
        }
    }
    
    // Delete a file from storage
    func deleteFile(at path: String) {
        guard let url = getFileURL(for: path) else { return }
        
        do {
            try fileManager.removeItem(at: url)
            print("Deleted file: \(url.lastPathComponent)")
        } catch {
            print("Failed to delete file: \(error)")
        }
    }
    
    // MARK: - Sync Status Monitoring
    
    private func setupMetadataQuery() {
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
    }
    
    @objc private func metadataQueryDidUpdate() {
        updateSyncStatus()
    }
    
    @objc private func metadataQueryDidFinishGathering() {
        updateSyncStatus()
    }
    
    private func updateSyncStatus() {
        guard let query = metadataQuery else { return }
        
        var uploading = 0
        var downloading = 0
        var hasErrors = false
        
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }
            
            // Check download status
            if let downloadStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String {
                if downloadStatus == URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue {
                    downloading += 1
                }
            }
            
            // Check upload status
            if let isUploaded = item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool,
               !isUploaded {
                uploading += 1
            }
            
            // Check for errors
            if let itemHasError = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool,
               itemHasError {
                hasErrors = true
            }
        }
        
        Task { @MainActor in
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
