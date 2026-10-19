//
//  RecordingTimerControls.swift
//  Voicely
//

import SwiftUI

/// Opens the custom timer sheet, either for the next recording or the active one.
struct RecordingTimerSheetRequest: Identifiable {
    enum Mode: String, CaseIterable, Identifiable {
        case duration = "After"
        case endTime = "At Time"
        var id: String { rawValue }
    }

    let id = UUID()
    let mode: Mode
    let isActiveRecording: Bool
    let initialEndDate: Date?
}

/// The timer button beside the record / stop buttons.
struct RecordingTimerMenu: View {
    @ObservedObject var session: RecordingSession
    let isRecording: Bool
    let onCustom: (RecordingTimerSheetRequest) -> Void

    var body: some View {
        Menu {
            if isRecording {
                recordingItems
            } else {
                idleItems
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordingTimerButton)
    }

    @ViewBuilder
    private var idleItems: some View {
        Section("Stop Recording After") {
            ForEach(RecordingStopPlan.presetDurations, id: \.self) { seconds in
                Button {
                    session.setPendingStopPlan(.duration(seconds))
                } label: {
                    if session.pendingStopPlan == .duration(seconds) {
                        Label(RecordingStopFormatting.length(seconds), systemImage: "checkmark")
                    } else {
                        Text(RecordingStopFormatting.length(seconds))
                    }
                }
            }
            Button("Custom Length…") {
                onCustom(RecordingTimerSheetRequest(mode: .duration, isActiveRecording: false, initialEndDate: nil))
            }
        }
        Button("Stop at a Time…") {
            onCustom(RecordingTimerSheetRequest(mode: .endTime, isActiveRecording: false, initialEndDate: nil))
        }
        if session.pendingStopPlan != nil {
            Button("No Timer", role: .destructive) {
                session.setPendingStopPlan(nil)
            }
        }
    }

    @ViewBuilder
    private var recordingItems: some View {
        if let schedule = session.stopSchedule {
            Section("Stops at \(RecordingStopFormatting.clockTime(schedule.endDate))") {
                ForEach(RecordingStopSchedule.extensionChoices, id: \.self) { seconds in
                    Button("Extend \(RecordingStopFormatting.length(seconds))") {
                        session.extendScheduledStop(by: seconds)
                    }
                }
            }
            Button("Change Stop Time…") {
                onCustom(RecordingTimerSheetRequest(mode: .endTime, isActiveRecording: true,
                                                    initialEndDate: schedule.endDate))
            }
            Button("Remove Timer", role: .destructive) {
                session.cancelScheduledStop()
            }
        } else {
            Section("Stop Recording In") {
                ForEach(RecordingStopPlan.presetDurations, id: \.self) { seconds in
                    Button(RecordingStopFormatting.length(seconds)) {
                        session.scheduleStop(.duration(seconds))
                    }
                }
                Button("Custom Length…") {
                    onCustom(RecordingTimerSheetRequest(mode: .duration, isActiveRecording: true, initialEndDate: nil))
                }
            }
            Button("Stop at a Time…") {
                onCustom(RecordingTimerSheetRequest(mode: .endTime, isActiveRecording: true, initialEndDate: nil))
            }
        }
    }

    private var hasTimer: Bool {
        isRecording ? session.stopSchedule != nil : session.pendingStopPlan != nil
    }

    private var pendingPlanText: String? {
        switch session.pendingStopPlan {
        case .duration(let seconds):
            return RecordingStopFormatting.length(seconds)
        case .endTime(let hour, let minute):
            let date = RecordingStopPlan.nextOccurrence(hour: hour, minute: minute, after: Date())
            return RecordingStopFormatting.clockTime(date)
        case nil:
            return nil
        }
    }

    @ViewBuilder
    private var label: some View {
        if !isRecording, let text = pendingPlanText {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text(text)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(Capsule().fill(VoicelyTheme.accent.opacity(0.85)))
        } else {
            Image(systemName: "timer")
                .font(.body.weight(.semibold))
                .foregroundStyle(hasTimer ? VoicelyTheme.accent : Color.primary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
    }

    private var accessibilityLabel: String {
        if isRecording, let schedule = session.stopSchedule {
            return "Timer, stops at \(RecordingStopFormatting.clockTime(schedule.endDate))"
        }
        if let text = pendingPlanText {
            return "Timer, \(text)"
        }
        return "Timer"
    }
}

/// Shows when the active recording will stop, with a quick extend near the end.
struct RecordingStopStatusRow: View {
    @ObservedObject var session: RecordingSession
    let schedule: RecordingStopSchedule

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isWarning = schedule.isInWarningWindow(at: context.date)
            let tint: Color = isWarning ? .orange : .secondary
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(tint)
                Text(isWarning ? "Stopping soon" : "Stops at \(RecordingStopFormatting.clockTime(schedule.endDate))")
                    .foregroundStyle(isWarning ? Color.orange : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(RecordingStopFormatting.countdown(schedule.remaining(at: context.date)))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if isWarning {
                    Button {
                        session.extendScheduledStop(by: 10 * 60)
                    } label: {
                        Text("+10 min")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.orange)
                    .accessibilityIdentifier(AccessibilityIdentifiers.Library.extendRecordingButton)
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isWarning ? Color.orange.opacity(0.12) : Color.primary.opacity(0.04))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordingStopStatus)
    }
}

/// Custom length or end time, for the next recording or the one in progress.
struct RecordingTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: RecordingSession
    let request: RecordingTimerSheetRequest

    @State private var mode: RecordingTimerSheetRequest.Mode
    @State private var minutes: Int
    @State private var endTime: Date

    init(session: RecordingSession, request: RecordingTimerSheetRequest) {
        self.session = session
        self.request = request
        _mode = State(initialValue: request.mode)
        let initialMinutes: Int
        if case .duration(let seconds) = session.pendingStopPlan, !request.isActiveRecording {
            initialMinutes = Int(seconds / 60)
        } else {
            initialMinutes = 60
        }
        _minutes = State(initialValue: initialMinutes)
        _endTime = State(initialValue: request.initialEndDate ?? Self.defaultEndTime())
    }

    /// The next quarter hour at least 30 minutes away: a typical meeting end.
    private static func defaultEndTime(now: Date = Date()) -> Date {
        let target = now.addingTimeInterval(30 * 60)
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: target)
        let rounded = calendar.date(byAdding: .minute, value: (15 - minute % 15) % 15, to: target) ?? target
        return calendar.date(bySetting: .second, value: 0, of: rounded) ?? rounded
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Stop", selection: $mode) {
                    ForEach(RecordingTimerSheetRequest.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .duration:
                    Section {
                        Stepper(value: $minutes, in: 1...600) {
                            HStack {
                                TextField("Minutes", value: $minutes, format: .number)
                                    .keyboardType(.numberPad)
                                    .monospacedDigit()
                                    .frame(maxWidth: 80)
                                Text("min")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordingTimerMinutes)
                    } footer: {
                        Text(durationFooter)
                    }
                case .endTime:
                    Section {
                        DatePicker("Stop at", selection: $endTime, displayedComponents: .hourAndMinute)
                    } footer: {
                        Text(endTimeFooter)
                    }
                }
            }
            .navigationTitle(request.isActiveRecording ? "Recording Timer" : "Timer for Next Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        apply()
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityIdentifiers.Library.recordingTimerSetButton)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 260)
    }

    private var plan: RecordingStopPlan {
        switch mode {
        case .duration:
            return .duration(TimeInterval(max(1, minutes)) * 60)
        case .endTime:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: endTime)
            return .endTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
    }

    private var durationFooter: String {
        if request.isActiveRecording {
            let end = plan.endDate(startingAt: Date())
            return "Stops at \(RecordingStopFormatting.clockTime(end)), counted from now."
        }
        return "Counted from when you start recording."
    }

    private var endTimeFooter: String {
        let end = plan.endDate(startingAt: Date())
        let isTomorrow = !Calendar.current.isDate(end, inSameDayAs: Date())
        return isTomorrow
            ? "That time has passed today, so the recording stops tomorrow at \(RecordingStopFormatting.clockTime(end))."
            : "Voicely reminds you 3 minutes before and then stops and saves the recording."
    }

    private func apply() {
        if request.isActiveRecording {
            session.scheduleStop(plan)
        } else {
            session.setPendingStopPlan(plan)
        }
    }
}
