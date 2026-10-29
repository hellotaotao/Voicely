//
//  TranscriptionService.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import AVFoundation
import Foundation
import os
import SwiftData
import UIKit

enum TranscriptionEngine {
    case qwen3
    case notAvailable
}

struct TranscriptionResult {
    let text: String
    let duration: TimeInterval
    let modelIdentifier: String?
    /// The language Qwen3-ASR named for the audio when it decoded without a
    /// hint ("English", "Chinese", "None", …), nil otherwise.
    var language: String? = nil
}

/// What a single transcription attempt produced. `.text` carries the engine's raw
/// output (still to be finalized); every other case names *why* there is no
/// text, so callers can react per cause instead of treating all failures alike.
/// A string literal becomes `.text`, so existing test stubs keep working.
enum RawTranscription: ExpressibleByStringLiteral {
    case text(String)
    case noSpeech
    case modelUnavailable
    case audioUnavailable
    case engineError(String?)
    case cancelled

    init(stringLiteral value: String) {
        self = .text(value)
    }
}

/// Outcome of a finalized transcription attempt, handed to the note layer so it
/// can react per cause (show non-speech verbatim, wait for a model, retry a real
/// error, ...) instead of collapsing everything into one failure.
enum TranscriptionOutcome {
    case transcribed(TranscriptionResult)
    case noSpeech
    case modelUnavailable
    case audioUnavailable
    case engineError(String?)
    case cancelled
}

/// Why a note waiting for transcription has not started, so the UI can name
/// the actual blocker instead of a generic "Queued".
enum TranscriptionWaitReason: Equatable {
    /// In this device's queue; 1 is the next note to run.
    case inLine(position: Int)
    case waitingForModel
    /// The audio has not reached this device yet.
    case waitingForAudio
    /// Recorded on another device, which transcribes it; this one only starts on request.
    case waitingForOtherDevice
    case pausedInBackground
    case startingSoon
}

@MainActor
class TranscriptionService: ObservableObject {
    typealias TranscribeImpl = (String, @escaping (Float) -> Void) async -> RawTranscription
    nonisolated private static let transcriptionLog = Logger(subsystem: "com.hellotaotao.Voicely", category: "TranscriptionTiming")
    nonisolated private static let savedJobLog = Logger(subsystem: "com.hellotaotao.Voicely", category: "ContinuedProcessing")

    @Published var isTranscribing = false
    @Published var loadingProgress: Float = 0.0
    // Smoothing state is internal; visible note progress publishes separately.
    var transcriptionProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var previewByNoteID: [UUID: String] = [:]
    @Published private(set) var progressByNoteID: [UUID: Float] = [:]
    /// Notes in the order this device will transcribe them; the first one is next.
    @Published private(set) var localQueueOrder: [UUID] = []
    /// Waiting notes whose audio is not on this device yet.
    @Published private(set) var audioWaitNoteIDs: Set<UUID> = []
    // Frequent clock updates belong to the telemetry card, not every service subscriber.
    let telemetryState = TranscriptionTelemetryState()
    private(set) var transcriptionTelemetry: TranscriptionTelemetrySnapshot {
        get { telemetryState.snapshot }
        set { telemetryState.update(newValue) }
    }

    var continuedProcessingDriver: (any ContinuedProcessingDriver)? = SystemContinuedProcessingDriver.shared

    /// Tokens the engine has decoded. Background tasks read it as proof of
    /// work while the audio position stands still, including inside one slice.
    nonisolated let decodeWorkCounter = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    var decodeWorkCount: UInt64 { decodeWorkCounter.withLock { $0 } }

    /// The language tag of the decode in progress. Decodes run one at a time,
    /// so `transcribeAudioOutcome` reads it once the engine returns. A test's
    /// `transcribeImpl` sets it to stand in for the engine.
    var decodedLanguage: String?

    /// Language choice for the decodes of one recording, keyed like the
    /// "selectedLanguage" setting; nil follows the setting.
    private var languageKeyByNoteID: [UUID: String] = [:]

    func setLanguageKey(_ key: String?, for noteID: UUID) {
        languageKeyByNoteID[noteID] = key
    }

    /// The language hint for a decode of `noteID`'s audio: the recording's own
    /// choice, else the setting. Nil is auto-detect.
    func languageHint(for noteID: UUID?) -> String? {
        let key = noteID.flatMap { languageKeyByNoteID[$0] }
            ?? UserDefaults.standard.string(forKey: Qwen3ASRDefaults.selectedLanguageKey)
        return Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: key)
    }

    /// The note whose audio is being decoded, for its language choice.
    private var decodingNoteID: UUID?

    var requiresBackgroundExecution: Bool = {
        #if targetEnvironment(macCatalyst)
        false
        #else
        true
        #endif
    }()
    private var runningSavedWorkingCopyIDs = Set<UUID>()
    @Published private(set) var backgroundStatusByNoteID: [UUID: String] = [:]
    private var savedTranscriptionNotes: [UUID: VoiceNote] = [:]
    private var savedContinuations: [UUID: SavedTranscriptionContinuation] = [:]
    private var backgroundPausedNoteIDs = Set<UUID>()
    private var savedJobsAreInForeground = true

    var modelManager: ModelManager?
    var transcribeImpl: TranscribeImpl = { _, _ in .engineError(nil) }
    var deviceIDProvider: () -> String = { DeviceIdentity.currentDeviceID }
    var nowProvider: () -> Date = { Date() }
    var audioDurationProvider: (String) async -> TimeInterval? = { filePath in
        await TranscriptionService.estimatedAudioDuration(for: filePath)
    }
    var prepareAudioFileForReading: (String) async -> URL? = { path in
        await CloudStorageManager.shared.prepareFileForReading(at: path)
    }
    var isAudioPermanentlyMissing: (String) -> Bool = { path in
        CloudStorageManager.shared.isAudioPermanentlyMissing(at: path)
    }
    /// How often this device's notes blocked outside the queue (audio still syncing) are checked again.
    var waitingRecheckInterval: TimeInterval = 30
    var audioAvailabilityRetryWindow: TimeInterval = 5 * 60
    var leaseDuration: TimeInterval = 5 * 60
    var heartbeatInterval: TimeInterval = 60

    /// Shared with the import path (ContentView) so the in-flight guard and
    /// resume sidecars are consistent across imports and re-transcriptions.
    let segmentProgressStore: SegmentProgressStore


    private var currentTranscriptionTask: Task<RawTranscription?, Never>?
    private var cancelRequested = false
    private var cancelledRunNoteIDs = Set<UUID>()
    private var localRecordingNoteIDs = Set<UUID>()
    private var discardedNoteIDs = Set<UUID>()
    private var lastCancellationHandled = false
    private var progressSmoothingTask: Task<Void, Never>?
    private var progressSmoothingTarget: Float = 0.0
    private var leaseHeartbeatTask: Task<Void, Never>?
    private var isProcessingPendingTranscriptions = false
    private var needsReprocessing = false
    private var pendingTranscriptionQueue: [UUID: VoiceNote] = [:]
    private var pendingTranscriptionOrder: [UUID] = []
    private var pendingTranscriptionOrderSet: Set<UUID> = []
    private var pendingTranscriptionOrderCursor = 0
    /// Dequeued and waiting for the decoder to free up.
    private var nextUpNoteID: UUID?
    /// Pending notes outside the queue; nothing else re-triggers them once they become runnable.
    private var waitingNotes: [UUID: VoiceNote] = [:]
    private var waitingRecheckTask: Task<Void, Never>?
    private var currentDecodeTelemetrySession: TranscriptionTelemetrySession?
    private var telemetrySessions: [UUID: TranscriptionTelemetrySession] = [:]
    private var noteTelemetrySessions: [UUID: UUID] = [:]
    private var telemetryTimerTask: Task<Void, Never>?

    init(modelManager: ModelManager? = nil,
         segmentProgressStore: SegmentProgressStore = SegmentProgressStore()) {
        self.modelManager = modelManager
        self.segmentProgressStore = segmentProgressStore
        self.transcribeImpl = { [weak self] filePath, progressCallback in
            guard let self else { return .cancelled }
            return await self.transcribeWithQwen(
                filePath: filePath,
                progressCallback: progressCallback
            )
        }
    }

    func setModelManager(_ manager: ModelManager) {
        self.modelManager = manager
        updateEngineStatus()
    }

    func loadSpeechModel() async -> Bool {
        guard let modelManager else {
            print("ModelManager not available")
            return false
        }

        loadingProgress = 0.1
        await modelManager.loadModel()

        updateEngineStatus()
        loadingProgress = modelManager.loadingProgressValue
        return modelManager.isModelLoaded()
    }

    /// Runs one inference on a slice of 16 kHz mono audio, calling the
    /// closure after each token. Tests replace it.
    var transcribeSamples: ([Float], String?, @escaping @Sendable () -> Void) async throws -> Qwen3SliceTranscript = {
        samples, languageHint, onToken in
        try await Qwen3ASRModelStore.shared.transcribe(samples: samples, languageHint: languageHint, onToken: onToken)
    }

    func configureNewNote(_ note: VoiceNote, shouldStartImmediately: Bool) {
        let now = nowProvider()
        note.transcriptionOriginDeviceID = currentDeviceID
        note.setTranscript("", spans: nil)
        note.lastTranscriptionDuration = 0
        note.transcriptionModelIdentifier = nil
        note.clearTransientTranscriptionFlags()
        note.clearTranscriptionTelemetrySummary()

        if shouldStartImmediately {
            let attemptID = UUID().uuidString
            note.claimTranscription(
                ownerDeviceID: currentDeviceID,
                attemptID: attemptID,
                queuedAt: now,
                leaseExpiresAt: now.addingTimeInterval(leaseDuration)
            )
        } else {
            note.queueTranscription(at: now)
        }
    }

    func migrateLegacyOwnershipIfNeeded(notes: [VoiceNote]) {
        let now = nowProvider()

        for note in notes {
            _ = recoverInterruptedLiveRecordingIfNeeded(note)
        }

        // A note with no state and no audio yet may be an import another device is
        // still transcribing; adopting it would mark it finished there. Notes from
        // before ownership existed always have their audio. Their origin stays
        // unknown, so no device starts one on its own; the user asks for it.
        for note in notes where !note.hasOwnershipState && !note.audioFilePath.isEmpty {
            if !note.transcription.isEmpty {
                note.completeTranscription()
            } else if note.pendingTranscription || note.isTranscribing {
                note.queueTranscription(at: note.timestamp > now ? now : note.timestamp)
            } else {
                note.completeTranscription()
            }

            note.clearTransientTranscriptionFlags()
        }
    }

    func processPendingTranscriptions(notes: [VoiceNote]) async {
        updateEngineStatus()

        guard isEngineLoaded else {
            return
        }

        migrateLegacyOwnershipIfNeeded(notes: notes)
        enqueueEligibleNotes(notes)

        guard !isProcessingPendingTranscriptions else {
            needsReprocessing = true
            return
        }

        isProcessingPendingTranscriptions = true
        defer {
            isProcessingPendingTranscriptions = false
            needsReprocessing = false
        }

        repeat {
            needsReprocessing = false

            while let note = dequeueNextPendingTranscription() {
                nextUpNoteID = note.id
                publishQueueOrder()
                while isTranscribing || activeNoteID != nil {
                    if Task.isCancelled {
                        nextUpNoteID = nil
                        publishQueueOrder()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                nextUpNoteID = nil
                publishQueueOrder()

                guard let action = processingAction(for: note, now: nowProvider()) else {
                    continue
                }

                switch action {
                case .claimNew(let attemptID, let queuedAt):
                    note.claimTranscription(
                        ownerDeviceID: currentDeviceID,
                        attemptID: attemptID,
                        queuedAt: queuedAt,
                        leaseExpiresAt: nowProvider().addingTimeInterval(leaseDuration)
                    )
                    note.clearTransientTranscriptionFlags()
                    await transcribeClaimedNote(note, attemptID: attemptID)
                case .resumeOwned(let attemptID):
                    note.claimTranscription(
                        ownerDeviceID: currentDeviceID,
                        attemptID: attemptID,
                        queuedAt: note.transcriptionQueuedAt ?? nowProvider(),
                        leaseExpiresAt: nowProvider().addingTimeInterval(leaseDuration)
                    )
                    note.clearTransientTranscriptionFlags()
                    await transcribeClaimedNote(note, attemptID: attemptID)
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        } while needsReprocessing
    }

    func requestTranscription(
        for note: VoiceNote,
        force: Bool = false,
        takeOver: Bool = false
    ) async -> Bool {
        updateEngineStatus()

        let workingCopy = segmentProgressStore.existingWorkingCopyURL(for: note.id)
        guard isEngineLoaded, !note.audioFilePath.isEmpty || workingCopy != nil,
              !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id) else {
            return false
        }

        migrateLegacyOwnershipIfNeeded(notes: [note])

        // Another device's claim is only ever taken over by an explicit request, and
        // never while that device is still recording: its audio does not exist yet.
        if isTranscribingOnAnotherDevice(note), !takeOver || isStillRecordingElsewhere(note) {
            return false
        }

        if !force, note.transcriptionState == .completed, !note.transcription.isEmpty,
           note.transcriptionOutcome != .failed {
            return false
        }

        if isLocallyTranscribing(note) || runningSavedWorkingCopyIDs.contains(note.id) {
            // An explicit retry can repair a declined background request without
            // restarting the decoder or replacing its saved segment checkpoint.
            if ownsSavedTranscription(noteID: note.id), savedJobsAreInForeground,
               !isPausedForBackground(noteID: note.id), savedContinuations[note.id]?.isAvailable != true {
                savedContinuations.removeValue(forKey: note.id)?.finish(success: false)
                beginSavedContinuation(for: note)
            }
            Self.savedJobLog.notice("event=savedRequestSkipped note=\(note.id.uuidString, privacy: .public) reason=alreadyRunning")
            return false
        }
        if pendingTranscriptionQueue[note.id] != nil {
            Self.savedJobLog.notice("event=savedRequestSkipped note=\(note.id.uuidString, privacy: .public) reason=alreadyQueued")
            return false
        }
        if force || note.transcriptionOutcome == .failed {
            do {
                try segmentProgressStore.resetProgressPreservingAttempt(for: note.id)
            } catch {
                note.markTranscriptionFailure("Could not preserve the previous attempt. Retry was not started; saved progress is unchanged.")
                return false
            }
        }
        note.resumeCancelledTranscription(at: nowProvider())
        savedTranscriptionNotes[note.id] = note
        Self.savedJobLog.notice("event=savedJobRegistered note=\(note.id.uuidString, privacy: .public) source=explicitRequest")
        backgroundPausedNoteIDs.remove(note.id)
        beginSavedContinuation(for: note)
        if note.audioFilePath.isEmpty, let workingCopy {
            await transcribeSavedWorkingCopy(note, url: workingCopy)
            return true
        }
        let queuedAt = force || takeOver || note.transcriptionOutcome == .failed
            ? nowProvider() : (note.transcriptionQueuedAt ?? nowProvider())
        note.claimTranscription(
            ownerDeviceID: currentDeviceID,
            attemptID: UUID().uuidString,
            queuedAt: queuedAt,
            leaseExpiresAt: nowProvider().addingTimeInterval(leaseDuration)
        )
        note.clearTransientTranscriptionFlags()
        await processPendingTranscriptions(notes: [note])
        return true
    }

    func ownsSavedTranscription(noteID: UUID) -> Bool { savedTranscriptionNotes[noteID] != nil }
    func isPausedForBackground(noteID: UUID) -> Bool { backgroundPausedNoteIDs.contains(noteID) }

    private func beginSavedContinuation(for note: VoiceNote) {
        guard requiresBackgroundExecution else {
            Self.savedJobLog.notice("event=savedContinuationSkipped note=\(note.id.uuidString, privacy: .public) reason=backgroundExecutionNotRequired")
            return
        }
        guard savedContinuations[note.id] == nil, !backgroundPausedNoteIDs.contains(note.id) else { return }
        let supportsBackground = modelManager?.loadedModelSupportsBackgroundTranscription ?? true
        Self.savedJobLog.notice("event=savedContinuationRequested note=\(note.id.uuidString, privacy: .public) foreground=\(self.savedJobsAreInForeground) supportedCompute=\(supportsBackground)")
        let continuation = SavedTranscriptionContinuation(
            driver: savedJobsAreInForeground && supportsBackground ? continuedProcessingDriver : nil,
            title: note.title,
            decodeWork: { [weak self] in self?.decodeWorkCount ?? 0 },
            onExpiration: { [weak self, weak note] in
                guard let self, let note else { return }
                self.pauseSavedTranscriptionForBackground(note)
            })
        savedContinuations[note.id] = continuation
        Self.savedJobLog.notice("event=savedContinuationReady note=\(note.id.uuidString, privacy: .public) available=\(continuation.isAvailable)")
        if !supportsBackground {
            backgroundStatusByNoteID[note.id] = "GPU transcription needs the app open. Progress is saved when the app goes into the background and resumes when you return."
        } else if !continuation.isAvailable {
            backgroundStatusByNoteID[note.id] = "Background execution is unavailable. Keep the app open; saved progress resumes when you return."
        } else {
            backgroundStatusByNoteID.removeValue(forKey: note.id)
        }
        if !savedJobsAreInForeground && !continuation.isAvailable { pauseSavedTranscriptionForBackground(note) }
    }

    private func finishSavedContinuation(for note: VoiceNote, remove: Bool = false) {
        // A run that reached the end with a few unreadable slices still produced a
        // transcript; the note names the gaps, and a lock screen "failed" for it
        // reads as if nothing was transcribed. Only a finished run with no text
        // at all is reported to the system as failed.
        let finishedWithText = note.transcriptionState == .completed
            && (note.transcriptionOutcome != .failed
                || LocalTranscriptFinalizer.finalizeTranscript(note.transcription) != nil)
        savedContinuations.removeValue(forKey: note.id)?.finish(success: finishedWithText)
        if remove || note.transcriptionState == .completed || isUserPaused(note) || isDiscarded(noteID: note.id) {
            savedTranscriptionNotes.removeValue(forKey: note.id)
            backgroundPausedNoteIDs.remove(note.id)
            backgroundStatusByNoteID.removeValue(forKey: note.id)
        }
    }

    /// Another device took the note over or finished it: drop this device's job so
    /// neither a foreground resume nor a background pause touches the note again.
    func forgetSavedTranscription(_ note: VoiceNote) {
        guard savedTranscriptionNotes[note.id] != nil || savedContinuations[note.id] != nil else { return }
        finishSavedContinuation(for: note, remove: true)
    }

    private func pauseSavedTranscriptionForBackground(_ note: VoiceNote) {
        guard savedTranscriptionNotes[note.id] != nil, !isUserPaused(note),
              !isDiscarded(noteID: note.id) else { return }
        if isTranscribingOnAnotherDevice(note) || note.transcriptionState == .completed {
            // Taken over or finished elsewhere: nothing is left to pause or resume here.
            if activeNoteID == note.id { cancelTranscriptionRun(for: note.id) }
            finishSavedContinuation(for: note, remove: true)
            return
        }
        backgroundPausedNoteIDs.insert(note.id)
        Self.savedJobLog.notice("event=savedJobPaused note=\(note.id.uuidString, privacy: .public) foreground=\(self.savedJobsAreInForeground)")
        if activeNoteID == note.id { cancelTranscriptionRun(for: note.id) }
        savedContinuations.removeValue(forKey: note.id)?.finish(success: false)
        holdOrQueue(note, queuedAt: note.transcriptionQueuedAt ?? nowProvider())
        backgroundStatusByNoteID[note.id] = "Transcription paused by iOS. Saved progress resumes when you return to the app."
        do { try note.modelContext?.save() }
        catch { note.markTranscriptionFailure("Could not save the paused state. Keep the app open. \(error.localizedDescription)") }
    }

    func savedTranscriptionsDidEnterBackground() {
        savedJobsAreInForeground = false
        guard requiresBackgroundExecution else { return }
        for note in Array(savedTranscriptionNotes.values) where savedContinuations[note.id]?.isAvailable != true {
            pauseSavedTranscriptionForBackground(note)
        }
    }

    func resumeSavedTranscriptionsInForeground() async {
        savedJobsAreInForeground = true
        // A cancelled decoder may still be unwinding when scene activation arrives.
        // Keep its engine ownership until it exits, then start a fresh attempt.
        while activeNoteID.map({ backgroundPausedNoteIDs.contains($0) }) == true
            || !runningSavedWorkingCopyIDs.isDisjoint(with: backgroundPausedNoteIDs) {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard savedJobsAreInForeground else { return }
        let notes = savedTranscriptionNotes.values.filter { activeNoteID != $0.id && !runningSavedWorkingCopyIDs.contains($0.id) }
        for note in notes where !isUserPaused(note) && !isDiscarded(noteID: note.id) {
            backgroundPausedNoteIDs.remove(note.id)
            beginSavedContinuation(for: note)
        }
        await processPendingTranscriptions(notes: notes)
        for note in notes where note.audioFilePath.isEmpty && ownsSavedTranscription(noteID: note.id)
            && !isPausedForBackground(noteID: note.id) && !isUserPaused(note) {
            if let url = segmentProgressStore.existingWorkingCopyURL(for: note.id) {
                await transcribeSavedWorkingCopy(note, url: url)
            }
        }
    }

    private func transcribeSavedWorkingCopy(_ note: VoiceNote, url: URL) async {
        guard runningSavedWorkingCopyIDs.insert(note.id).inserted else { return }
        defer {
            runningSavedWorkingCopyIDs.remove(note.id)
            finishSavedContinuation(for: note)
        }
        await SegmentedAudioTranscriber(transcriptionService: self, progressStore: segmentProgressStore)
            .transcribe(note: note, sourceURL: url)
    }

    func cancelTranscription(for note: VoiceNote) {
        // Recording ownership includes the final flush, not a cancellable saved-note job.
        guard !localRecordingNoteIDs.contains(note.id) else { return }
        guard activeNoteID == note.id || note.transcriptionState == .queued || note.transcriptionState == .cancelled
            || (note.transcriptionState == .claimed && note.transcriptionOwnerDeviceID == currentDeviceID) else { return }
        finishSavedContinuation(for: note, remove: true)
        if activeNoteID == note.id { cancelTranscriptionRun(for: note.id) }
        pendingTranscriptionQueue.removeValue(forKey: note.id)
        waitingNotes.removeValue(forKey: note.id)
        audioWaitNoteIDs.remove(note.id)
        // The loop may already hold it while the decoder is busy; it skips the note on its own.
        if nextUpNoteID == note.id { nextUpNoteID = nil }
        publishQueueOrder()
        previewByNoteID.removeValue(forKey: note.id)
        note.cancelTranscription()
        do {
            // Do not rely on autosave: the user may force-quit immediately.
            try note.modelContext?.save()
        } catch {
            note.markTranscriptionFailure("Cancellation could not be saved. Keep the app open and cancel again before closing it. \(error.localizedDescription)")
        }
    }

    func isQueuedForLocalTranscription(_ note: VoiceNote) -> Bool {
        note.pendingTranscription || (note.transcriptionState == .claimed
            && note.transcriptionOwnerDeviceID == currentDeviceID
            && activeNoteID != note.id && !note.isTranscribing)
    }

    func beginLocalRecording(noteID: UUID) { localRecordingNoteIDs.insert(noteID) }
    func endLocalRecording(noteID: UUID) { localRecordingNoteIDs.remove(noteID) }
    func isLocalRecording(noteID: UUID) -> Bool { localRecordingNoteIDs.contains(noteID) }
    func isUserPaused(_ note: VoiceNote) -> Bool { note.transcriptionState == .cancelled }
    func isDiscarded(noteID: UUID) -> Bool { discardedNoteIDs.contains(noteID) }
    func discardTranscription(for note: VoiceNote) {
        discardedNoteIDs.insert(note.id)
        finishSavedContinuation(for: note, remove: true)
        if activeNoteID == note.id { cancelTranscriptionRun(for: note.id) }
        pendingTranscriptionQueue.removeValue(forKey: note.id)
        waitingNotes.removeValue(forKey: note.id)
        audioWaitNoteIDs.remove(note.id)
        // The loop may already hold it while the decoder is busy; it skips the note on its own.
        if nextUpNoteID == note.id { nextUpNoteID = nil }
        publishQueueOrder()
        previewByNoteID.removeValue(forKey: note.id)
    }
    func isRunCancelled(noteID: UUID) -> Bool { cancelledRunNoteIDs.contains(noteID) }
    func transcriptionPreview(for noteID: UUID) -> String? { previewByNoteID[noteID] }
    func reportExternalPreview(_ text: String, for noteID: UUID) {
        guard previewByNoteID[noteID] != text else { return }
        previewByNoteID[noteID] = text
    }

    func localProgress(for note: VoiceNote) -> Float {
        progressByNoteID[note.id] ?? 0.0
    }

    func isLocallyTranscribing(_ note: VoiceNote) -> Bool {
        activeNoteID == note.id
    }

    /// Long recordings with audio are re-transcribed via SegmentedAudioTranscriber
    /// (segmented + resumable + progress) rather than the whole-file single pass.
    func shouldSegmentTranscription(audioDuration: TimeInterval) -> Bool {
        audioDuration > Qwen3ASRDefaults.singlePassSecondsLimit
    }

    /// Surfaces a note transcribed by an external coordinator
    /// (SegmentedAudioTranscriber) as locally transcribing, so the detail view
    /// shows the same "Transcribing…" state and progress as the in-process path.
    func beginExternalTranscription(noteID: UUID) {
        cancelledRunNoteIDs.remove(noteID)
        activeNoteID = noteID
        progressByNoteID[noteID] = 0
    }

    func reportExternalProgress(_ progress: Float, for noteID: UUID) {
        let clamped = min(1, max(0, progress))
        guard progressByNoteID[noteID] != clamped else { return }
        progressByNoteID[noteID] = clamped
        savedContinuations[noteID]?.update(progress: Double(clamped))
    }

    func endExternalTranscription(noteID: UUID) {
        cancelledRunNoteIDs.remove(noteID)
        previewByNoteID.removeValue(forKey: noteID)
        if activeNoteID == noteID { activeNoteID = nil }
        progressByNoteID.removeValue(forKey: noteID)
    }

    /// Another device holds the note, lease or no lease: a lapsed lease may only
    /// mean that device is asleep, so it stays its note until the user takes it over.
    func isTranscribingOnAnotherDevice(_ note: VoiceNote) -> Bool {
        guard note.transcriptionState == .claimed,
              let ownerDeviceID = note.transcriptionOwnerDeviceID else {
            return false
        }
        return ownerDeviceID != currentDeviceID
    }

    /// Another device is still recording the note (stop sets the duration). A note
    /// left mid-finalization keeps `isTranscribing` but has its duration and audio.
    func isStillRecordingElsewhere(_ note: VoiceNote) -> Bool {
        isTranscribingOnAnotherDevice(note) && note.isTranscribing && note.duration <= 0
    }

    /// The user handed this device's recording to another device, which holds it
    /// or already finished it; live text and finalization then leave it alone.
    func wasTakenOverElsewhere(_ note: VoiceNote) -> Bool {
        isTranscribingOnAnotherDevice(note) || note.transcriptionState == .completed
    }

    func shouldShowPendingState(_ note: VoiceNote, now: Date? = nil) -> Bool {
        // A live recording may outlast the queue lease without becoming queued work.
        guard !localRecordingNoteIDs.contains(note.id) else { return false }
        if note.transcriptionState == .queued {
            return true
        }

        return note.transcriptionState == .claimed && !isTranscribingOnAnotherDevice(note)
            && leaseHasExpired(note, now: now)
    }

    /// Stops this device's work on a note. A note taken over from another device
    /// stays claimed: queueing clears the owner, and the recording device would then
    /// start a note the user handed to this one. This device's own notes go back to
    /// the queue, which no other device starts on its own.
    func holdOrQueue(_ note: VoiceNote, queuedAt: Date) {
        if note.transcriptionState == .claimed, note.transcriptionOwnerDeviceID == currentDeviceID,
           let originDeviceID = note.transcriptionOriginDeviceID, originDeviceID != currentDeviceID {
            note.transcriptionQueuedAt = queuedAt
            note.clearTransientTranscriptionFlags()
        } else {
            note.queueTranscription(at: queuedAt)
        }
    }

    func isEngineAvailable() -> Bool {
        updateEngineStatus()
        return isEngineLoaded
    }

    /// Runs one transcription attempt and reports *why* there is no transcript, so
    /// callers can react per cause instead of treating every empty result the same.
    func transcribeAudioOutcome(
        filePath: String,
        progressCallback: @escaping (Float) -> Void = { _ in },
        telemetrySession: TranscriptionTelemetrySession? = nil
    ) async -> TranscriptionOutcome {
        updateEngineStatus()

        let pausedForEngine = isTranscribing && telemetrySession?.activeWorkOnly == true
        if pausedForEngine, let telemetrySession { pauseTelemetryWork(telemetrySession) }
        while isTranscribing {
            if Task.isCancelled || telemetrySession?.isCancelled == true { return .cancelled }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        if pausedForEngine, let telemetrySession { resumeTelemetryWork(telemetrySession) }
        lastCancellationHandled = false
        if telemetrySession?.isCancelled == true { return .cancelled }
        if cancelRequested {
            cancelRequested = false
            lastCancellationHandled = true
            return .cancelled
        }

        isTranscribing = true
        transcriptionProgress = 0.0
        resetProgressSmoothing()
        let startTime = Date()
        let ownsTelemetry = telemetrySession == nil
        let session = telemetrySession ?? beginTelemetrySession()
        currentDecodeTelemetrySession = session
        decodedLanguage = nil
        decodingNoteID = session.noteID
        defer {
            decodingNoteID = nil
            isTranscribing = false
            currentTranscriptionTask = nil
            if currentDecodeTelemetrySession?.id == session.id { currentDecodeTelemetrySession = nil }
            if ownsTelemetry { endTelemetrySession(session) }
            resetProgressSmoothing()
            transcriptionProgress = 0.0
        }

        guard isEngineLoaded else {
            return .modelUnavailable
        }

        if ownsTelemetry {
            setTelemetryAudioDuration(await audioDurationProvider(filePath), session: session)
        }
        // Cancellation may arrive while reading metadata, before a decode task exists.
        guard !cancelRequested, !Task.isCancelled, !session.isCancelled else {
            cancelRequested = false
            lastCancellationHandled = true
            return .cancelled
        }

        let task = Task { [weak self] in
            await self?.transcribeImpl(filePath) { fraction in
                // The decoder can reach the end before its output is validated.
                // Only an accepted outcome completes audio.
                let pending = fraction.isFinite ? min(max(fraction, 0), 0.99) : 0
                progressCallback(pending)
            }
        }
        currentTranscriptionTask = task

        guard let raw = await task.value else {
            return .cancelled
        }

        if cancelRequested || Task.isCancelled || session.isCancelled {
            cancelRequested = false
            lastCancellationHandled = true
            return .cancelled
        }
        switch raw {
        case .text(let rawText):
            guard let finalizedTranscript = LocalTranscriptFinalizer.finalizeTranscript(rawText) else {
                // The engine ran but produced nothing usable. Treat it as a real error
                // to surface for diagnosis — not as a calm "no speech".
                return .engineError("blank output")
            }
            progressCallback(1)
            if ownsTelemetry, let duration = session.audioDuration {
                recordProcessedAudio(start: 0, end: duration, session: session)
            }
            let elapsed = Date().timeIntervalSince(startTime)
            let modelIdentifier = modelManager?.currentModelIdentifier() ?? modelManager?.selectedModel
            return .transcribed(TranscriptionResult(
                text: finalizedTranscript.text,
                duration: elapsed,
                modelIdentifier: modelIdentifier,
                language: decodedLanguage
            ))
        case .noSpeech:
            progressCallback(1)
            if ownsTelemetry, let duration = session.audioDuration {
                recordProcessedAudio(start: 0, end: duration, session: session)
            }
            return .noSpeech
        case .modelUnavailable:
            return .modelUnavailable
        case .audioUnavailable:
            return .audioUnavailable
        case .engineError(let diagnostic):
            return .engineError(diagnostic)
        case .cancelled:
            lastCancellationHandled = true
            return .cancelled
        }
    }

    func transcribeAudio(
        filePath: String,
        progressCallback: @escaping (Float) -> Void = { _ in }
    ) async -> TranscriptionResult? {
        if case .transcribed(let result) = await transcribeAudioOutcome(
            filePath: filePath,
            progressCallback: progressCallback
        ) {
            return result
        }
        return nil
    }

    private func cancelTranscriptionRun(for noteID: UUID) {
        cancelledRunNoteIDs.insert(noteID)
        if let id = noteTelemetrySessions[noteID] { telemetrySessions[id]?.isCancelled = true }
        if currentDecodeTelemetrySession?.noteID == noteID { cancelTranscription() }
    }

    func cancelTranscription() {
        print("Cancelling current transcription...")
        cancelRequested = true
        currentDecodeTelemetrySession?.isCancelled = true
        if let noteID = currentDecodeTelemetrySession?.noteID ?? activeNoteID { cancelledRunNoteIDs.insert(noteID) }
        currentTranscriptionTask?.cancel()
        currentTranscriptionTask = nil
        stopLeaseHeartbeat()
        resetProgressSmoothing()
        // The owning task releases the engine and note only after decoding exits.
        transcriptionProgress = 0.0
    }

    func wasTranscriptionCancelled() -> Bool {
        lastCancellationHandled
    }

    /// Drops a stale cancellation flag left by an unrelated, already-finished
    /// transcription so it can't turn the next caller's first segment into a
    /// spurious `.cancelled`. Safe only when no transcription is active.
    func clearPendingCancellation() {
        cancelRequested = false
        lastCancellationHandled = false
    }

    nonisolated static func estimatedAudioDuration(for filePath: String) async -> TimeInterval? {
        let url = URL(fileURLWithPath: filePath)

        if let audioFile = try? AVAudioFile(forReading: url) {
            let sampleRate = audioFile.fileFormat.sampleRate
            if sampleRate > 0 {
                let seconds = Double(audioFile.length) / sampleRate
                if seconds.isFinite, seconds > 0 {
                    return seconds
                }
            }
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else {
                return nil
            }
            return seconds
        } catch {
            return nil
        }
    }
}

extension TranscriptionService {
    func beginTelemetrySession(noteID: UUID? = nil, activeWorkOnly: Bool = false) -> TranscriptionTelemetrySession {
        let session = TranscriptionTelemetrySession(noteID: noteID, activeWorkOnly: activeWorkOnly, now: nowProvider())
        if let noteID {
            if let previous = noteTelemetrySessions[noteID] {
                telemetrySessions[previous]?.isCancelled = true
                telemetrySessions.removeValue(forKey: previous)
            }
            noteTelemetrySessions[noteID] = session.id
        }
        telemetrySessions[session.id] = session
        refreshTranscriptionTelemetry(session)
        if telemetryTimerTask == nil {
            telemetryTimerTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self else { break }
                    for session in self.telemetrySessions.values where session.runningSince != nil {
                        self.refreshTranscriptionTelemetry(session)
                    }
                }
            }
        }
        return session
    }

    func isTelemetrySessionCurrent(_ session: TranscriptionTelemetrySession) -> Bool {
        telemetrySessions[session.id] != nil
    }

    func resumeTelemetryWork(_ session: TranscriptionTelemetrySession) {
        guard telemetrySessions[session.id] != nil, session.runningSince == nil else { return }
        session.runningSince = nowProvider()
        refreshTranscriptionTelemetry(session)
    }

    func pauseTelemetryWork(_ session: TranscriptionTelemetrySession) {
        guard telemetrySessions[session.id] != nil else { return }
        if let started = session.runningSince { session.elapsed += max(0, nowProvider().timeIntervalSince(started)) }
        session.runningSince = nil
        refreshTranscriptionTelemetry(session)
    }

    func setTelemetryAudioDuration(_ duration: TimeInterval?, session: TranscriptionTelemetrySession) {
        guard telemetrySessions[session.id] != nil else { return }
        session.audioDuration = duration
        refreshTranscriptionTelemetry(session)
    }

    func recordProcessedAudio(start: TimeInterval, end: TimeInterval, session: TranscriptionTelemetrySession) {
        guard telemetrySessions[session.id] != nil, !session.isCancelled else { return }
        session.coverage.record(start: start, end: end)
        refreshTranscriptionTelemetry(session)
    }

    func endTelemetrySession(_ session: TranscriptionTelemetrySession) {
        guard telemetrySessions[session.id] != nil else { return }
        pauseTelemetryWork(session)
        refreshTranscriptionTelemetry(session, isActive: false)
        session.isCancelled = true
        telemetrySessions.removeValue(forKey: session.id)
        if let noteID = session.noteID, noteTelemetrySessions[noteID] == session.id {
            noteTelemetrySessions.removeValue(forKey: noteID)
        }
        if telemetrySessions.isEmpty {
            telemetryTimerTask?.cancel()
            telemetryTimerTask = nil
        }
    }

    func waitReason(for note: VoiceNote, now: Date? = nil) -> TranscriptionWaitReason? {
        guard activeNoteID != note.id, !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id),
              isQueuedForLocalTranscription(note) || shouldShowPendingState(note, now: now) else {
            return nil
        }
        if isPausedForBackground(noteID: note.id) { return .pausedInBackground }
        if !isEngineLoaded { return .waitingForModel }
        if let index = localQueueOrder.firstIndex(of: note.id) { return .inLine(position: index + 1) }
        if audioWaitNoteIDs.contains(note.id) { return .waitingForAudio }
        if !isLocalTask(note) { return .waitingForOtherDevice }
        return .startingSoon
    }
}

private extension TranscriptionService {
    enum ProcessingAction {
        case claimNew(attemptID: String, queuedAt: Date)
        case resumeOwned(attemptID: String)
    }

    var currentDeviceID: String {
        deviceIDProvider()
    }

    var isEngineLoaded: Bool {
        modelManager?.isModelLoaded() ?? false
    }

    func refreshTranscriptionTelemetry(_ session: TranscriptionTelemetrySession, isActive: Bool = true) {
        guard telemetrySessions[session.id] != nil else { return }
        let elapsed = session.elapsed + (session.runningSince.map { max(0, nowProvider().timeIntervalSince($0)) } ?? 0)
        telemetryState.update(TranscriptionTelemetrySnapshot(
            isActive: isActive,
            modelName: currentTelemetryModelName(),
            computeRoute: currentTelemetryComputeRoute(),
            metrics: TranscriptionTelemetryMetrics(
                elapsedSeconds: elapsed,
                audioDurationSeconds: session.audioDuration,
                processedAudioSeconds: session.coverage.processedSeconds
            ),
            thermalState: ProcessInfo.processInfo.thermalState
        ), noteID: session.noteID)
    }

    func currentTelemetryModelName() -> String {
        let modelIdentifier = modelManager?.currentModelIdentifier() ?? modelManager?.selectedModel
        guard let modelIdentifier, !modelIdentifier.isEmpty else {
            return "No model"
        }
        return ModelManager.displayName(for: modelIdentifier)
    }

    func currentTelemetryComputeRoute() -> TranscriptionComputeRoute {
        TranscriptionComputeRoute(backend: modelManager?.backend ?? .current)
    }

    func updateEngineStatus() {
        if isEngineLoaded {
            currentEngine = .qwen3
        } else {
            currentEngine = .notAvailable
        }
    }

    func processingAction(for note: VoiceNote, now: Date) -> ProcessingAction? {
        guard !note.audioFilePath.isEmpty, !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id), !isPausedForBackground(noteID: note.id) else {
            return nil
        }

        // Work only starts on its own for notes this device is responsible for;
        // another device's note waits for that device or for the user to take it over.
        guard isLocalTask(note) else { return nil }

        switch note.transcriptionState {
        case .claimed:
            let attemptID = note.transcriptionAttemptID ?? UUID().uuidString
            return .resumeOwned(attemptID: attemptID)
        case .queued:
            return .claimNew(
                attemptID: UUID().uuidString,
                queuedAt: note.transcriptionQueuedAt ?? now
            )
        case .completed, .cancelled:
            return nil
        case .none:
            return nil
        }
    }

    /// This device holds the note, or it is unclaimed and was recorded or imported
    /// here or requested here by the user.
    func isLocalTask(_ note: VoiceNote) -> Bool {
        if note.transcriptionState == .claimed {
            return note.transcriptionOwnerDeviceID == currentDeviceID
        }
        return note.transcriptionOriginDeviceID == currentDeviceID || savedTranscriptionNotes[note.id] != nil
    }

    func leaseHasExpired(_ note: VoiceNote, now: Date? = nil) -> Bool {
        guard let leaseExpiresAt = note.transcriptionLeaseExpiresAt else {
            return true
        }
        return leaseExpiresAt <= (now ?? nowProvider())
    }

    func recoverInterruptedLiveRecordingIfNeeded(_ note: VoiceNote) -> Bool {
        guard note.hasOwnershipState, note.transcriptionState != .cancelled else {
            return false
        }

        guard note.isTranscribing else {
            return false
        }

        guard activeNoteID != note.id, !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id) else {
            return false
        }

        // Live recording never renews its lease, so a lapsed one does not mean the
        // recording stopped. Only the recording device can tell it was interrupted.
        guard note.transcriptionOriginDeviceID == currentDeviceID, !isTranscribingOnAnotherDevice(note) else {
            return false
        }

        if note.audioFilePath.isEmpty {
            note.completeTranscription()
            note.clearTransientTranscriptionFlags()
        } else {
            note.queueTranscription(at: note.transcriptionQueuedAt ?? note.timestamp)
        }

        return true
    }

    func enqueueEligibleNotes(_ notes: [VoiceNote]) {
        let now = nowProvider()

        for note in notes {
            guard processingAction(for: note, now: now) != nil else {
                if mayBecomeRunnableLater(note), !note.audioFilePath.isEmpty,
                   !discardedNoteIDs.contains(note.id), pendingTranscriptionQueue[note.id] == nil {
                    waitingNotes[note.id] = note
                } else {
                    waitingNotes.removeValue(forKey: note.id)
                }
                continue
            }

            waitingNotes.removeValue(forKey: note.id)
            pendingTranscriptionQueue[note.id] = note
            if pendingTranscriptionOrderSet.insert(note.id).inserted {
                pendingTranscriptionOrder.append(note.id)
            }
        }
        publishQueueOrder()
        scheduleWaitingRecheck()
    }

    private func publishQueueOrder() {
        var order: [UUID] = nextUpNoteID.map { [$0] } ?? []
        if pendingTranscriptionOrderCursor < pendingTranscriptionOrder.count {
            order += pendingTranscriptionOrder[pendingTranscriptionOrderCursor...].filter {
                pendingTranscriptionQueue[$0] != nil && $0 != nextUpNoteID
            }
        }
        if order != localQueueOrder { localQueueOrder = order }
    }

    /// Unfinished work this device is responsible for. It can become runnable
    /// without an event the UI would notice (its audio finishes syncing), so poll it.
    /// Other devices' notes are never polled: only the user hands them to this one.
    private func mayBecomeRunnableLater(_ note: VoiceNote) -> Bool {
        isLocalTask(note) && !localRecordingNoteIDs.contains(note.id)
            && (note.transcriptionState == .queued || note.transcriptionState == .claimed)
    }

    private func scheduleWaitingRecheck() {
        waitingNotes = waitingNotes.filter { id, note in
            !discardedNoteIDs.contains(id) && pendingTranscriptionQueue[id] == nil
                && mayBecomeRunnableLater(note)
        }
        let audioWaits = audioWaitNoteIDs.filter { waitingNotes[$0] != nil || pendingTranscriptionQueue[$0] != nil }
        if audioWaits != audioWaitNoteIDs { audioWaitNoteIDs = audioWaits }

        guard !waitingNotes.isEmpty else {
            waitingRecheckTask?.cancel()
            waitingRecheckTask = nil
            return
        }
        guard waitingRecheckTask == nil else { return }

        let delay = waitingRecheckInterval
        waitingRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.waitingRecheckTask = nil
            await self.processPendingTranscriptions(notes: Array(self.waitingNotes.values))
            // processPendingTranscriptions returns before enqueueing while the model is unloaded.
            self.scheduleWaitingRecheck()
        }
    }

    func dequeueNextPendingTranscription() -> VoiceNote? {
        while pendingTranscriptionOrderCursor < pendingTranscriptionOrder.count {
            let noteID = pendingTranscriptionOrder[pendingTranscriptionOrderCursor]
            pendingTranscriptionOrderCursor += 1
            pendingTranscriptionOrderSet.remove(noteID)

            guard let note = pendingTranscriptionQueue.removeValue(forKey: noteID) else {
                continue
            }

            if pendingTranscriptionOrderCursor >= pendingTranscriptionOrder.count {
                pendingTranscriptionOrder.removeAll(keepingCapacity: true)
                pendingTranscriptionOrderCursor = 0
            }

            return note
        }

        if !pendingTranscriptionOrder.isEmpty {
            pendingTranscriptionOrder.removeAll(keepingCapacity: true)
            pendingTranscriptionOrderCursor = 0
        }

        return nil
    }

    func transcribeClaimedNote(_ note: VoiceNote, attemptID: String) async {
        guard activeNoteID != note.id, !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id) else {
            return
        }

        guard !isPausedForBackground(noteID: note.id) else { return }
        // Persisted queued/claimed jobs survive relaunch; in-memory continuation
        // ownership does not. Register only when this job acquires the decoder.
        if savedTranscriptionNotes[note.id] == nil {
            savedTranscriptionNotes[note.id] = note
            Self.savedJobLog.notice("event=savedJobRegistered note=\(note.id.uuidString, privacy: .public) source=queueRecovery")
        }
        beginSavedContinuation(for: note)
        defer { finishSavedContinuation(for: note) }
        // A queue may reach this job after the app has already backgrounded.
        // Without an existing grant, beginSavedContinuation checkpoints it.
        guard !isPausedForBackground(noteID: note.id) else { return }
        beginLocalTranscription(for: note, attemptID: attemptID)
        let session = beginTelemetrySession(noteID: note.id)
        defer { endTelemetrySession(session) }
        startLeaseHeartbeat(for: note, attemptID: attemptID)
        defer {
            stopLeaseHeartbeat()
            endLocalTranscription(for: note.id)
        }

        func stillOwnsAttempt() -> Bool {
            !discardedNoteIDs.contains(note.id) && note.transcriptionState == .claimed
                && note.transcriptionAttemptID == attemptID
                && note.transcriptionOwnerDeviceID == currentDeviceID
        }

        // Resolve the actual file before routing. Cloud metadata can be absent or stale.
        let preparationStart = ProcessInfo.processInfo.systemUptime
        Self.transcriptionLog.notice("attempt=\(attemptID, privacy: .public) stage=filePreparationStarted")
        guard let url = await prepareAudioFileForReading(note.audioFilePath) else {
            Self.transcriptionLog.notice("attempt=\(attemptID, privacy: .public) stage=fileUnavailable seconds=\(ProcessInfo.processInfo.systemUptime - preparationStart)")
            if stillOwnsAttempt() { handleUnavailableAudio(for: note) }
            return
        }
        if audioWaitNoteIDs.contains(note.id) { audioWaitNoteIDs.remove(note.id) }
        guard stillOwnsAttempt() else { return }
        let resolvedDuration = await audioDurationProvider(url.path)
        Self.transcriptionLog.notice("attempt=\(attemptID, privacy: .public) stage=filePreparationFinished seconds=\(ProcessInfo.processInfo.systemUptime - preparationStart)")
        guard stillOwnsAttempt() else { return }
        guard let resolvedDuration, resolvedDuration.isFinite, resolvedDuration > 0 else {
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("Could not read audio duration. The previous transcript and audio have been kept.")
            note.clearTransientTranscriptionFlags()
            return
        }
        note.duration = resolvedDuration
        setTelemetryAudioDuration(resolvedDuration, session: session)
        if shouldSegmentTranscription(audioDuration: resolvedDuration) {
            stopLeaseHeartbeat()
            endLocalTranscription(for: note.id)
            await SegmentedAudioTranscriber(transcriptionService: self, progressStore: segmentProgressStore)
                .transcribe(note: note, sourceURL: url, telemetrySession: session)
            return
        }

        let noteID = note.id
        let hadExistingTranscript = LocalTranscriptFinalizer.finalizeTranscript(note.transcription) != nil

        let onProgress: (Float) -> Void = { [weak self] value in
            // This callback already runs on the main actor. Enqueueing another
            // task can recreate progress after endLocalTranscription cleared it.
            self?.reportExternalProgress(value, for: noteID)
        }

        var outcome = await transcribeAudioOutcome(filePath: url.path, progressCallback: onProgress, telemetrySession: session)

        // An aborted decode is often transient — retry once before giving up.
        // Output the engine produced and we rejected would only come back the same.
        if case .engineError(let diagnostic) = outcome, Self.isEngineFailure(diagnostic), !wasTranscriptionCancelled() {
            outcome = await transcribeAudioOutcome(filePath: url.path, progressCallback: onProgress, telemetrySession: session)
        }

        stopLeaseHeartbeat()
        endLocalTranscription(for: noteID)

        guard !discardedNoteIDs.contains(noteID),
              note.transcriptionOwnerDeviceID == currentDeviceID,
              note.transcriptionAttemptID == attemptID,
              note.transcriptionState == .claimed else {
            return
        }

        if wasTranscriptionCancelled() {
            requeueNote(note, queuedAt: nowProvider())
            return
        }

        switch outcome {
        case .transcribed(let result):
            recordProcessedAudio(start: 0, end: resolvedDuration, session: session)
            note.setTranscript(result.text, spans: TranscriptTimeline.singleSpan(for: result.text, duration: resolvedDuration))
            note.lastTranscriptionDuration = result.duration
            note.transcriptionModelIdentifier = result.modelIdentifier
            if let snapshot = telemetryState.snapshot(for: note.id) { note.replaceCumulativeTranscriptionTelemetry(snapshot) }
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.clearTransientTranscriptionFlags()

        case .noSpeech:
            recordProcessedAudio(start: 0, end: resolvedDuration, session: session)
            // Existing text may be an incomplete live preview, not a proven
            // complete transcript. A silent retry cannot establish completeness.
            if !hadExistingTranscript {
                note.setTranscript("", spans: nil)
                note.lastTranscriptionDuration = 0
                note.transcriptionModelIdentifier = nil
                note.clearTranscriptionTelemetrySummary()
            }
            note.completeTranscription()
            note.transcriptionOutcome = hadExistingTranscript ? .failed : .noSpeech
            if hadExistingTranscript {
                note.markTranscriptionFailure("re-transcription produced no speech; kept previous transcript")
            }
            note.clearTransientTranscriptionFlags()

        case .audioUnavailable:
            handleUnavailableAudio(for: note)

        case .modelUnavailable, .cancelled:
            // Nothing to blame the user for: the model isn't loaded yet, the audio
            // isn't downloaded yet, or it was cancelled. Requeue and let it run again
            // automatically once the condition clears (e.g. modelLoadedNotification).
            requeueNote(note, queuedAt: nowProvider())

        case .engineError(let diagnostic):
            // A real error survived the retry. Don't pretend it succeeded, and don't
            // dump jargon on the user — keep the real reason internally for us.
            #if DEBUG
            print("❌ [TranscriptionService] note \(noteID) failed: \(diagnostic ?? "unknown error")")
            #endif
            if !hadExistingTranscript {
                note.setTranscript("", spans: nil)
                note.lastTranscriptionDuration = 0
                note.transcriptionModelIdentifier = nil
                note.clearTranscriptionTelemetrySummary()
            }
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure(diagnostic ?? "transcription error")
            note.clearTransientTranscriptionFlags()
        }
    }

    func beginLocalTranscription(for note: VoiceNote, attemptID: String) {
        cancelledRunNoteIDs.remove(note.id)
        cancelRequested = false
        activeNoteID = note.id
        progressByNoteID[note.id] = 0.0
        transcriptionProgress = 0.0
        note.claimTranscription(
            ownerDeviceID: currentDeviceID,
            attemptID: attemptID,
            queuedAt: note.transcriptionQueuedAt ?? nowProvider(),
            leaseExpiresAt: nowProvider().addingTimeInterval(leaseDuration)
        )
        note.clearTransientTranscriptionFlags()
    }

    func endLocalTranscription(for noteID: UUID) {
        cancelledRunNoteIDs.remove(noteID)
        if activeNoteID == noteID {
            activeNoteID = nil
        }
        progressByNoteID.removeValue(forKey: noteID)
        transcriptionProgress = 0.0
    }

    private func handleUnavailableAudio(for note: VoiceNote) {
        let queuedAt = note.transcriptionQueuedAt ?? nowProvider()
        let permanentlyMissing = isAudioPermanentlyMissing(note.audioFilePath)
        if !permanentlyMissing,
           nowProvider().timeIntervalSince(queuedAt) < audioAvailabilityRetryWindow {
            // Keep the persisted first queue time so repeated cloud failures cannot
            // restart the retry window indefinitely, including after app relaunch.
            audioWaitNoteIDs.insert(note.id)
            requeueNote(note, queuedAt: queuedAt)
            return
        }
        audioWaitNoteIDs.remove(note.id)
        // Timeout means unavailable, not proven missing. Both outcomes preserve
        // prior text and recovery checkpoints and allow an explicit later retry.
        note.completeTranscription()
        note.transcriptionOutcome = .failed
        note.markTranscriptionFailure(permanentlyMissing
            ? "Audio file is missing from this device. Restore the audio or import it again to retry."
            : "Audio is still unavailable. Automatic retries stopped. Check iCloud and retry.")
        note.clearTransientTranscriptionFlags()
    }

    func requeueNote(_ note: VoiceNote, queuedAt: Date) {
        holdOrQueue(note, queuedAt: queuedAt)
        // A dequeued note is not re-added by the running loop; the recheck picks it up.
        waitingNotes[note.id] = note
        scheduleWaitingRecheck()
    }

    func startLeaseHeartbeat(for note: VoiceNote, attemptID: String) {
        stopLeaseHeartbeat()
        leaseHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))

                guard !Task.isCancelled else {
                    break
                }

                guard self.activeNoteID == note.id,
                      note.transcriptionState == .claimed,
                      note.transcriptionOwnerDeviceID == self.currentDeviceID,
                      note.transcriptionAttemptID == attemptID else {
                    break
                }

                note.transcriptionLeaseExpiresAt = self.nowProvider().addingTimeInterval(self.leaseDuration)
            }
        }
    }

    func stopLeaseHeartbeat() {
        leaseHeartbeatTask?.cancel()
        leaseHeartbeatTask = nil
    }

    func transcribeWithQwen(
        filePath: String,
        progressCallback: @escaping (Float) -> Void
    ) async -> RawTranscription {
        guard isEngineLoaded else {
            currentEngine = .notAvailable
            return .modelUnavailable
        }

        if cancelRequested || Task.isCancelled {
            return .cancelled
        }
        currentEngine = .qwen3

        // Persist timings in Release without recording paths or text.
        let diagnosticID = UUID().uuidString
        let preparationStart = ProcessInfo.processInfo.systemUptime
        Self.transcriptionLog.notice("decode=\(diagnosticID, privacy: .public) stage=preparationStarted")

        guard let audioURL = await CloudStorageManager.shared.prepareFileForReading(at: filePath) else {
            print("Failed to prepare audio file for transcription: \(filePath)")
            return .audioUnavailable
        }
        Self.transcriptionLog.notice("decode=\(diagnosticID, privacy: .public) stage=fileReady seconds=\(ProcessInfo.processInfo.systemUptime - preparationStart)")

        let updateProgressOnMain: (Float) -> Void = { [weak self] value in
            guard let self else { return }
            self.smoothProgress(to: value, progressCallback: progressCallback)
        }
        updateProgressOnMain(0.01)

        // An empty transcript cannot be relied on to mark silence: CoreML always
        // writes something and MLX often does. Confident silence is turned away
        // here, and output from uncertain audio is checked afterwards.
        let vadStart = ProcessInfo.processInfo.systemUptime
        let presence = await Task.detached(priority: .utility) {
            NeuralSpeechAnalyzer.safelySpeechPresence(at: audioURL)
        }.value
        Self.transcriptionLog.notice("decode=\(diagnosticID, privacy: .public) stage=vadFinished seconds=\(ProcessInfo.processInfo.systemUptime - vadStart) presence=\(String(describing: presence), privacy: .public)")
        guard presence != .silence else {
            updateProgressOnMain(1.0)
            return .noSpeech
        }

        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .utility) {
                try Qwen3AudioPCM.loadPCM16kMono(url: audioURL)
            }.value
        } catch {
            print("Could not decode audio for transcription: \(error)")
            return .engineError(Self.engineFailurePrefix + error.localizedDescription)
        }
        guard !samples.isEmpty else { return .noSpeech }
        updateProgressOnMain(0.1)

        let languageHint = self.languageHint(for: decodingNoteID)
        let pieces: [String]
        do {
            guard let decoded = try await decodePasses(
                samples, languageHint: languageHint, diagnosticID: diagnosticID,
                progress: { updateProgressOnMain(0.1 + 0.9 * $0) }
            ) else { return .cancelled }
            pieces = decoded
        } catch is CancellationError {
            return .cancelled
        } catch is Qwen3ASRModelStore.StoreError {
            currentEngine = .notAvailable
            return .modelUnavailable
        } catch {
            print("Transcription engine error: \(error)")
            return .engineError(Self.engineFailurePrefix + error.localizedDescription)
        }

        return Self.gatedOutput(pieces.joined(separator: " "), presence: presence)
    }

    func resetProgressSmoothing() {
        progressSmoothingTask?.cancel()
        progressSmoothingTask = nil
        progressSmoothingTarget = 0.0
    }

    func smoothProgress(to target: Float, progressCallback: @escaping (Float) -> Void) {
        // A finished decoder pass may still be rejected, so it stops short of 100%.
        let clamped = target.isFinite ? min(0.99, max(0.0, target)) : 0
        if clamped <= transcriptionProgress {
            return
        }

        progressSmoothingTarget = max(progressSmoothingTarget, clamped)

        if progressSmoothingTask != nil {
            return
        }

        progressSmoothingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let current = self.transcriptionProgress
                let target = self.progressSmoothingTarget
                if current >= target {
                    break
                }
                let delta = target - current
                let step = min(0.05, max(0.01, delta * 0.25))
                let next = min(target, current + step)
                self.transcriptionProgress = next
                progressCallback(next)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.progressSmoothingTask = nil
        }
    }
}

extension TranscriptionService {
    /// Loose backstop, not a normal-speech quality gate: legitimate repeated
    /// terminology can exceed ratios of 2.0 and 2.4.
    static let repetitionCompressionLimit: Float = 8.0

    /// Marks a diagnostic for a decode the engine aborted, as opposed to output
    /// it produced and we rejected. Only the former is worth another attempt.
    nonisolated static let engineFailurePrefix = "Engine error: "

    nonisolated static func isEngineFailure(_ diagnostic: String?) -> Bool {
        diagnostic?.hasPrefix(engineFailurePrefix) ?? false
    }

    /// How much smaller DEFLATE makes the text. Ordinary speech stays near 1–2;
    /// a decoder stuck repeating itself compresses many times over.
    nonisolated static func compressionRatio(of text: String) -> Float {
        let data = Data(text.utf8)
        guard !data.isEmpty,
              let compressed = try? (data as NSData).compressed(using: .zlib),
              compressed.length > 0 else { return 0 }
        return Float(data.count) / Float(compressed.length)
    }

    /// Words (each CJK character counts as one) that output from uncertain audio
    /// needs to count as speech. On near-silence the decoder writes fragments
    /// such as "嗯。" or "No."; far-field speech that the VAD scores low came out
    /// as whole sentences (13 words, 31 characters) in the calibration recordings.
    nonisolated static let minimumUncertainWords = 3

    /// Engine output after the speech gate. Text that is only whitespace or
    /// punctuation is noise, not a decoder failure, and must not fail the note.
    /// Decodes `samples` in passes no longer than the engine's limit; callers
    /// slice to that limit already, so this cut is a safeguard. Each token
    /// counts as decode work. Returns nil when cancelled between passes.
    func decodePasses(
        _ samples: [Float],
        languageHint: String?,
        diagnosticID: String,
        progress: (Float) -> Void
    ) async throws -> [String]? {
        let chunkSamples = Int(Qwen3ASRDefaults.singlePassSecondsLimit * 16_000)
        let counter = decodeWorkCounter
        var pieces: [String] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSamples, samples.count)
            let passStart = ProcessInfo.processInfo.systemUptime
            let pass = try await transcribeSamples(Array(samples[offset..<end]), languageHint) {
                counter.withLock { $0 &+= 1 }
            }
            let endReason = pass.reachedTokenLimit ? "tokenLimit" : "endOfTurn"
            Self.transcriptionLog.notice("decode=\(diagnosticID, privacy: .public) stage=passEnded seconds=\(ProcessInfo.processInfo.systemUptime - passStart) audioSeconds=\(Double(end - offset) / 16_000) tokens=\(pass.tokenCount) endReason=\(endReason, privacy: .public)")
            if pass.reachedTokenLimit {
                debugLog("⚠️ [TranscriptionService] A \(Double(end - offset) / 16_000) s pass hit the \(Qwen3ASRDefaults.maxTokens)-token cap; its text is cut short")
            }
            if cancelRequested || Task.isCancelled {
                return nil
            }
            pieces.append(pass.text)
            // Callers pass one slice, so there is one pass and one tag.
            if decodedLanguage == nil { decodedLanguage = pass.language }
            offset = end
            progress(Float(offset) / Float(samples.count))
        }
        return pieces
    }

    nonisolated static func gatedOutput(_ text: String, presence: SpeechPresence) -> RawTranscription {
        guard LocalTranscriptFinalizer.hasContent(text) else { return .noSpeech }
        if presence == .uncertain, wordCount(text) < minimumUncertainWords { return .noSpeech }
        return validatedEngineOutput(text)
    }

    /// Runs of letters or digits count as one word; each CJK character (Han,
    /// kana including half-width, Hangul in composed or decomposed form) counts
    /// as one. Counts by grapheme, so combining marks never add a word, and
    /// punctuation such as the katakana middle dot never counts.
    nonisolated static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            guard let scalar = character.unicodeScalars.first,
                  !character.isPunctuation, !character.isWhitespace, !character.isSymbol else {
                inWord = false
                continue
            }
            if isCJKCharacter(scalar) {
                count += 1
                inWord = false
            } else if character.isLetter || character.isNumber {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    private nonisolated static func isCJKCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3041...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0xFF66...0xFF9D,   // Half-width katakana
             0x1100...0x11FF,   // Hangul Jamo (decomposed syllables)
             0x3130...0x318F,   // Hangul compatibility Jamo
             0xAC00...0xD7A3:   // Hangul syllables
            return true
        default:
            return false
        }
    }

    nonisolated static func validatedEngineOutput(_ text: String) -> RawTranscription {
        // The repetition penalty makes loops rare, not impossible.
        guard compressionRatio(of: text) <= repetitionCompressionLimit else {
            return .engineError("repetitive output")
        }
        return .text(text)
    }

    func annotatedText(for result: TranscriptionResult) -> String {
        annotatedText(text: result.text, duration: result.duration)
    }

    func annotatedText(text: String, duration: TimeInterval) -> String {
        let formatted = formatTranscriptionDuration(duration)
        let header = "Transcription completed in \(formatted)."
        if text.isEmpty {
            return header
        }
        return header + "\n\n" + text
    }

    func formatTranscriptionDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.2f seconds", duration)
        }

        if duration < 60 {
            return String(format: "%.2f seconds", duration)
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropTrailing

        if let formatted = formatter.string(from: duration), !formatted.isEmpty {
            return formatted
        }

        return String(format: "%.2f seconds", duration)
    }
}
