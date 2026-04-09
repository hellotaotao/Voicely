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
    @Published private(set) var accountStatus: CKAccountStatus?
    @Published var lastSyncError: Error?
    @Published var isRecovering: Bool = false
    @Published private(set) var lastStatusCheck: Date?

    private var modelContainer: ModelContainer?
    private var accountStatusTask: Task<Void, Never>?

    enum SyncStatus: Equatable {
        case idle
        case checkingAccount
        case available
        case error(String)
        case recovering
    }

    init() {
        setupNotificationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        accountStatusTask?.cancel()
    }

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccountStatusChange),
            name: .CKAccountChanged,
            object: nil
        )
    }

    @objc private func handleAccountStatusChange(notification: Notification) {
        accountStatusTask?.cancel()
        accountStatusTask = Task { @MainActor in
            await checkCloudKitAccountStatus()
        }
    }

    func checkCloudKitAccountStatus() async {
        let container = CKContainer(identifier: "iCloud.com.hellotaotao.Voicely")
        syncStatus = .checkingAccount

        do {
            let status = try await container.accountStatus()
            applyAccountStatus(status, checkedAt: Date())
        } catch {
            lastSyncError = error
            lastStatusCheck = Date()
            syncStatus = .error("Failed to check iCloud account: \(error.localizedDescription)")
        }
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
            isRecovering = true
            syncStatus = .recovering

            // Delete all VoiceNote objects
            try context.delete(model: VoiceNote.self)
            try context.save()

            print("Local data reset completed - CloudKit will re-sync data")
            lastSyncError = nil
            await checkCloudKitAccountStatus()
        } catch {
            print("Failed to reset local data: \(error)")
            lastSyncError = error
            syncStatus = .error("Failed to reset local data")
        }

        isRecovering = false
    }

    func applyAccountStatus(_ status: CKAccountStatus, checkedAt: Date = Date()) {
        accountStatus = status
        lastStatusCheck = checkedAt

        switch status {
        case .available:
            lastSyncError = nil
            syncStatus = .available
        case .noAccount:
            syncStatus = .error("No iCloud account found")
        case .restricted:
            syncStatus = .error("iCloud account is restricted")
        case .couldNotDetermine:
            syncStatus = .error("Could not determine iCloud account status")
        case .temporarilyUnavailable:
            syncStatus = .error("iCloud account is temporarily unavailable")
        @unknown default:
            syncStatus = .error("Unknown iCloud account status")
        }
    }

    var statusDescription: String {
        switch syncStatus {
        case .idle:
            return "Cloud status has not been checked yet."
        case .checkingAccount:
            return "Checking iCloud account..."
        case .available:
            if let lastStatusCheck {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "iCloud account available. Last checked: \(formatter.string(from: lastStatusCheck))"
            }
            return "iCloud account available."
        case .error(let message):
            return "Error: \(message)"
        case .recovering:
            return "Resetting local data and refreshing cloud status..."
        }
    }

    var statusColor: Color {
        switch syncStatus {
        case .idle:
            return .gray
        case .checkingAccount, .recovering:
            return .orange
        case .available:
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
