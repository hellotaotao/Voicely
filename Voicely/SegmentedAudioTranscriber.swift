import AVFoundation
import Foundation

/// Monotonic source of unique segment indices (temp-file names) within one run.
/// A reference type so it can be shared across the recursive bisection helpers.
private final class SegmentIndexCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

/// One outcome of salvaging a failed range: either recovered pieces or a sub-range
/// that still couldn't be transcribed (kept as a placeholder).
private enum SalvagedPiece {
    /// `pieces` are slice-local (0-based within the salvaged sub-range); `startFrame`
    /// is that sub-range's offset in the recording so the caller can re-base them to
    /// global time.
    case text([TranscriptPiece], startFrame: Int64,
              duration: TimeInterval, modelIdentifier: String?)
    case failure(SegmentFailureRange)
}

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
    /// Defaults to the neural-VAD cut, run off the main actor, with cut bounds
    /// sized for the active engine; tests inject a deterministic value.
    var nextCutFrame: (URL, Int64, Int64) async -> Int64 = { url, start, target in
        let mode = TranscriptionEngineMode.currentResolved()
        return await Task.detached(priority: .utility) {
            switch mode {
            case .qwen3ASR:
                var configuration = IncrementalVoiceActivityCutConfiguration.default
                configuration.minimumCutSeconds = Qwen3ASRDefaults.minimumChunkCutSeconds
                return IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                    fileURL: url, startFrame: start, targetFrame: target,
                    targetSegmentSeconds: Qwen3ASRDefaults.chunkSeconds,
                    configuration: configuration)
            case .whisperKit:
                return IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                    fileURL: url, startFrame: start, targetFrame: target)
            }
        }.value
    }

    /// When true, the segment loop stops at the next boundary, leaving the
    /// sidecar intact for later resume. Wired to background-time expiration.
    var shouldStopForBackground: () -> Bool = { false }

    /// Queue-claimed notes hand transient single-pass failures (model or audio
    /// unavailable, cancellation) back to the queue instead of finishing as
    /// failed — the queue retries them automatically once the condition clears.
    /// Imports have no queue identity, so nil keeps the finish-as-failed default.
    var onTransientSinglePassFailure: ((VoiceNote) -> Void)?

    /// Minimum length (seconds) of a failed range still worth bisecting. A real
    /// transcription error is often local, so a failed segment is split in half
    /// and each side retried; below this length salvage costs more than the audio
    /// it could recover, so the range is kept as a placeholder. Tests override it
    /// to control how deep bisection goes.
    var minSalvageSeconds: Double = 8.0

    /// Files longer than one engine window get sliced + a resume sidecar
    /// (Whisper: 30 s; Qwen3: 15 s, its fast-path decoding bound).
    private let singlePassFrameLimit: (Double) -> Int64 = { sampleRate in
        switch TranscriptionEngineMode.currentResolved() {
        case .qwen3ASR: return Int64(Qwen3ASRDefaults.singlePassSecondsLimit * sampleRate)
        case .whisperKit: return Int64(30.0 * sampleRate)
        }
    }

    init(transcriptionService: TranscriptionService,
         progressStore: SegmentProgressStore,
         nowProvider: @escaping () -> Date = { Date() }) {
        self.transcriptionService = transcriptionService
        self.progressStore = progressStore
        self.nowProvider = nowProvider
        self.transcribeSegmentOutcome = { url in
            // The whole run drives one telemetry session (see transcribe); a
            // per-slice call must not reset it, so it transcribes silently.
            await transcriptionService.transcribeAudioOutcome(filePath: url.path,
                                                              driveTelemetry: false)
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

        // Claim for this device before doing any work. The attempt ID is checked
        // again before results are applied: another device can re-claim the note
        // while we transcribe, and a stale attempt must not overwrite its work.
        let now = nowProvider()
        let attemptID = UUID().uuidString
        note.claimTranscription(
            ownerDeviceID: transcriptionService.deviceIDProvider(),
            attemptID: attemptID,
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

        // Drive one whole-file telemetry session for the entire run so the detail
        // view shows a real, growing whole-recording time-ratio/speed. Per-slice
        // transcribe calls pass driveTelemetry:false (see init) so they don't
        // reset it each ~29 s slice (which would show only per-slice values).
        transcriptionService.beginTranscriptionTelemetry(audioDuration: audioDurationSeconds)
        defer { transcriptionService.finishTranscriptionTelemetry() }

        if info.totalFrames <= singlePassFrameLimit(info.sampleRate) {
            var outcome = await transcribeSegmentOutcome(sourceURL)
            // A real Whisper error is often transient — retry once before giving up.
            if case .whisperError(_, true) = outcome, !transcriptionService.wasTranscriptionCancelled() {
                outcome = await transcribeSegmentOutcome(sourceURL)
            }
            finalizeSinglePass(note: note, outcome: outcome,
                               hadExistingTranscript: hadExistingTranscript,
                               audioDurationSeconds: audioDurationSeconds,
                               attemptID: attemptID)
        } else {
            await transcribeSegmented(note: note, sourceURL: sourceURL, info: info,
                                      hadExistingTranscript: hadExistingTranscript,
                                      attemptID: attemptID)
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
                                    hadExistingTranscript: Bool, audioDurationSeconds: TimeInterval,
                                    attemptID: String) {
        // Another device may have re-claimed the note while we transcribed (every
        // claim rewrites the attempt ID). A stale attempt must not overwrite the
        // current owner's work — abandon silently.
        guard note.transcriptionAttemptID == attemptID,
              note.transcriptionState == .claimed else {
            return
        }

        if case .transcribed(let result) = outcome {
            // Single pass transcribes the whole file, so word times are already
            // global (relative to the recording start) — store them as-is.
            note.setTranscript(text: result.text, words: result.words)
#if DEBUG
            if let first = result.words.first, let last = result.words.last {
                print("📍 stored \(result.words.count) word timings (single pass), span \(String(format: "%.2f", first.start))–\(String(format: "%.2f", last.end))s")
            }
#endif
            note.lastTranscriptionDuration = result.duration
            note.transcriptionModelIdentifier = result.modelIdentifier
            recordTelemetry(note: note, elapsedSeconds: result.duration,
                            audioDurationSeconds: audioDurationSeconds)
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.clearTransientTranscriptionFlags()
            return
        }

        // Transient conditions first: nothing is wrong with the audio — the model
        // isn't loaded yet, the file isn't downloaded, or the run was cancelled.
        // A queue-claimed note goes back to the queue to run again later.
        switch outcome {
        case .modelUnavailable, .audioUnavailable, .cancelled:
            if let onTransientSinglePassFailure {
                onTransientSinglePassFailure(note)
                return
            }
        default:
            break
        }

        // No new text produced. If re-transcribing, keep the previous transcript.
        if hadExistingTranscript {
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.markTranscriptionFailure("re-transcription produced no usable text; kept previous transcript")
            note.clearTransientTranscriptionFlags()
            return
        }

        // A fresh attempt that produced nothing must not keep metadata from a
        // previous run (duration, model badge, telemetry summary) — nor its
        // word timeline, which would otherwise keep rendering the stale text.
        note.setTranscript(text: "", words: [])
        note.lastTranscriptionDuration = 0
        note.transcriptionModelIdentifier = nil
        note.clearTranscriptionTelemetrySummary()

        switch outcome {
        case .noSpeech:
            note.completeTranscription()
            note.transcriptionOutcome = .noSpeech
        case .whisperError(let diagnostic, _):
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

    private func transcribeSegmented(note: VoiceNote, sourceURL: URL, info: AudioInfo,
                                     hadExistingTranscript: Bool, attemptID: String) async {
        let noteID = note.id
        let batchSeconds: Double = switch TranscriptionEngineMode.currentResolved() {
        case .qwen3ASR: Qwen3ASRDefaults.chunkSeconds
        case .whisperKit: Double(IncrementalTranscriptionTiming.defaultIntervalSeconds)
        }
        let batchFrames = Int64(batchSeconds * info.sampleRate)
        let resumed = progressStore.load(for: noteID)
        var start: Int64 = resumed?.lastFrame ?? 0
        var failedRanges: [SegmentFailureRange] = resumed?.failedRanges ?? []
        let segmentIndex = SegmentIndexCounter()
        var lastModelIdentifier: String?
        var accumulatedDuration: TimeInterval = 0
        // Pieces accumulate across slices, each re-based to global time; the
        // assembled (text, words) pair is persisted in the sidecar so a resumed
        // run reopens as one opening piece. A legacy sidecar (resumed past frame
        // 0 with no saved words) can't complete a word timeline.
        var accumulated: [TranscriptPiece] = []
        let wordTimelineComplete = (resumed?.lastFrame ?? 0) == 0
            || resumed?.accumulatedWords != nil
        if let savedWords = resumed?.accumulatedWords, !savedWords.isEmpty {
            accumulated = [TranscriptPiece(words: savedWords)]
        } else if let savedText = resumed?.accumulatedText, !savedText.isEmpty {
            accumulated = TranscriptPiece.pieces(fromText: savedText, start: 0,
                                                 end: Double(start) / info.sampleRate)
        }
        var producedAnyText = !accumulated.isEmpty
        // Reassembles the accumulated pieces; nil when nothing usable yet.
        // The all-non-speech fallback stays out of segmented results (matching
        // the previous per-slice gate): a pure-noise file finishes as noSpeech.
        func assembleUsable() -> AssembledTranscript? {
            guard let assembled = TranscriptAssembler.assemble(accumulated),
                  !assembled.isNonSpeechFallback else { return nil }
            return assembled
        }
        func saveSidecar() {
            let assembled = assembleUsable()
            progressStore.save(.init(lastFrame: start, totalFrames: info.totalFrames,
                                     accumulatedText: assembled?.text ?? "",
                                     failedRanges: failedRanges, updatedAt: nowProvider(),
                                     accumulatedWords: assembled?.words ?? []), for: noteID)
        }

        while start < info.totalFrames {
            if shouldStopForBackground() { return }   // sidecar already persisted; resume later

            let targetFrame = min(start + batchFrames, info.totalFrames)
            let isLastBatch = targetFrame >= info.totalFrames
            var end = targetFrame
            if !isLastBatch {
                let cut = await nextCutFrame(sourceURL, start, targetFrame)
                if cut > start { end = cut }
            }

            guard let outcome = await transcribeSliceOutcome(
                sourceURL: sourceURL, start: start, end: end, index: segmentIndex.next()) else {
                // Couldn't read this slice (e.g. an unsupported container) — record
                // it as failed instead of silently finishing as noSpeech. A slice we
                // can't even read won't be fixed by splitting, so don't bisect here.
                failedRanges.append(SegmentFailureRange(startFrame: start, endFrame: end))
                accumulated.append(Self.placeholderPiece(forStart: start, end: end,
                                                         sampleRate: info.sampleRate))
                start = end
                saveSidecar()
                continue
            }

            switch outcome {
            case .transcribed(let result):
                // The slice's pieces join the pool only when the slice carries
                // real speech — text and words enter (or stay out) together.
                let slicePieces = result.effectivePieces
                if TranscriptAssembler.assemble(slicePieces)?.isNonSpeechFallback == false {
                    let offset = Double(start) / info.sampleRate
                    accumulated.append(contentsOf: slicePieces.map { $0.rebased(by: offset) })
                    producedAnyText = true
                    lastModelIdentifier = result.modelIdentifier ?? lastModelIdentifier
                    accumulatedDuration += result.duration
                }
            case .noSpeech:
                break  // silence in this slice — contributes nothing, not an error
            case .whisperError, .modelUnavailable, .audioUnavailable, .cancelled:
                // The segment failed as a whole. A real error is often local, so
                // split it and salvage the parts that do transcribe; only the
                // still-failing sub-range is kept as a (smaller) placeholder.
                let salvaged = Self.coalesceFailures(await salvageFailedRange(
                    sourceURL: sourceURL, start: start, end: end,
                    minFrames: Int64(minSalvageSeconds * info.sampleRate),
                    indexCounter: segmentIndex))
                for piece in salvaged {
                    switch piece {
                    case .text(let slicePieces, let pieceStart, let duration, let model):
                        // Re-base the salvaged sub-range's slice-local times to
                        // global time so the tappable transcript stays in sync.
                        let offset = Double(pieceStart) / info.sampleRate
                        accumulated.append(contentsOf: slicePieces.map { $0.rebased(by: offset) })
                        producedAnyText = true
                        lastModelIdentifier = model ?? lastModelIdentifier
                        accumulatedDuration += duration
                    case .failure(let range):
                        failedRanges.append(range)
                        accumulated.append(Self.placeholderPiece(forStart: range.startFrame,
                                                                 end: range.endFrame,
                                                                 sampleRate: info.sampleRate))
                    }
                }
            }

            start = end
            saveSidecar()
            // Surface text as it lands so the detail view fills in segment by
            // segment instead of staying blank until the whole file finishes.
            // Only once real text exists, so a re-transcription's previous
            // transcript is preserved until the first new segment arrives.
            let stillOwnsNote = note.transcriptionAttemptID == attemptID
                && note.transcriptionState == .claimed
            if stillOwnsNote, producedAnyText, let assembled = assembleUsable() {
                note.setTranscript(text: assembled.text,
                                   words: wordTimelineComplete ? assembled.words : [])
            }
            if stillOwnsNote {
                note.transcriptionLeaseExpiresAt = nowProvider().addingTimeInterval(transcriptionService.leaseDuration)
            }
            transcriptionService.reportExternalProgress(Float(start) / Float(info.totalFrames), for: noteID)
        }

        let assembled = assembleUsable()
#if DEBUG
        print("🏁 segmented done: producedAnyText=\(producedAnyText) pieces=\(accumulated.count) failedRanges=\(failedRanges.count) words=\(assembled?.words.count ?? 0) lastModel=\(lastModelIdentifier ?? "nil") hadExisting=\(hadExistingTranscript) keptPrevious=\(hadExistingTranscript && !producedAnyText)")
#endif
        // Another device re-claimed the note mid-run — abandon our result.
        guard note.transcriptionAttemptID == attemptID,
              note.transcriptionState == .claimed else {
            return
        }
        // Re-transcription that produced no new text: keep the previous transcript.
        if hadExistingTranscript, !producedAnyText {
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.markTranscriptionFailure("re-transcription produced no usable text; kept previous transcript")
            note.clearTransientTranscriptionFlags()
            return
        }

        // Store the assembled transcript with its aligned global-time word
        // timeline. A legacy sidecar resumed without saved words can't complete
        // the timeline, so clear timings there and let the detail view fall back
        // to the freshly written text instead of re-rendering the previous run's
        // (now stale) timings.
        note.setTranscript(text: assembled?.text ?? "",
                           words: wordTimelineComplete ? (assembled?.words ?? []) : [])
#if DEBUG
        if let first = assembled?.words.first, let last = assembled?.words.last {
            print("📍 stored \(assembled?.words.count ?? 0) word timings (segmented), span \(String(format: "%.2f", first.start))–\(String(format: "%.2f", last.end))s, complete=\(wordTimelineComplete)")
        }
#endif
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
            // Some text plus a gap is a partial success, not a failure — don't nag
            // the user to retry the whole thing. Only a run that produced nothing
            // usable is a real failure.
            note.transcriptionOutcome = producedAnyText ? .partial : .failed
            note.markTranscriptionFailure("\(failedRanges.count) segment(s) failed after retry")
        } else if !producedAnyText {
            note.transcriptionOutcome = .noSpeech
        } else {
            note.transcriptionOutcome = .transcribed
        }
        note.clearTransientTranscriptionFlags()
    }

    // MARK: - Bisection salvage

    /// Extract [start, end] to a temp file and transcribe it, retrying up to twice
    /// on a transient whisper error. Returns nil only when the slice can't even be
    /// read; the temp file is always removed before returning.
    private func transcribeSliceOutcome(sourceURL: URL, start: Int64, end: Int64,
                                        index: Int) async -> TranscriptionOutcome? {
        guard let segmentURL = await Task.detached(priority: .utility, operation: {
            IncrementalTranscriptionCoordinator.extractSegment(
                fileURL: sourceURL, from: start, to: end, segmentIndex: index)
        }).value else { return nil }

        var outcome = await transcribeSegmentOutcome(segmentURL)
        var retries = 0
        // Only a transient (thrown) error is worth re-running the identical window;
        // a deterministic blank/empty decode is left for bisection to salvage.
        while case .whisperError(_, true) = outcome, retries < 2 {
            retries += 1
            outcome = await transcribeSegmentOutcome(segmentURL)
        }
        try? FileManager.default.removeItem(at: segmentURL)
        return outcome
    }

    /// `[start, end]` already failed to transcribe as a whole. Recover what we can
    /// by splitting it at the frame midpoint and transcribing each half. If only
    /// one half fails, recurse into it — the error is local and the good part is
    /// worth keeping. If both halves fail, the error isn't local, so stop splitting
    /// and keep a single placeholder for the whole range. Ranges shorter than
    /// `minFrames` aren't split further (salvage would cost more than it saves).
    private func salvageFailedRange(sourceURL: URL, start: Int64, end: Int64,
                                    minFrames: Int64,
                                    indexCounter: SegmentIndexCounter) async -> [SalvagedPiece] {
        guard end - start > minFrames else {
            return [.failure(SegmentFailureRange(startFrame: start, endFrame: end))]
        }
        let mid = start + (end - start) / 2
        let left = await transcribeSliceOutcome(sourceURL: sourceURL, start: start, end: mid,
                                                index: indexCounter.next())
        let right = await transcribeSliceOutcome(sourceURL: sourceURL, start: mid, end: end,
                                                 index: indexCounter.next())

        // Both halves failed ⇒ the error spans the whole range; splitting further
        // just fragments one gap into several. Keep a single placeholder.
        if Self.isFailure(left) && Self.isFailure(right) {
            return [.failure(SegmentFailureRange(startFrame: start, endFrame: end))]
        }

        return await resolveHalf(left, sourceURL: sourceURL, start: start, end: mid,
                                 minFrames: minFrames, indexCounter: indexCounter)
             + (await resolveHalf(right, sourceURL: sourceURL, start: mid, end: end,
                                  minFrames: minFrames, indexCounter: indexCounter))
    }

    /// Turn one bisected half's outcome into pieces: text on success, nothing on
    /// silence, and a deeper bisection on a (now-localized) failure.
    private func resolveHalf(_ outcome: TranscriptionOutcome?, sourceURL: URL,
                             start: Int64, end: Int64, minFrames: Int64,
                             indexCounter: SegmentIndexCounter) async -> [SalvagedPiece] {
        switch outcome {
        case .transcribed(let result):
            let slicePieces = result.effectivePieces
            if TranscriptAssembler.assemble(slicePieces)?.isNonSpeechFallback == false {
                return [.text(slicePieces, startFrame: start,
                              duration: result.duration, modelIdentifier: result.modelIdentifier)]
            }
            return []
        case .noSpeech:
            return []
        default:   // whisperError / modelUnavailable / audioUnavailable / cancelled / nil
            return await salvageFailedRange(sourceURL: sourceURL, start: start, end: end,
                                            minFrames: minFrames, indexCounter: indexCounter)
        }
    }

    /// A half counts as failed when it produced neither text nor a clean noSpeech
    /// (nil = the slice couldn't be read).
    private static func isFailure(_ outcome: TranscriptionOutcome?) -> Bool {
        switch outcome {
        case .some(.transcribed), .some(.noSpeech): return false
        default: return true
        }
    }

    /// Merge runs of adjacent failure placeholders into one so a wholly-failed
    /// region reads as a single gap rather than several touching ones.
    private static func coalesceFailures(_ pieces: [SalvagedPiece]) -> [SalvagedPiece] {
        var out: [SalvagedPiece] = []
        for piece in pieces {
            if case .failure(let range) = piece,
               case .failure(let previous)? = out.last,
               previous.endFrame == range.startFrame {
                out[out.count - 1] = .failure(
                    SegmentFailureRange(startFrame: previous.startFrame, endFrame: range.endFrame))
            } else {
                out.append(piece)
            }
        }
        return out
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

    /// A failed range as a transcript piece: the placeholder text becomes a
    /// single token spanning the gap, so it renders (and taps) like any word.
    nonisolated static func placeholderPiece(forStart start: Int64, end: Int64,
                                             sampleRate: Double) -> TranscriptPiece {
        TranscriptPiece(text: placeholder(forStart: start, end: end, sampleRate: sampleRate),
                        start: Double(start) / sampleRate,
                        end: Double(end) / sampleRate)
    }
}
