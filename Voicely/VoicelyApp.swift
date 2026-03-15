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
        let schema = Schema([
            VoiceNote.self
        ])
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = AppRuntime.isRunningTests ? .none : .automatic
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: AppRuntime.isRunningTests,
            cloudKitDatabase: cloudKitDatabase
        )

        if !AppRuntime.isRunningTests {
            print("🔍 [DEBUG] Initializing ModelContainer...")
            print("🔍 [DEBUG] CloudKit database mode: \(cloudKitDatabase)")
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            if !AppRuntime.isRunningTests {
                print("✅ [DEBUG] ModelContainer created successfully with CloudKit support")
            }
            return container
        } catch {
            if !AppRuntime.isRunningTests {
                print("❌ [DEBUG] Failed to create ModelContainer: \(error)")
            }
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncMonitor)
                .task {
                    if AppRuntime.isRunningTests {
                        seedUITestNoteIfNeeded()
                    } else {
                        syncMonitor.setModelContainer(sharedModelContainer)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }

    private func seedUITestNoteIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICELY_UI_TEST_SEED_NOTE"] == "1" else { return }

        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<VoiceNote>()

        if let existingNotes = try? context.fetch(descriptor), !existingNotes.isEmpty {
            return
        }

        let noteTitle = environment["VOICELY_UI_TEST_NOTE_TITLE"] ?? "UI Test Note"
        let seededNote = VoiceNote(title: noteTitle)
        context.insert(seededNote)

        do {
            try context.save()
        } catch {
            assertionFailure("Failed to seed UI test note: \(error)")
        }
    }
}

// AppDelegate to handle remote notifications
class AppDelegate: NSObject, UIApplicationDelegate {
    private static var didRequestRemoteNotifications = false
    private static let deviceTokenDefaultsKey = "VoicelyDeviceToken"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        guard !AppRuntime.isRunningTests else {
            return true
        }

        print("🔍 [DEBUG] App did finish launching")
        
        if Self.didRequestRemoteNotifications {
            return true
        }
        Self.didRequestRemoteNotifications = true

        // Register for remote notifications (required for CloudKit)
        print("🔍 [DEBUG] Registering for remote notifications...")
        application.registerForRemoteNotifications()
        
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let defaults = UserDefaults.standard
        if let previousToken = defaults.string(forKey: Self.deviceTokenDefaultsKey),
           previousToken == tokenString {
            return
        }
        defaults.set(tokenString, forKey: Self.deviceTokenDefaultsKey)
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
