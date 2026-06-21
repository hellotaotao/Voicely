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
    @Published var transcriptionProgress: Float = 0.0
    @Published var currentEngine: TranscriptionEngine = .notAvailable
    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var progressByNoteID: [UUID: Float] = [:]
    @Published private(set) var transcriptionTelemetry: TranscriptionTelemetrySnapshot = .inactive()

    var modelManager: ModelManager?
    var transcribeImpl: TranscribeImpl = { _, _ in .whisperError(nil) }
    var deviceIDProvider: () -> String = { DeviceIdentity.currentDeviceID }
    var nowProvider: () -> Date = { Date() }
    var audioDurationProvider: (String) async -> TimeInterval? = { filePath in
        await TranscriptionService.estimatedAudioDuration(for: filePath)
    }
    var leaseDuration: TimeInterval = 5 * 60
    var heartbeatInterval: TimeInterval = 60
    var nonOriginQueueGracePeriod: TimeInterval = 5 * 60

    private static let ownershipMigrationDefaultsKey = "VoicelyOwnershipMigrationV1"

    private var currentTranscriptionTask: Task<RawTranscription?, Never>?
    private var cancelRequested = false
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

    init(modelManager: ModelManager? = nil) {
        self.modelManager = modelManager
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
        progressCallback: @escaping (Float) -> Void = { _ in }
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
        let startTime = Date()
        defer {
            isTranscribing = false
            currentTranscriptionTask = nil
            finishTranscriptionTelemetry()
            resetProgressSmoothing()
            transcriptionProgress = 0.0
        }

        guard isWhisperLoaded else {
            return .modelUnavailable
        }

        await beginTranscriptionTelemetry(filePath: filePath)

        let task = Task { [weak self] in
            await self?.transcribeImpl(filePath, progressCallback)
        }
        currentTranscriptionTask = task

        guard let raw = await task.value else {
            return .cancelled
        }

        switch raw {
        case .text(let rawText):
            if cancelRequested || Task.isCancelled {
                cancelRequested = false
                lastCancellationHandled = true
                return .cancelled
            }
            guard let finalizedTranscript = LocalTranscriptFinalizer.finalizeTranscript(rawText) else {
                // Whisper ran but produced nothing usable. Treat it as a real error
                // to surface for diagnosis — not as a calm "no speech".
                return .whisperError("blank output")
            }
            let elapsed = Date().timeIntervalSince(startTime)
            let modelIdentifier = modelManager?.currentModelIdentifier() ?? modelManager?.selectedModel
            return .transcribed(TranscriptionResult(
                text: finalizedTranscript.text,
                duration: elapsed,
                modelIdentifier: modelIdentifier
            ))
        case .noSpeech:
            return .noSpeech
        case .modelUnavailable:
            return .modelUnavailable
        case .audioUnavailable:
            return .audioUnavailable
        case .whisperError(let diagnostic):
            return .whisperError(diagnostic)
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
            endLocalTranscription(for: noteID)
        }
    }

    func wasTranscriptionCancelled() -> Bool {
        lastCancellationHandled
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

    var isWhisperLoaded: Bool {
        modelManager?.isModelLoaded() ?? false
    }

    func beginTranscriptionTelemetry(filePath: String) async {
        finishTranscriptionTelemetry()
        telemetryStartedAt = nowProvider()
        telemetryAudioDuration = await audioDurationProvider(filePath)
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

        beginLocalTranscription(for: note, attemptID: attemptID)
        startLeaseHeartbeat(for: note, attemptID: attemptID)
        let noteID = note.id
        let hadExistingTranscript = LocalTranscriptFinalizer.finalizeTranscript(note.transcription) != nil

        let onProgress: (Float) -> Void = { [weak self] value in
            Task { @MainActor in
                self?.progressByNoteID[noteID] = value
            }
        }

        var outcome = await transcribeAudioOutcome(filePath: note.audioFilePath, progressCallback: onProgress)

        // A real Whisper error is often transient — retry once before giving up.
        if case .whisperError = outcome, !wasTranscriptionCancelled() {
            outcome = await transcribeAudioOutcome(filePath: note.audioFilePath, progressCallback: onProgress)
        }

        stopLeaseHeartbeat()
        endLocalTranscription(for: noteID)

        guard note.transcriptionOwnerDeviceID == currentDeviceID,
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
            note.transcription = result.text
            note.lastTranscriptionDuration = result.duration
            note.transcriptionModelIdentifier = result.modelIdentifier
            note.recordTranscriptionTelemetry(transcriptionTelemetry)
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.clearTransientTranscriptionFlags()

        case .noSpeech:
            // The whole clip had no speech — finish calmly. This is not an error.
            if !hadExistingTranscript {
                note.transcription = ""
                note.lastTranscriptionDuration = 0
                note.transcriptionModelIdentifier = nil
                note.clearTranscriptionTelemetrySummary()
            }
            note.completeTranscription()
            note.transcriptionOutcome = hadExistingTranscript ? .transcribed : .noSpeech
            note.clearTransientTranscriptionFlags()

        case .modelUnavailable, .audioUnavailable, .cancelled:
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
            note.transcriptionOutcome = hadExistingTranscript ? .transcribed : .failed
            note.markTranscriptionFailure(diagnostic ?? "transcription error")
            note.clearTransientTranscriptionFlags()
        }
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
                temperatureFallbackCount: 0,
                sampleLength: 224,
                usePrefillPrompt: true,
                usePrefillCache: false,
                detectLanguage: isAutoLanguage,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: false,
                clipTimestamps: [0.0],
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

            return .text(result.text)
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
