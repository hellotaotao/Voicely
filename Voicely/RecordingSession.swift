//
//  RecordingSession.swift
//  Voicely
//

import AVFoundation
import Foundation
import SwiftData
import UIKit

/// A finite iOS execution allowance for post-recording persistence and final flush.
/// Expiration releases the assertion; it does not cancel work or promise continued execution.
@MainActor
final class RecordingFinalizationBackgroundTask {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private let endTask: @MainActor (UIBackgroundTaskIdentifier) -> Void

    init(
        begin: @MainActor (@escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier = { expiration in
            #if targetEnvironment(macCatalyst)
            return .invalid
            #else
            return UIApplication.shared.beginBackgroundTask(withName: "Finalize recording", expirationHandler: expiration)
            #endif
        },
        end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    ) {
        endTask = end
        taskID = begin { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        let completedTaskID = taskID
        taskID = .invalid
        endTask(completedTaskID)
    }
}

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

    @Published private var finalizingNoteIDs: Set<UUID> = []
    @Published private var preparingAudioNoteIDs: Set<UUID> = []

    private var coordinator: IncrementalTranscriptionCoordinator?

    /// Called when a note is created (on start, or — defensively — on stop if no
    /// in-progress note exists). The owner inserts it into the model context and
    /// updates navigation selection.
    var onRecordingComplete: (VoiceNote) -> Void = { _ in }

    /// Overridable so tests can supply a coordinator that does no real work.
    var coordinatorFactory: (URL) -> IncrementalTranscriptionCoordinator

    var incrementalIntervalSeconds: Int = IncrementalTranscriptionTiming.defaultIntervalSeconds

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

    func isRecording(_ note: VoiceNote) -> Bool {
        currentRecordingNote?.id == note.id || finalizingNoteIDs.contains(note.id)
    }

    func isPreparingAudio(_ note: VoiceNote) -> Bool {
        preparingAudioNoteIDs.contains(note.id)
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
        transcriptionService.modelManager?.isModelLoaded() ?? false
    }

    private var isModelLoading: Bool {
        guard let modelManager = transcriptionService.modelManager else { return false }
        return modelManager.modelState == .loading || modelManager.modelState == .downloading
            || modelManager.modelState == .prewarming
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
        transcriptionService.beginLocalRecording(noteID: note.id)
        recordingStartedAt = Date()
        isStartingRecording = false
        didStart = true
        onRecordingComplete(note)
        RecordingLiveActivityController.shared.start(recordingID: note.id, title: note.title)

        let coord = coordinatorFactory(pcmURL)
        coord.frameCountProvider = { [weak audioService] in
            audioService?.currentFramePosition ?? 0
        }
        coord.transcriptCallback = { [weak self, note] transcript in
            guard let self else { return }
            guard let finalizedTranscript = LocalTranscriptFinalizer.finalizeTranscript(transcript) else { return }

            note.transcription = finalizedTranscript.text
            note.isTranscribing = true
            note.transcriptionModelIdentifier = self.transcriptionService.modelManager?.currentModelIdentifier()
                ?? self.transcriptionService.modelManager?.selectedModel
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
        let backgroundTask = RecordingFinalizationBackgroundTask()
        let capturedCoordinator = coordinator
        let recordingNote = currentRecordingNote
        coordinator = nil
        registerLiveActivityControls()
        currentRecordingNote = nil
        isStartingRecording = false
        recordingStartedAt = nil

        let stopResult = audioService.stopRecording()
        let finalFrame = audioService.currentFramePosition
        RecordingLiveActivityController.shared.end(elapsedDuration: stopResult.duration)

        guard let filePath = stopResult.filePath else {
            backgroundTask.end()
            capturedCoordinator?.pause()
            capturedCoordinator?.transcriptCallback = nil
            if let recordingNote {
                recordingNote.completeTranscription()
                recordingNote.transcriptionOutcome = .failed
                recordingNote.markTranscriptionFailure("Recording could not be finalized. Please check the saved audio before retrying.")
                recordingNote.clearTransientTranscriptionFlags()
                transcriptionService.endLocalRecording(noteID: recordingNote.id)
            }
            return
        }

        let note: VoiceNote
        if let recordingNote {
            note = recordingNote
        } else {
            note = makeRecordingNote(filePath: filePath)
            note.transcriptionOriginDeviceID = transcriptionService.deviceIDProvider()
            onRecordingComplete(note)
        }

        preparingAudioNoteIDs.insert(note.id)
        finalizingNoteIDs.insert(note.id)
        note.audioFilePath = filePath
        note.duration = stopResult.duration
        note.isTranscribing = true
        note.pendingTranscription = false
        note.transcriptionProgress = 0.0

        Task { @MainActor in
            defer {
                backgroundTask.end()
                finalizingNoteIDs.remove(note.id)
                transcriptionService.endLocalRecording(noteID: note.id)
            }
            let assetTask = Task { @MainActor in
                defer { preparingAudioNoteIDs.remove(note.id) }
                if let path = await stopResult.resolvedFilePath() {
                    note.audioFilePath = path
                    do {
                        try note.modelContext?.save()
                        return true
                    } catch {
                        return false
                    }
                }
                return false
            }
            let accumulatedTranscript: String
            if let coord = capturedCoordinator {
                accumulatedTranscript = await coord.stop(currentFrame: finalFrame)
            } else {
                accumulatedTranscript = ""
            }

            if await assetTask.value {
                await stopResult.cleanupTemporaryAudio()
            }

            let finalizedTranscript = LocalTranscriptFinalizer.finalizeTranscript(accumulatedTranscript)
            let trimmedTranscript = finalizedTranscript?.text ?? ""

            if !trimmedTranscript.isEmpty, capturedCoordinator?.requiresFullTranscription == false {
                note.transcription = trimmedTranscript
                note.transcriptionModelIdentifier = transcriptionService.modelManager?.currentModelIdentifier()
                    ?? transcriptionService.modelManager?.selectedModel
                note.recordTranscriptionTelemetry(transcriptionService.transcriptionTelemetry)
                note.completeTranscription()
                note.clearTransientTranscriptionFlags()
                return
            }

            transcriptionService.endLocalRecording(noteID: note.id)
            note.queueTranscription(at: Date())
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
