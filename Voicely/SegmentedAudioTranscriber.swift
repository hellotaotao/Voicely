import AVFoundation
import Foundation

/// Drives transcription of an imported, already-complete audio file.
/// Files ≤30 s run in a single pass (no sidecar); longer files are sliced into
/// ≤29 s neural-VAD segments with a resume sidecar written after each one.
/// The imported file is never stored in iCloud — a throwaway working copy is
/// used during transcription and removed on completion.
@MainActor
final class SegmentedAudioTranscriber {
    private let transcriptionService: TranscriptionService
    private let progressStore: SegmentProgressStore
    private let nowProvider: () -> Date

    /// Per-segment transcription. Defaults to the real service; tests override.
    var transcribeSegmentOutcome: (URL) async -> TranscriptionOutcome

    /// Chooses the end frame of the next segment within [start, target].
    /// Defaults to the neural-VAD cut, run off the main actor; tests inject a
    /// deterministic value.
    var nextCutFrame: (URL, Int64, Int64) async -> Int64 = { url, start, target in
        await Task.detached(priority: .utility) {
            IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                fileURL: url, startFrame: start, targetFrame: target)
        }.value
    }

    /// When true, the segment loop stops at the next boundary, leaving the
    /// sidecar intact for later resume. Wired to background-time expiration.
    var shouldStopForBackground: () -> Bool = { false }

    /// Files longer than one WhisperKit window get sliced + a resume sidecar.
    private let singlePassFrameLimit: (Double) -> Int64 = { sampleRate in
        Int64(30.0 * sampleRate)
    }

    init(transcriptionService: TranscriptionService,
         progressStore: SegmentProgressStore,
         nowProvider: @escaping () -> Date = { Date() }) {
        self.transcriptionService = transcriptionService
        self.progressStore = progressStore
        self.nowProvider = nowProvider
        self.transcribeSegmentOutcome = { url in
            await transcriptionService.transcribeAudioOutcome(filePath: url.path)
        }
    }

    func transcribe(note: VoiceNote, sourceURL: URL) async {
        // Prevent two concurrent runs over the same note (an import racing a
        // scene-activation resume, or repeated resumes corrupting the sidecar).
        guard progressStore.beginTranscribing(note.id) else { return }
        defer { progressStore.endTranscribing(note.id) }
        // Drop a stale cancellation flag left by a prior, unrelated transcription.
        transcriptionService.clearPendingCancellation()

        // A re-transcription of an existing recording starts with a transcript;
        // an import starts empty. Used to preserve the old text on total failure.
        let hadExistingTranscript = LocalTranscriptFinalizer.finalizeTranscript(note.transcription) != nil

        guard let info = Self.readAudioInfo(sourceURL) else {
            note.completeTranscription()
            if hadExistingTranscript {
                note.transcriptionOutcome = .transcribed   // keep the previous transcript
                note.markTranscriptionFailure("could not read audio for re-transcription; kept previous transcript")
            } else {
                note.transcriptionOutcome = .failed
                note.markTranscriptionFailure("could not read imported audio")
            }
            progressStore.removeWorkingCopy(for: note.id)
            return
        }

        // Claim for this device before doing any work.
        let now = nowProvider()
        note.claimTranscription(
            ownerDeviceID: transcriptionService.deviceIDProvider(),
            attemptID: UUID().uuidString,
            queuedAt: note.transcriptionQueuedAt ?? now,
            leaseExpiresAt: now.addingTimeInterval(transcriptionService.leaseDuration))
        note.clearTransientTranscriptionFlags()

        // Surface as locally transcribing so the detail view shows a
        // "Transcribing…" state and progress, like the in-process path.
        transcriptionService.beginExternalTranscription(noteID: note.id)
        defer { transcriptionService.endExternalTranscription(noteID: note.id) }

        let audioDurationSeconds = info.sampleRate > 0
            ? Double(info.totalFrames) / info.sampleRate
            : 0

        if info.totalFrames <= singlePassFrameLimit(info.sampleRate) {
            let outcome = await transcribeSegmentOutcome(sourceURL)
            finalizeSinglePass(note: note, outcome: outcome,
                               hadExistingTranscript: hadExistingTranscript,
                               audioDurationSeconds: audioDurationSeconds)
        } else {
            await transcribeSegmented(note: note, sourceURL: sourceURL, info: info,
                                      hadExistingTranscript: hadExistingTranscript)
            // Backgrounded mid-run: keep the working copy + sidecar for resume.
            if note.transcriptionState != .completed { return }
        }
        progressStore.removeWorkingCopy(for: note.id)
        progressStore.delete(for: note.id)
    }

    /// Re-drive imports that have a sidecar and a surviving working copy
    /// (e.g. after the app was suspended or killed mid-transcription).
    func resumePending(notes: [VoiceNote]) async {
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in progressStore.listPendingNoteIDs() {
            guard let note = byID[id],
                  let workingCopy = progressStore.existingWorkingCopyURL(for: id) else {
                progressStore.delete(for: id)            // orphan: note gone — clean up
                continue
            }
            await transcribe(note: note, sourceURL: workingCopy)
        }
    }

    // MARK: - Single pass (≤30 s)

    private func finalizeSinglePass(note: VoiceNote, outcome: TranscriptionOutcome,
                                    hadExistingTranscript: Bool, audioDurationSeconds: TimeInterval) {
        if case .transcribed(let result) = outcome {
            note.transcription = result.text
            note.lastTranscriptionDuration = result.duration
            note.transcriptionModelIdentifier = result.modelIdentifier
            recordTelemetry(note: note, elapsedSeconds: result.duration,
                            audioDurationSeconds: audioDurationSeconds)
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.clearTransientTranscriptionFlags()
            return
        }

        // No new text produced. If re-transcribing, keep the previous transcript.
        if hadExistingTranscript {
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.markTranscriptionFailure("re-transcription produced no usable text; kept previous transcript")
            note.clearTransientTranscriptionFlags()
            return
        }

        switch outcome {
        case .noSpeech:
            note.transcription = ""
            note.completeTranscription()
            note.transcriptionOutcome = .noSpeech
        case .whisperError(let diagnostic):
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure(diagnostic ?? "transcription error")
        default:   // modelUnavailable, audioUnavailable, cancelled
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("model or audio unavailable")
        }
        note.clearTransientTranscriptionFlags()
    }

    // MARK: - Segmented (>30 s)

    private func transcribeSegmented(note: VoiceNote, sourceURL: URL, info: AudioInfo, hadExistingTranscript: Bool) async {
        let noteID = note.id
        let batchFrames = Int64(Double(IncrementalTranscriptionTiming.defaultIntervalSeconds) * info.sampleRate)
        let resumed = progressStore.load(for: noteID)
        var start: Int64 = resumed?.lastFrame ?? 0
        var pieces: [String] = (resumed?.accumulatedText).flatMap { $0.isEmpty ? [] : [$0] } ?? []
        var failedRanges: [SegmentFailureRange] = resumed?.failedRanges ?? []
        var producedAnyText = !pieces.isEmpty
        var segmentIndex = 0
        var lastModelIdentifier: String?
        var accumulatedDuration: TimeInterval = 0

        while start < info.totalFrames {
            if shouldStopForBackground() { return }   // sidecar already persisted; resume later

            let targetFrame = min(start + batchFrames, info.totalFrames)
            let isLastBatch = targetFrame >= info.totalFrames
            var end = targetFrame
            if !isLastBatch {
                let cut = await nextCutFrame(sourceURL, start, targetFrame)
                if cut > start { end = cut }
            }

            segmentIndex += 1
            let captured = segmentIndex
            guard let segmentURL = await Task.detached(priority: .utility, operation: {
                IncrementalTranscriptionCoordinator.extractSegment(
                    fileURL: sourceURL, from: start, to: end, segmentIndex: captured)
            }).value else {
                // Couldn't read this slice (e.g. an unsupported container) — record
                // it as failed instead of silently finishing as noSpeech.
                failedRanges.append(SegmentFailureRange(startFrame: start, endFrame: end))
                pieces.append(Self.placeholder(forStart: start, end: end, sampleRate: info.sampleRate))
                start = end
                progressStore.save(.init(lastFrame: start, totalFrames: info.totalFrames,
                                         accumulatedText: pieces.joined(separator: "\n"),
                                         failedRanges: failedRanges, updatedAt: nowProvider()), for: noteID)
                continue
            }

            var outcome = await transcribeSegmentOutcome(segmentURL)
            var retries = 0
            while case .whisperError = outcome, retries < 2 {
                retries += 1
                outcome = await transcribeSegmentOutcome(segmentURL)
            }
            try? FileManager.default.removeItem(at: segmentURL)

            switch outcome {
            case .transcribed(let result):
                if let text = IncrementalTranscriptionCoordinator.sanitizedSegmentText(result.text) {
                    pieces.append(text)
                }
                producedAnyText = true
                lastModelIdentifier = result.modelIdentifier ?? lastModelIdentifier
                accumulatedDuration += result.duration
            case .noSpeech:
                break  // silence in this slice — contributes nothing, not an error
            case .whisperError, .modelUnavailable, .audioUnavailable, .cancelled:
                failedRanges.append(SegmentFailureRange(startFrame: start, endFrame: end))
                pieces.append(Self.placeholder(forStart: start, end: end, sampleRate: info.sampleRate))
            }

            start = end
            progressStore.save(.init(lastFrame: start, totalFrames: info.totalFrames,
                                     accumulatedText: pieces.joined(separator: "\n"),
                                     failedRanges: failedRanges, updatedAt: nowProvider()), for: noteID)
            // Surface text as it lands so the detail view fills in segment by
            // segment instead of staying blank until the whole file finishes.
            // Only once real text exists, so a re-transcription's previous
            // transcript is preserved until the first new segment arrives.
            if producedAnyText {
                note.transcription = pieces.joined(separator: "\n")
            }
            note.transcriptionLeaseExpiresAt = nowProvider().addingTimeInterval(transcriptionService.leaseDuration)
            transcriptionService.reportExternalProgress(Float(start) / Float(info.totalFrames), for: noteID)
        }

        // Re-transcription that produced no new text: keep the previous transcript.
        if hadExistingTranscript, !producedAnyText {
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.markTranscriptionFailure("re-transcription produced no usable text; kept previous transcript")
            note.clearTransientTranscriptionFlags()
            return
        }

        note.transcription = pieces.joined(separator: "\n")
        note.transcriptionModelIdentifier = lastModelIdentifier
        note.lastTranscriptionDuration = accumulatedDuration
        if producedAnyText {
            // Persist an overall snapshot (sum of per-segment processing time vs
            // full audio duration) so the detail view keeps showing metrics once
            // transcription finishes, like the live path does.
            let audioDuration = info.sampleRate > 0 ? Double(info.totalFrames) / info.sampleRate : 0
            recordTelemetry(note: note, elapsedSeconds: accumulatedDuration,
                            audioDurationSeconds: audioDuration)
        }
        note.completeTranscription()
        if !failedRanges.isEmpty {
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("\(failedRanges.count) segment(s) failed after retry")
        } else if !producedAnyText {
            note.transcriptionOutcome = .noSpeech
        } else {
            note.transcriptionOutcome = .transcribed
        }
        note.clearTransientTranscriptionFlags()
    }

    /// Persists an overall telemetry snapshot for a finished run. No-op when the
    /// numbers are unusable (the snapshot's own guards drop a zero ratio/speed).
    private func recordTelemetry(note: VoiceNote, elapsedSeconds: TimeInterval,
                                 audioDurationSeconds: TimeInterval) {
        guard elapsedSeconds > 0, audioDurationSeconds > 0 else { return }
        note.recordTranscriptionTelemetry(
            transcriptionService.finishedTelemetrySnapshot(
                elapsedSeconds: elapsedSeconds,
                audioDurationSeconds: audioDurationSeconds))
    }

    // MARK: - Audio info & formatting

    struct AudioInfo { let totalFrames: Int64; let sampleRate: Double }

    nonisolated static func readAudioInfo(_ url: URL) -> AudioInfo? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return AudioInfo(totalFrames: file.length,
                         sampleRate: file.processingFormat.sampleRate)
    }

    nonisolated static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    nonisolated static func placeholder(forStart start: Int64, end: Int64, sampleRate: Double) -> String {
        let from = formatTimestamp(Double(start) / sampleRate)
        let to = formatTimestamp(Double(end) / sampleRate)
        return "[\(from)–\(to) transcription unavailable]"
    }
}
