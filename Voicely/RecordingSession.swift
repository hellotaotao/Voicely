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

/// Asks iOS (26+) to keep finalizing a stopped recording after the user leaves
/// the app, showing system progress. When the system declines or expires the
/// task, finalization still runs under `RecordingFinalizationBackgroundTask` and
/// resumes with the app; this type never cancels the work itself.
@MainActor
final class RecordingFinalizationContinuation {
    private let driver: (any ContinuedProcessingDriver)?
    private let progress: () -> Double
    private var identifier: String?
    private var handle: (any ContinuedProcessingHandle)?
    private var progressTask: Task<Void, Never>?
    private var isFinished = false
    private var heartbeat: DecodeWorkHeartbeat

    init(
        driver: (any ContinuedProcessingDriver)?,
        title: String,
        subtitle: String,
        decodeWork: @escaping () -> UInt64 = { 0 },
        progress: @escaping () -> Double
    ) {
        self.driver = driver
        self.progress = progress
        heartbeat = DecodeWorkHeartbeat(decodeWork: decodeWork)
        let submitted = driver?.submit(title: title, subtitle: subtitle) { [weak self] handle in
            guard let self, !self.isFinished else {
                handle.complete(success: false)
                return
            }
            self.identifier = nil
            self.handle = handle
            handle.expirationHandler = { [weak self] in self?.release(success: false) }
            self.startReportingProgress()
        }
        if handle == nil {
            identifier = submitted
        }
    }

    func finish(success: Bool) {
        isFinished = true
        if let identifier {
            driver?.cancel(identifier: identifier)
        }
        identifier = nil
        release(success: success)
    }

    private func startReportingProgress() {
        report()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.report()
            }
        }
    }

    private func report() {
        let value = progress()
        let clamped = value.isFinite ? min(max(value, 0), 0.99) : 0
        handle?.update(progress: clamped, subtitle: "\(Int((clamped * 100).rounded(.down)))% transcribed")
        if heartbeat.decoderAdvanced() { handle?.advanceForWork() }
    }

    private func release(success: Bool) {
        progressTask?.cancel()
        progressTask = nil
        handle?.expirationHandler = nil
        handle?.complete(success: success)
        handle = nil
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

    func startRecording() async -> String?
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

    /// The stop the user picked before starting; applied when the next recording begins.
    @Published var pendingStopPlan: RecordingStopPlan?
    /// The active recording's scheduled stop, or nil when it runs until stopped by hand.
    @Published private(set) var stopSchedule: RecordingStopSchedule?

    // MARK: Dependencies

    private let audioService: RecordingAudioControlling
    private let transcriptionService: TranscriptionService

    @Published private var finalizingNoteIDs: Set<UUID> = []
    @Published private var preparingAudioNoteIDs: Set<UUID> = []

    private var coordinator: IncrementalTranscriptionCoordinator?
    private var stopScheduleTask: Task<Void, Never>?
    private var pendingStopExpiryTask: Task<Void, Never>?
    private let stopNotifier: RecordingStopNotifying
    /// Injectable so tests can move time without waiting.
    var now: () -> Date = Date.init

    /// Called when a note is created (on start, or — defensively — on stop if no
    /// in-progress note exists). The owner inserts it into the model context and
    /// updates navigation selection.
    var onRecordingComplete: (VoiceNote) -> Void = { _ in }

    /// Overridable so tests can supply a coordinator that does no real work.
    var coordinatorFactory: (URL) -> IncrementalTranscriptionCoordinator

    var incrementalIntervalSeconds: Int = IncrementalTranscriptionTiming.defaultIntervalSeconds

    /// Where launch recovery looks for, and saves, audio of recordings that never stopped.
    var orphanedRecordingStorage: OrphanedRecordingStorage = .live
    /// PCM files an earlier recovery pass is still exporting.
    private var recoveringPCMFiles: Set<URL> = []

    /// Keeps post-recording finalization running after the user leaves the app.
    var continuedProcessingDriver: (any ContinuedProcessingDriver)? = SystemContinuedProcessingDriver.shared

    /// Below this much remaining audio the finite background task is enough, and
    /// the system progress UI would only flash.
    static let continuedProcessingThresholdSeconds: Double = 20

    // MARK: Init

    init(
        audioService: RecordingAudioControlling,
        transcriptionService: TranscriptionService,
        stopNotifier: RecordingStopNotifying? = nil
    ) {
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.stopNotifier = stopNotifier
            ?? (AppRuntime.isRunningTests ? SilentRecordingStopNotifier() : RecordingStopNotifier.shared)
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
        return modelManager.modelState == .loading
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
            await beginRecordingAfterFeedback()
        }
    }

    func startRecordingFromQuickAction() {
        guard !audioService.isRecording, !isStartingRecording else { return }

        if !isModelLoaded && !isModelLoading {
            Task {
                _ = await transcriptionService.loadSpeechModel()
            }
        }

        startRecording()
    }

    private func beginRecordingAfterFeedback() async {
        var didStart = false
        defer {
            if !didStart {
                isStartingRecording = false
                recordingStartedAt = nil
            }
        }

        guard let filePath = await audioService.startRecording() else { return }
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
        coord.configureTelemetry(noteID: note.id)
        coord.telemetryCallback = { [weak note] snapshot in
            note?.replaceCumulativeTranscriptionTelemetry(snapshot)
        }
        coord.frameCountProvider = { [weak audioService] in
            audioService?.currentFramePosition ?? 0
        }
        coord.transcriptCallback = { [weak self, note] transcript in
            guard let self else { return }
            guard let finalizedTranscript = LocalTranscriptFinalizer.finalizeTranscript(transcript) else { return }

            note.setTranscript(finalizedTranscript.text, spans: nil)
            note.isTranscribing = true
            note.transcriptionModelIdentifier = self.transcriptionService.modelManager?.currentModelIdentifier()
                ?? self.transcriptionService.modelManager?.selectedModel
            note.transcriptionLastErrorMessage = nil
        }
        coordinator = coord
        registerLiveActivityControls()
        coord.start(intervalSeconds: incrementalIntervalSeconds)

        if let plan = pendingStopPlan {
            clearPendingStopPlan()
            // A stop time that passed before the recording began is dropped,
            // never rolled over to the same time tomorrow.
            if plan.isUsable(at: now()) {
                applyStopSchedule(RecordingStopSchedule(endDate: plan.endDate(startingAt: now())))
            }
        }
    }

    // MARK: Scheduled stop

    /// Chooses the stop for the next recording; nil clears it.
    func setPendingStopPlan(_ plan: RecordingStopPlan?) {
        clearPendingStopPlan()
        guard let resolved = plan?.resolved(at: now()) else { return }
        pendingStopPlan = resolved
        stopNotifier.requestAuthorizationIfNeeded()

        // Drop a stop time once it can no longer be used, so the idle controls
        // never keep offering a time that has already passed.
        if case .endDate(let date) = resolved {
            let delay = date.addingTimeInterval(-RecordingStopSchedule.minimumLength).timeIntervalSince(now())
            pendingStopExpiryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, delay)))
                guard !Task.isCancelled, let self, self.pendingStopPlan == resolved else { return }
                self.pendingStopPlan = nil
            }
        }
    }

    private func clearPendingStopPlan() {
        pendingStopExpiryTask?.cancel()
        pendingStopExpiryTask = nil
        pendingStopPlan = nil
    }

    /// The pending plan as the idle controls should show it: nil once its end time has passed.
    func pendingStopPlan(at date: Date) -> RecordingStopPlan? {
        guard let pendingStopPlan, pendingStopPlan.isUsable(at: date) else { return nil }
        return pendingStopPlan
    }

    /// Adds or replaces the stop of the active recording.
    func scheduleStop(_ plan: RecordingStopPlan) {
        guard audioService.isRecording, currentRecordingNote != nil else { return }
        stopNotifier.requestAuthorizationIfNeeded()
        var schedule = stopSchedule ?? RecordingStopSchedule(endDate: now())
        schedule.reschedule(to: plan.endDate(startingAt: now()), now: now())
        applyStopSchedule(schedule)
    }

    func extendScheduledStop(by seconds: TimeInterval) {
        guard var schedule = stopSchedule else { return }
        schedule.extend(by: seconds, now: now())
        applyStopSchedule(schedule)
    }

    func cancelScheduledStop() {
        guard stopSchedule != nil else { return }
        clearStopSchedule()
        updateLiveActivitySchedule()
    }

    /// Stops the recording once its end has passed. Driven by a one-second
    /// ticker that compares against the wall clock, so a late tick (app in the
    /// background, Mac woken from sleep) still stops as soon as it runs.
    func evaluateStopSchedule() {
        guard let schedule = stopSchedule, audioService.isRecording else { return }
        guard schedule.shouldStop(at: now()) else { return }
        debugLog("⏰ [RecordingSession] Scheduled stop reached at \(schedule.endDate)")
        let title = currentRecordingNote?.title ?? "Recording"
        finalizeRecording()
        stopNotifier.announceScheduledStop(endDate: schedule.endDate, noteTitle: title)
    }

    private func applyStopSchedule(_ schedule: RecordingStopSchedule) {
        stopSchedule = schedule
        stopNotifier.setActionHandler { [weak self] action in
            self?.handleStopReminderAction(action)
        }
        stopNotifier.cancelWarning()
        if let warningDate = schedule.warningDate(at: now()) {
            stopNotifier.scheduleWarning(
                at: warningDate,
                endDate: schedule.endDate,
                noteTitle: currentRecordingNote?.title ?? "Your recording"
            )
        }
        updateLiveActivitySchedule()
        startStopScheduleTicker()
    }

    private func handleStopReminderAction(_ action: RecordingStopReminderAction) {
        guard audioService.isRecording, stopSchedule != nil else { return }
        switch action {
        case .extend(let seconds):
            extendScheduledStop(by: seconds)
        case .stopNow:
            finalizeRecording()
        }
    }

    private func startStopScheduleTicker() {
        guard stopScheduleTask == nil else { return }
        stopScheduleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.evaluateStopSchedule()
            }
        }
    }

    private func clearStopSchedule() {
        stopScheduleTask?.cancel()
        stopScheduleTask = nil
        stopNotifier.cancelWarning()
        stopSchedule = nil
    }

    private func updateLiveActivitySchedule() {
        RecordingLiveActivityController.shared.updateScheduledEnd(
            stopSchedule?.endDate,
            isPaused: audioService.isPaused,
            elapsedDuration: audioService.recordingDuration
        )
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

    // MARK: Recovery

    /// Clears notes left mid-finalization by an app that iOS suspended and then
    /// killed. Live slices live only in the coordinator's memory, so nothing can
    /// resume them; the note keeps the text the live pass already wrote and stops
    /// claiming to be busy. Without this it shows "Finalizing" forever, because
    /// `isTranscribing` is persisted and no other code path clears it.
    /// Re-transcribing stays the user's explicit choice.
    func recoverInterruptedFinalizations(in notes: [VoiceNote]) {
        for note in notes where note.isTranscribing && note.duration > 0 {
            guard currentRecordingNote?.id != note.id,
                  !finalizingNoteIDs.contains(note.id),
                  !note.isAwaitingTranscription,
                  !transcriptionService.isLocalRecording(noteID: note.id),
                  !transcriptionService.ownsSavedTranscription(noteID: note.id),
                  transcriptionService.activeNoteID != note.id else { continue }

            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure(
                "Finalizing was interrupted before it finished. The text below stops where the recording was transcribed live — re-transcribe to fill in the rest."
            )
            note.clearTransientTranscriptionFlags()
            try? note.modelContext?.save()
        }

        recoverInterruptedRecordings(in: notes)
    }

    /// Recovers notes whose app died while still recording (crash, app update,
    /// jetsam). Stop never ran, so the note has no duration and its `.m4a` was
    /// never exported, yet it stays queued on every device for audio that will
    /// never arrive. The live PCM file is still on disk: export it the way
    /// stop does and transcribe it. Without it the audio is lost, so the note
    /// stops waiting and says so. Only the recording device can do either.
    /// The same applies when the app died during stop's export: the note then
    /// points at a partial `.m4a` that cannot be read, while the PCM is intact.
    /// Returns the export tasks so callers can await them.
    @discardableResult
    func recoverInterruptedRecordings(in notes: [VoiceNote]) -> [Task<Void, Never>] {
        let storage = orphanedRecordingStorage
        let deviceID = transcriptionService.deviceIDProvider()
        let ownIdleNotes = notes.filter { note in
            note.transcriptionOriginDeviceID == deviceID
                && !note.audioFilePath.isEmpty
                && currentRecordingNote?.id != note.id
                && !finalizingNoteIDs.contains(note.id)
                && !transcriptionService.isLocalRecording(noteID: note.id)
                && transcriptionService.activeNoteID != note.id
        }
        let interrupted = ownIdleNotes.filter { note in
            note.duration <= 0
                && Self.isWaitingForTranscription(note)
                && storage.isAudioAbsent(note.audioFilePath)
        }

        let livePCMURL = audioService.currentPCMFileURL?.standardizedFileURL
        let pcmFiles = storage.pcmDirectories()
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { url in
                OrphanedRecordingMatcher.startTime(ofPCMFile: url) != nil
                    && url.standardizedFileURL != livePCMURL
                    && !recoveringPCMFiles.contains(url.standardizedFileURL)
            }
        // Only notes that started next to a leftover PCM file are probed, so a
        // launch without leftovers opens no audio files.
        let interruptedIDs = Set(interrupted.map(\.id))
        let pcmStarts = pcmFiles.compactMap(OrphanedRecordingMatcher.startTime(ofPCMFile:))
        let unplayable = ownIdleNotes.filter { note in
            guard !interruptedIDs.contains(note.id) else { return false }
            let start = floor(OrphanedRecordingMatcher.startTime(of: note))
            guard pcmStarts.contains(where: { abs(start - $0) <= OrphanedRecordingMatcher.maximumStartGap }) else {
                return false
            }
            return storage.isAudioAbsent(note.audioFilePath) || storage.isAudioDamaged(note.audioFilePath)
        }

        let matches = OrphanedRecordingMatcher.match(interrupted + unplayable, to: pcmFiles)
        removeUnclaimedPCMFiles(pcmFiles, claimed: Set(matches.values), notes: notes, storage: storage)

        var tasks: [Task<Void, Never>] = []
        for note in unplayable {
            guard let pcmURL = matches[note.id], let duration = storage.duration(pcmURL), duration > 0 else { continue }
            debugLog("🔍 [RecordingSession] Re-exporting unreadable recording \(note.audioFilePath) from \(pcmURL.lastPathComponent)")
            tasks.append(reattachOrphanedRecording(
                pcmURL, duration: duration, to: note, storage: storage, replacingUnreadableAudio: true))
        }
        for note in interrupted {
            if let pcmURL = matches[note.id],
               let duration = storage.duration(pcmURL), duration > 0 {
                debugLog("🔍 [RecordingSession] Recovering interrupted recording \(note.audioFilePath) from \(pcmURL.lastPathComponent)")
                tasks.append(reattachOrphanedRecording(pcmURL, duration: duration, to: note, storage: storage))
            } else {
                debugLog("⚠️ [RecordingSession] No audio left for interrupted recording \(note.audioFilePath)")
                let liveText = note.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "" : " The text below is what was transcribed live."
                note.completeTranscription()
                note.transcriptionOutcome = .failed
                note.markTranscriptionFailure("Recording was interrupted before it was saved.\(liveText)")
                note.clearTransientTranscriptionFlags()
                try? note.modelContext?.save()
            }
        }
        return tasks
    }

    /// How long a PCM file no note claims is kept. Stop and recovery delete the
    /// files they export; what is left belongs to a note that is gone or to a
    /// recording whose note was never saved.
    static let unclaimedPCMRetention: TimeInterval = 7 * 24 * 60 * 60

    private func removeUnclaimedPCMFiles(
        _ pcmFiles: [URL],
        claimed: Set<URL>,
        notes: [VoiceNote],
        storage: OrphanedRecordingStorage
    ) {
        // A note whose export and fallback copy both failed plays the PCM file itself.
        let referenced = Set(notes.map { URL(fileURLWithPath: $0.audioFilePath).lastPathComponent })
        let cutoff = storage.now().addingTimeInterval(-Self.unclaimedPCMRetention)
        for url in pcmFiles where !claimed.contains(url) && !referenced.contains(url.lastPathComponent) {
            guard let modified = storage.modificationDate(url), modified < cutoff else { continue }
            debugLog("🔍 [RecordingSession] Removing unclaimed recording \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isWaitingForTranscription(_ note: VoiceNote) -> Bool {
        switch note.transcriptionState {
        case .queued, .claimed: return true
        case .completed, .cancelled: return false
        case .none: return note.isTranscribing || note.isAwaitingTranscription
        }
    }

    private func reattachOrphanedRecording(
        _ pcmURL: URL,
        duration: TimeInterval,
        to note: VoiceNote,
        storage: OrphanedRecordingStorage,
        replacingUnreadableAudio: Bool = false
    ) -> Task<Void, Never> {
        let name = URL(fileURLWithPath: note.audioFilePath).lastPathComponent
        let destination = storage.destinationURL(name)
        if replacingUnreadableAudio {
            // The export cannot write over the partial file it replaces.
            try? FileManager.default.removeItem(at: destination)
        }
        let export = RecordingStopResult.converting(
            sourceURL: pcmURL,
            destinationURL: destination,
            duration: duration,
            convert: storage.convert
        )
        // Keep the queue off the note until its audio exists.
        transcriptionService.beginLocalRecording(noteID: note.id)
        preparingAudioNoteIDs.insert(note.id)
        let recoveringURL = pcmURL.standardizedFileURL
        recoveringPCMFiles.insert(recoveringURL)

        return Task { @MainActor in
            defer {
                recoveringPCMFiles.remove(recoveringURL)
                preparingAudioNoteIDs.remove(note.id)
                transcriptionService.endLocalRecording(noteID: note.id)
            }
            guard let path = await export.resolvedFilePath() else { return }
            note.audioFilePath = path
            note.duration = duration
            note.transcriptionLastErrorMessage = nil
            // A finished note only gets here with audio it could not read; with
            // the audio back, the whole recording is transcribed again.
            note.transcriptionOutcome = nil
            note.queueTranscription(at: Date())
            do {
                try note.modelContext?.save()
            } catch {
                // Keep the PCM source until the note durably points at the export.
                return
            }
            await export.cleanupTemporaryAudio()

            transcriptionService.endLocalRecording(noteID: note.id)
            if isModelLoaded {
                await transcriptionService.processPendingTranscriptions(notes: [note])
            }
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
        clearStopSchedule()
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
            capturedCoordinator?.finishTelemetry()
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

        // Without a coordinator the whole recording goes through the queue.
        let remainingSeconds = capturedCoordinator?.remainingAudioSeconds(upTo: finalFrame) ?? .infinity
        let continuation = RecordingFinalizationContinuation(
            driver: remainingSeconds >= Self.continuedProcessingThresholdSeconds ? continuedProcessingDriver : nil,
            title: "Finishing transcription",
            subtitle: note.title,
            decodeWork: { [service = transcriptionService] in service.decodeWorkCount }
        ) { [weak capturedCoordinator, service = transcriptionService] in
            if let capturedCoordinator, !capturedCoordinator.requiresFullTranscription {
                return capturedCoordinator.finalizationProgress
            }
            // Full recovery runs through the regular queue and reports there.
            return Double(service.progressByNoteID[note.id] ?? 0)
        }

        Task { @MainActor in
            defer {
                continuation.finish(success: note.transcriptionState == .completed)
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
                // Finalizing only trims whitespace the slices never carry, so the
                // live spans fit unless it changed the text.
                let spans = trimmedTranscript == accumulatedTranscript ? capturedCoordinator?.accumulatedSpans : nil
                note.setTranscript(trimmedTranscript, spans: spans)
                note.transcriptionModelIdentifier = transcriptionService.modelManager?.currentModelIdentifier()
                    ?? transcriptionService.modelManager?.selectedModel
                note.completeTranscription()
                if let unrecovered = capturedCoordinator?.unrecoveredSliceRanges, !unrecovered.isEmpty {
                    // Gaps are marked inline; re-transcribing is an explicit user choice.
                    note.transcriptionOutcome = .failed
                    note.markTranscriptionFailure(SegmentedAudioTranscriber.failureSummary(for: unrecovered))
                }
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
