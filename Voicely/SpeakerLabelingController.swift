import Foundation
import SwiftData

/// The exact revision a job reads. Even if a new transcription produces the
/// same text, its times might differ, so compare the stored timeline as well.
struct SpeakerLabelingSource: Sendable {
    let noteID: UUID
    let audioPath: String
    let text: String
    let spans: [TranscriptSpan]
    let timingPlan: SpeakerTimingPlan?
    let timelineData: Data
    let isEnglish: Bool

    @MainActor init?(note: VoiceNote) {
        guard !note.audioFilePath.isEmpty,
              !note.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let spans = note.transcriptSpans,
              let data = note.transcriptSpansData else { return nil }
        noteID = note.id
        audioPath = note.audioFilePath
        let text = note.transcription
        self.text = text
        self.spans = spans
        timingPlan = SpeakerTimingPlan(text: text, spans: spans)
        timelineData = data
        isEnglish = note.transcribedByParakeetAlone
    }

    @MainActor func matches(_ note: VoiceNote) -> Bool {
        !note.isDeleted && note.id == noteID && note.audioFilePath == audioPath
            && note.transcription.utf8.elementsEqual(text.utf8) && note.transcriptSpansData == timelineData
    }
}

@MainActor
final class SpeakerLabelingController: ObservableObject {
    enum Phase: Equatable {
        case preparingAudio
        case downloadingAlignmentModel
        case loadingSpeakerModel
        case identifying(SpeakerProcessingProgress)
        case loadingAlignmentModel
        case aligning(SpeakerProcessingProgress)
        case applyingLabels
        case stopping

        var title: String {
            switch self {
            case .preparingAudio: String(localized: "Preparing audio…")
            case .downloadingAlignmentModel: String(localized: "Downloading text alignment model…")
            case .loadingSpeakerModel: String(localized: "Loading speaker identification model…")
            case .identifying: String(localized: "Identifying speakers…")
            case .loadingAlignmentModel: String(localized: "Loading text alignment model…")
            case .aligning: String(localized: "Aligning transcript…")
            case .applyingLabels: String(localized: "Applying speaker labels…")
            case .stopping: String(localized: "Stopping speaker identification…")
            }
        }

        var progress: SpeakerProcessingProgress? {
            switch self {
            case .identifying(let progress), .aligning(let progress): progress
            default: nil
            }
        }
    }

    enum ProgressStage: Sendable {
        case diarization
        case alignment

        func updating(_ phase: Phase?, with progress: SpeakerProcessingProgress) -> Phase? {
            guard progress.isValid else { return nil }
            switch (self, phase) {
            case (.diarization, .loadingSpeakerModel):
                return .identifying(progress)
            case (.alignment, .loadingAlignmentModel):
                return .aligning(progress)
            case (.diarization, .identifying(let previous)),
                 (.alignment, .aligning(let previous)):
                // The model callbacks are delivered to the main actor asynchronously.
                // Ignore delayed callbacks and only publish visible percentage changes.
                guard progress.totalUnits == previous.totalUnits, progress.percent > previous.percent else { return nil }
                return self == .diarization ? .identifying(progress) : .aligning(progress)
            default:
                return nil
            }
        }
    }

    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var phase: Phase?
    @Published private(set) var failureNoteID: UUID?
    @Published private(set) var failureMessage: String?

    private var task: Task<Void, Never>?
    private var activeRunID: UUID?

    private func progressReporter(for stage: ProgressStage, runID: UUID)
        -> @Sendable (SpeakerProcessingProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.activeRunID == runID,
                      let updated = stage.updating(self.phase, with: progress) else { return }
                self.phase = updated
            }
        }
    }

    static func needsAlignmentDownload(for source: SpeakerLabelingSource) -> Bool {
        #if targetEnvironment(macCatalyst)
        guard let plan = source.timingPlan, plan.requiresForcedAlignment else { return false }
        return plan.needsAlignmentDownload(alignmentInstalled: SpeakerTranscriptAligner.isModelInstalled)
        #else
        return false
        #endif
    }

    func start(note: VoiceNote, source: SpeakerLabelingSource, allowAlignmentDownload: Bool,
               transcriptionService: TranscriptionService) {
        #if targetEnvironment(macCatalyst)
        guard task == nil, source.matches(note), transcriptionService.isIdleForWarmUp else { return }
        let runID = UUID()
        activeRunID = runID
        activeNoteID = source.noteID
        phase = .preparingAudio
        clearFailure(for: source.noteID)

        task = Task { [weak self, weak note] in
            guard let self else { return }
            defer {
                self.phase = nil
                self.activeNoteID = nil
                self.activeRunID = nil
                self.task = nil
            }

            do {
                guard let plan = source.timingPlan else { throw SpeakerTranscriptAligner.AlignmentError.unsupportedTimeline }
                guard plan.hasSpeech else { throw SpeakerTranscriptAligner.AlignmentError.noAlignedSpeech }
                guard let audioURL = await CloudStorageManager.shared.prepareFileForReading(at: source.audioPath) else {
                    try Task.checkCancellation()
                    throw LabelingError.audioUnavailable
                }
                try Self.checkCanContinue(note, source: source, transcriptionService: transcriptionService)
                if Self.needsAlignmentDownload(for: source) {
                    guard allowAlignmentDownload else { throw LabelingError.alignmentNeedsDownload }
                    self.phase = .downloadingAlignmentModel
                    try await SpeakerTranscriptAligner.prepareModel()
                    try Self.checkCanContinue(note, source: source, transcriptionService: transcriptionService)
                }
                await transcriptionService.releaseModelsBeforeSpeakerLabeling()
                try Self.checkCanContinue(note, source: source, transcriptionService: transcriptionService)
                self.phase = .loadingSpeakerModel
                let speakerTimes = try await SpeakerDiarizationEngine.segments(
                    for: audioURL, onProgress: self.progressReporter(for: .diarization, runID: runID)
                )
                try Self.checkCanContinue(note, source: source, transcriptionService: transcriptionService)
                guard !speakerTimes.isEmpty else { throw LabelingError.noLabels }

                let tokens: [SpeakerAlignedToken]
                if plan.requiresForcedAlignment {
                    self.phase = .loadingAlignmentModel
                    tokens = try await SpeakerTranscriptAligner.align(
                        audioURL: audioURL, plan: plan, isEnglish: source.isEnglish,
                        onProgress: self.progressReporter(for: .alignment, runID: runID)
                    )
                } else {
                    tokens = plan.storedTokens
                }
                try Self.checkCanContinue(note, source: source, transcriptionService: transcriptionService)
                self.phase = .applyingLabels
                let labels = await Task.detached(priority: .userInitiated) {
                    SpeakerTranscriptBuilder.make(text: source.text, spans: source.spans, audioPath: source.audioPath,
                                                  tokens: tokens, segments: speakerTimes)
                }.value
                try Self.checkCanContinue(note, source: source, transcriptionService: transcriptionService)
                guard let note, let context = note.modelContext, let labels,
                      note.setSpeakerTranscript(labels) else { throw LabelingError.noLabels }
                do {
                    try context.save()
                } catch {
                    note.transcriptSpansData = source.timelineData
                    throw LabelingError.couldNotSave
                }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                self.failureNoteID = source.noteID
                self.failureMessage = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "Speaker identification failed. Your transcript is unchanged.")
            }
        }
        #endif
    }

    func cancel(noteID: UUID? = nil) {
        guard let task, noteID == nil || activeNoteID == noteID else { return }
        phase = .stopping
        task.cancel()
    }

    func clearFailure(for noteID: UUID) {
        guard failureNoteID == noteID else { return }
        failureNoteID = nil
        failureMessage = nil
    }

    func removeLabels(from note: VoiceNote) {
        guard let context = note.modelContext, !note.isDeleted, note.speakerTranscript != nil else { return }
        clearFailure(for: note.id)
        let previous = note.transcriptSpansData
        guard note.setSpeakerTranscript(nil) else { return }
        do {
            try context.save()
        } catch {
            note.transcriptSpansData = previous
            failureNoteID = note.id
            failureMessage = LabelingError.couldNotSave.errorDescription
        }
    }

    private static func checkCanContinue(_ note: VoiceNote?, source: SpeakerLabelingSource,
                                         transcriptionService: TranscriptionService) throws {
        try Task.checkCancellation()
        guard transcriptionService.isIdleForWarmUp else { throw CancellationError() }
        guard let note, source.matches(note), !transcriptionService.isTranscribingOnAnotherDevice(note)
        else { throw LabelingError.changed }
    }

    private enum LabelingError: LocalizedError {
        case audioUnavailable
        case alignmentNeedsDownload
        case changed
        case noLabels
        case couldNotSave

        var errorDescription: String? {
            switch self {
            case .audioUnavailable: String(localized: "The audio isn't available on this Mac. Try again once it has synced.")
            case .alignmentNeedsDownload: String(localized: "Tap Identify Speakers again to download the text alignment model.")
            case .changed: String(localized: "This recording changed during speaker identification. Try again.")
            case .noLabels: String(localized: "Voicely couldn't confidently match speakers to the transcript.")
            case .couldNotSave: String(localized: "The speaker labels could not be saved. Your transcript is unchanged.")
            }
        }
    }
}
