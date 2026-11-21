import Testing
@testable import Voicely

struct SpeakerProcessingProgressTests {
    @Test func wholePercentDoesNotRoundUpBeforeWorkFinishes() {
        #expect(SpeakerProcessingProgress(completedUnits: 58, totalUnits: 100).percent == 58)
        #expect(SpeakerProcessingProgress(completedUnits: 2, totalUnits: 3).percent == 66)
        #expect(SpeakerProcessingProgress(completedUnits: 999, totalUnits: 1000).percent == 99)
        #expect(SpeakerProcessingProgress(completedUnits: .max - 1, totalUnits: .max).percent == 99)
        #expect(SpeakerProcessingProgress(completedUnits: 1000, totalUnits: 1000).percent == 100)
    }
}
