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
    
    private let fileManager = FileManager.default
    private var containerURL: URL?
    
    private init() {
        setupCloudContainer()
    }
    
    private func setupCloudContainer() {
        if let url = fileManager.url(forUbiquityContainerIdentifier: nil) {
            containerURL = url.appendingPathComponent("Documents/AudioRecordings")
            isCloudEnabled = true
            
            // Create directory if it doesn't exist
            if !fileManager.fileExists(atPath: containerURL!.path) {
                do {
                    try fileManager.createDirectory(at: containerURL!, withIntermediateDirectories: true, attributes: nil)
                    print("Created iCloud audio directory")
                } catch {
                    print("Failed to create iCloud directory: \(error)")
                }
            }
        } else {
            print("iCloud not available")
            isCloudEnabled = false
        }
    }
    
    // Get the appropriate directory for storing audio files
    func getAudioStorageDirectory() -> URL {
        if isCloudEnabled, let cloudURL = containerURL {
            return cloudURL
        } else {
            // Fallback to local documents directory
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
    }
    
    // Generate a unique filename for audio recording
    func generateAudioFilename() -> URL {
        let directory = getAudioStorageDirectory()
        let filename = "recording_\(Date().timeIntervalSince1970).wav"
        return directory.appendingPathComponent(filename)
    }
    
    // Move existing local files to iCloud
    func migrateLocalFilesToCloud() async {
        guard isCloudEnabled, let cloudURL = containerURL else { return }
        
        let localURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        do {
            let localFiles = try fileManager.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil)
            
            for file in localFiles where file.pathExtension == "wav" {
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
        guard isCloudEnabled, let cloudURL = containerURL else { return false }
        let fileURL = cloudURL.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: fileURL.path)
    }
    
    // Get the full URL for a file
    func getFileURL(for path: String) -> URL? {
        // If it's already a full path, convert to URL
        if path.starts(with: "/") {
            return URL(fileURLWithPath: path)
        }
        
        // Otherwise, construct the URL from filename
        let directory = getAudioStorageDirectory()
        return directory.appendingPathComponent(path)
    }
    
    // Start downloading a file from iCloud if needed
    func startDownloadingFromCloud(url: URL) {
        guard isCloudEnabled else { return }
        
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
}
