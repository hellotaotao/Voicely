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
import WhisperKit

enum TranscriptionEngine {
    case whisperKit
    case notAvailable
}

struct TranscriptionResult {
    let text: String
    let duration: TimeInterval
    let modelIdentifier: String?
}

/// What a single transcription attempt produced. `.text` carries Whisper's raw
/// output (still to be finalized); every other case names *why* there is no
/// text, so callers can react per cause instead of treating all failures alike.
/// A string literal becomes `.text`, so existing test stubs keep working.
enum RawTranscription: ExpressibleByStringLiteral {
    case text(String)
    case noSpeech
    case modelUnavailable
    case audioUnavailable
    case whisperError(String?)
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
    case whisperError(String?)
    case cancelled
}

@MainActor
class TranscriptionService: ObservableObject {
    typealias TranscribeImpl = (String, @escaping (Float) -> Void) async -> RawTranscription

    @Published var isTranscribing = false
    @Published var loadingProgress: Float = 0.0
    // Smoothing state is internal; visible note progress publishes separately.
    var transcriptionProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var previewByNoteID: [UUID: String] = [:]
    @Published private(set) var progressByNoteID: [UUID: Float] = [:]
    // Frequent clock updates belong to the telemetry card, not every service subscriber.
    let telemetryState = TranscriptionTelemetryState()
    private(set) var transcriptionTelemetry: TranscriptionTelemetrySnapshot {
        get { telemetryState.snapshot }
        set { telemetryState.update(newValue) }
    }

    var modelManager: ModelManager?
    var transcribeImpl: TranscribeImpl = { _, _ in .whisperError(nil) }
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
    var audioAvailabilityRetryWindow: TimeInterval = 5 * 60
    var leaseDuration: TimeInterval = 5 * 60
    var heartbeatInterval: TimeInterval = 60
    var nonOriginQueueGracePeriod: TimeInterval = 5 * 60

    /// Shared with the import path (ContentView) so the in-flight guard and
    /// resume sidecars are consistent across imports and re-transcriptions.
    let segmentProgressStore: SegmentProgressStore

    private static let ownershipMigrationDefaultsKey = "VoicelyOwnershipMigrationV1"

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
            return await self.transcribeWithWhisper(
                filePath: filePath,
                progressCallback: progressCallback
            )
        }
    }

    func setModelManager(_ manager: ModelManager) {
        self.modelManager = manager
        updateEngineStatus()
    }

    func loadWhisperModel() async -> Bool {
        guard let modelManager else {
            print("ModelManager not available")
            return false
        }

        let modelName = modelManager.selectedModel
        loadingProgress = 0.1
        await modelManager.loadModel(modelName)

        updateEngineStatus()
        loadingProgress = modelManager.loadingProgressValue

        let success = modelManager.isModelLoaded()
        if success {
            print("WhisperKit loaded successfully with model: \(modelName)")
        } else {
            print("Failed to load WhisperKit model: \(modelName)")
        }
        return success
    }

    func configureNewNote(_ note: VoiceNote, shouldStartImmediately: Bool) {
        let now = nowProvider()
        note.transcriptionOriginDeviceID = currentDeviceID
        note.transcription = ""
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
        var migratedAny = false

        for note in notes {
            if recoverInterruptedLiveRecordingIfNeeded(note, now: now) {
                migratedAny = true
            }
        }

        for note in notes where !note.hasOwnershipState {
            migratedAny = true
            note.transcriptionOriginDeviceID = note.transcriptionOriginDeviceID ?? currentDeviceID

            if !note.transcription.isEmpty {
                note.completeTranscription()
            } else if note.pendingTranscription || note.isTranscribing {
                note.queueTranscription(at: note.timestamp > now ? now : note.timestamp)
            } else {
                note.completeTranscription()
            }

            note.clearTransientTranscriptionFlags()
        }

        if migratedAny {
            UserDefaults.standard.set(true, forKey: Self.ownershipMigrationDefaultsKey)
        }
    }

    func processPendingTranscriptions(notes: [VoiceNote]) async {
        updateEngineStatus()

        guard isWhisperLoaded else {
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
                while isTranscribing || activeNoteID != nil {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

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
        guard isWhisperLoaded, !note.audioFilePath.isEmpty || workingCopy != nil,
              !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id) else {
            return false
        }

        migrateLegacyOwnershipIfNeeded(notes: [note])

        if !takeOver, isTranscribingOnAnotherDevice(note) && !leaseHasExpired(note) {
            return false
        }

        if !force, note.transcriptionState == .completed, !note.transcription.isEmpty,
           note.transcriptionOutcome != .failed {
            return false
        }

        if isLocallyTranscribing(note) { return false }
        if force || note.transcriptionOutcome == .failed {
            do {
                try segmentProgressStore.resetProgressPreservingAttempt(for: note.id)
            } catch {
                note.markTranscriptionFailure("Could not preserve the previous attempt. Retry was not started; saved progress is unchanged.")
                return false
            }
        }
        note.resumeCancelledTranscription(at: nowProvider())
        if note.audioFilePath.isEmpty, let workingCopy {
            await SegmentedAudioTranscriber(transcriptionService: self, progressStore: segmentProgressStore)
                .transcribe(note: note, sourceURL: workingCopy)
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

    func cancelTranscription(for note: VoiceNote) {
        // Recording ownership includes the final flush, not a cancellable saved-note job.
        guard !localRecordingNoteIDs.contains(note.id) else { return }
        guard activeNoteID == note.id || note.transcriptionState == .queued || note.transcriptionState == .cancelled
            || (note.transcriptionState == .claimed && note.transcriptionOwnerDeviceID == currentDeviceID) else { return }
        if activeNoteID == note.id { cancelTranscriptionRun(for: note.id) }
        pendingTranscriptionQueue.removeValue(forKey: note.id)
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
        if activeNoteID == note.id { cancelTranscriptionRun(for: note.id) }
        pendingTranscriptionQueue.removeValue(forKey: note.id)
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
        audioDuration > 30
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
    }

    func endExternalTranscription(noteID: UUID) {
        cancelledRunNoteIDs.remove(noteID)
        previewByNoteID.removeValue(forKey: noteID)
        if activeNoteID == noteID { activeNoteID = nil }
        progressByNoteID.removeValue(forKey: noteID)
    }

    func isTranscribingOnAnotherDevice(_ note: VoiceNote, now: Date? = nil) -> Bool {
        guard note.transcriptionState == .claimed else {
            return false
        }

        guard let ownerDeviceID = note.transcriptionOwnerDeviceID,
              ownerDeviceID != currentDeviceID else {
            return false
        }

        return !leaseHasExpired(note, now: now)
    }

    func shouldShowPendingState(_ note: VoiceNote, now: Date? = nil) -> Bool {
        // A live recording may outlast the queue lease without becoming queued work.
        guard !localRecordingNoteIDs.contains(note.id) else { return false }
        if note.transcriptionState == .queued {
            return true
        }

        return note.transcriptionState == .claimed && leaseHasExpired(note, now: now)
    }

    func unloadWhisperModel() {
        if let modelManager {
            modelManager.whisperKit = nil
            modelManager.modelState = .unloaded
        }
        currentEngine = .notAvailable
        loadingProgress = 0.0
        print("WhisperKit model unloaded")
    }

    func getAvailableModels() -> [String] {
        [
            "tiny",
            "base",
            "small"
        ]
    }

    func isWhisperAvailable() -> Bool {
        updateEngineStatus()
        return isWhisperLoaded
    }

    func getCurrentEngineDescription() -> String {
        updateEngineStatus()

        switch currentEngine {
        case .whisperKit:
            return "WhisperKit (Local AI)"
        case .notAvailable:
            return "No transcription available"
        }
    }

    func getEngineStatusMessage() -> String {
        updateEngineStatus()

        switch currentEngine {
        case .whisperKit:
            return "Using WhisperKit for high-quality offline transcription"
        case .notAvailable:
            return "WhisperKit not loaded. Please load a model first."
        }
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
        defer {
            isTranscribing = false
            currentTranscriptionTask = nil
            if currentDecodeTelemetrySession?.id == session.id { currentDecodeTelemetrySession = nil }
            if ownsTelemetry { endTelemetrySession(session) }
            resetProgressSmoothing()
            transcriptionProgress = 0.0
        }

        guard isWhisperLoaded else {
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
            await self?.transcribeImpl(filePath, progressCallback)
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
                // Whisper ran but produced nothing usable. Treat it as a real error
                // to surface for diagnosis — not as a calm "no speech".
                return .whisperError("blank output")
            }
            if ownsTelemetry, let duration = session.audioDuration {
                recordProcessedAudio(start: 0, end: duration, session: session)
            }
            let elapsed = Date().timeIntervalSince(startTime)
            let modelIdentifier = modelManager?.currentModelIdentifier() ?? modelManager?.selectedModel
            return .transcribed(TranscriptionResult(
                text: finalizedTranscript.text,
                duration: elapsed,
                modelIdentifier: modelIdentifier
            ))
        case .noSpeech:
            if ownsTelemetry, let duration = session.audioDuration {
                recordProcessedAudio(start: 0, end: duration, session: session)
            }
            return .noSpeech
        case .modelUnavailable:
            return .modelUnavailable
        case .audioUnavailable:
            return .audioUnavailable
        case .whisperError(let diagnostic):
            return .whisperError(diagnostic)
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
}

private extension TranscriptionService {
    enum ProcessingAction {
        case claimNew(attemptID: String, queuedAt: Date)
        case resumeOwned(attemptID: String)
    }

    var currentDeviceID: String {
        deviceIDProvider()
    }

    var isWhisperLoaded: Bool {
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
        TranscriptionComputeRoute(
            encoderUnits: modelManager?.encoderComputeUnits ?? .cpuAndNeuralEngine,
            decoderUnits: modelManager?.decoderComputeUnits ?? .cpuAndNeuralEngine
        )
    }

    func updateEngineStatus() {
        if isWhisperLoaded {
            currentEngine = .whisperKit
        } else {
            currentEngine = .notAvailable
        }
    }

    func processingAction(for note: VoiceNote, now: Date) -> ProcessingAction? {
        guard !note.audioFilePath.isEmpty, !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id) else {
            return nil
        }

        switch note.transcriptionState {
        case .claimed:
            if note.transcriptionOwnerDeviceID == currentDeviceID {
                let attemptID = note.transcriptionAttemptID ?? UUID().uuidString
                return .resumeOwned(attemptID: attemptID)
            }

            guard leaseHasExpired(note, now: now) else {
                return nil
            }

            return .claimNew(
                attemptID: UUID().uuidString,
                queuedAt: note.transcriptionQueuedAt ?? now
            )
        case .queued:
            guard canCurrentDeviceClaimQueuedNote(note, now: now) else {
                return nil
            }

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

    func canCurrentDeviceClaimQueuedNote(_ note: VoiceNote, now: Date) -> Bool {
        guard note.transcriptionState == .queued else {
            return false
        }

        if note.transcriptionOriginDeviceID == currentDeviceID {
            return true
        }

        guard let queuedAt = note.transcriptionQueuedAt else {
            return true
        }

        return now.timeIntervalSince(queuedAt) >= nonOriginQueueGracePeriod
    }

    func leaseHasExpired(_ note: VoiceNote, now: Date? = nil) -> Bool {
        guard let leaseExpiresAt = note.transcriptionLeaseExpiresAt else {
            return true
        }
        return leaseExpiresAt <= (now ?? nowProvider())
    }

    func recoverInterruptedLiveRecordingIfNeeded(_ note: VoiceNote, now: Date) -> Bool {
        guard note.hasOwnershipState, note.transcriptionState != .cancelled else {
            return false
        }

        guard note.isTranscribing else {
            return false
        }

        guard activeNoteID != note.id, !localRecordingNoteIDs.contains(note.id), !discardedNoteIDs.contains(note.id) else {
            return false
        }

        if let ownerDeviceID = note.transcriptionOwnerDeviceID,
           ownerDeviceID != currentDeviceID,
           !leaseHasExpired(note, now: now) {
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
                continue
            }

            pendingTranscriptionQueue[note.id] = note
            if pendingTranscriptionOrderSet.insert(note.id).inserted {
                pendingTranscriptionOrder.append(note.id)
            }
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
        guard let url = await prepareAudioFileForReading(note.audioFilePath) else {
            if stillOwnsAttempt() { handleUnavailableAudio(for: note) }
            return
        }
        guard stillOwnsAttempt() else { return }
        let resolvedDuration = await audioDurationProvider(url.path)
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
            Task { @MainActor in
                self?.reportExternalProgress(value, for: noteID)
            }
        }

        var outcome = await transcribeAudioOutcome(filePath: url.path, progressCallback: onProgress, telemetrySession: session)

        // A real Whisper error is often transient — retry once before giving up.
        if case .whisperError = outcome, !wasTranscriptionCancelled() {
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
            note.transcription = result.text
            note.lastTranscriptionDuration = result.duration
            note.transcriptionModelIdentifier = result.modelIdentifier
            if let snapshot = telemetryState.snapshot(for: note.id) { note.recordTranscriptionTelemetry(snapshot) }
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.clearTransientTranscriptionFlags()

        case .noSpeech:
            recordProcessedAudio(start: 0, end: resolvedDuration, session: session)
            // Existing text may be an incomplete live preview, not a proven
            // complete transcript. A silent retry cannot establish completeness.
            if !hadExistingTranscript {
                note.transcription = ""
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

        case .whisperError(let diagnostic):
            // A real error survived the retry. Don't pretend it succeeded, and don't
            // dump jargon on the user — keep the real reason internally for us.
            #if DEBUG
            print("❌ [TranscriptionService] note \(noteID) failed after retry: \(diagnostic ?? "unknown error")")
            #endif
            if !hadExistingTranscript {
                note.transcription = ""
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
            requeueNote(note, queuedAt: queuedAt)
            return
        }
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
        note.queueTranscription(at: queuedAt)
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

    func transcribeWithWhisper(
        filePath: String,
        progressCallback: @escaping (Float) -> Void
    ) async -> RawTranscription {
        guard let modelManager,
              let whisperKit = modelManager.getWhisperKit() else {
            print("WhisperKit not available")
            currentEngine = .notAvailable
            return .modelUnavailable
        }

        if cancelRequested || Task.isCancelled {
            return .cancelled
        }

        do {
            currentEngine = .whisperKit
            print("Using WhisperKit for transcription")

            guard let audioURL = await CloudStorageManager.shared.prepareFileForReading(at: filePath) else {
                print("Failed to prepare audio file for transcription: \(filePath)")
                return .audioUnavailable
            }

#if DEBUG
            let windowSamples = whisperKit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
            let windowSeconds = Double(windowSamples) / Double(WhisperKit.sampleRate)
            print("WhisperKit windowSamples=\(windowSamples) (~\(String(format: "%.2f", windowSeconds))s) sampleRate=\(WhisperKit.sampleRate)")
#endif

            let updateProgressOnMain: (Float) -> Void = { [weak self] value in
                guard let self else { return }
                self.smoothProgress(to: value, progressCallback: progressCallback)
            }
            updateProgressOnMain(0.01)

            let containsProbableSpeech = await Task.detached(priority: .utility) {
                NeuralSpeechAnalyzer.safelyContainsProbableSpeech(at: audioURL)
            }.value
            guard containsProbableSpeech else {
                print("Skipping transcription because no probable speech was detected in audio file: \(filePath)")
                updateProgressOnMain(1.0)
                return .noSpeech
            }

            whisperKit.transcriptionStateCallback = { state in
                Task { @MainActor in
                    switch state {
                    case .convertingAudio:
                        updateProgressOnMain(0.05)
                    case .transcribing:
                        updateProgressOnMain(0.1)
                    case .finished:
                        break
                    }
                }
            }
            defer {
                whisperKit.segmentDiscoveryCallback = nil
                whisperKit.transcriptionStateCallback = nil
            }

            let selectedLanguageKey = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto"
            let languageCode: String?
            let customPrompt = UserDefaults.standard.string(forKey: "transcriptionPrompt") ?? ""

            updateProgressOnMain(0.02)

            let audioPath = audioURL.path

            let isAutoLanguage = selectedLanguageKey == "auto"
            if isAutoLanguage {
                languageCode = nil
                print("Auto language mode: WhisperKit will detect language via prefill")
            } else {
                languageCode = LanguageConstants.languages[selectedLanguageKey]
                print("Using selected language code: \(languageCode ?? "nil")")
            }
            updateProgressOnMain(0.06)
            updateProgressOnMain(0.1)

            var decodeOptions = DecodingOptions(
                task: .transcribe,
                language: languageCode,
                temperature: 0.0,
                temperatureFallbackCount: 3,
                sampleLength: 224,
                usePrefillPrompt: true,
                usePrefillCache: false,
                detectLanguage: isAutoLanguage,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: false,
                clipTimestamps: [0.0],
                compressionRatioThreshold: 2.0,
                // Incremental segments are pre-cut to ≤29 s by our own VAD;
                // WhisperKit must treat each input as a single window.
                chunkingStrategy: ChunkingStrategy.none
            )

            if !customPrompt.isEmpty, let tokenizer = whisperKit.tokenizer {
                let promptText = " " + customPrompt.trimmingCharacters(in: .whitespaces)
                decodeOptions.promptTokens = tokenizer.encode(text: promptText)
                print("Using custom prompt: \(customPrompt)")
            }

            // Whisper invokes this once per decoded token; only hop to the
            // main actor when the fraction moved enough to be visible.
            let lastReportedFraction = OSAllocatedUnfairLock<Float>(initialState: 0)
            let transcriptionResults = try await whisperKit.transcribe(
                audioPath: audioPath,
                decodeOptions: decodeOptions
            ) { [weak self] _ in
                guard let self else { return nil }
                if self.cancelRequested || Task.isCancelled {
                    return false
                }
                let fraction = Float(whisperKit.progress.fractionCompleted)
                let shouldPublish = lastReportedFraction.withLock { last in
                    guard fraction >= last + 0.01 || fraction >= 1.0 else { return false }
                    last = fraction
                    return true
                }
                if shouldPublish {
                    Task { @MainActor in
                        updateProgressOnMain(fraction)
                    }
                }
                return nil
            }

            updateProgressOnMain(1.0)

            if cancelRequested || Task.isCancelled {
                return .cancelled
            }

            guard let result = transcriptionResults.first else {
                return .whisperError("empty result")
            }

            return Self.validatedWhisperOutput(result.text)
        } catch {
            print("WhisperKit transcription error: \(error)")
            currentEngine = .notAvailable
            return .whisperError("WhisperKit error: \(error.localizedDescription)")
        }
    }

    func resetProgressSmoothing() {
        progressSmoothingTask?.cancel()
        progressSmoothingTask = nil
        progressSmoothingTarget = 0.0
    }

    func smoothProgress(to target: Float, progressCallback: @escaping (Float) -> Void) {
        let clamped = min(1.0, max(0.0, target))
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
    nonisolated static func validatedWhisperOutput(_ text: String) -> RawTranscription {
        // Decoder temperature fallback can exhaust its retries and still return
        // repetitive text. Use a loose backstop, not a normal-speech quality gate:
        // legitimate repeated terminology can exceed ratios of 2.0 and 2.4.
        guard TextUtilities.compressionRatio(of: text) <= 8.0 else {
            return .whisperError("repetitive output")
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
