//
//  CloudKitSyncMonitor.swift
//  Voicely
//
//  Created by Assistant on 1/6/2025.
//

import CloudKit
import Foundation
import SwiftData
import SwiftUI

/// Monitor CloudKit sync status and handle sync errors
@MainActor
class CloudKitSyncMonitor: ObservableObject {
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncError: Error?
    @Published var isRecovering: Bool = false
    @Published var lastSuccessfulSync: Date?

    private var modelContainer: ModelContainer?

    enum SyncStatus {
        case idle
        case syncing
        case success
        case error(String)
        case recovering
    }

    init() {
        setupNotificationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    private func setupNotificationObservers() {
        // Listen for CloudKit sync notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSyncWillStart),
            name: Notification.Name("NSCloudKitMirroringDelegateWillStartSyncNotificationName"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSyncDidFinish),
            name: Notification.Name("NSCloudKitMirroringDelegateDidFinishSyncNotificationName"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSyncWillReset),
            name: Notification.Name("NSCloudKitMirroringDelegateWillResetSyncNotificationName"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSyncDidReset),
            name: Notification.Name("NSCloudKitMirroringDelegateDidResetSyncNotificationName"),
            object: nil
        )

        // Listen for CloudKit account status changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccountStatusChange),
            name: .CKAccountChanged,
            object: nil
        )
    }

    @objc private func handleSyncWillStart(notification: Notification) {
        Task { @MainActor in
            syncStatus = .syncing
            print("CloudKit sync will start")
        }
    }

    @objc private func handleSyncDidFinish(notification: Notification) {
        Task { @MainActor in
            if let error = notification.userInfo?["error"] as? Error {
                syncStatus = .error(error.localizedDescription)
                lastSyncError = error
                print("CloudKit sync finished with error: \(error)")

                // Handle specific CloudKit errors
                handleCloudKitError(error)
            } else {
                syncStatus = .success
                lastSuccessfulSync = Date()
                lastSyncError = nil
                print("CloudKit sync finished successfully")
            }
        }
    }

    @objc private func handleSyncWillReset(notification: Notification) {
        Task { @MainActor in
            isRecovering = true
            syncStatus = .recovering
            print("CloudKit sync will reset - entering recovery mode")

            if let reason = notification.userInfo?["reason"] as? String {
                print("Reset reason: \(reason)")
            }
        }
    }

    @objc private func handleSyncDidReset(notification: Notification) {
        Task { @MainActor in
            isRecovering = false
            syncStatus = .idle
            print("CloudKit sync did reset - recovery completed")
        }
    }

    @objc private func handleAccountStatusChange(notification: Notification) {
        Task { @MainActor in
            await checkCloudKitAccountStatus()
        }
    }

    private func handleCloudKitError(_ error: Error) {
        guard let ckError = error as? CKError else { return }

        switch ckError.code {
        case .changeTokenExpired:
            print("Change token expired - CloudKit will automatically recover")
        // The system will automatically reset and re-sync

        case .accountTemporarilyUnavailable:
            print("CloudKit account temporarily unavailable")
            // Retry after a delay
            scheduleRetry()

        case .networkUnavailable, .networkFailure:
            print("Network issue - will retry when network is available")
            scheduleRetry()

        case .quotaExceeded:
            print("CloudKit quota exceeded")
            syncStatus = .error("iCloud storage quota exceeded")

        case .notAuthenticated:
            print("User not signed in to iCloud")
            syncStatus = .error("Please sign in to iCloud in Settings")

        default:
            print("Other CloudKit error: \(ckError.localizedDescription)")
        }
    }

    private func scheduleRetry() {
        // Retry sync after 30 seconds
        Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
            await forceSyncIfNeeded()
        }
    }

    func checkCloudKitAccountStatus() async {
        let container = CKContainer(identifier: "iCloud.com.hellotaotao.Voicely")

        do {
            let status = try await container.accountStatus()

            switch status {
            case .available:
                print("CloudKit account is available")

            case .noAccount:
                await MainActor.run {
                    syncStatus = .error("No iCloud account found")
                }

            case .restricted:
                await MainActor.run {
                    syncStatus = .error("iCloud account is restricted")
                }

            case .couldNotDetermine:
                await MainActor.run {
                    syncStatus = .error("Could not determine iCloud account status")
                }

            case .temporarilyUnavailable:
                await MainActor.run {
                    syncStatus = .error("iCloud account temporarily unavailable")
                }

            @unknown default:
                print("Unknown CloudKit account status")
            }
        } catch {
            await MainActor.run {
                syncStatus = .error("Failed to check iCloud account: \(error.localizedDescription)")
            }
        }
    }

    func forceSyncIfNeeded() async {
        // This will trigger a sync if the system determines it's needed
        // SwiftData handles this automatically, but we can check status
        await checkCloudKitAccountStatus()
    }

    func resetLocalData() async {
        // WARNING: This will delete all local data and re-sync from CloudKit
        // Only use this as a last resort

        guard let container = modelContainer else {
            print("No model container available for reset")
            return
        }

        // Create a new context for the reset operation
        let context = ModelContext(container)

        do {
            // Delete all VoiceNote objects
            try context.delete(model: VoiceNote.self)
            try context.save()

            print("Local data reset completed - CloudKit will re-sync data")

            await MainActor.run {
                syncStatus = .recovering
            }

        } catch {
            print("Failed to reset local data: \(error)")
            await MainActor.run {
                syncStatus = .error("Failed to reset local data")
            }
        }
    }

    var statusDescription: String {
        switch syncStatus {
        case .idle:
            return "Ready"
        case .syncing:
            return "Syncing..."
        case .success:
            if let lastSync = lastSuccessfulSync {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "Last synced: \(formatter.string(from: lastSync))"
            }
            return "Synced"
        case .error(let message):
            return "Error: \(message)"
        case .recovering:
            return "Recovering..."
        }
    }

    var statusColor: Color {
        switch syncStatus {
        case .idle:
            return .gray
        case .syncing, .recovering:
            return .orange
        case .success:
            return .green
        case .error:
            return .red
        }
    }
}

// Extension to provide user-friendly error messages
extension CloudKitSyncMonitor {
    func userFriendlyErrorMessage(for error: Error) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }

        switch ckError.code {
        case .changeTokenExpired:
            return "Sync data is outdated. The app will automatically refresh."

        case .accountTemporarilyUnavailable:
            return "iCloud is temporarily unavailable. Please try again later."

        case .networkUnavailable, .networkFailure:
            return "No internet connection. Sync will resume when connected."

        case .quotaExceeded:
            return "iCloud storage is full. Please free up space in iCloud Settings."

        case .notAuthenticated:
            return "Please sign in to iCloud in Settings to enable sync."

        case .serverRecordChanged:
            return "Data was modified on another device. Resolving conflicts..."

        case .zoneBusy:
            return "Sync service is busy. Will retry automatically."

        default:
            return "Sync error: \(ckError.localizedDescription)"
        }
    }
}
