//
//  CloudKitSyncMonitor.swift
//  Voicely
//
//  Created by Assistant on 1/6/2025.
//

import CloudKit
import Foundation
import SwiftUI

/// Monitor CloudKit sync status and handle sync errors
@MainActor
class CloudKitSyncMonitor: ObservableObject {
    @Published var syncStatus: SyncStatus = .idle
    @Published private(set) var accountStatus: CKAccountStatus?
    @Published var lastSyncError: Error?
    @Published private(set) var lastStatusCheck: Date?

    private var accountStatusTask: Task<Void, Never>?

    enum SyncStatus: Equatable {
        case idle
        case checkingAccount
        case available
        case error(String)
    }

    init() {
        setupNotificationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        accountStatusTask?.cancel()
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
            syncStatus = .error(String(localized: "iCloud account is restricted"))
        case .couldNotDetermine:
            syncStatus = .error("Could not determine iCloud account status")
        case .temporarilyUnavailable:
            syncStatus = .error(String(localized: "iCloud account is temporarily unavailable"))
        @unknown default:
            syncStatus = .error(String(localized: "Unknown iCloud account status"))
        }
    }

    var statusDescription: String {
        switch syncStatus {
        case .idle:
            return String(localized: "Cloud status has not been checked yet.")
        case .checkingAccount:
            return String(localized: "Checking iCloud account...")
        case .available:
            if let lastStatusCheck {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return String(localized: "iCloud account available. Last checked: \(formatter.string(from: lastStatusCheck))")
            }
            return String(localized: "iCloud account available.")
        case .error(let message):
            if message == "No iCloud account found" {
                return String(localized: "iCloud sync is off. Sign in to iCloud in Settings to sync recordings across devices.")
            }
            return String(localized: "Error: \(message)")
        }
    }

    var statusColor: Color {
        switch syncStatus {
        case .idle:
            return .gray
        case .checkingAccount:
            return .orange
        case .available:
            return .green
        case .error(let message):
            if message == "No iCloud account found" {
                return .orange
            }
            return .red
        }
    }
}
