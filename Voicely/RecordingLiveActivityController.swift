//
//  RecordingLiveActivityController.swift
//  Voicely
//
//  Created by Codex on 5/28/2026.
//

import Foundation
import os

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor
final class RecordingLiveActivityController {
    static let shared = RecordingLiveActivityController()

    private init() {}

    nonisolated private static let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "LiveActivity")

    /// Carried into every state update so pause/resume keep showing the planned stop.
    private var scheduledEndDate: Date?

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var activity: Activity<RecordingActivityAttributes>?
    #endif

    func start(recordingID: UUID, title: String, elapsedDuration: TimeInterval = 0) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        scheduledEndDate = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = RecordingActivityAttributes(recordingID: recordingID, title: title)
        let state = RecordingActivityAttributes.ContentState.active(elapsedDuration: elapsedDuration)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            debugLog("⚠️ [LiveActivity] Failed to start recording activity: \(error)")
        }
        #endif
    }

    /// Ends recording activities this process did not start. A recording never
    /// outlives its process, so such an activity belongs to one that died with
    /// the app (crash, power loss). iOS restores it after a restart with its timer
    /// still counting from the original start, and only the app can end it.
    func endActivitiesFromEarlierLaunches() {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        // Taken now, so an activity a recording requests later is never in it.
        let stale = Activity<RecordingActivityAttributes>.activities.filter { $0.id != activity?.id }
        guard !stale.isEmpty else { return }
        Self.log.notice("event=endStaleActivities count=\(stale.count)")
        Task {
            for activity in stale {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    func pause(elapsedDuration: TimeInterval) {
        update(recordingState: .paused, elapsedDuration: elapsedDuration)
    }

    func resume(elapsedDuration: TimeInterval) {
        update(recordingState: .recording, elapsedDuration: elapsedDuration)
    }

    func updateScheduledEnd(_ endDate: Date?, isPaused: Bool, elapsedDuration: TimeInterval) {
        scheduledEndDate = endDate
        update(recordingState: isPaused ? .paused : .recording, elapsedDuration: elapsedDuration)
    }

    func end(elapsedDuration: TimeInterval) {
        scheduledEndDate = nil
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let activity else { return }

        let state = RecordingActivityAttributes.ContentState(
            recordingState: .stopping,
            timerBaseDate: Date().addingTimeInterval(-elapsedDuration),
            elapsedDuration: elapsedDuration,
            scheduledEndDate: nil
        )

        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        self.activity = nil
        #endif
    }

    private func update(
        recordingState: RecordingActivityAttributes.RecordingState,
        elapsedDuration: TimeInterval
    ) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        guard let activity else { return }

        let state = RecordingActivityAttributes.ContentState(
            recordingState: recordingState,
            timerBaseDate: Date().addingTimeInterval(-elapsedDuration),
            elapsedDuration: elapsedDuration,
            scheduledEndDate: scheduledEndDate
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }
}
