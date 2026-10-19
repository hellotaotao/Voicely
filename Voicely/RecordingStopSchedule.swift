//
//  RecordingStopSchedule.swift
//  Voicely
//

import Foundation

/// What the user picked before (or during) a recording: stop after a length of
/// time, or at a wall-clock time.
enum RecordingStopPlan: Equatable {
    case duration(TimeInterval)
    /// A clock time as picked; resolves to its next occurrence.
    case endTime(hour: Int, minute: Int)
    /// A clock time already resolved to a date, so a recording that starts
    /// after it has passed does not roll it over to tomorrow.
    case endDate(Date)

    static let presetDurations: [TimeInterval] = [15, 30, 45, 60, 90, 120].map { $0 * 60 }

    /// Resolves the plan to an absolute end date for a recording that starts at `start`.
    func endDate(startingAt start: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .duration(let seconds):
            return start.addingTimeInterval(max(seconds, RecordingStopSchedule.minimumLength))
        case .endTime(let hour, let minute):
            return Self.nextOccurrence(hour: hour, minute: minute, after: start, calendar: calendar)
        case .endDate(let date):
            return date
        }
    }

    /// Fixes a clock time to a date at the moment it is picked.
    func resolved(at now: Date, calendar: Calendar = .current) -> RecordingStopPlan {
        guard case .endTime = self else { return self }
        return .endDate(endDate(startingAt: now, calendar: calendar))
    }

    /// False for an end date that has passed, or is too close to record toward.
    func isUsable(at now: Date) -> Bool {
        guard case .endDate(let date) = self else { return true }
        return date >= now.addingTimeInterval(RecordingStopSchedule.minimumLength)
    }

    /// The first moment at `hour:minute` that lies at least a minute after `date`,
    /// so a time that already passed today means tomorrow.
    static func nextOccurrence(hour: Int, minute: Int, after date: Date, calendar: Calendar = .current) -> Date {
        let earliest = date.addingTimeInterval(RecordingStopSchedule.minimumLength)
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        if let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date),
           today >= earliest {
            return today
        }
        return calendar.nextDate(after: earliest, matching: components, matchingPolicy: .nextTime)
            ?? earliest
    }
}

/// The active stop time of a recording. The end is a wall-clock date: pausing
/// does not move it, because the point is to stop when the meeting ends.
struct RecordingStopSchedule: Equatable {
    static let minimumLength: TimeInterval = 60
    static let warningLeadTime: TimeInterval = 3 * 60
    static let extensionChoices: [TimeInterval] = [5, 10, 15, 30].map { $0 * 60 }
    /// The one-tap extend in the status row; taps add up, so it stays small.
    static let quickExtension: TimeInterval = 5 * 60

    private(set) var endDate: Date

    init(endDate: Date) {
        self.endDate = endDate
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, endDate.timeIntervalSince(now))
    }

    func shouldStop(at now: Date) -> Bool {
        now >= endDate
    }

    /// True during the final stretch before the stop, when the user is reminded.
    func isInWarningWindow(at now: Date) -> Bool {
        !shouldStop(at: now) && remaining(at: now) <= Self.warningLeadTime
    }

    /// When the reminder should fire, or nil if the schedule is already inside the window.
    func warningDate(at now: Date) -> Date? {
        let date = endDate.addingTimeInterval(-Self.warningLeadTime)
        return date > now ? date : nil
    }

    /// Pushes the end out by `seconds`, counted from the planned end so repeated
    /// taps add up the way they read ("+10" twice is twenty more minutes).
    mutating func extend(by seconds: TimeInterval, now: Date) {
        endDate = max(endDate, now).addingTimeInterval(seconds)
    }

    /// Replaces the end, never closer than a minute from now so a stale picker
    /// value cannot stop the recording the moment it is applied.
    mutating func reschedule(to date: Date, now: Date) {
        endDate = max(date, now.addingTimeInterval(Self.minimumLength))
    }
}

enum RecordingStopFormatting {
    /// "1:05:09" / "4:09" style countdown.
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "15 min", "1 hr", "1 hr 30 min".
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }

    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
