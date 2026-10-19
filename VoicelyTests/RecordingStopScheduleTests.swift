//
//  RecordingStopScheduleTests.swift
//  VoicelyTests
//

import Foundation
import Testing
@testable import Voicely

struct RecordingStopScheduleTests {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }()

    private static func date(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    // MARK: Plan resolution

    @Test func durationCountsFromTheStart() {
        let start = Self.date(9, 0)
        #expect(RecordingStopPlan.duration(35 * 60).endDate(startingAt: start, calendar: Self.calendar)
            == Self.date(9, 35))
        #expect(RecordingStopPlan.duration(41 * 60).endDate(startingAt: start, calendar: Self.calendar)
            == Self.date(9, 41))
    }

    @Test func endTimeLaterTodayStaysToday() {
        let end = RecordingStopPlan.endTime(hour: 10, minute: 0)
            .endDate(startingAt: Self.date(9, 12, 30), calendar: Self.calendar)
        #expect(end == Self.date(10, 0))
    }

    @Test func endTimeThatAlreadyPassedMeansTomorrow() {
        let end = RecordingStopPlan.endTime(hour: 8, minute: 30)
            .endDate(startingAt: Self.date(9, 0), calendar: Self.calendar)
        #expect(end == Self.date(8, 30, day: 21))
    }

    @Test func endTimeLessThanAMinuteAwayMeansTomorrow() {
        let end = RecordingStopPlan.endTime(hour: 10, minute: 0)
            .endDate(startingAt: Self.date(9, 59, 30), calendar: Self.calendar)
        #expect(end == Self.date(10, 0, day: 21))
    }

    // MARK: Schedule

    @Test func warningWindowCoversTheLastThreeMinutes() {
        let schedule = RecordingStopSchedule(endDate: Self.date(10, 0))
        #expect(!schedule.isInWarningWindow(at: Self.date(9, 56, 59)))
        #expect(schedule.isInWarningWindow(at: Self.date(9, 57)))
        #expect(schedule.isInWarningWindow(at: Self.date(9, 59, 59)))
        #expect(!schedule.isInWarningWindow(at: Self.date(10, 0)))
        #expect(!schedule.shouldStop(at: Self.date(9, 59, 59)))
        #expect(schedule.shouldStop(at: Self.date(10, 0)))
        #expect(schedule.warningDate(at: Self.date(9, 0)) == Self.date(9, 57))
        #expect(schedule.warningDate(at: Self.date(9, 58)) == nil)
    }

    @Test func extendingAddsToThePlannedEnd() {
        var schedule = RecordingStopSchedule(endDate: Self.date(10, 0))
        schedule.extend(by: 10 * 60, now: Self.date(9, 58))
        schedule.extend(by: 10 * 60, now: Self.date(9, 58, 5))
        #expect(schedule.endDate == Self.date(10, 20))
    }

    @Test func extendingAnOverdueScheduleCountsFromNow() {
        var schedule = RecordingStopSchedule(endDate: Self.date(10, 0))
        schedule.extend(by: 5 * 60, now: Self.date(10, 2))
        #expect(schedule.endDate == Self.date(10, 7))
    }

    @Test func reschedulingNeverLandsWithinAMinute() {
        var schedule = RecordingStopSchedule(endDate: Self.date(10, 0))
        schedule.reschedule(to: Self.date(9, 30), now: Self.date(9, 40))
        #expect(schedule.endDate == Self.date(9, 41))
        schedule.reschedule(to: Self.date(11, 15), now: Self.date(9, 40))
        #expect(schedule.endDate == Self.date(11, 15))
    }

    @Test func formatting() {
        #expect(RecordingStopFormatting.countdown(179.2) == "3:00")
        #expect(RecordingStopFormatting.countdown(3_909) == "1:05:09")
        #expect(RecordingStopFormatting.length(45 * 60) == "45 min")
        #expect(RecordingStopFormatting.length(60 * 60) == "1 hr")
        #expect(RecordingStopFormatting.length(90 * 60) == "1 hr 30 min")
    }
}

@MainActor
struct RecordingSessionStopScheduleTests {

    final class RecordingNotifier: RecordingStopNotifying {
        private(set) var warnings: [(warning: Date, end: Date)] = []
        private(set) var cancelCount = 0
        private(set) var announcedEnds: [Date] = []
        private(set) var authorizationRequests = 0
        private var handler: ((RecordingStopReminderAction) -> Void)?

        func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
        func scheduleWarning(at warningDate: Date, endDate: Date, noteTitle: String) {
            warnings.append((warningDate, endDate))
        }
        func cancelWarning() { cancelCount += 1 }
        func announceScheduledStop(endDate: Date, noteTitle: String) { announcedEnds.append(endDate) }
        func setActionHandler(_ handler: @escaping (RecordingStopReminderAction) -> Void) {
            self.handler = handler
        }
        func tap(_ action: RecordingStopReminderAction) { handler?(action) }
    }

    private struct Fixture {
        let session: RecordingSession
        let audio: RecordingSessionTests.MockRecordingAudio
        let notifier: RecordingNotifier
        let pcmURL: URL
        let clock: TestClock
    }

    final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeFixture() throws -> Fixture {
        let audio = RecordingSessionTests.MockRecordingAudio()
        let pcmURL = try IncrementalTranscriptionCoordinatorTests().makeSilentCAF(seconds: 2)
        audio.currentPCMFileURL = pcmURL
        let notifier = RecordingNotifier()
        let session = RecordingSession(
            audioService: audio, transcriptionService: TranscriptionService(), stopNotifier: notifier)
        session.coordinatorFactory = { url in
            let coordinator = IncrementalTranscriptionCoordinator(
                transcriptionService: TranscriptionService(), recordingFileURL: url)
            coordinator.transcribeOverride = { @Sendable _ in "" }
            return coordinator
        }
        let clock = TestClock()
        session.now = { clock.now }
        return Fixture(session: session, audio: audio, notifier: notifier, pcmURL: pcmURL, clock: clock)
    }

    private func start(_ fixture: Fixture) async throws {
        fixture.session.startRecording()
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while fixture.session.currentRecordingNote == nil {
            try #require(ContinuousClock().now < deadline, "Timed out waiting for the recording to start")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pendingPlanBecomesTheRecordingsScheduleAndFiresAtItsEnd() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        fixture.session.setPendingStopPlan(.duration(30 * 60))
        #expect(fixture.notifier.authorizationRequests == 1)

        try await start(fixture)
        let schedule = try #require(fixture.session.stopSchedule)
        #expect(schedule.endDate == fixture.clock.now.addingTimeInterval(30 * 60))
        #expect(fixture.session.pendingStopPlan == nil)
        #expect(fixture.notifier.warnings.last?.end == schedule.endDate)

        fixture.clock.now = schedule.endDate.addingTimeInterval(-1)
        fixture.session.evaluateStopSchedule()
        #expect(fixture.audio.stopCount == 0)

        fixture.clock.now = schedule.endDate
        fixture.session.evaluateStopSchedule()
        #expect(fixture.audio.stopCount == 1)
        #expect(fixture.session.stopSchedule == nil)
        #expect(fixture.session.currentRecordingNote == nil)
        #expect(fixture.notifier.announcedEnds == [schedule.endDate])
    }

    @Test func extendingMovesTheStopAndTheReminder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        try await start(fixture)
        fixture.session.scheduleStop(.duration(10 * 60))
        let originalEnd = try #require(fixture.session.stopSchedule?.endDate)
        #expect(originalEnd == fixture.clock.now.addingTimeInterval(10 * 60))

        fixture.clock.now = originalEnd.addingTimeInterval(-60)
        fixture.notifier.tap(.extend(10 * 60))
        let extendedEnd = originalEnd.addingTimeInterval(10 * 60)
        #expect(fixture.session.stopSchedule?.endDate == extendedEnd)
        #expect(fixture.notifier.warnings.last?.warning == extendedEnd.addingTimeInterval(-3 * 60))

        fixture.clock.now = originalEnd
        fixture.session.evaluateStopSchedule()
        #expect(fixture.audio.stopCount == 0)

        fixture.clock.now = extendedEnd
        fixture.session.evaluateStopSchedule()
        #expect(fixture.audio.stopCount == 1)
    }

    @Test func removingTheTimerKeepsRecording() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        try await start(fixture)
        fixture.session.scheduleStop(.duration(5 * 60))
        let cancelsBefore = fixture.notifier.cancelCount

        fixture.session.cancelScheduledStop()
        #expect(fixture.session.stopSchedule == nil)
        #expect(fixture.notifier.cancelCount > cancelsBefore)

        fixture.clock.now = fixture.clock.now.addingTimeInterval(60 * 60)
        fixture.session.evaluateStopSchedule()
        #expect(fixture.audio.stopCount == 0)
        #expect(fixture.session.currentRecordingNote != nil)
    }

    @Test func pausedRecordingStillStopsOnTime() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        try await start(fixture)
        fixture.session.scheduleStop(.duration(5 * 60))
        fixture.session.togglePauseResume()
        #expect(fixture.audio.isPaused)

        fixture.clock.now = fixture.clock.now.addingTimeInterval(5 * 60)
        fixture.session.evaluateStopSchedule()
        #expect(fixture.audio.stopCount == 1)
    }

    @Test func stopNowFromTheReminderSkipsTheAccidentalStopGuard() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        try await start(fixture)
        fixture.session.scheduleStop(.duration(5 * 60))

        fixture.notifier.tap(.stopNow)
        #expect(fixture.audio.stopCount == 1)
        #expect(fixture.session.stopSchedule == nil)
        #expect(fixture.notifier.announcedEnds.isEmpty)
    }

    @Test func manualStopClearsTheScheduleAndItsReminder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        try await start(fixture)
        fixture.session.scheduleStop(.duration(5 * 60))
        let cancelsBefore = fixture.notifier.cancelCount

        fixture.session.stopDueToInterruption()
        #expect(fixture.session.stopSchedule == nil)
        #expect(fixture.notifier.cancelCount > cancelsBefore)

        // A stale reminder action after the stop must not touch the next recording.
        fixture.notifier.tap(.stopNow)
        #expect(fixture.audio.stopCount == 1)
    }

    @Test func pendingStopTimeIsFixedWhenPickedNotWhenRecordingStarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        let picked = fixture.clock.now
        fixture.session.setPendingStopPlan(.endTime(hour: 23, minute: 59))
        guard case .endDate(let end) = fixture.session.pendingStopPlan else {
            Issue.record("Expected the picked time to be stored as a date")
            return
        }
        #expect(end == RecordingStopPlan.nextOccurrence(hour: 23, minute: 59, after: picked))

        fixture.clock.now = end.addingTimeInterval(-10 * 60)
        try await start(fixture)
        #expect(fixture.session.stopSchedule?.endDate == end)
    }

    @Test func pendingStopTimeThatPassedBeforeStartingIsDropped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        let end = fixture.clock.now.addingTimeInterval(30 * 60)
        fixture.session.setPendingStopPlan(.endDate(end))
        #expect(fixture.session.pendingStopPlan(at: fixture.clock.now) != nil)

        // Starting half an hour late must not roll the stop over to tomorrow.
        fixture.clock.now = end.addingTimeInterval(30 * 60)
        #expect(fixture.session.pendingStopPlan(at: fixture.clock.now) == nil)
        try await start(fixture)
        #expect(fixture.session.stopSchedule == nil)
        #expect(fixture.session.pendingStopPlan == nil)
        #expect(fixture.notifier.warnings.isEmpty)
    }

    @Test func pendingStopTimeClearsItselfOnceItCanNoLongerBeUsed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        // Usable for about one more real second.
        fixture.session.setPendingStopPlan(.endDate(fixture.clock.now.addingTimeInterval(61)))
        #expect(fixture.session.pendingStopPlan != nil)

        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while fixture.session.pendingStopPlan != nil, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(fixture.session.pendingStopPlan == nil)
    }

    @Test func quickExtendAddsUpAcrossTaps() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        try await start(fixture)
        fixture.session.scheduleStop(.duration(10 * 60))
        let originalEnd = try #require(fixture.session.stopSchedule?.endDate)

        fixture.clock.now = originalEnd.addingTimeInterval(-2 * 60)
        for _ in 0..<3 { fixture.session.extendScheduledStop(by: RecordingStopSchedule.quickExtension) }
        #expect(fixture.session.stopSchedule?.endDate == originalEnd.addingTimeInterval(15 * 60))
    }

    @Test func schedulingNeedsAnActiveRecording() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.pcmURL) }
        fixture.session.scheduleStop(.duration(5 * 60))
        #expect(fixture.session.stopSchedule == nil)
    }
}
