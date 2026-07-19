//
//  RecordingSession.swift
//  Voicely
//

import AVFoundation
import Foundation

/// Abstraction over the audio recorder so the recording-session control logic
/// can be unit-tested without driving a real `AVAudioEngine`.
@MainActor
protocol RecordingAudioControlling: AnyObject {
    var isRecording: Bool { get }
    var isPaused: Bool { get }
    var recordingDuration: TimeInterval { get }
    var hasPermission: Bool { get }
    var currentPCMFileURL: URL? { get }
    var currentFramePosition: AVAudioFramePosition { get }

    func startRecording() -> String?
    func stopRecording() -> RecordingStopResult
    func pauseRecording()
    @discardableResult func resumeRecording() -> Bool
}

extension AudioRecordingService: RecordingAudioControlling {}

/// Owns the lifecycle of a single recording session: which note is being
/// recorded, the incremental-transcription coordinator, and the start / pause /
/// stop control flow.
///
/// This object is deliberately a reference type held by the **root** view
/// (`ContentView`) as a `@StateObject`. Earlier this state lived in the
/// `RecordingControls` *subview* as `@State`, so anything that changed the
/// subview's identity — most notably an iPhone rotation, which swaps the whole
/// layout tree between the horizontal and vertical branches — destroyed and
/// recreated the subview and reset `currentRecordingNote`/`coordinator` to nil
/// *while recording continued*. On stop, `finalizeRecording()` then saw no
/// in-progress note, spun up a brand-new note for the same audio file, and
/// re-transcribed the whole recording from scratch. Hoisting the state into an
/// object whose lifetime matches the recording session fixes that at the root.
@MainActor
final class RecordingSession: ObservableObject {

    // MARK: Published session state

    /// The note currently being recorded, or nil when idle. Live transcription
    /// segments are written to this note as they complete.
    @Published private(set) var currentRecordingNote: VoiceNote?
    @Published private(set) var isStartingRecording = false
    @Published private(set) var recordingStartedAt: Date?

    // MARK: Dependencies

    private let audioService: RecordingAudioControlling
    private let transcriptionService: TranscriptionService

    private var coordinator: IncrementalTranscriptionCoordinator?

    /// Called when a note is created (on start, or — defensively — on stop if no
    /// in-progress note exists). The owner inserts it into the model context and
    /// updates navigation selection.
    var onRecordingComplete: (VoiceNote) -> Void = { _ in }

    /// Overridable so tests can supply a coordinator that does no real work.
    var coordinatorFactory: (URL) -> IncrementalTranscriptionCoordinator

    /// Live incremental cadence for the active engine: Whisper batches ≤29 s
    /// (one Whisper window); Qwen3 stays under its 15 s fast-path bound.
    var incrementalIntervalSeconds: Int {
        switch TranscriptionEngineMode.currentResolved() {
        case .qwen3ASR: return Int(Qwen3ASRDefaults.chunkSeconds)
        case .whisperKit: return IncrementalTranscriptionTiming.defaultIntervalSeconds
        }
    }

    // MARK: Init

    init(audioService: RecordingAudioControlling, transcriptionService: TranscriptionService) {
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.coordinatorFactory = { url in
            IncrementalTranscriptionCoordinator(
                transcriptionService: transcriptionService,
                recordingFileURL: url
            )
        }
    }

    // MARK: Derived UI state

    var controlPhase: RecordingControlPhase {
        RecordingControlState.phase(
            isRecording: audioService.isRecording,
            isStarting: isStartingRecording
        )
    }

    /// True while this note is the one being recorded. Deleting it mid-recording
    /// would leave `finalizeRecording`'s trailing task writing to a note that is
    /// no longer in the model context, so callers guard destructive actions on it.
    func isRecording(_ note: VoiceNote) -> Bool {
        currentRecordingNote?.id == note.id
    }

    var canStopRecording: Bool {
        RecordingControlState.shouldAcceptStopRequest(
            isStarting: isStartingRecording,
            recordingStartedAt: recordingStartedAt,
            now: Date(),
            recordingDuration: audioService.recordingDuration
        )
    }

    private var isModelLoaded: Bool {
        transcriptionService.isWhisperAvailable()
    }

    private var isModelLoading: Bool {
        switch TranscriptionEngineMode.currentResolved() {
        case .qwen3ASR:
            if case .downloading = Qwen3ModelDownloadController.shared.state { return true }
            return false
        case .whisperKit:
            guard let modelManager = transcriptionService.modelManager else { return false }
            return modelManager.modelState == .loading || modelManager.modelState == .downloading
                || modelManager.modelState == .prewarming
        }
    }

    // MARK: Start

    func startRecording() {
        guard !isStartingRecording,
              !audioService.isRecording,
              currentRecordingNote == nil else { return }

        isStartingRecording = true

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard isStartingRecording else { return }
            beginRecordingAfterFeedback()
        }
    }

    func startRecordingFromQuickAction() {
        guard !audioService.isRecording, !isStartingRecording else { return }

        if !isModelLoaded && !isModelLoading {
            Task {
                _ = await transcriptionService.loadWhisperModel()
            }
        }

        startRecording()
    }

    private func beginRecordingAfterFeedback() {
        var didStart = false
        defer {
            if !didStart {
                isStartingRecording = false
                recordingStartedAt = nil
            }
        }

        guard let filePath = audioService.startRecording() else { return }
        guard let pcmURL = audioService.currentPCMFileURL else {
            _ = audioService.stopRecording()
            return
        }

        let note = makeRecordingNote(filePath: filePath)
        transcriptionService.configureNewNote(note, shouldStartImmediately: true)
        note.isTranscribing = true
        note.transcriptionProgress = 0.0
        currentRecordingNote = note
        recordingStartedAt = Date()
        isStartingRecording = false
        didStart = true
        onRecordingComplete(note)
        RecordingLiveActivityController.shared.start(recordingID: note.id, title: note.title)

        let coord = coordinatorFactory(pcmURL)
        coord.frameCountProvider = { [weak audioService] in
            audioService?.currentFramePosition ?? 0
        }
        coord.transcriptCallback = { [weak self, note] assembled in
            guard let self else { return }
            // The coordinator already assembled (filtered) the transcript across
            // segments — text and word timings land together, in lockstep.
            note.setTranscript(text: assembled.text, words: assembled.words)
            note.isTranscribing = true
            note.transcriptionModelIdentifier = self.transcriptionService.currentEngineModelIdentifier()
            note.transcriptionLastErrorMessage = nil
            note.recordTranscriptionTelemetry(self.transcriptionService.transcriptionTelemetry)
        }
        coordinator = coord
        registerLiveActivityControls()
        coord.start(intervalSeconds: incrementalIntervalSeconds)
    }

    // MARK: Pause / Resume

    func togglePauseResume() {
        if audioService.isPaused {
            guard audioService.resumeRecording() else { return }
            coordinator?.resume(intervalSeconds: incrementalIntervalSeconds)
            RecordingLiveActivityController.shared.resume(elapsedDuration: audioService.recordingDuration)
        } else {
            audioService.pauseRecording()
            coordinator?.pause()
            RecordingLiveActivityController.shared.pause(elapsedDuration: audioService.recordingDuration)
        }
    }

    func togglePauseResumeFromQuickAction() {
        guard audioService.isRecording else { return }
        togglePauseResume()
    }

    /// Wires the lock-screen / Live Activity pause toggle to this session.
    /// Captures `self` weakly so a stale session can never act on a recording.
    func registerLiveActivityControls() {
        RecordingControlCommandCenter.shared.setTogglePauseHandler { [weak self] in
            guard let self, self.audioService.isRecording else { return }
            self.togglePauseResume()
        }
    }

    // MARK: Stop

    func stopRecording() {
        guard canStopRecording else { return }
        finalizeRecording()
    }

    /// Force-finalizes the active recording without the accidental-stop guard.
    /// Used when the system interrupts recording (incoming call, another app
    /// taking the audio session) — an interruption is never accidental and may
    /// arrive within the first second of recording.
    func stopDueToInterruption() {
        guard audioService.isRecording else { return }
        finalizeRecording()
    }

    private func finalizeRecording() {
        let capturedCoordinator = coordinator
        let recordingNote = currentRecordingNote
        coordinator = nil
        registerLiveActivityControls()
        currentRecordingNote = nil
        isStartingRecording = false
        recordingStartedAt = nil

        let finalFrame = audioService.currentFramePosition
        let stopResult = audioService.stopRecording()
        RecordingLiveActivityController.shared.end(elapsedDuration: stopResult.duration)

        guard let filePath = stopResult.filePath else { return }

        let note: VoiceNote
        if let recordingNote {
            note = recordingNote
        } else {
            note = makeRecordingNote(filePath: filePath)
            onRecordingComplete(note)
        }

        note.audioFilePath = filePath
        note.duration = stopResult.duration
        note.isTranscribing = true
        note.pendingTranscription = false
        note.transcriptionProgress = 0.0

        Task { @MainActor in
            var assembled: AssembledTranscript?
            if let coord = capturedCoordinator {
                _ = await coord.stop(currentFrame: finalFrame)
                assembled = coord.assembledTranscript
            }

            if let assembled {
                // Live recordings carry word timings too — text and timeline are
                // one write, already filtered across segments by the assembler.
                note.setTranscript(text: assembled.text, words: assembled.words)
                note.transcriptionModelIdentifier = transcriptionService.modelManager?.currentModelIdentifier()
                    ?? transcriptionService.modelManager?.selectedModel
                note.recordTranscriptionTelemetry(transcriptionService.transcriptionTelemetry)
                note.completeTranscription()
                note.clearTransientTranscriptionFlags()
                return
            }

            await stopResult.awaitConversionIfNeeded(forIncrementalTranscript: "")
            transcriptionService.configureNewNote(note, shouldStartImmediately: isModelLoaded)
            if isModelLoaded {
                await transcriptionService.processPendingTranscriptions(notes: [note])
            }
        }
    }

    private func makeRecordingNote(filePath: String) -> VoiceNote {
        VoiceNote(
            title: "Voice Note \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))",
            audioFilePath: filePath
        )
    }
}
