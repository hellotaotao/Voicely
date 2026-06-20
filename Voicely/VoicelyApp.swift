//
//  VoicelyApp.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import SwiftData
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let startRecordingQuickAction = Notification.Name("VoicelyStartRecordingQuickAction")
    static let toggleRecordingPauseQuickAction = Notification.Name("VoicelyToggleRecordingPauseQuickAction")
    static let stopRecordingQuickAction = Notification.Name("VoicelyStopRecordingQuickAction")
}

enum QuickAction {
    static let startRecordingType = "au.taotao.voicely.start-recording"
    private static let pendingStartRecordingKey = "VoicelyPendingStartRecordingQuickAction"

    static func markPendingStartRecording() {
        UserDefaults.standard.set(true, forKey: pendingStartRecordingKey)
    }

    static func consumePendingStartRecording() -> Bool {
        let defaults = UserDefaults.standard
        let isPending = defaults.bool(forKey: pendingStartRecordingKey)
        if isPending {
            defaults.set(false, forKey: pendingStartRecordingKey)
        }
        return isPending
    }

    static func postStartRecordingRequest() {
        NotificationCenter.default.post(name: .startRecordingQuickAction, object: nil)
    }

    static func requestStartRecording(postNotification: () -> Void = { QuickAction.postStartRecordingRequest() }) {
        markPendingStartRecording()
        postNotification()
    }
}

@main
struct VoicelyApp: App {
    @Environment(\.scenePhase) private var scenePhase
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
            debugLog("🔍 [DEBUG] Initializing ModelContainer...")
            debugLog("🔍 [DEBUG] CloudKit database mode: \(cloudKitDatabase)")
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            if !AppRuntime.isRunningTests {
                debugLog("✅ [DEBUG] ModelContainer created successfully with CloudKit support")
            }
            return container
        } catch {
            if !AppRuntime.isRunningTests {
                debugLog("❌ [DEBUG] Failed to create ModelContainer: \(error)")
            }
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncMonitor)
                .task {
                    #if DEBUG
                    await launchRecordingLiveActivityPreviewIfNeeded()
                    #endif

                    if AppRuntime.isRunningTests {
                        seedUITestNoteIfNeeded()
                    } else {
                        syncMonitor.setModelContainer(sharedModelContainer)
                        await syncMonitor.checkCloudKitAccountStatus()
                    }
                }
                .onChange(of: scenePhase) { _, newValue in
                    guard newValue == .active, !AppRuntime.isRunningTests else { return }
                    Task {
                        await syncMonitor.checkCloudKitAccountStatus()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }

    #if DEBUG
    @MainActor private static var didLaunchRecordingActivityPreview = false

    @MainActor
    private func launchRecordingLiveActivityPreviewIfNeeded() async {
        let processInfo = ProcessInfo.processInfo
        let environment = processInfo.environment
        let arguments = Set(processInfo.arguments)
        let isRequested = environment["VOICELY_SHOW_RECORDING_ACTIVITY_PREVIEW"] == "1"
            || arguments.contains("VOICELY_SHOW_RECORDING_ACTIVITY_PREVIEW")

        guard isRequested, !Self.didLaunchRecordingActivityPreview else { return }
        Self.didLaunchRecordingActivityPreview = true

        let title = environment["VOICELY_LIVE_ACTIVITY_PREVIEW_TITLE"] ?? "Voice Note 11:42 am"
        let elapsedDuration = environment["VOICELY_LIVE_ACTIVITY_PREVIEW_ELAPSED_SECONDS"].flatMap(TimeInterval.init) ?? 21
        let state = environment["VOICELY_LIVE_ACTIVITY_PREVIEW_STATE"] ?? "recording"

        try? await Task.sleep(nanoseconds: 800_000_000)
        RecordingLiveActivityController.shared.start(
            recordingID: UUID(),
            title: title,
            elapsedDuration: elapsedDuration
        )

        if state == "paused" {
            RecordingLiveActivityController.shared.pause(elapsedDuration: elapsedDuration)
        }
    }
    #endif

    private func seedUITestNoteIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICELY_UI_TEST_SEED_NOTE"] == "1" else { return }

        let context = sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<VoiceNote>()

        if let existingNotes = try? context.fetch(descriptor), !existingNotes.isEmpty {
            return
        }

        let noteTitle = environment["VOICELY_UI_TEST_NOTE_TITLE"] ?? "UI Test Note"
        let audioFilePath = environment["VOICELY_UI_TEST_NOTE_AUDIO_PATH"] ?? ""
        let seededNote = VoiceNote(title: noteTitle, audioFilePath: audioFilePath)
        seededNote.titleWasManuallyEdited = true
        if let durationValue = environment["VOICELY_UI_TEST_NOTE_DURATION"].flatMap(Double.init) {
            seededNote.duration = durationValue
        }
        if let transcription = environment["VOICELY_UI_TEST_NOTE_TRANSCRIPTION"], !transcription.isEmpty {
            seededNote.transcription = transcription
            if let modelIdentifier = environment["VOICELY_UI_TEST_NOTE_TRANSCRIPTION_MODEL_IDENTIFIER"], !modelIdentifier.isEmpty {
                seededNote.transcriptionModelIdentifier = modelIdentifier
            }
            seededNote.completeTranscription()
        } else if environment["VOICELY_UI_TEST_NOTE_TRANSCRIPTION_STATE"] == "queued" {
            seededNote.transcriptionOriginDeviceID = DeviceIdentity.currentDeviceID
            seededNote.queueTranscription(at: Date())
        }
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
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem,
           shortcutItem.type == QuickAction.startRecordingType {
            QuickAction.markPendingStartRecording()
        }

        guard !AppRuntime.isRunningTests else {
            return true
        }

#if DEBUG
        print("🔍 [DEBUG] App did finish launching")
#endif

        if Self.didRequestRemoteNotifications {
            return true
        }
        Self.didRequestRemoteNotifications = true

        #if targetEnvironment(simulator)
        #if DEBUG
        print("ℹ️ [DEBUG] Running on Simulator; skipping remote notification registration")
        #endif
        #else
        // Register for remote notifications (required for CloudKit)
        #if DEBUG
        print("🔍 [DEBUG] Registering for remote notifications...")
        #endif
        application.registerForRemoteNotifications()
        #endif
        
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(handleShortcutItem(shortcutItem))
    }

    func handleShortcutItem(
        _ shortcutItem: UIApplicationShortcutItem,
        requestStartRecording: () -> Void = { QuickAction.requestStartRecording() }
    ) -> Bool {
        guard shortcutItem.type == QuickAction.startRecordingType else { return false }

        requestStartRecording()
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
#if DEBUG
        print("✅ [DEBUG] Successfully registered for remote notifications")
        print("✅ [DEBUG] Device token: \(tokenString)")
#endif
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
#if DEBUG
        print("⚠️ [DEBUG] Failed to register for remote notifications: \(error)")
        print("⚠️ [DEBUG] This is the source of 'Giving up waiting to register' warning")
        print("⚠️ [DEBUG] Common causes:")
        print("   - Running in iOS Simulator (remote notifications not supported)")
        print("   - Network connectivity issues")
        print("   - Apple Push Notification service unavailable")
        print("   - Incorrect provisioning profile or entitlements")
        print("⚠️ [DEBUG] CloudKit sync may still work without remote notifications")
#endif
    }
}
