//
//  RecordingStopNotifier.swift
//  Voicely
//

import Foundation
import UserNotifications

/// What a scheduled-stop reminder asks the recording session to do.
enum RecordingStopReminderAction: Equatable {
    case extend(TimeInterval)
    case stopNow
}

/// Local notifications for a scheduled stop, so the reminder reaches a user who
/// switched to another app (on the Mac, usually the meeting app itself).
@MainActor
protocol RecordingStopNotifying: AnyObject {
    func requestAuthorizationIfNeeded()
    func scheduleWarning(at warningDate: Date, endDate: Date, noteTitle: String)
    func cancelWarning()
    func announceScheduledStop(endDate: Date, noteTitle: String)
    func setActionHandler(_ handler: @escaping (RecordingStopReminderAction) -> Void)
}

@MainActor
final class RecordingStopNotifier: NSObject, RecordingStopNotifying {
    static let shared = RecordingStopNotifier()

    nonisolated static let warningCategory = "VoicelyRecordingStopWarning"
    static let stoppedCategory = "VoicelyRecordingStopped"
    private static let warningIdentifier = "VoicelyRecordingStopWarning"
    private static let stoppedIdentifier = "VoicelyRecordingStopped"
    private static let extendTenAction = "VoicelyExtend10"
    private static let extendThirtyAction = "VoicelyExtend30"
    private static let stopNowAction = "VoicelyStopNow"

    private var actionHandler: ((RecordingStopReminderAction) -> Void)?
    private var didRequestAuthorization = false

    private var center: UNUserNotificationCenter { .current() }

    private override init() {
        super.init()
    }

    /// Becomes the notification delegate and registers the reminder actions.
    /// Call once at launch so an action tapped while the app is in the
    /// background still reaches the session.
    func install() {
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: Self.extendTenAction, title: "Extend 10 min"),
            UNNotificationAction(identifier: Self.extendThirtyAction, title: "Extend 30 min"),
            UNNotificationAction(identifier: Self.stopNowAction, title: "Stop Now", options: [.destructive]),
        ]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.warningCategory, actions: actions, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.stoppedCategory, actions: [], intentIdentifiers: []),
        ])
    }

    /// Asks once, the first time the user sets a timer, not at launch.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                debugLog("⚠️ [RecordingStopNotifier] Authorization failed: \(error)")
            } else if !granted {
                debugLog("⚠️ [RecordingStopNotifier] Notifications not allowed; reminders stay in-app")
            }
        }
    }

    func setActionHandler(_ handler: @escaping (RecordingStopReminderAction) -> Void) {
        actionHandler = handler
    }

    func scheduleWarning(at warningDate: Date, endDate: Date, noteTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stops at \(RecordingStopFormatting.clockTime(endDate))"
        content.body = "\(noteTitle) will stop and be saved in \(RecordingStopFormatting.length(RecordingStopSchedule.warningLeadTime))."
        content.sound = .default
        content.categoryIdentifier = Self.warningCategory

        let interval = max(1, warningDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        // Reusing the identifier replaces any earlier reminder for this recording.
        center.add(UNNotificationRequest(identifier: Self.warningIdentifier, content: content, trigger: trigger))
    }

    func cancelWarning() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.warningIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.warningIdentifier])
    }

    func announceScheduledStop(endDate: Date, noteTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped at \(RecordingStopFormatting.clockTime(endDate))"
        content.body = "\(noteTitle) was saved as scheduled."
        content.categoryIdentifier = Self.stoppedCategory
        center.add(UNNotificationRequest(identifier: Self.stoppedIdentifier, content: content, trigger: nil))
    }

    fileprivate func handle(actionIdentifier: String) {
        let action: RecordingStopReminderAction
        switch actionIdentifier {
        case Self.extendTenAction: action = .extend(10 * 60)
        case Self.extendThirtyAction: action = .extend(30 * 60)
        case Self.stopNowAction: action = .stopNow
        default: return
        }
        actionHandler?(action)
    }
}

extension RecordingStopNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The recording controls already show the countdown while the app is in front.
        notification.request.content.categoryIdentifier == Self.warningCategory ? [] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.actionIdentifier
        await MainActor.run { handle(actionIdentifier: identifier) }
    }
}

/// Stand-in used under tests, where the app must not touch the real notification center.
@MainActor
final class SilentRecordingStopNotifier: RecordingStopNotifying {
    func requestAuthorizationIfNeeded() {}
    func scheduleWarning(at warningDate: Date, endDate: Date, noteTitle: String) {}
    func cancelWarning() {}
    func announceScheduledStop(endDate: Date, noteTitle: String) {}
    func setActionHandler(_ handler: @escaping (RecordingStopReminderAction) -> Void) {}
}
