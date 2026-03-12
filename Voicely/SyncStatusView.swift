//
//  SyncStatusView.swift
//  Voicely
//
//  Created by Tao Wang on 1/17/2025.
//

import SwiftUI

struct SyncStatusView: View {
    @EnvironmentObject var cloudManager: CloudStorageManager
    @State private var showingDetail = false
    
    var body: some View {
        Button(action: {
            showingDetail = true
        }) {
            HStack(spacing: 4) {
                syncIcon
                    .font(.caption)
                
                if cloudManager.isSyncing {
                    Text(cloudManager.getSyncStatusText())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .actionSheet(isPresented: $showingDetail) {
            ActionSheet(
                title: Text("iCloud Sync"),
                message: Text(cloudManager.getSyncStatusText()),
                buttons: [
                    .default(Text("Refresh Sync")) {
                        Task {
                            await cloudManager.refreshSync()
                        }
                    },
                    .default(Text("Download All")) {
                        Task {
                            await cloudManager.forceDownloadAll()
                        }
                    },
                    .cancel()
                ]
            )
        }
    }
    
    @ViewBuilder
    private var syncIcon: some View {
        switch cloudManager.syncStatus {
        case .idle:
            Image(systemName: "icloud.fill")
                .foregroundColor(.green)
                
        case .checking:
            Image(systemName: "icloud")
                .foregroundColor(.orange)
                
        case .uploading(_):
            Image(systemName: "icloud.and.arrow.up")
                .foregroundColor(.blue)
                
        case .downloading(_):
            Image(systemName: "icloud.and.arrow.down")
                .foregroundColor(.blue)
                
        case .error(_):
            Image(systemName: "icloud.slash")
                .foregroundColor(.red)
        }
    }
}

// MARK: - Pull to Refresh for Voice Notes List

struct RefreshableVoiceNotesList: View {
    let voiceNotes: [VoiceNote]
    let onDelete: (IndexSet) -> Void
    @EnvironmentObject var cloudManager: CloudStorageManager
    @EnvironmentObject var transcriptionService: TranscriptionService
    
    var body: some View {
        List {
            ForEach(voiceNotes) { note in
                NavigationLink(
                    destination: VoiceNoteDetailView(note: note)
                        .environmentObject(transcriptionService)
                ) {
                    VoiceNoteRow(note: note, transcriptionService: transcriptionService)
                }
                .listRowSeparator(.hidden)
            }
            .onDelete(perform: onDelete)
        }
        .refreshable {
            await cloudManager.refreshSync()
        }
    }
}

#Preview {
    SyncStatusView()
        .environmentObject(CloudStorageManager.shared)
}
