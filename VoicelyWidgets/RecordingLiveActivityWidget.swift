//
//  RecordingLiveActivityWidget.swift
//  VoicelyWidgets
//
//  Created by Codex on 5/28/2026.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VoicelyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
    }
}

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.red)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "record.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    ActivityElapsedTimeView(state: context.state, compact: false)
                        .font(.caption.weight(.semibold).monospacedDigit())
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.recordingState.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                ActivityElapsedTimeView(state: context.state, compact: true)
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } minimal: {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }
}

private struct RecordingLiveActivityLockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.16))
                    .frame(width: 44, height: 44)
                Image(systemName: "mic.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Voicely is recording")
                    .font(.headline)
                    .lineLimit(1)
                Text(context.attributes.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("Elapsed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ActivityElapsedTimeView(state: context.state, compact: false)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ActivityElapsedTimeView: View {
    let state: RecordingActivityAttributes.ContentState
    let compact: Bool

    var body: some View {
        if state.recordingState == .recording {
            Text(state.timerBaseDate, style: .timer)
                .lineLimit(1)
                .minimumScaleFactor(compact ? 0.78 : 0.9)
        } else {
            Text(formatElapsed(state.elapsedDuration))
                .lineLimit(1)
                .minimumScaleFactor(compact ? 0.78 : 0.9)
        }
    }

    private func formatElapsed(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
