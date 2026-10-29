import AVFoundation
import Foundation

/// Drives transcription of an imported, already-complete audio file.
/// Files within the engine's single-pass limit run in one pass (no sidecar);
/// longer files are sliced at neural-VAD cuts (`Qwen3SliceLimits`) with a
/// resume sidecar written after each slice.
/// The imported file is never stored in iCloud — a throwaway working copy is
/// used during transcription and removed on completion.
@MainActor
final class SegmentedAudioTranscriber {
    private let transcriptionService: TranscriptionService
    private let progressStore: SegmentProgressStore
    private var telemetrySession: TranscriptionTelemetrySession?
    private let nowProvider: () -> Date

    /// Per-segment transcription. Defaults to the real service; tests override.
    var transcribeSegmentOutcome: (URL) async -> TranscriptionOutcome = { _ in .cancelled }

    /// Builds one shared snapshot for a segment checkpoint and its UI preview.
    var joinTranscriptPieces: ([String]) -> String = { $0.joined(separator: "\n") }

    /// Chooses the end frame of the next segment within [start, target].
    /// Defaults to the neural-VAD cut, run off the main actor; tests inject a
    /// deterministic value.
    var nextCutFrame: (URL, Int64, Int64) async -> Int64 = { url, start, target in
        await Task.detached(priority: .utility) {
            IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(
                fileURL: url, startFrame: start, targetFrame: target)
        }.value
    }

    /// Cuts the last stretch of the file, whose regular cut would leave a short
    /// tail, into two slices of similar length. Tests inject a value.
    var nextRebalancedCutFrame: (URL, Int64, Int64) async -> Int64 = { url, start, end in
        await Task.detached(priority: .utility) {
            IncrementalTranscriptionCoordinator.rebalancedCutFrame(
                fileURL: url, startFrame: start, endFrame: end)
        }.value
    }

    /// Keeps a listening copy of an imported file and returns its path. Runs once
    /// the transcript is in; tests replace it.
    var storeImportedAudio: (URL) async throws -> String = { source in
        try await ImportedAudioListeningCopy.store(from: source)
    }

    /// Transcribes one stretch of the file with Parakeet. Tests replace it.
    var transcribeEnglish: EnglishStretchRouting.Transcriber = { url, start, end in
        try await ParakeetEnglishEngine.shared.transcribe(fileURL: url, startFrame: start, endFrame: end)
    }

    /// Frees Parakeet once a run is done with it. Tests replace it.
    var releaseEnglishEngine: () async -> Void = {
        await ParakeetEnglishEngine.shared.unload()
    }

    /// When true, the segment loop stops at the next boundary, leaving the
    /// sidecar intact for later resume. Wired to background-time expiration.
    var shouldStopForBackground: () -> Bool = { false }

    /// The segment being decoded, so the decoder's progress through it can be
    /// reported as progress through the whole file. iOS expires a continued
    /// processing task that reports nothing for ~30 s.
    private var activeSegment: (noteID: UUID, start: Int64, end: Int64, total: Int64)?
    private var reportedProgress: Float = 0
    /// The claim this run made; another device taking the note over replaces it.
    private var attemptID: String?

    /// Files longer than one engine pass get sliced + a resume sidecar.
    private let singlePassFrameLimit: (Double) -> Int64 = { sampleRate in
        Int64(Qwen3ASRDefaults.singlePassSecondsLimit * sampleRate)
    }

    init(transcriptionService: TranscriptionService,
         progressStore: SegmentProgressStore,
         nowProvider: @escaping () -> Date = { Date() }) {
        self.transcriptionService = transcriptionService
        self.progressStore = progressStore
        self.nowProvider = nowProvider
        self.transcribeEnglish = { [counter = transcriptionService.decodeWorkCounter] url, start, end in
            // Each step counts as decode work for the background task.
            try await ParakeetEnglishEngine.shared.transcribe(fileURL: url, startFrame: start, endFrame: end) { _ in
                counter.withLock { $0 &+= 1 }
            }
        }
        self.transcribeSegmentOutcome = { [weak self] url in
            await transcriptionService.transcribeAudioOutcome(
                filePath: url.path,
                progressCallback: { fraction in self?.reportSegmentProgress(fraction) },
                telemetrySession: self?.telemetrySession)
        }
    }

    func transcribe(note: VoiceNote, sourceURL: URL, telemetrySession suppliedSession: TranscriptionTelemetrySession? = nil) async {
        guard !transcriptionService.isLocalRecording(noteID: note.id),
              !transcriptionService.isDiscarded(noteID: note.id),
              !transcriptionService.isUserPaused(note),
              !transcriptionService.isPausedForBackground(noteID: note.id) else { return }
        // Prevent two concurrent runs over the same note (an import racing a
        // scene-activation resume, or repeated resumes corrupting the sidecar).
        guard progressStore.beginTranscribing(note.id) else { return }
        defer { progressStore.endTranscribing(note.id) }
        while transcriptionService.activeNoteID != nil || transcriptionService.isTranscribing {
            if Task.isCancelled || transcriptionService.isPausedForBackground(noteID: note.id) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if Task.isCancelled || transcriptionService.isDiscarded(noteID: note.id)
            || transcriptionService.isUserPaused(note) || transcriptionService.isPausedForBackground(noteID: note.id) { return }
        // Taken over on another device while this one waited: that device does it now.
        if transcriptionService.isTranscribingOnAnotherDevice(note) {
            transcriptionService.forgetSavedTranscription(note)
            return
        }
        // Drop a stale cancellation flag left by a prior, unrelated transcription.
        transcriptionService.clearPendingCancellation()

        let session = suppliedSession ?? transcriptionService.beginTelemetrySession(noteID: note.id)
        telemetrySession = session
        defer {
            if suppliedSession == nil { transcriptionService.endTelemetrySession(session) }
            telemetrySession = nil
        }

        // A re-transcription of an existing recording starts with a transcript;
        // an import starts empty. Used to preserve the old text on total failure.
        let hadExistingTranscript = LocalTranscriptFinalizer.finalizeTranscript(note.transcription) != nil

        guard let info = Self.readAudioInfo(sourceURL) else {
            note.completeTranscription()
            if hadExistingTranscript {
                note.transcriptionOutcome = .failed   // Preserve text, not a success claim.
                note.markTranscriptionFailure("could not read audio for re-transcription; kept previous transcript")
            } else {
                note.transcriptionOutcome = .failed
                note.markTranscriptionFailure("could not read imported audio")
            }
            return
        }

        let duration = Double(info.totalFrames) / info.sampleRate
        if duration.isFinite, duration > 0 { note.duration = duration }
        transcriptionService.setTelemetryAudioDuration(duration, session: session)

        // Claim for this device before doing any work. An import is this device's
        // from the start; say so before the note syncs without a state.
        let now = nowProvider()
        let deviceID = transcriptionService.deviceIDProvider()
        if note.transcriptionOriginDeviceID == nil { note.transcriptionOriginDeviceID = deviceID }
        let attemptID = UUID().uuidString
        self.attemptID = attemptID
        note.claimTranscription(
            ownerDeviceID: deviceID,
            attemptID: attemptID,
            queuedAt: note.transcriptionQueuedAt ?? now,
            leaseExpiresAt: now.addingTimeInterval(transcriptionService.leaseDuration))
        note.clearTransientTranscriptionFlags()

        // Surface as locally transcribing so the detail view shows a
        // "Transcribing…" state and progress, like the in-process path.
        transcriptionService.beginExternalTranscription(noteID: note.id)
        defer { transcriptionService.endExternalTranscription(noteID: note.id) }

        if info.totalFrames <= singlePassFrameLimit(info.sampleRate) {
            let outcome = await transcribeSegmentOutcome(sourceURL)
            if transcriptionService.isDiscarded(noteID: note.id) { return }
            guard ownsRun(note) else { return }
            if transcriptionService.isRunCancelled(noteID: note.id) || transcriptionService.isUserPaused(note) || Task.isCancelled {
                pause(note)
                return
            }
            switch outcome {
            case .transcribed, .noSpeech:
                transcriptionService.recordProcessedAudio(start: 0, end: duration, session: session)
            default: break
            }
            if let routed = await transcribeEnglishStretches(
                in: [LanguageTaggedSlice(start: 0, end: duration, text: nil, language: nil)],
                of: note, sourceURL: sourceURL, sampleRate: info.sampleRate) {
                // Only an English choice sends a single pass to Parakeet.
                switch outcome {
                case .transcribed(let result) where routed.slices[0].text != nil:
                    let english = EnglishStretchRouting.transcript(of: routed.slices)
                    note.setTranscript(english.text, spans: english.spans,
                                       alternate: AlternateTranscript(engine: .qwen3, text: result.text,
                                                                      spans: TranscriptTimeline.singleSpan(for: result.text, duration: duration)))
                    note.lastTranscriptionDuration = result.duration
                    note.transcriptionModelIdentifier = result.modelIdentifier
                    persistTelemetry(on: note)
                    note.completeTranscription()
                    note.transcriptionOutcome = .transcribed
                    note.clearTransientTranscriptionFlags()
                case .noSpeech where routed.slices[0].text != nil:
                    let english = EnglishStretchRouting.transcript(of: routed.slices)
                    finalizeSinglePass(note: note, outcome: .transcribed(TranscriptionResult(
                        text: english.text, duration: 0, modelIdentifier: nil)),
                        duration: duration, hadExistingTranscript: hadExistingTranscript)
                default:
                    finalizeSinglePass(note: note, outcome: outcome, duration: duration, hadExistingTranscript: hadExistingTranscript)
                }
            } else {
                finalizeSinglePass(note: note, outcome: outcome, duration: duration, hadExistingTranscript: hadExistingTranscript)
            }
            if note.transcriptionState != .completed { return }
        } else {
            await transcribeSegmented(note: note, sourceURL: sourceURL, info: info,
                                      hadExistingTranscript: hadExistingTranscript)
            // Backgrounded mid-run: keep the working copy + sidecar for resume.
            if note.transcriptionState != .completed { return }
        }
        // Failed imports keep their only local audio for an explicit retry.
        if note.transcriptionOutcome == .failed {
            do {
                try progressStore.archiveProgressIfNeeded(for: note.id)
            } catch {
                // Keep the checkpoint so a later retry can archive it safely.
                note.markTranscriptionFailure("Could not save this attempt separately; its recovery checkpoint has been kept. \(error.localizedDescription)")
            }
            return
        }
        // An import has no audio of its own until now. If its listening copy
        // cannot be stored, the working copy stays for `storePendingImportedAudio`.
        if note.audioFilePath.isEmpty, !(await keepImportedAudio(for: note, from: sourceURL)) {
            progressStore.delete(for: note.id)
            return
        }
        progressStore.removeWorkingCopy(for: note.id)
        progressStore.delete(for: note.id)
    }

    /// Stores listening copies that finished imports still lack because writing
    /// one failed or the app quit first. Their transcripts are complete; only
    /// the working copy is used, nothing is transcribed again.
    func storePendingImportedAudio(notes: [VoiceNote]) async {
        for note in notes where note.audioFilePath.isEmpty && note.transcriptionState == .completed
            && note.transcriptionOutcome != .failed {
            guard let workingCopy = progressStore.existingWorkingCopyURL(for: note.id),
                  progressStore.beginTranscribing(note.id) else { continue }
            if await keepImportedAudio(for: note, from: workingCopy) {
                progressStore.removeWorkingCopy(for: note.id)
                progressStore.delete(for: note.id)
            }
            progressStore.endTranscribing(note.id)
        }
    }

    /// True once nothing more is owed: the copy is attached, or the note was
    /// deleted meanwhile and the copy removed.
    private func keepImportedAudio(for note: VoiceNote, from sourceURL: URL) async -> Bool {
        let path: String
        do {
            path = try await storeImportedAudio(sourceURL)
        } catch {
            debugLog("⚠️ [SegmentedAudioTranscriber] Could not keep imported audio: \(error)")
            return false
        }
        guard !transcriptionService.isDiscarded(noteID: note.id) else {
            _ = CloudStorageManager.shared.deleteFile(at: path)
            return true
        }
        note.audioFilePath = path
        try? note.modelContext?.save()
        return true
    }

    /// Re-drive imports that have a sidecar and a surviving working copy
    /// (e.g. after the app was suspended or killed mid-transcription).
    func resumePending(notes: [VoiceNote]) async {
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in progressStore.listPendingNoteIDs() {
            guard let note = byID[id] else {
                progressStore.delete(for: id)
                progressStore.removeWorkingCopy(for: id)
                continue
            }
            // A recording has a checkpoint but no import working copy.
            guard note.transcriptionState != .completed,
                  !transcriptionService.isUserPaused(note),
                  !transcriptionService.ownsSavedTranscription(noteID: id),
                  let workingCopy = progressStore.existingWorkingCopyURL(for: id) else { continue }
            if Task.isCancelled { return }
            await transcribe(note: note, sourceURL: workingCopy)
        }
    }

    // MARK: - Single pass

    private func finalizeSinglePass(note: VoiceNote, outcome: TranscriptionOutcome, duration: TimeInterval, hadExistingTranscript: Bool) {
        switch outcome {
        case .modelUnavailable, .audioUnavailable, .cancelled:
            pause(note)
            return
        default: break
        }
        if case .transcribed(let result) = outcome {
            note.setTranscript(result.text, spans: TranscriptTimeline.singleSpan(for: result.text, duration: duration))
            note.lastTranscriptionDuration = result.duration
            note.transcriptionModelIdentifier = result.modelIdentifier
            persistTelemetry(on: note)
            note.completeTranscription()
            note.transcriptionOutcome = .transcribed
            note.clearTransientTranscriptionFlags()
            return
        }

        // No new text produced. If re-transcribing, keep the previous transcript.
        if hadExistingTranscript {
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("re-transcription did not complete successfully; kept previous transcript")
            note.clearTransientTranscriptionFlags()
            return
        }

        switch outcome {
        case .noSpeech:
            note.setTranscript("", spans: nil)
            note.completeTranscription()
            note.transcriptionOutcome = .noSpeech
        case .engineError(let diagnostic):
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

    // MARK: - Segmented

    private func transcribeSegmented(note: VoiceNote, sourceURL: URL, info: AudioInfo, hadExistingTranscript: Bool) async {
        guard let session = telemetrySession else { return }
        let noteID = note.id
        let batchFrames = Int64(Double(IncrementalTranscriptionTiming.defaultIntervalSeconds) * info.sampleRate)
        let resumed = progressStore.load(for: noteID)
        var start: Int64 = resumed?.lastFrame ?? 0
        var accumulatedText = resumed?.accumulatedText ?? ""
        var pieces: [String] = accumulatedText.isEmpty ? [] : [accumulatedText]
        var spans = TranscriptSpanBuilder(resumedText: accumulatedText, resumedSpans: resumed?.spans)
        // Unknown when resuming a checkpoint written before tags were kept.
        var tagged: [LanguageTaggedSlice]? = start == 0 ? [] : resumed?.slices
        func seconds(_ frame: Int64) -> TimeInterval { Double(frame) / info.sampleRate }
        var failedRanges: [SegmentFailureRange] = resumed?.failedRanges ?? []
        var producedAnyText = !pieces.isEmpty
        var segmentIndex = 0
        var lastModelIdentifier: String?
        var accumulatedDuration: TimeInterval = 0

        transcriptionService.reportExternalPreview(accumulatedText, for: noteID)
        reportedProgress = Float(start) / Float(info.totalFrames)
        transcriptionService.reportExternalProgress(reportedProgress, for: noteID)
        defer { activeSegment = nil }
        while start < info.totalFrames {
            if transcriptionService.isDiscarded(noteID: noteID) { return }
            guard ownsRun(note) else { return }
            if transcriptionService.isRunCancelled(noteID: noteID) || transcriptionService.isUserPaused(note) || Task.isCancelled {
                pause(note)
                return
            }
            if shouldStopForBackground() { pause(note); return }   // sidecar already persisted; resume later

            let targetFrame = min(start + batchFrames, info.totalFrames)
            let isLastBatch = targetFrame >= info.totalFrames
            var end = targetFrame
            if !isLastBatch {
                let cut = await nextCutFrame(sourceURL, start, targetFrame)
                if cut > start { end = cut }
                // Never leave a last slice too short to decode well on its own.
                if IncrementalTranscriptionCoordinator.leavesShortTail(
                    cutFrame: end, endFrame: info.totalFrames, sampleRate: info.sampleRate) {
                    end = IncrementalTranscriptionCoordinator.fitsOnePass(
                        from: start, to: info.totalFrames, sampleRate: info.sampleRate)
                        ? info.totalFrames
                        : await nextRebalancedCutFrame(sourceURL, start, info.totalFrames)
                }
            }

            segmentIndex += 1
            let captured = segmentIndex
            let extractedURL = await Task.detached(priority: .utility, operation: {
                IncrementalTranscriptionCoordinator.extractSegment(
                    fileURL: sourceURL, from: start, to: end, segmentIndex: captured)
            }).value
            if transcriptionService.isDiscarded(noteID: noteID)
                || transcriptionService.isRunCancelled(noteID: noteID) || transcriptionService.isUserPaused(note) || Task.isCancelled {
                if let extractedURL { try? FileManager.default.removeItem(at: extractedURL) }
                pause(note)
                return
            }
            guard let segmentURL = extractedURL else {
                // Couldn't read this slice (e.g. an unsupported container) — record
                // it as failed instead of silently finishing as noSpeech.
                failedRanges.append(SegmentFailureRange(startFrame: start, endFrame: end,
                                                        reason: "could not read slice"))
                let placeholder = Self.placeholder(forStart: start, end: end, sampleRate: info.sampleRate)
                pieces.append(placeholder)
                spans.append(placeholder, start: seconds(start), end: seconds(end))
                tagged?.append(LanguageTaggedSlice(start: seconds(start), end: seconds(end), text: placeholder, language: nil))
                start = end
                accumulatedText = joinTranscriptPieces(pieces)
                progressStore.save(.init(lastFrame: start, totalFrames: info.totalFrames,
                                         accumulatedText: accumulatedText,
                                         failedRanges: failedRanges, updatedAt: nowProvider(),
                                         spans: spans.spans, slices: tagged), for: noteID)
                transcriptionService.reportExternalPreview(accumulatedText, for: noteID)
                continue
            }

            activeSegment = (noteID, start, end, info.totalFrames)
            var outcome = await transcribeSegmentOutcome(segmentURL)
            // Only an aborted decode is worth repeating; rejected output is not.
            if case .engineError(let diagnostic) = outcome, TranscriptionService.isEngineFailure(diagnostic),
               !transcriptionService.isRunCancelled(noteID: noteID), !transcriptionService.isUserPaused(note), !Task.isCancelled {
                outcome = await transcribeSegmentOutcome(segmentURL)
            }
            try? FileManager.default.removeItem(at: segmentURL)
            activeSegment = nil

            if transcriptionService.isDiscarded(noteID: noteID) { return }
            // Checked again before this slice's text and lease are written.
            guard ownsRun(note) else { return }
            if transcriptionService.isRunCancelled(noteID: noteID) || transcriptionService.isUserPaused(note) || Task.isCancelled {
                pause(note)
                return
            }
            switch outcome {
            case .transcribed(let result):
                let text = IncrementalTranscriptionCoordinator.finalizedSegmentText(result.text)
                if let text {
                    pieces.append(text)
                    spans.append(text, start: seconds(start), end: seconds(end))
                }
                tagged?.append(LanguageTaggedSlice(start: seconds(start), end: seconds(end),
                                                   text: text, language: text == nil ? nil : result.language))
                producedAnyText = true
                lastModelIdentifier = result.modelIdentifier ?? lastModelIdentifier
                accumulatedDuration += result.duration
            case .noSpeech:
                // Silence in this slice contributes nothing and is not an error.
                tagged?.append(LanguageTaggedSlice(start: seconds(start), end: seconds(end), text: nil, language: nil))
            case .modelUnavailable, .audioUnavailable, .cancelled:
                pause(note)
                return
            case .engineError(let diagnostic):
                failedRanges.append(SegmentFailureRange(startFrame: start, endFrame: end,
                                                        reason: diagnostic))
                let placeholder = Self.placeholder(forStart: start, end: end, sampleRate: info.sampleRate)
                pieces.append(placeholder)
                spans.append(placeholder, start: seconds(start), end: seconds(end))
                tagged?.append(LanguageTaggedSlice(start: seconds(start), end: seconds(end), text: placeholder, language: nil))
            }

            switch outcome {
            case .transcribed, .noSpeech:
                transcriptionService.recordProcessedAudio(
                    start: Double(start) / info.sampleRate, end: Double(end) / info.sampleRate, session: session)
            default: break
            }
            start = end
            accumulatedText = joinTranscriptPieces(pieces)
            progressStore.save(.init(lastFrame: start, totalFrames: info.totalFrames,
                                     accumulatedText: accumulatedText,
                                     failedRanges: failedRanges, updatedAt: nowProvider(),
                                     spans: spans.spans, slices: tagged), for: noteID)
            transcriptionService.reportExternalPreview(accumulatedText, for: noteID)
            note.transcriptionLeaseExpiresAt = nowProvider().addingTimeInterval(transcriptionService.leaseDuration)
            reportProgress(Float(start) / Float(info.totalFrames), for: noteID)
        }

        guard ownsRun(note) else { return }

        var qwenVersion: AlternateTranscript?
        if let tagged, let routed = await transcribeEnglishStretches(
            in: tagged, of: note, sourceURL: sourceURL, sampleRate: info.sampleRate) {
            guard ownsRun(note) else { return }
            qwenVersion = AlternateTranscript(engine: .qwen3, text: accumulatedText, spans: spans.spans)
            let english = EnglishStretchRouting.transcript(of: routed.slices)
            accumulatedText = english.text
            spans = TranscriptSpanBuilder(resumedText: english.text, resumedSpans: english.spans)
            let replacedStarts = Set(routed.replaced.map { Int64((routed.slices[$0].start * info.sampleRate).rounded()) })
            failedRanges.removeAll { replacedStarts.contains($0.startFrame) }
            producedAnyText = producedAnyText || !english.text.isEmpty
        }

        // Re-transcription that produced no new text: keep the previous transcript.
        // A partial run is not lost — it is archived as a retained attempt the
        // detail view can show.
        if hadExistingTranscript, !producedAnyText || !failedRanges.isEmpty {
            note.completeTranscription()
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure("re-transcription did not complete successfully; kept previous transcript")
            note.clearTransientTranscriptionFlags()
            return
        }

        if let qwenVersion {
            note.setTranscript(accumulatedText, spans: spans.spans, alternate: qwenVersion)
        } else {
            note.setTranscript(accumulatedText, spans: spans.spans)
        }
        note.transcriptionModelIdentifier = lastModelIdentifier
        note.lastTranscriptionDuration = accumulatedDuration
        if producedAnyText {
            persistTelemetry(on: note)
        } else {
            note.clearTranscriptionTelemetrySummary()
        }
        note.completeTranscription()
        if !failedRanges.isEmpty {
            note.transcriptionOutcome = .failed
            note.markTranscriptionFailure(Self.failureSummary(for: failedRanges))
        } else if !producedAnyText {
            note.transcriptionOutcome = .noSpeech
        } else {
            note.transcriptionOutcome = .transcribed
        }
        note.clearTransientTranscriptionFlags()
    }

    /// Runs Parakeet on the English stretches of the slices, for the language
    /// chosen for the note. Nil when nothing was replaced.
    private func transcribeEnglishStretches(
        in slices: [LanguageTaggedSlice],
        of note: VoiceNote,
        sourceURL: URL,
        sampleRate: Double
    ) async -> (slices: [LanguageTaggedSlice], replaced: [Int])? {
        let mode = EnglishStretchRouting.Mode(languageHint: transcriptionService.languageHint(for: note.id))
        guard !EnglishStretchRouting.stretches(in: slices, mode: mode).isEmpty else { return nil }
        let transcribeEnglish = self.transcribeEnglish
        let routed = await EnglishStretchRouting.transcribeStretches(
            in: slices, mode: mode, fileURL: sourceURL, sampleRate: sampleRate, transcribe: transcribeEnglish)
        await releaseEnglishEngine()
        return routed.replaced.isEmpty ? nil : routed
    }

    /// Maps the decoder's progress through the active segment onto the file.
    /// Retries restart the decoder at zero, so only forward movement is reported.
    func reportSegmentProgress(_ fraction: Float) {
        guard let segment = activeSegment, segment.total > 0 else { return }
        let within = Double(min(max(fraction, 0), 1))
        let frame = Double(segment.start) + within * Double(segment.end - segment.start)
        reportProgress(Float(frame / Double(segment.total)), for: segment.noteID)
    }

    private func reportProgress(_ value: Float, for noteID: UUID) {
        guard value > reportedProgress else { return }
        reportedProgress = value
        transcriptionService.reportExternalProgress(value, for: noteID)
    }

    /// False once this run may no longer write text, lease, or state: another
    /// device took the note over, it was finished elsewhere, or a newer run on this
    /// device replaced this one. A note this device paused back into the queue is
    /// still this run's; the cancellation checks stop it.
    private func ownsRun(_ note: VoiceNote) -> Bool {
        if transcriptionService.isTranscribingOnAnotherDevice(note) || note.transcriptionState == .completed {
            transcriptionService.forgetSavedTranscription(note)
            return false
        }
        if note.transcriptionState == .claimed { return note.transcriptionAttemptID == attemptID }
        return true
    }

    private func pause(_ note: VoiceNote) {
        guard !transcriptionService.isDiscarded(noteID: note.id),
              !transcriptionService.isUserPaused(note), ownsRun(note) else { return }
        transcriptionService.holdOrQueue(note, queuedAt: note.transcriptionQueuedAt ?? nowProvider())
        try? note.modelContext?.save()
    }

    /// The note's speed and compute badges describe this run, replacing any
    /// earlier run's (a re-transcription may run on another device or backend).
    private func persistTelemetry(on note: VoiceNote) {
        guard let snapshot = transcriptionService.telemetryState.snapshot(for: note.id) else { return }
        note.replaceCumulativeTranscriptionTelemetry(snapshot)
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

    /// Names why slices failed, not just how many. Release builds have no debug
    /// log, so this message is the only place the cause survives.
    nonisolated static func failureSummary(for ranges: [SegmentFailureRange]) -> String {
        let headline = "\(ranges.count) segment(s) failed"
        var order: [String] = []
        var counts: [String: Int] = [:]
        for reason in ranges.map({ $0.reason ?? "unknown error" }) {
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        guard !order.isEmpty else { return headline }
        let breakdown = order.map { "\($0) ×\(counts[$0] ?? 0)" }.joined(separator: ", ")
        return "\(headline): \(breakdown)"
    }

    nonisolated static func placeholder(forStart start: Int64, end: Int64, sampleRate: Double) -> String {
        let from = formatTimestamp(Double(start) / sampleRate)
        let to = formatTimestamp(Double(end) / sampleRate)
        return "[\(from)–\(to) transcription unavailable]"
    }
}
