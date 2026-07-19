//
//  TranscriptionService.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import AVFoundation
import Foundation
import os
import WhisperKit

enum TranscriptionEngine {
    case whisperKit
    case qwen3ASR
    case notAvailable
}

struct TranscriptionResult {
    let text: String
    let duration: TimeInterval
    let modelIdentifier: String?
    /// Word-level timings for this attempt (empty unless wordTimestamps was on).
    /// Always in lockstep with `text`: joined word texts reproduce it exactly.
    var words: [WordToken] = []
    /// Raw, unfiltered whisper-segment pieces (slice-local times). Accumulating
    /// callers collect these across slices and assemble once at the outer level,
    /// so cross-slice dedup/merge decisions see segment granularity.
    var pieces: [TranscriptPiece] = []

    /// Pieces for accumulation; synthesizes from text/words for hand-built
    /// results (test stubs) that don't carry pieces.
    var effectivePieces: [TranscriptPiece] {
        if !pieces.isEmpty { return pieces }
        if !words.isEmpty { return [TranscriptPiece(words: words)] }
        return TranscriptPiece.pieces(fromText: text, start: 0, end: 0)
    }
}

/// What a single transcription attempt produced. `.text` carries Whisper's raw
/// per-segment pieces (still to be assembled/filtered); every other case names
/// *why* there is no text, so callers can react per cause instead of treating
/// all failures alike. A string literal becomes `.text`, so test stubs stay terse.
enum RawTranscription: ExpressibleByStringLiteral {
    case text([TranscriptPiece])
    case noSpeech
    case modelUnavailable
    case audioUnavailable
    /// `retryable` is true only for a thrown WhisperKit error (often a transient
    /// ANE/Metal hiccup). A deterministic empty/blank decode is `false` — re-running
    /// the identical window just repeats the same degenerate output; let the caller
    /// salvage it by bisection instead.
    case whisperError(String?, retryable: Bool)
    case cancelled

    init(stringLiteral value: String) {
        self = .text(TranscriptPiece.pieces(fromText: value, start: 0, end: 0))
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
    /// `retryable` is true only for a thrown WhisperKit error (often a transient
    /// ANE/Metal hiccup). A deterministic empty/blank decode is `false` — re-running
    /// the identical window just repeats the same degenerate output; let the caller
    /// salvage it by bisection instead.
    case whisperError(String?, retryable: Bool)
    case cancelled
}

@MainActor
class TranscriptionService: ObservableObject {
    typealias TranscribeImpl = (String, @escaping (Float) -> Void) async -> RawTranscription

    @Published var isTranscribing = false
    @Published var loadingProgress: Float = 0.0
    @Published var transcriptionProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var progressByNoteID: [UUID: Float] = [:]
    @Published private(set) var transcriptionTelemetry: TranscriptionTelemetrySnapshot = .inactive()

    var modelManager: ModelManager?
    var transcribeImpl: TranscribeImpl = { _, _ in .whisperError(nil, retryable: false) }
    /// Which engine this service routes to. Injectable so tests can pin a mode
    /// regardless of the stored default.
    var engineModeProvider: () -> TranscriptionEngineMode = { TranscriptionEngineMode.currentResolved() }
    var deviceIDProvider: () -> String = { DeviceIdentity.currentDeviceID }
    var nowProvider: () -> Date = { Date() }
    var audioDurationProvider: (String) async -> TimeInterval? = { filePath in
        await TranscriptionService.estimatedAudioDuration(for: filePath)
    }
    var leaseDuration: TimeInterval = 5 * 60
    var heartbeatInterval: TimeInterval = 60
    var nonOriginQueueGracePeriod: TimeInterval = 5 * 60

    /// Shared with the import path (ContentView) so the in-flight guard and
    /// resume sidecars are consistent across imports and re-transcriptions.
    let segmentProgressStore: SegmentProgressStore

    private static let ownershipMigrationDefaultsKey = "VoicelyOwnershipMigrationV1"

    private var currentTranscriptionTask: Task<RawTranscription?, Never>?
    private var cancelRequested = false
    /// Notes whose in-flight (possibly multi-batch) run the user cancelled.
    private var cancelledRunNoteIDs: Set<UUID> = []
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
    private var telemetryStartedAt: Date?
    private var telemetryAudioDuration: TimeInterval?
    private var telemetryTimerTask: Task<Void, Never>?

    init(modelManager: ModelManager? = nil,
         segmentProgressStore: SegmentProgressStore = SegmentProgressStore()) {
        self.modelManager = modelManager
        self.segmentProgressStore = segmentProgressStore
        self.transcribeImpl = { [weak self] filePath, progressCallback in
            guard let self else { return .cancelled }
            switch self.engineModeProvider() {
            case .qwen3ASR:
                return await self.transcribeWithQwen(
                    filePath: filePath,
                    progressCallback: progressCallback
                )
            case .whisperKit:
                return await self.transcribeWithWhisper(
                    filePath: filePath,
                    progressCallback: progressCallback
                )
            }
        }
    }

    func setModelManager(_ manager: ModelManager) {
        self.modelManager = manager
        updateEngineStatus()
    }

    /// Loads whichever engine is selected: Qwen3 downloads (if needed) and
    /// loads its MLX weights; Whisper loads the selected CoreML model.
    /// The name predates the engine switch — every call site treats it as
    /// "make the transcription engine ready".
    func loadWhisperModel() async -> Bool {
        switch engineModeProvider() {
        case .qwen3ASR:
            return await loadQwenEngine()
        case .whisperKit:
            return await loadWhisperEngine()
        }
    }

    private func loadQwenEngine() async -> Bool {
        loadingProgress = 0.05
        let ready = await Qwen3ModelDownloadController.shared.downloadAndLoad()
        loadingProgress = ready ? 1.0 : 0.0
        updateEngineStatus()
        print(ready ? "Qwen3 ASR engine ready" : "Failed to prepare Qwen3 ASR engine")
        return ready
    }

    private func loadWhisperEngine() async -> Bool {
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
        note.setTranscript(text: "", words: [])
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
                while isTranscribing {
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

        guard isWhisperLoaded, !note.audioFilePath.isEmpty else {
            return false
        }

        migrateLegacyOwnershipIfNeeded(notes: [note])

        if !takeOver, isTranscribingOnAnotherDevice(note) && !leaseHasExpired(note) {
            return false
        }

        if !force, note.transcriptionState == .completed, !note.transcription.isEmpty {
            return false
        }

        if force {
            // An explicit re-transcribe means "start over": drop any leftover
            // resume sidecar + working copy so the run starts fresh instead of
            // continuing a stale partial (often left by a run the user interrupted
            // by switching models). A resumed run keeps the previous word timings,
            // which is what made a finished re-transcribe look like it reverted.
            segmentProgressStore.delete(for: note.id)
            segmentProgressStore.removeWorkingCopy(for: note.id)
        }

        let queuedAt = note.transcriptionQueuedAt ?? nowProvider()
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
        guard activeNoteID == note.id else { return }
        cancelTranscription()
        requeueNote(note, queuedAt: nowProvider())
    }

    func localProgress(for note: VoiceNote) -> Float {
        progressByNoteID[note.id] ?? 0.0
    }

    func isLocallyTranscribing(_ note: VoiceNote) -> Bool {
        activeNoteID == note.id
    }

    /// Surfaces a note transcribed by an external coordinator
    /// (SegmentedAudioTranscriber) as locally transcribing, so the detail view
    /// shows the same "Transcribing…" state and progress as the in-process path.
    func beginExternalTranscription(noteID: UUID) {
        activeNoteID = noteID
        progressByNoteID[noteID] = 0
    }

    func reportExternalProgress(_ progress: Float, for noteID: UUID) {
        progressByNoteID[noteID] = min(1, max(0, progress))
    }

    func endExternalTranscription(noteID: UUID) {
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
        Task { await Qwen3ASRModelStore.shared.unloadModel() }
        currentEngine = .notAvailable
        loadingProgress = 0.0
        print("Transcription engine unloaded")
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
        case .qwen3ASR:
            return "Qwen3 ASR (Local AI)"
        case .notAvailable:
            return "No transcription available"
        }
    }

    func getEngineStatusMessage() -> String {
        updateEngineStatus()

        switch currentEngine {
        case .whisperKit:
            return "Using WhisperKit for high-quality offline transcription"
        case .qwen3ASR:
            return "Using Qwen3 ASR for fast offline transcription"
        case .notAvailable:
            return "No transcription engine is ready. Please load a model first."
        }
    }

    /// Identifier stored on notes and shown in telemetry for the active engine.
    func currentEngineModelIdentifier() -> String? {
        switch engineModeProvider() {
        case .qwen3ASR:
            return Qwen3ASRDefaults.modelId
        case .whisperKit:
            return modelManager?.currentModelIdentifier() ?? modelManager?.selectedModel
        }
    }

    /// Runs one transcription attempt and reports *why* there is no transcript, so
    /// callers can react per cause instead of treating every empty result the same.
    func transcribeAudioOutcome(
        filePath: String,
        progressCallback: @escaping (Float) -> Void = { _ in },
        driveTelemetry: Bool = true
    ) async -> TranscriptionOutcome {
        updateEngineStatus()

        while isTranscribing {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        lastCancellationHandled = false
        if cancelRequested {
            cancelRequested = false
            lastCancellationHandled = true
            return .cancelled
        }

        isTranscribing = true
        transcriptionProgress = 0.0
        resetProgressSmoothing()
        let startTime = nowProvider()
        defer {
            isTranscribing = false
            currentTranscriptionTask = nil
            // The segmented path drives one whole-file telemetry session itself
            // (driveTelemetry == false), so a per-slice call must not finish it.
            if driveTelemetry { finishTranscriptionTelemetry() }
            resetProgressSmoothing()
            transcriptionProgress = 0.0
        }

        guard isWhisperLoaded else {
            return .modelUnavailable
        }

        if driveTelemetry {
            await beginTranscriptionTelemetry(filePath: filePath)
        }

        let task = Task { [weak self] in
            await self?.transcribeImpl(filePath, progressCallback)
        }
        currentTranscriptionTask = task

        guard let raw = await task.value else {
            return .cancelled
        }

        switch raw {
        case .text(let rawPieces):
            if cancelRequested || Task.isCancelled {
                cancelRequested = false
                lastCancellationHandled = true
                return .cancelled
            }
            guard let assembled = TranscriptAssembler.assemble(rawPieces) else {
                // Whisper ran but produced nothing usable. Treat it as a real error
                // to surface for diagnosis — not as a calm "no speech". Deterministic,
                // so not retryable: an identical re-decode yields the same blank.
                return .whisperError("blank output", retryable: false)
            }
            let elapsed = nowProvider().timeIntervalSince(startTime)
            let modelIdentifier = currentEngineModelIdentifier()
            return .transcribed(TranscriptionResult(
                text: assembled.text,
                duration: elapsed,
                modelIdentifier: modelIdentifier,
                words: assembled.words,
                pieces: rawPieces
            ))
        case .noSpeech:
            return .noSpeech
        case .modelUnavailable:
            return .modelUnavailable
        case .audioUnavailable:
            return .audioUnavailable
        case .whisperError(let diagnostic, let retryable):
            return .whisperError(diagnostic, retryable: retryable)
        case .cancelled:
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

    func cancelTranscription() {
        print("Cancelling current transcription...")
        cancelRequested = true
        currentTranscriptionTask?.cancel()
        currentTranscriptionTask = nil
        finishTranscriptionTelemetry()
        stopLeaseHeartbeat()
        resetProgressSmoothing()
        isTranscribing = false
        transcriptionProgress = 0.0
        if let noteID = activeNoteID {
            // Sticky mark so a segmented (multi-batch) run stops at its next
            // boundary — cancelling only the in-flight slice would let the outer
            // loop carry on through the rest of the file.
            cancelledRunNoteIDs.insert(noteID)
            endLocalTranscription(for: noteID)
        }
    }

    func wasTranscriptionCancelled() -> Bool {
        lastCancellationHandled
    }

    /// True once the user cancelled the run for this note. `cancelRequested` is
    /// consumed by whichever slice observes it, so a multi-batch run needs this
    /// separate, sticky signal to stop at its next boundary instead of grinding
    /// through every remaining batch. Cleared when a fresh run for the note starts.
    func isRunCancelled(noteID: UUID) -> Bool {
        cancelledRunNoteIDs.contains(noteID)
    }

    func clearRunCancellation(for noteID: UUID) {
        cancelledRunNoteIDs.remove(noteID)
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

private extension TranscriptionService {
    enum ProcessingAction {
        case claimNew(attemptID: String, queuedAt: Date)
        case resumeOwned(attemptID: String)
    }

    var currentDeviceID: String {
        deviceIDProvider()
    }

    /// Whether the selected engine can transcribe right now. For Qwen3 the
    /// weights on disk are enough — the store loads them lazily on first use;
    /// for Whisper the CoreML model must be loaded. The name predates the
    /// engine switch.
    var isWhisperLoaded: Bool {
        switch engineModeProvider() {
        case .qwen3ASR:
            return Qwen3ASRModelStore.isModelDownloaded()
        case .whisperKit:
            return modelManager?.isModelLoaded() ?? false
        }
    }

    func beginTranscriptionTelemetry(filePath: String) async {
        finishTranscriptionTelemetry()
        telemetryStartedAt = nowProvider()
        telemetryAudioDuration = await audioDurationProvider(filePath)
        startTelemetryTimer()
    }

    private func startTelemetryTimer() {
        refreshTranscriptionTelemetry(isActive: true)

        telemetryTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else {
                    break
                }
                self?.refreshTranscriptionTelemetry(isActive: true)
            }
        }
    }

    func refreshTranscriptionTelemetry(isActive: Bool) {
        guard let telemetryStartedAt else {
            transcriptionTelemetry = TranscriptionTelemetrySnapshot.inactive(
                modelName: currentTelemetryModelName(),
                computeRoute: currentTelemetryComputeRoute()
            )
            return
        }

        let elapsed = max(0, nowProvider().timeIntervalSince(telemetryStartedAt))
        transcriptionTelemetry = TranscriptionTelemetrySnapshot(
            isActive: isActive,
            modelName: currentTelemetryModelName(),
            computeRoute: currentTelemetryComputeRoute(),
            metrics: TranscriptionTelemetryMetrics(
                elapsedSeconds: elapsed,
                audioDurationSeconds: telemetryAudioDuration
            ),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    func currentTelemetryModelName() -> String {
        guard let modelIdentifier = currentEngineModelIdentifier(), !modelIdentifier.isEmpty else {
            return "No model"
        }
        return ModelManager.displayName(for: modelIdentifier)
    }

    func currentTelemetryComputeRoute() -> TranscriptionComputeRoute {
        switch engineModeProvider() {
        case .qwen3ASR:
            // MLX inference runs entirely on the GPU.
            return TranscriptionComputeRoute(encoderUnits: .cpuAndGPU, decoderUnits: .cpuAndGPU)
        case .whisperKit:
            return TranscriptionComputeRoute(
                encoderUnits: modelManager?.encoderComputeUnits ?? .cpuAndNeuralEngine,
                decoderUnits: modelManager?.decoderComputeUnits ?? .cpuAndNeuralEngine
            )
        }
    }

    func updateEngineStatus() {
        guard isWhisperLoaded else {
            currentEngine = .notAvailable
            return
        }
        switch engineModeProvider() {
        case .qwen3ASR:
            currentEngine = .qwen3ASR
        case .whisperKit:
            currentEngine = .whisperKit
        }
    }

    func processingAction(for note: VoiceNote, now: Date) -> ProcessingAction? {
        guard !note.audioFilePath.isEmpty else {
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
        case .completed:
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
        guard note.hasOwnershipState else {
            return false
        }

        guard note.isTranscribing else {
            return false
        }

        guard activeNoteID != note.id else {
            return false
        }

        if let ownerDeviceID = note.transcriptionOwnerDeviceID,
           ownerDeviceID != currentDeviceID,
           !leaseHasExpired(note, now: now) {
            return false
        }

        let hasTranscript = !note.transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasTranscript || note.duration <= 0 || note.audioFilePath.isEmpty {
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
        guard activeNoteID != note.id else {
            return
        }

        // Every claimed note runs through the shared file transcriber (single
        // pass ≤30 s, segmented + resumable above), which also stores word
        // timings. The queue decides *when and who* transcribes; only the
        // transcriber knows *how*.
        guard let url = await CloudStorageManager.shared.prepareFileForReading(at: note.audioFilePath) else {
            requeueNote(note, queuedAt: nowProvider())   // audio not ready — try again later
            return
        }
        let transcriber = SegmentedAudioTranscriber(transcriptionService: self,
                                                    progressStore: segmentProgressStore)
        transcriber.onTransientSinglePassFailure = { [weak self] note in
            guard let self else { return }
            self.requeueNote(note, queuedAt: self.nowProvider())
        }
        await transcriber.transcribe(note: note, sourceURL: url)
    }

    func beginLocalTranscription(for note: VoiceNote, attemptID: String) {
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
        if activeNoteID == noteID {
            activeNoteID = nil
        }
        progressByNoteID.removeValue(forKey: noteID)
        transcriptionProgress = 0.0
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

    /// One Qwen3 (MLX) transcription attempt over a whole file or slice.
    /// Mirrors the Whisper path's contract: decoded pieces carry slice-local
    /// times. Qwen3 returns plain text without word timings, so the slice
    /// becomes one coarse token spanning its real duration — timings stay
    /// honest at chunk granularity and `text == words.joined()` still holds.
    func transcribeWithQwen(
        filePath: String,
        progressCallback: @escaping (Float) -> Void
    ) async -> RawTranscription {
        guard Qwen3ASRModelStore.isModelDownloaded() else {
            print("Qwen3 model not downloaded")
            currentEngine = .notAvailable
            return .modelUnavailable
        }

        if cancelRequested || Task.isCancelled {
            return .cancelled
        }

        currentEngine = .qwen3ASR

        guard let audioURL = await CloudStorageManager.shared.prepareFileForReading(at: filePath) else {
            print("Failed to prepare audio file for transcription: \(filePath)")
            return .audioUnavailable
        }

        let updateProgressOnMain: (Float) -> Void = { [weak self] value in
            guard let self else { return }
            self.smoothProgress(to: value, progressCallback: progressCallback)
        }
        updateProgressOnMain(0.02)

        let containsProbableSpeech = await Task.detached(priority: .utility) {
            NeuralSpeechAnalyzer.safelyContainsProbableSpeech(at: audioURL)
        }.value
        guard containsProbableSpeech else {
            print("Skipping transcription because no probable speech was detected in audio file: \(filePath)")
            updateProgressOnMain(1.0)
            return .noSpeech
        }
        updateProgressOnMain(0.1)

        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .userInitiated) {
                try Qwen3AudioPCM.loadPCM16kMono(url: audioURL)
            }.value
        } catch {
            print("Failed to decode audio for Qwen3: \(error)")
            return .audioUnavailable
        }
        guard !samples.isEmpty else {
            return .noSpeech
        }
        updateProgressOnMain(0.25)

        let selectedLanguageKey = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto"
        let languageHint = Qwen3ASRDefaults.languageHint(forSelectedLanguageKey: selectedLanguageKey)
        let customPrompt = (UserDefaults.standard.string(forKey: "transcriptionPrompt") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = Qwen3ASRDefaults.decodingOptions(
            languageHint: languageHint,
            context: customPrompt.isEmpty ? nil : customPrompt
        )

        do {
#if DEBUG
            let qwenStart = Date()
#endif
            let rawText = try await Qwen3ASRModelStore.shared.transcribe(samples: samples, options: options)
            if cancelRequested || Task.isCancelled {
                return .cancelled
            }
            updateProgressOnMain(1.0)

            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // Deterministic blank decode — re-running the same window just
                // repeats it; let the caller salvage by bisection instead.
                return .whisperError("empty result", retryable: false)
            }
            let sliceDuration = Double(samples.count) / 16_000
#if DEBUG
            let qwenElapsed = Date().timeIntervalSince(qwenStart)
            print("⏱️ Qwen3 transcribe: \(String(format: "%.2f", qwenElapsed))s for \(String(format: "%.1f", sliceDuration))s audio, \(text.count) chars")
#endif
            return .text(TranscriptPiece.pieces(fromText: text, start: 0, end: sliceDuration))
        } catch let error as Qwen3ASRModelStore.StoreError {
            print("Qwen3 model unavailable: \(error)")
            currentEngine = .notAvailable
            return .modelUnavailable
        } catch {
            print("Qwen3 transcription error: \(error)")
            return .whisperError("Qwen3 error: \(error.localizedDescription)", retryable: false)
        }
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
                // Anti-repetition safety net for degenerate decoding loops
                // (e.g. "It's not? It's not? …" repeated dozens of times on
                // noisy/cluttered speech). Two parts are both required, but
                // DecodingOptions wants them in declaration order so they are
                // not adjacent here:
                //  - temperatureFallbackCount > 0 (below) lets WhisperKit
                //    re-decode a window at higher temperature when degenerate.
                //  - compressionRatioThreshold 2.0 (further below; default 2.4
                //    is too lax) makes the repetition actually trip the
                //    fallback; without lowering it most loops never reach 2.4
                //    and fallback never fires. See WhisperKit issue #294.
                temperatureFallbackCount: 3,
                sampleLength: 224,
                usePrefillPrompt: true,
                usePrefillCache: false,
                detectLanguage: isAutoLanguage,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: true,
                clipTimestamps: [0.0],
                // Lowered from the 2.4 default — see the fallback note above.
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
            let whisperStart = Date()
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

            guard !transcriptionResults.isEmpty else {
                return .whisperError("empty result", retryable: false)
            }

            // Keep WhisperKit's segment grouping: each segment becomes one piece
            // pairing its text with its word timings (slice-local times; slicing
            // callers re-base to global time). The grouping is the evidence the
            // assembler's dedup/non-speech decisions run on — flattening it here
            // would make text and words impossible to filter in lockstep.
            let pieces: [TranscriptPiece] = transcriptionResults
                .flatMap { $0.segments }
                .map { segment in
                    let words = (segment.words ?? []).map {
                        WordToken(word: $0.word, start: Double($0.start), end: Double($0.end))
                    }
                    if !words.isEmpty { return TranscriptPiece(words: words) }
                    // Wordless segment (rare with wordTimestamps on): synthesize a
                    // token from the segment text so timings still cover the span.
                    return TranscriptPiece(
                        text: Self.strippedSpecialTokens(segment.text),
                        start: Double(segment.start),
                        end: Double(segment.end))
                }
                .filter { !$0.words.isEmpty }
#if DEBUG
            let whisperElapsed = Date().timeIntervalSince(whisperStart)
            let wordCount = pieces.reduce(0) { $0 + $1.words.count }
            print("⏱️ WhisperKit transcribe: \(String(format: "%.2f", whisperElapsed))s, \(pieces.count) segments, \(wordCount) word timings")
#endif
            return .text(pieces)
        } catch {
            print("WhisperKit transcription error: \(error)")
            currentEngine = .notAvailable
            // A thrown error is often a transient ANE/Metal hiccup — worth one retry.
            return .whisperError("WhisperKit error: \(error.localizedDescription)", retryable: true)
        }
    }

    /// Removes whisper special-token markers (`<|nospeech|>`, `<|0.00|>`, …)
    /// from a segment's text before it is synthesized into a display token.
    nonisolated static func strippedSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
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
    /// Builds a finished (non-active) telemetry snapshot from a completed run's
    /// total processing time and audio duration. The segmented path's live
    /// telemetry session is finished (timer reset to inactive) when the run ends,
    /// so this persisted snapshot is what the detail view's Done card shows
    /// afterwards.
    func finishedTelemetrySnapshot(
        elapsedSeconds: TimeInterval,
        audioDurationSeconds: TimeInterval
    ) -> TranscriptionTelemetrySnapshot {
        TranscriptionTelemetrySnapshot(
            isActive: false,
            modelName: currentTelemetryModelName(),
            computeRoute: currentTelemetryComputeRoute(),
            metrics: TranscriptionTelemetryMetrics(
                elapsedSeconds: elapsedSeconds,
                audioDurationSeconds: audioDurationSeconds
            ),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// Begin a single live telemetry session for a whole-file run whose duration
    /// is already known (the segmented path computes it from the audio info), so
    /// we skip re-reading the file. The segmented run owns this one session for
    /// its whole length — its per-slice transcribe calls pass driveTelemetry:
    /// false so they don't reset it each ~29 s slice (which made the card show
    /// per-slice values instead of the whole recording). Pair with
    /// `finishTranscriptionTelemetry()`.
    func beginTranscriptionTelemetry(audioDuration: TimeInterval) {
        finishTranscriptionTelemetry()
        telemetryStartedAt = nowProvider()
        telemetryAudioDuration = audioDuration > 0 ? audioDuration : nil
        startTelemetryTimer()
    }

    /// Stop the live telemetry timer and reset to inactive. Safe to call with no
    /// active session. Internal so the segmented transcriber can end the
    /// whole-file session it began.
    func finishTranscriptionTelemetry() {
        telemetryTimerTask?.cancel()
        telemetryTimerTask = nil

        guard telemetryStartedAt != nil else {
            return
        }

        refreshTranscriptionTelemetry(isActive: false)
        telemetryStartedAt = nil
        telemetryAudioDuration = nil
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
