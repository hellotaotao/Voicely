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

    @Test @MainActor func onlyNewerWholePercentUpdatesApplyWithinTheirOwnPhase() {
        let stage = SpeakerLabelingController.ProgressStage.diarization
        let zero = SpeakerProcessingProgress(completedUnits: 0, totalUnits: 1000)
        let first = SpeakerProcessingProgress(completedUnits: 540, totalUnits: 1000)
        let samePercent = SpeakerProcessingProgress(completedUnits: 541, totalUnits: 1000)
        let lower = SpeakerProcessingProgress(completedUnits: 530, totalUnits: 1000)

        let started = stage.updating(.loadingSpeakerModel, with: zero)
        #expect(started == .identifying(zero))
        let active = stage.updating(started, with: first)
        #expect(active == .identifying(first))
        #expect(stage.updating(active, with: samePercent) == nil)
        #expect(stage.updating(active, with: lower) == nil)
        #expect(stage.updating(active, with: .init(completedUnits: 7, totalUnits: 10)) == nil)
        #expect(stage.updating(.loadingAlignmentModel, with: first) == nil)
        #expect(stage.updating(.stopping, with: first) == nil)
        #expect(stage.updating(.applyingLabels, with: first) == nil)
        #expect(stage.updating(nil, with: first) == nil)
    }

    @Test @MainActor func alignmentStartsItsOwnProgressAndRejectsInvalidCounts() {
        let stage = SpeakerLabelingController.ProgressStage.alignment
        let progress = SpeakerProcessingProgress(completedUnits: 1, totalUnits: 3)
        #expect(stage.updating(.loadingAlignmentModel, with: progress) == .aligning(progress))
        #expect(stage.updating(.loadingSpeakerModel, with: progress) == nil)
        #expect(stage.updating(.loadingAlignmentModel, with: .init(completedUnits: 1, totalUnits: 0)) == nil)
        #expect(stage.updating(.loadingAlignmentModel, with: .init(completedUnits: 4, totalUnits: 3)) == nil)
    }
}
