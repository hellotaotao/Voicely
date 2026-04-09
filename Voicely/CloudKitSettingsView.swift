//
//  CloudKitSettingsView.swift
//  Voicely
//
//  Created by Assistant on 1/6/2025.
//

import CloudKit
import SwiftData
import SwiftUI

struct CloudKitSettingsView: View {
    @EnvironmentObject private var syncMonitor: CloudKitSyncMonitor
    @Environment(\.modelContext) private var modelContext

    @State private var showingResetAlert = false
    @State private var showingDiagnostics = false

    var body: some View {
        NavigationView {
            List {
                // Account Status Section
                Section("iCloud Account") {
                    HStack {
                        Image(systemName: cloudKitStatusIcon)
                            .foregroundColor(cloudKitStatusColor)

                        VStack(alignment: .leading) {
                            Text("iCloud Status")
                                .font(.headline)
                            Text(cloudKitStatusText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if syncMonitor.syncStatus == .checkingAccount {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }

                    Button("Check Account Status") {
                        checkAccountStatus()
                    }
                    .disabled(syncMonitor.syncStatus == .checkingAccount)
                }

                // Sync Status Section
                Section("Sync Status") {
                    HStack {
                        Circle()
                            .fill(syncMonitor.statusColor)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading) {
                            Text("Current Status")
                                .font(.headline)
                            Text(syncMonitor.statusDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let lastStatusCheck = syncMonitor.lastStatusCheck {
                        HStack {
                            Text("Last Status Check")
                            Spacer()
                            Text(formatDate(lastStatusCheck))
                                .foregroundColor(.secondary)
                        }
                    }

                    if syncMonitor.isRecovering {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.orange)
                            Text("Recovery in Progress")
                                .foregroundColor(.orange)
                        }
                    }
                }

                // Error Information Section
                if let error = syncMonitor.lastSyncError {
                    Section("Last Error") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(syncMonitor.userFriendlyErrorMessage(for: error))
                                .font(.body)

                            Text("Technical Details:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }

                        Button("Copy Error Details") {
                            UIPasteboard.general.string = error.localizedDescription
                        }
                        .foregroundColor(.blue)
                    }
                }

                // Actions Section
                Section("Actions") {
                    Button("Force Sync") {
                        Task {
                            await syncMonitor.forceSyncIfNeeded()
                        }
                    }
                    .foregroundColor(.blue)

                    Button("Show Diagnostics") {
                        showingDiagnostics = true
                    }
                    .foregroundColor(.blue)

                    Button("Reset Sync Data") {
                        showingResetAlert = true
                    }
                    .foregroundColor(.red)
                }

                // Tips Section
                Section("Tips") {
                    VStack(alignment: .leading, spacing: 12) {
                        tipRow(
                            icon: "wifi",
                            title: "Network Connection",
                            description:
                                "Ensure you have a stable internet connection for sync to work properly."
                        )

                        tipRow(
                            icon: "icloud",
                            title: "iCloud Storage",
                            description:
                                "Check that you have enough iCloud storage space available."
                        )

                        tipRow(
                            icon: "person.fill.checkmark",
                            title: "Account Verification",
                            description:
                                "Make sure you're signed in to the same iCloud account on all devices."
                        )

                        tipRow(
                            icon: "clock",
                            title: "Sync Timing",
                            description:
                                "CloudKit sync may take some time, especially for large amounts of data."
                        )
                    }
                }
            }
            .navigationTitle("CloudKit Sync")
            .onAppear {
                checkAccountStatus()
            }
            .alert("Reset Sync Data", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetSyncData()
                }
            } message: {
                Text(
                    "This will delete all local data and re-sync from iCloud. This action cannot be undone."
                )
            }
            .sheet(isPresented: $showingDiagnostics) {
                CloudKitDiagnosticsView()
                    .environmentObject(syncMonitor)
            }
        }
    }

    private var cloudKitStatusIcon: String {
        guard let status = syncMonitor.accountStatus else { return "questionmark.circle" }

        switch status {
        case .available:
            return "checkmark.circle.fill"
        case .noAccount:
            return "person.crop.circle.badge.minus"
        case .restricted:
            return "lock.circle.fill"
        case .couldNotDetermine:
            return "questionmark.circle.fill"
        case .temporarilyUnavailable:
            return "exclamationmark.triangle.fill"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var cloudKitStatusColor: Color {
        guard let status = syncMonitor.accountStatus else { return .gray }

        switch status {
        case .available:
            return .green
        case .noAccount:
            return .red
        case .restricted:
            return .orange
        case .couldNotDetermine:
            return .gray
        case .temporarilyUnavailable:
            return .yellow
        @unknown default:
            return .gray
        }
    }

    private var cloudKitStatusText: String {
        guard let status = syncMonitor.accountStatus else {
            if syncMonitor.syncStatus == .checkingAccount {
                return "Checking iCloud account..."
            }
            return "Account status not checked yet"
        }

        switch status {
        case .available:
            return "iCloud account is available and ready"
        case .noAccount:
            return "No iCloud account found. Please sign in to iCloud in Settings."
        case .restricted:
            return "iCloud account is restricted"
        case .couldNotDetermine:
            return "Could not determine iCloud account status"
        case .temporarilyUnavailable:
            return "iCloud account is temporarily unavailable"
        @unknown default:
            return "Unknown account status"
        }
    }

    private func tipRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func checkAccountStatus() {
        Task {
            await syncMonitor.checkCloudKitAccountStatus()
        }
    }

    private func resetSyncData() {
        Task {
            await syncMonitor.resetLocalData()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct CloudKitDiagnosticsView: View {
    @EnvironmentObject private var syncMonitor: CloudKitSyncMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var diagnosticsInfo: [DiagnosticItem] = []
    @State private var isLoading = true

    struct DiagnosticItem {
        let title: String
        let value: String
        let status: Status

        enum Status {
            case good, warning, error, info

            var color: Color {
                switch self {
                case .good: return .green
                case .warning: return .orange
                case .error: return .red
                case .info: return .blue
                }
            }

            var icon: String {
                switch self {
                case .good: return "checkmark.circle"
                case .warning: return "exclamationmark.triangle"
                case .error: return "xmark.circle"
                case .info: return "info.circle"
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            List {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Gathering diagnostics...")
                    }
                    .padding()
                } else {
                    ForEach(diagnosticsInfo.indices, id: \.self) { index in
                        let item = diagnosticsInfo[index]

                        HStack {
                            Image(systemName: item.status.icon)
                                .foregroundColor(item.status.color)

                            VStack(alignment: .leading) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.value)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }

                    Section {
                        Button("Copy All Diagnostics") {
                            copyDiagnostics()
                        }
                        .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                gatherDiagnostics()
            }
        }
    }

    private func gatherDiagnostics() {
        Task {
            var items: [DiagnosticItem] = []

            // Basic app info
            items.append(
                DiagnosticItem(
                    title: "App Version",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? "Unknown",
                    status: .info
                ))

            items.append(
                DiagnosticItem(
                    title: "Build Number",
                    value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown",
                    status: .info
                ))

            // CloudKit Container
            items.append(
                DiagnosticItem(
                    title: "CloudKit Container",
                    value: "iCloud.com.hellotaotao.Voicely",
                    status: .info
                ))

            // Check CloudKit account status
            let container = CKContainer(identifier: "iCloud.com.hellotaotao.Voicely")

            do {
                let accountStatus = try await container.accountStatus()
                let statusText: String
                let status: DiagnosticItem.Status

                switch accountStatus {
                case .available:
                    statusText = "Available"
                    status = .good
                case .noAccount:
                    statusText = "No Account"
                    status = .error
                case .restricted:
                    statusText = "Restricted"
                    status = .warning
                case .couldNotDetermine:
                    statusText = "Could Not Determine"
                    status = .warning
                case .temporarilyUnavailable:
                    statusText = "Temporarily Unavailable"
                    status = .warning
                @unknown default:
                    statusText = "Unknown"
                    status = .warning
                }

                items.append(
                    DiagnosticItem(
                        title: "iCloud Account Status",
                        value: statusText,
                        status: status
                    ))
            } catch {
                items.append(
                    DiagnosticItem(
                        title: "iCloud Account Status",
                        value: "Error: \(error.localizedDescription)",
                        status: .error
                    ))
            }

            // Sync status
            let syncStatus: DiagnosticItem.Status
            let syncValue: String

            switch syncMonitor.syncStatus {
            case .idle:
                syncValue = "Idle"
                syncStatus = .info
            case .checkingAccount:
                syncValue = "Checking Account"
                syncStatus = .info
            case .available:
                syncValue = "Account Available"
                syncStatus = .good
            case .error(let message):
                syncValue = "Error: \(message)"
                syncStatus = .error
            case .recovering:
                syncValue = "Resetting Local Data"
                syncStatus = .warning
            }

            items.append(
                DiagnosticItem(
                    title: "Current Sync Status",
                    value: syncValue,
                    status: syncStatus
                ))

            // Last status check
            if let lastStatusCheck = syncMonitor.lastStatusCheck {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short

                items.append(
                    DiagnosticItem(
                        title: "Last Status Check",
                        value: formatter.string(from: lastStatusCheck),
                        status: .good
                    ))
            } else {
                items.append(
                    DiagnosticItem(
                        title: "Last Status Check",
                        value: "Never",
                        status: .warning
                    ))
            }

            // Count local records
            let descriptor = FetchDescriptor<VoiceNote>()
            let noteCount = (try? modelContext.fetchCount(descriptor)) ?? 0

            items.append(
                DiagnosticItem(
                    title: "Local Voice Notes",
                    value: "\(noteCount) notes",
                    status: noteCount > 0 ? .good : .info
                ))

            // Network status
            items.append(
                DiagnosticItem(
                    title: "Network Status",
                    value: "Connected",  // Simplified - would need actual network checking
                    status: .good
                ))

            // Device info
            items.append(
                DiagnosticItem(
                    title: "Device Model",
                    value: UIDevice.current.model,
                    status: .info
                ))

            items.append(
                DiagnosticItem(
                    title: "iOS Version",
                    value: UIDevice.current.systemVersion,
                    status: .info
                ))

            await MainActor.run {
                self.diagnosticsInfo = items
                self.isLoading = false
            }
        }
    }

    private func copyDiagnostics() {
        let diagnosticsText = diagnosticsInfo.map { item in
            "\(item.title): \(item.value)"
        }.joined(separator: "\n")

        UIPasteboard.general.string = diagnosticsText
    }
}

#Preview {
    CloudKitSettingsView()
        .environmentObject(CloudKitSyncMonitor())
}
