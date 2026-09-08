import Testing
@testable import Voicely

#if DEBUG
struct AudioTapTimingTests {
    @Test func comparesElapsedTimeAgainstActualInputPeriod() {
        let timing = AudioTapTiming(frameCount: 4_096, sampleRate: 48_000)
        #expect(!timing.exceedsBufferPeriod(elapsedNanoseconds: 85_333_333))
        #expect(timing.exceedsBufferPeriod(elapsedNanoseconds: 85_333_334))
    }

    @Test func equalPeriodDoesNotExceedBudget() {
        let timing = AudioTapTiming(frameCount: 480, sampleRate: 48_000)
        #expect(!timing.exceedsBufferPeriod(elapsedNanoseconds: 10_000_000))
        #expect(timing.exceedsBufferPeriod(elapsedNanoseconds: 10_000_001))
    }

    @Test func invalidInputDoesNotReportBudgetOverrun() {
        for rate in [0.0, -1.0, Double.infinity, Double.nan] {
            let timing = AudioTapTiming(frameCount: 4_096, sampleRate: rate)
            #expect(!timing.exceedsBufferPeriod(elapsedNanoseconds: UInt64.max))
        }
        #expect(!AudioTapTiming(frameCount: 0, sampleRate: 48_000)
            .exceedsBufferPeriod(elapsedNanoseconds: UInt64.max))
    }
}
#endif
