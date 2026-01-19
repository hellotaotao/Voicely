//
//  VoicelyApp.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftData
import SwiftUI
import UserNotifications

@main
struct VoicelyApp: App {
    @StateObject private var syncMonitor = CloudKitSyncMonitor()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        print("🔍 [DEBUG] Initializing ModelContainer...")
        let schema = Schema([
            VoiceNote.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        
        print("🔍 [DEBUG] CloudKit database mode: .automatic")

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            print("✅ [DEBUG] ModelContainer created successfully with CloudKit support")
            return container
        } catch {
            print("❌ [DEBUG] Failed to create ModelContainer: \(error)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncMonitor)
                .task {
                    syncMonitor.setModelContainer(sharedModelContainer)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

// AppDelegate to handle remote notifications
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        print("🔍 [DEBUG] App did finish launching")
        
        // Register for remote notifications (required for CloudKit)
        print("🔍 [DEBUG] Registering for remote notifications...")
        application.registerForRemoteNotifications()
        
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("✅ [DEBUG] Successfully registered for remote notifications")
        print("✅ [DEBUG] Device token: \(tokenString)")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("⚠️ [DEBUG] Failed to register for remote notifications: \(error)")
        print("⚠️ [DEBUG] This is the source of 'Giving up waiting to register' warning")
        print("⚠️ [DEBUG] Common causes:")
        print("   - Running in iOS Simulator (remote notifications not supported)")
        print("   - Network connectivity issues")
        print("   - Apple Push Notification service unavailable")
        print("   - Incorrect provisioning profile or entitlements")
        print("⚠️ [DEBUG] CloudKit sync may still work without remote notifications")
    }
}
