//
//  VoicelyApp.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftData
import SwiftUI

@main
struct VoicelyApp: App {
    @StateObject private var syncMonitor = CloudKitSyncMonitor()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VoiceNote.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncMonitor)
        }
        .modelContainer(sharedModelContainer)
        .onAppear {
            syncMonitor.setModelContainer(sharedModelContainer)
        }
    }
}
