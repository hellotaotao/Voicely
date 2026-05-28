//
//  RecordingLiveActivityController.swift
//  Voicely
//
//  Created by Codex on 5/28/2026.
//

import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor
final class RecordingLiveActivityController {
    static let shared = RecordingLiveActivityController()

    private init() {}

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var activity: Activity<RecordingActivityAttributes>?
    #endif

    func start(recordingID: UUID, title: String, elapsedDuration: TimeInterval = 0) {
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
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

    func pause(elapsedDuration: TimeInterval) {
        update(recordingState: .paused, elapsedDuration: elapsedDuration)
    }

    func resume(elapsedDuration: TimeInterval) {
        update(recordingState: .recording, elapsedDuration: elapsedDuration)
    }

    func end(elapsedDuration: TimeInterval) {
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
            scheduledEndDate: nil
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }
}
