//
//  DiagnosticsView.swift
//  Voicely
//

import SwiftUI
import SwiftData
import CloudKit

/// Read-only iCloud diagnostics for verifying notes are consistent across
/// devices. Compares the local SwiftData note count against the authoritative
/// CloudKit record count: if two devices disagree on the iCloud number, they're
/// talking to different clouds (account / container / environment) — which is
/// exactly the "why won't these stay in sync" problem you can't otherwise see.
@MainActor
final class CloudDiagnostics: ObservableObject {
    @Published private(set) var cloudNoteCount: Int?
    @Published private(set) var accountStatusText = "—"
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorText: String?

    static let containerIdentifier = "iCloud.com.hellotaotao.Voicely"

    // SwiftData mirrors @Model types into CloudKit as "CD_<Entity>" records,
    // all inside this one private zone. This is internal naming, not public API:
    // if Apple ever renames it the count simply comes back nil and the row shows
    // "—" — a diagnostic signal, not a crash.
    private static let recordType = "CD_VoiceNote"
    private static let zoneName = "com.apple.coredata.cloudkit.zone"

    func refresh() async {
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        let container = CKContainer(identifier: Self.containerIdentifier)

        do {
            accountStatusText = Self.describe(try await container.accountStatus())
        } catch {
            accountStatusText = "error"
        }

        do {
            cloudNoteCount = try await Self.countCloudNotes(in: container.privateCloudDatabase)
        } catch {
            cloudNoteCount = nil
            errorText = error.localizedDescription
        }
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "available"
        case .noAccount: return "no account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could not determine"
        case .temporarilyUnavailable: return "temporarily unavailable"
        @unknown default: return "unknown"
        }
    }

    // Count CD_VoiceNote records by walking the zone's change feed (paged). Using
    // zone changes rather than a CKQuery avoids needing a queryable index in the
    // CloudKit schema. desiredKeys = [] keeps it to metadata — we only count.
    private static func countCloudNotes(in database: CKDatabase) async throws -> Int {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        var total = 0
        var token: CKServerChangeToken?

        while true {
            let page = try await countPage(in: database, zoneID: zoneID, since: token)
            total += page.count
            token = page.token
            if !page.more { break }
        }
        return total
    }

    private static func countPage(
        in database: CKDatabase,
        zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> (count: Int, token: CKServerChangeToken?, more: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token
            config.desiredKeys = []

            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config]
            )

            var count = 0
            var nextToken = token
            var more = false
            var zoneError: Error?

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result, record.recordType == recordType {
                    count += 1
                }
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let success):
                    nextToken = success.serverChangeToken
                    more = success.moreComing
                case .failure(let error):
                    zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(returning: (count, nextToken, more))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
}

struct DiagnosticsContent: View {
    @Query private var notes: [VoiceNote]
    @StateObject private var diagnostics = CloudDiagnostics()

    private var localCount: Int { notes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(label: "Notes — local", value: "\(localCount)")

            HStack {
                Text("Notes — iCloud")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(cloudCountText)
                    .font(.subheadline.weight(.medium))
                Button {
                    Task { await diagnostics.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoicelyTheme.accent)
                .disabled(diagnostics.isRefreshing)
            }

            consistencyRow

            Divider().background(VoicelyTheme.hairline)

            row(label: "iCloud account", value: diagnostics.accountStatusText)
            row(label: "Container", value: CloudDiagnostics.containerIdentifier, mono: true)

            if let errorText = diagnostics.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await diagnostics.refresh() }
    }

    private var cloudCountText: String {
        if diagnostics.isRefreshing { return "…" }
        if let count = diagnostics.cloudNoteCount { return "\(count)" }
        return "—"
    }

    @ViewBuilder
    private var consistencyRow: some View {
        if let cloud = diagnostics.cloudNoteCount {
            if cloud == localCount {
                Label("Consistent (\(localCount))", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("Δ local \(localCount) / iCloud \(cloud) — syncing or mismatch",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(label: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .caption.monospaced() : .subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}
