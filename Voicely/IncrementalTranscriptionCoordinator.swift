//
//  IncrementalTranscriptionCoordinator.swift
//  Voicely
//

import AVFoundation
import Foundation

struct IncrementalTranscriptionTiming {
    static let defaultIntervalSeconds = Int(Qwen3ASRDefaults.chunkSeconds)
    /// Earliest position inside a full batch where a VAD cut is allowed,
    /// so every chunk sent to the engine carries at least this much audio.
    static let minimumCutSeconds = Int(Qwen3ASRDefaults.minimumChunkCutSeconds)
}

struct IncrementalVoiceActivityCutConfiguration: Sendable {
    var minimumSilenceSeconds: Double = 0.35
    var minimumCutSeconds: Double = Double(IncrementalTranscriptionTiming.minimumCutSeconds)
    var speechProbabilityThreshold: Double = 0.30
    /// Length of the quietest stretch to cut in when the VAD hears no speech
    /// anywhere in the window.
    var quietStretchSeconds: Double = 0.3

    static let `default` = IncrementalVoiceActivityCutConfiguration()
}

private struct VoiceActivityCutCandidate {
    let localFrame: Int
    let confidence: Double
}

/// Manages incremental (segment-by-segment) transcription during a long recording.
/// Lives only for the duration of one recording session.
@MainActor
final class IncrementalTranscriptionCoordinator {

    // MARK: Public state

    /// All transcribed text so far, in recording order. A slice that failed live
    /// is absent until stop fills it in or marks it unavailable.
    var accumulatedTranscript: String {
        slices.compactMap(\.text).joined(separator: "\n")
    }

    /// Where each slice of `accumulatedTranscript` sits in the recording.
    var accumulatedSpans: [TranscriptSpan]? {
        var builder = TranscriptSpanBuilder()
        for slice in slices {
            guard let text = slice.text else { continue }
            builder.append(text,
                           start: Double(slice.startFrame) / recordingSampleRate,
                           end: Double(slice.endFrame) / recordingSampleRate)
        }
        return builder.spans
    }

    /// True when a failed slice could not be decoded at all (no model, unreadable
    /// audio, cancelled), so only the regular queue can recover the recording.
    private(set) var requiresFullTranscription = false

    /// Slices the engine ran on and could not transcribe. Their text is a visible
    /// "[m:ss–m:ss transcription unavailable]" marker.
    private(set) var unrecoveredSliceCount = 0

    /// One entry per unrecovered slice, carrying the engine's diagnostic so the note
    /// can name the cause. Release builds have no debug log to fall back on.
    private(set) var unrecoveredSliceRanges: [SegmentFailureRange] = []

    /// Live slices that failed and are not settled yet.
    var failedSliceCount: Int {
        slices.reduce(0) { $0 + ($1.failure == nil ? 0 : 1) }
    }

    /// Share of the stopped recording whose text is settled, including gaps
    /// already marked as unavailable.
    var finalizationProgress: Double {
        guard let finalFrame, finalFrame > 0 else { return 0 }
        let settledFrames = slices.reduce(AVAudioFramePosition(0)) { total, slice in
            slice.awaitsRetry ? total : total + (slice.endFrame - slice.startFrame)
        }
        // The slice being decoded is never settled yet — a tail slice is not in
        // `slices` and a retried one still awaits its retry — so its partial
        // frames are not counted twice. Without them the reported value only
        // moves once per slice, and iOS expires a continued processing task that
        // reports nothing for ~30 s.
        // A short tail decoded again with the slice before it overlaps that
        // settled slice; the bar moves on only once the decoder passes it.
        let decodingFrames = decodingSlice.map { decoding -> AVAudioFramePosition in
            let settledOverlap = slices.reduce(AVAudioFramePosition(0)) { total, slice in
                slice.awaitsRetry ? total
                    : total + max(0, min(slice.endFrame, decoding.end) - max(slice.startFrame, decoding.start))
            }
            let decoded = AVAudioFramePosition(Double(decoding.end - decoding.start) * decoding.fraction)
            return max(0, decoded - settledOverlap)
        } ?? 0
        return min(1, max(0, Double(settledFrames + decodingFrames) / Double(finalFrame)))
    }

    /// Audio still to transcribe if the recording stops at `frame`: the part live
    /// transcription has not reached, the slice being transcribed, and slices
    /// that could not be decoded live.
    func remainingAudioSeconds(upTo frame: AVAudioFramePosition) -> Double {
        let failedFrames = slices.reduce(AVAudioFramePosition(0)) { total, slice in
            slice.awaitsRetry ? total + (slice.endFrame - slice.startFrame) : total
        }
        let inFlightFrames = inFlightSlice.map { $0.end - $0.start } ?? 0
        let unreachedFrames = max(0, frame - lastSegmentEndFrame)
        return Double(unreachedFrames + inFlightFrames + failedFrames) / recordingSampleRate
    }

    /// Overridable for testing. When non-nil, used instead of TranscriptionService.
    var transcribeOverride: (@Sendable (String) async -> String?)? = nil

    var resolveVoiceActivityCut: (URL, AVAudioFramePosition, AVAudioFramePosition, Double) async -> AVAudioFramePosition = { url, start, end, seconds in
        await Task.detached {
            IncrementalTranscriptionCoordinator.voiceActivityAwareCutFrame(fileURL: url, startFrame: start, targetFrame: end, targetSegmentSeconds: seconds)
        }.value
    }

    var resolveRebalancedCut: (URL, AVAudioFramePosition, AVAudioFramePosition) async -> AVAudioFramePosition = { url, start, end in
        await Task.detached {
            IncrementalTranscriptionCoordinator.rebalancedCutFrame(fileURL: url, startFrame: start, endFrame: end)
        }.value
    }

    /// Closure that returns the current number of frames written to the recording file.
    var frameCountProvider: () -> AVAudioFramePosition = { 0 }

    /// Optional transcript relay after a segment appends to the accumulated transcript.
    var transcriptCallback: ((String) -> Void)? = nil
    var telemetryCallback: ((TranscriptionTelemetrySnapshot) -> Void)?
    private var telemetryFinished = false
    private var telemetrySession: TranscriptionTelemetrySession?

    func configureTelemetry(noteID: UUID) {
        finishTelemetry()
        telemetryFinished = false
        telemetrySession = transcriptionService.beginTelemetrySession(noteID: noteID, activeWorkOnly: true)
    }

    func finishTelemetry() {
        telemetryFinished = true
        if let session = telemetrySession { transcriptionService.endTelemetrySession(session) }
        telemetrySession = nil
        telemetryCallback = nil
    }


    // MARK: Private

    private let transcriptionService: TranscriptionService
    private let recordingFileURL: URL
    private let recordingSampleRate: Double

    private var segmentTimer: Timer?
    private var targetIntervalSeconds: Int = IncrementalTranscriptionTiming.defaultIntervalSeconds
    private var lastSegmentEndFrame: AVAudioFramePosition = 0
    private var segmentIndex: Int = 0
    private var isProcessingSegment = false
    private struct PendingSegmentRequest {
        var frameEnd: AVAudioFramePosition
        var useVoiceActivityCut: Bool
    }

    private let minimumCutFrames: AVAudioFramePosition

    private var pendingSegmentRequest: PendingSegmentRequest?
    private var segmentProcessingWaiters: [CheckedContinuation<Void, Never>] = []

    private enum SliceFailure: Equatable {
        /// The engine ran and produced nothing usable; the gap is marked at stop.
        /// Carries the engine's diagnostic so the note can name the cause later.
        case transcription(String?)
        /// The engine threw instead of decoding, e.g. GPU work refused while the
        /// phone is locked. Retried once at stop, when the app is in front again.
        case engine(String?)
        /// The slice could not be decoded at all right now.
        case unavailable
    }

    private enum SliceResult {
        case text(String, language: String?)
        case silent
        case failed(SliceFailure)
    }

    /// One contiguous stretch of the recording and what transcribing it produced.
    private struct LiveSlice {
        let startFrame: AVAudioFramePosition
        let endFrame: AVAudioFramePosition
        var text: String?
        var failure: SliceFailure?
        /// The language Qwen3-ASR named for the slice, nil without one.
        var language: String?

        /// The engine never got to judge this audio, so stop decodes it once more.
        var awaitsRetry: Bool {
            // A gap marker means the retry already ran and the slice is settled.
            guard text == nil else { return false }
            switch failure {
            case .unavailable, .engine: return true
            case .transcription, nil: return false
            }
        }

        init(startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition, result: SliceResult) {
            self.startFrame = startFrame
            self.endFrame = endFrame
            apply(result)
        }

        mutating func apply(_ result: SliceResult) {
            switch result {
            case .text(let text, let language):
                self.text = text
                self.language = language
                failure = nil
            case .silent:
                text = nil
                language = nil
                failure = nil
            case .failed(let reason):
                text = nil
                language = nil
                failure = reason
            }
        }
    }

    private var slices: [LiveSlice] = []
    /// The live slice being transcribed right now. `lastSegmentEndFrame` already
    /// covers it, but it joins `slices` only once transcription returns.
    private var inFlightSlice: (start: AVAudioFramePosition, end: AVAudioFramePosition)?
    /// The slice the engine is decoding right now and how far through it the
    /// decoder has reached (0...1), for live progress while it runs.
    private var decodingSlice: (start: AVAudioFramePosition, end: AVAudioFramePosition, fraction: Double)?
    private var finalFrame: AVAudioFramePosition?

    private var targetIntervalFrames: AVAudioFramePosition {
        AVAudioFramePosition(Double(targetIntervalSeconds) * recordingSampleRate)
    }

    // MARK: Init

    init(transcriptionService: TranscriptionService, recordingFileURL: URL) {
        self.transcriptionService = transcriptionService
        self.recordingFileURL = recordingFileURL
        self.recordingSampleRate = Self.sampleRate(for: recordingFileURL)
        self.minimumCutFrames = AVAudioFramePosition(
            Double(IncrementalTranscriptionTiming.minimumCutSeconds) * recordingSampleRate
        )
    }

    // MARK: Lifecycle

    /// Start periodic transcription every `intervalSeconds` seconds.
    func start(intervalSeconds: Int) {
        targetIntervalSeconds = max(1, intervalSeconds)
        let interval = TimeInterval(1)
        segmentTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleTimerFired()
            }
        }
    }

    /// Stop the timer, transcribe any remaining frames and retry slices that
    /// could not be decoded live. Returns the complete accumulated transcript.
    func stop(currentFrame: AVAudioFramePosition) async -> String {
        segmentTimer?.invalidate()
        segmentTimer = nil
        finalFrame = currentFrame
        await transcribeSegment(
            upToFrame: currentFrame,
            waitForCompletion: true,
            useVoiceActivityCut: false
        )
        await retryUndecodedSlices()
        settleRemainingFailures()
        finishTelemetry()
        return accumulatedTranscript
    }

    // MARK: English stretches

    /// Transcribes one stretch of the recording with Parakeet. Tests replace it.
    var transcribeEnglish: (URL, AVAudioFramePosition, AVAudioFramePosition, @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] = { url, start, end, progress in
        try await ParakeetEnglishEngine.shared.transcribe(fileURL: url, startFrame: start, endFrame: end, onProgress: progress)
    }

    /// Frees Parakeet once the recording is done with it. Tests replace it.
    var releaseEnglishEngine: () async -> Void = {
        await ParakeetEnglishEngine.shared.unload()
    }

    /// The slices as Qwen3-ASR left them, after `stop`.
    var languageTaggedSlices: [LanguageTaggedSlice] {
        slices.map {
            LanguageTaggedSlice(start: Double($0.startFrame) / recordingSampleRate,
                                end: Double($0.endFrame) / recordingSampleRate,
                                text: $0.text, language: $0.language)
        }
    }

    /// After `stop`, transcribes the English stretches again with Parakeet
    /// (`EnglishStretchRouting`) and puts its text in their slices. Returns
    /// Qwen3-ASR's version of the transcript when anything was replaced, nil
    /// when nothing was, Parakeet failed, or the recording needs the regular
    /// queue anyway. A stretch that fails keeps Qwen3-ASR's text.
    func transcribeEnglishStretches(mode: EnglishStretchRouting.Mode) async -> AlternateTranscript? {
        guard !requiresFullTranscription else { return nil }
        let tagged = languageTaggedSlices
        guard !EnglishStretchRouting.stretches(in: tagged, mode: mode).isEmpty else { return nil }
        let qwenVersion = AlternateTranscript(engine: .qwen3, text: accumulatedTranscript, spans: accumulatedSpans)

        let counter = transcriptionService.decodeWorkCounter
        let transcribeEnglish = self.transcribeEnglish
        let routed = await EnglishStretchRouting.transcribeStretches(
            in: tagged, mode: mode, fileURL: recordingFileURL, sampleRate: recordingSampleRate
        ) { url, start, end in
            // Each step counts as decode work for the background task.
            try await transcribeEnglish(url, start, end) { _ in counter.withLock { $0 &+= 1 } }
        }
        await releaseEnglishEngine()
        guard !routed.replaced.isEmpty else { return nil }
        var replacedStarts = Set<AVAudioFramePosition>()
        for index in routed.replaced {
            slices[index].text = routed.slices[index].text
            slices[index].failure = nil
            replacedStarts.insert(slices[index].startFrame)
        }
        // Parakeet transcribed the gaps it covered, so they are no longer unavailable.
        unrecoveredSliceRanges.removeAll { replacedStarts.contains($0.startFrame) }
        unrecoveredSliceCount = unrecoveredSliceRanges.count
        transcriptCallback?(accumulatedTranscript)
        return qwenVersion
    }

    /// Pause the timer while recording is paused.
    func pause() {
        segmentTimer?.invalidate()
        segmentTimer = nil
    }

    /// Resume periodic transcription with the original interval.
    func resume(intervalSeconds: Int) {
        start(intervalSeconds: intervalSeconds)
    }

    // MARK: Private helpers

    private func handleTimerFired() {
        let frame = frameCountProvider()
        Task { @MainActor [weak self] in
            await self?.transcribeSegment(upToFrame: frame)
        }
    }

    /// Extract frames [lastSegmentEndFrame, upToFrame) into a temp WAV file,
    /// transcribe it, and append the result to accumulatedTranscript.
    func transcribeSegment(upToFrame: AVAudioFramePosition) async {
        await transcribeSegment(
            upToFrame: upToFrame,
            waitForCompletion: false,
            useVoiceActivityCut: true
        )
    }

    private func transcribeSegment(
        upToFrame: AVAudioFramePosition,
        waitForCompletion: Bool,
        useVoiceActivityCut: Bool
    ) async {
        if isProcessingSegment {
            queuePendingSegment(upToFrame: upToFrame, useVoiceActivityCut: useVoiceActivityCut)
            if waitForCompletion {
                await waitForSegmentProcessingToFinish()
            }
            return
        }

        guard upToFrame > lastSegmentEndFrame + requiredMinimumSegmentFrames(useVoiceActivityCut: useVoiceActivityCut) else { return }

        isProcessingSegment = true
        defer {
            isProcessingSegment = false
            resumeSegmentProcessingWaiters()
        }

        var nextRequest: PendingSegmentRequest? = PendingSegmentRequest(
            frameEnd: upToFrame,
            useVoiceActivityCut: useVoiceActivityCut
        )
        while let request = nextRequest, !telemetryFinished {
            pendingSegmentRequest = nil
            if request.frameEnd > lastSegmentEndFrame + requiredMinimumSegmentFrames(useVoiceActivityCut: request.useVoiceActivityCut) {
                await transcribeCurrentSegment(
                    upToFrame: request.frameEnd,
                    useVoiceActivityCut: request.useVoiceActivityCut
                )
            }
            if !request.useVoiceActivityCut, lastSegmentEndFrame < request.frameEnd {
                queuePendingSegment(upToFrame: request.frameEnd, useVoiceActivityCut: false)
            }
            nextRequest = pendingSegmentRequest
        }
    }

    private func transcribeCurrentSegment(
        upToFrame requestedEndFrame: AVAudioFramePosition,
        useVoiceActivityCut: Bool
    ) async {
        await performSliceWork { session in
            let startFrame = lastSegmentEndFrame
            guard let endFrame = await resolvedSegmentEndFrame(
                requestedEndFrame,
                startFrame: startFrame,
                fileURL: recordingFileURL,
                useVoiceActivityCut: useVoiceActivityCut
            ) else {
                return
            }

            lastSegmentEndFrame = endFrame
            inFlightSlice = (startFrame, endFrame)
            if !useVoiceActivityCut, endFrame == requestedEndFrame,
               await foldShortTailIntoLastSlice(tailStart: startFrame, end: endFrame, session: session) {
                inFlightSlice = nil
                transcriptCallback?(accumulatedTranscript)
                return
            }
            let result = await transcribeSlice(from: startFrame, to: endFrame, session: session)
            inFlightSlice = nil
            slices.append(LiveSlice(startFrame: startFrame, endFrame: endFrame, result: result))
            if case .text = result {
                transcriptCallback?(accumulatedTranscript)
            }
        }
    }

    /// Decodes a short final tail together with the slice before it, which was
    /// decoded live without it, and replaces that slice with the result. Too
    /// long for one pass, the two are cut again near their middle. Returns
    /// false, changing nothing, when there is no such slice or the new decode
    /// failed or lost the text the slice had; the tail is then decoded alone.
    private func foldShortTailIntoLastSlice(
        tailStart: AVAudioFramePosition,
        end: AVAudioFramePosition,
        session: TranscriptionTelemetrySession
    ) async -> Bool {
        guard Self.leavesShortTail(cutFrame: tailStart, endFrame: end, sampleRate: recordingSampleRate),
              let previous = slices.last, previous.endFrame == tailStart else { return false }

        var bounds = [previous.startFrame, end]
        if !Self.fitsOnePass(from: previous.startFrame, to: end, sampleRate: recordingSampleRate) {
            let cut = await resolveRebalancedCut(recordingFileURL, previous.startFrame, end)
            bounds.insert(cut, at: 1)
        }
        var replacements: [LiveSlice] = []
        for (start, sliceEnd) in zip(bounds, bounds.dropFirst()) {
            let result = await transcribeSlice(from: start, to: sliceEnd, session: session)
            if case .failed = result { return false }
            replacements.append(LiveSlice(startFrame: start, endFrame: sliceEnd, result: result))
        }
        if previous.text != nil, replacements.allSatisfy({ $0.text == nil }) { return false }
        slices.removeLast()
        slices.append(contentsOf: replacements)
        return true
    }

    /// Runs slice work on the active-work clock, then reports the run's
    /// cumulative telemetry.
    private func performSliceWork(_ work: (TranscriptionTelemetrySession) async -> Void) async {
        guard !telemetryFinished else { return }
        if telemetrySession == nil {
            telemetrySession = transcriptionService.beginTelemetrySession(activeWorkOnly: true)
        }
        guard let session = telemetrySession else { return }
        transcriptionService.resumeTelemetryWork(session)
        await work(session)
        transcriptionService.pauseTelemetryWork(session)
        if transcriptionService.isTelemetrySessionCurrent(session), let noteID = session.noteID,
           let snapshot = transcriptionService.telemetryState.snapshot(for: noteID) {
            telemetryCallback?(snapshot)
        }
    }

    private func transcribeSlice(
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition,
        session: TranscriptionTelemetrySession
    ) async -> SliceResult {
        segmentIndex += 1
        let index = segmentIndex
        let fileURL = recordingFileURL
        let extracted = await Task.detached {
            Self.extractSegment(
                fileURL: fileURL,
                from: startFrame,
                to: endFrame,
                segmentIndex: index
            )
        }.value
        guard let sliceURL = extracted else { return .failed(.unavailable) }
        defer {
            try? FileManager.default.removeItem(at: sliceURL)
        }

        // No separate speech preflight here: transcribeAudio runs the same
        // neural VAD gate before invoking the engine, so checking twice would
        // just double the inference cost per segment.
        let result: SliceResult
        decodingSlice = (startFrame, endFrame, 0)
        defer { decodingSlice = nil }
        if let override = transcribeOverride {
            if let text = await override(sliceURL.path) {
                result = Self.finalizedSegmentText(text).map { SliceResult.text($0, language: nil) } ?? .silent
            } else {
                result = .failed(.transcription(nil))
            }
        } else {
            let outcome = await transcriptionService.transcribeAudioOutcome(
                filePath: sliceURL.path,
                progressCallback: { [weak self] fraction in self?.reportSliceProgress(fraction) },
                telemetrySession: session)
            switch outcome {
            case .transcribed(let transcription):
                result = Self.finalizedSegmentText(transcription.text)
                    .map { SliceResult.text($0, language: transcription.language) } ?? .silent
            case .noSpeech:
                result = .silent
            case .engineError(let diagnostic):
                result = .failed(TranscriptionService.isEngineFailure(diagnostic)
                    ? .engine(diagnostic) : .transcription(diagnostic))
            case .modelUnavailable, .audioUnavailable, .cancelled:
                result = .failed(.unavailable)
            }
        }

        if case .failed = result {
            return result
        }
        if !Task.isCancelled {
            transcriptionService.recordProcessedAudio(
                start: Double(startFrame) / recordingSampleRate,
                end: Double(endFrame) / recordingSampleRate, session: session)
        }
        return result
    }

    /// Records how far the decoder has reached through the slice it is decoding.
    /// Retries restart the decoder at zero, so only forward movement counts.
    func reportSliceProgress(_ fraction: Float) {
        guard let slice = decodingSlice else { return }
        let clamped = Double(min(max(fraction, 0), 1))
        guard clamped > slice.fraction else { return }
        decodingSlice = (slice.start, slice.end, clamped)
    }

    /// A slice the engine never decoded (model still loading, cancelled, engine
    /// error) gets one attempt in place, so it never forces the whole recording to
    /// be transcribed again. A slice the engine ran on and rejected is not retried:
    /// decoding is deterministic, so it would be rejected again, and repeating it
    /// held "Finalizing" for minutes after the text was complete.
    private func retryUndecodedSlices() async {
        for index in slices.indices where slices[index].awaitsRetry {
            guard !telemetryFinished else { return }
            let slice = slices[index]
            var result = SliceResult.failed(slice.failure ?? .unavailable)
            await performSliceWork { session in
                result = await transcribeSlice(from: slice.startFrame, to: slice.endFrame, session: session)
            }
            slices[index].apply(result)
            if slices[index].text != nil {
                transcriptCallback?(accumulatedTranscript)
            }
        }
    }

    /// Marks slices the engine could not transcribe as visible gaps; anything that
    /// still could not be decoded at all hands the recording to the regular queue.
    private func settleRemainingFailures() {
        unrecoveredSliceCount = 0
        unrecoveredSliceRanges = []
        for index in slices.indices {
            switch slices[index].failure {
            case .transcription(let diagnostic), .engine(let diagnostic):
                unrecoveredSliceCount += 1
                unrecoveredSliceRanges.append(SegmentFailureRange(
                    startFrame: slices[index].startFrame,
                    endFrame: slices[index].endFrame,
                    reason: diagnostic
                ))
                slices[index].text = SegmentedAudioTranscriber.placeholder(
                    forStart: slices[index].startFrame,
                    end: slices[index].endFrame,
                    sampleRate: recordingSampleRate
                )
            case .unavailable:
                requiresFullTranscription = true
            case nil:
                break
            }
        }
    }

    private func resolvedSegmentEndFrame(
        _ requestedEndFrame: AVAudioFramePosition,
        startFrame: AVAudioFramePosition,
        fileURL: URL,
        useVoiceActivityCut: Bool
    ) async -> AVAudioFramePosition? {
        guard useVoiceActivityCut else {
            // The recording has stopped, so the rest of it is known: cut at a
            // pause, and never so late that a short tail is left behind.
            guard requestedEndFrame - startFrame > targetIntervalFrames else { return requestedEndFrame }
            let fixedCut = startFrame + max(1, targetIntervalFrames)
            var cutFrame = await resolveVoiceActivityCut(fileURL, startFrame, requestedEndFrame, Double(targetIntervalSeconds))
            if cutFrame <= startFrame + minimumCutFrames || cutFrame > fixedCut {
                cutFrame = fixedCut
            }
            if Self.leavesShortTail(cutFrame: cutFrame, endFrame: requestedEndFrame, sampleRate: recordingSampleRate) {
                cutFrame = Self.fitsOnePass(from: startFrame, to: requestedEndFrame, sampleRate: recordingSampleRate)
                    ? requestedEndFrame
                    : await resolveRebalancedCut(fileURL, startFrame, requestedEndFrame)
            }
            return cutFrame
        }

        let targetIntervalSeconds = self.targetIntervalSeconds
        let cutFrame = await resolveVoiceActivityCut(fileURL, startFrame, requestedEndFrame, Double(targetIntervalSeconds))

        guard cutFrame > startFrame + minimumCutFrames else {
            return nil
        }

        return cutFrame
    }

    /// Periodic VAD cuts wait until a full batch has accumulated so the VAD
    /// runs once per batch instead of probing every tick. The final flush
    /// (non-VAD) must transcribe whatever remains, however short, otherwise
    /// the tail of the recording is silently lost.
    private func requiredMinimumSegmentFrames(useVoiceActivityCut: Bool) -> AVAudioFramePosition {
        useVoiceActivityCut ? targetIntervalFrames : 0
    }

    private func queuePendingSegment(
        upToFrame: AVAudioFramePosition,
        useVoiceActivityCut: Bool
    ) {
        guard upToFrame > lastSegmentEndFrame + requiredMinimumSegmentFrames(useVoiceActivityCut: useVoiceActivityCut) else { return }

        if var pendingSegmentRequest {
            pendingSegmentRequest.frameEnd = max(pendingSegmentRequest.frameEnd, upToFrame)
            pendingSegmentRequest.useVoiceActivityCut = pendingSegmentRequest.useVoiceActivityCut && useVoiceActivityCut
            self.pendingSegmentRequest = pendingSegmentRequest
        } else {
            pendingSegmentRequest = PendingSegmentRequest(
                frameEnd: upToFrame,
                useVoiceActivityCut: useVoiceActivityCut
            )
        }
    }

    private func waitForSegmentProcessingToFinish() async {
        guard isProcessingSegment else { return }

        await withCheckedContinuation { continuation in
            segmentProcessingWaiters.append(continuation)
        }
    }

    private func resumeSegmentProcessingWaiters() {
        let waiters = segmentProcessingWaiters
        segmentProcessingWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Test-only convenience that mirrors the legacy signature.
    /// Increments `segmentIndex` and calls into the nonisolated extractor.
    func extractSegmentPublic(
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition
    ) -> URL? {
        segmentIndex += 1
        return Self.extractSegment(
            fileURL: recordingFileURL,
            from: startFrame,
            to: endFrame,
            segmentIndex: segmentIndex
        )
    }

    private nonisolated static func sampleRate(for fileURL: URL) -> Double {
        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            return sourceFile.processingFormat.sampleRate
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Failed to read recording sample rate: \(error)")
            return 16_000
        }
    }

    /// Reads audio frames from the recording file and writes them to a temp WAV.
    /// Runs off the MainActor (called from Task.detached) to keep file I/O off the UI thread.
    nonisolated static func extractSegment(
        fileURL: URL,
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition,
        segmentIndex: Int
    ) -> URL? {
        guard startFrame >= 0, endFrame > startFrame, endFrame - startFrame <= Int64(UInt32.max) else { return nil }
        let frameCount = AVAudioFrameCount(endFrame - startFrame)
        guard frameCount > 0 else { return nil }

        var temporaryURL: URL?
        var completed = false
        defer {
            if !completed, let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            sourceFile.framePosition = startFrame

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: min(frameCount, 16_384)
            ) else { return nil }


            let segmentURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicely_seg_\(segmentIndex)_\(UUID().uuidString).wav")

            temporaryURL = segmentURL
            let segmentFile = try AVAudioFile(
                forWriting: segmentURL,
                settings: sourceFile.processingFormat.settings
            )
            var remaining = frameCount
            while remaining > 0 {
                try sourceFile.read(into: buffer, frameCount: min(remaining, buffer.frameCapacity))
                guard buffer.frameLength > 0 else {
                    try? FileManager.default.removeItem(at: segmentURL)
                    return nil
                }
                try segmentFile.write(from: buffer)
                remaining -= buffer.frameLength
            }
            completed = true
            return segmentURL
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Segment extraction failed: \(error)")
            return nil
        }
    }


    /// Chooses a cut point with a single neural VAD pass per full batch.
    ///
    /// The coordinator accumulates `targetSegmentSeconds` of audio, then this
    /// runs Silero VAD once over [start + minimumCutSeconds, batch end] and cuts
    /// in the middle of the best pause found, falling back to the deepest short
    /// dip, and to the batch end only when no frame is below the threshold.
    /// Audio past the cut carries over into the next batch.
    ///
    /// Returns `startFrame` while the batch is still filling, which tells the
    /// coordinator to keep recording before cutting the chunk.
    nonisolated static func voiceActivityAwareCutFrame(
        fileURL: URL,
        startFrame: AVAudioFramePosition,
        targetFrame: AVAudioFramePosition,
        targetSegmentSeconds: Double = Double(IncrementalTranscriptionTiming.defaultIntervalSeconds),
        configuration: IncrementalVoiceActivityCutConfiguration = .default,
        neuralVoiceActivityDetector: NeuralVoiceActivityDetecting? = nil
    ) -> AVAudioFramePosition {
        do {
            let sourceFile = try AVAudioFile(forReading: fileURL)
            let format = sourceFile.processingFormat
            let sampleRate = format.sampleRate
            let targetSeconds = max(configuration.minimumCutSeconds, targetSegmentSeconds)
            let targetFrames = AVAudioFramePosition(targetSeconds * sampleRate)
            let minimumCutFrames = AVAudioFramePosition(configuration.minimumCutSeconds * sampleRate)

            // A batch is exactly `targetSeconds` long; audio past it carries
            // over so every chunk stays within the engine's single-pass limit.
            let batchEndFrame = min(targetFrame, sourceFile.length, startFrame + targetFrames)

            guard batchEndFrame >= startFrame + targetFrames else {
                return startFrame
            }

            let analysisStartFrame = startFrame + minimumCutFrames
            let framesToRead = AVAudioFrameCount(batchEndFrame - analysisStartFrame)
            guard framesToRead > 0 else { return batchEndFrame }

            sourceFile.framePosition = analysisStartFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                return batchEndFrame
            }

            try sourceFile.read(into: buffer, frameCount: framesToRead)
            let samples = monoFloatSamples(from: buffer)
            guard !samples.isEmpty else { return batchEndFrame }

            // Silero only reads 16 kHz audio; imported files keep their own rate.
            let vadSampleRate = Double(SileroNeuralVoiceActivityDetector.sampleRate)
            let vadSamples = sampleRate == vadSampleRate
                ? samples
                : try resampled(samples, from: sampleRate, to: vadSampleRate)
            let detector = try neuralVoiceActivityDetector ?? SileroNeuralVoiceActivityDetector()
            let vadFrames = try detector.speechProbabilities(in: vadSamples)
            // Silero can be deaf to a whole voice: every frame quiet while
            // someone talks. Its pause midpoint would then be a blind guess
            // that can split a word, so cut in the quietest stretch of the
            // waveform instead, a breath or a gap between words.
            let vadHeardNothing = !vadFrames.isEmpty && vadFrames.allSatisfy {
                $0.speechProbability <= configuration.speechProbabilityThreshold
            }
            let candidate = vadHeardNothing
                ? quietestStretchCandidate(
                    in: vadSamples,
                    windowSamples: max(1, Int(configuration.quietStretchSeconds * vadSampleRate))
                )
                : bestNeuralSilenceCutCandidate(
                    in: vadFrames,
                    speechProbabilityThreshold: configuration.speechProbabilityThreshold,
                    minimumSilenceFrames: max(1, Int(configuration.minimumSilenceSeconds * vadSampleRate))
                )

            guard let candidate else {
                return batchEndFrame
            }

            // The candidate counts 16 kHz samples; cut in the file's own frames.
            let localFrame = (Double(candidate.localFrame) * sampleRate / vadSampleRate).rounded()
            let cutFrame = analysisStartFrame + AVAudioFramePosition(localFrame)
            return min(max(cutFrame, analysisStartFrame), batchEndFrame)
        } catch {
            debugLog("⚠️ [IncrementalCoordinator] Neural VAD cut failed: \(error)")
            return targetFrame
        }
    }

    nonisolated private static func resampled(
        _ samples: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) throws -> [Float] {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                               channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount((Double(samples.count) * targetRate / sourceRate).rounded(.up)) + 1_024
              ) else {
            throw NeuralSpeechAnalyzerError.audioConversionUnavailable
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error, let channelData = output.floatChannelData else {
            throw NeuralSpeechAnalyzerError.audioConversionUnavailable
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }

    nonisolated private static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let floatChannelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }
        let channelCount = max(1, Int(buffer.format.channelCount))

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        }

        var samples = Array(repeating: Float(0), count: frameLength)
        for channel in 0..<channelCount {
            let channelSamples = floatChannelData[channel]
            for frame in 0..<frameLength {
                samples[frame] += channelSamples[frame] / Float(channelCount)
            }
        }
        return samples
    }

    /// Picks the pause to cut at and cuts in its middle, so neither slice clips
    /// a word that starts or ends at the pause's edge.
    ///
    /// Pauses at least `minimumSilenceFrames` long are preferred. When there is
    /// none, the best shorter dip below the threshold is used instead: in
    /// far-field, fast speech a whole window can hold only 0.1–0.3 s gaps, and
    /// cutting at one of them beats cutting at the batch end, which can land
    /// inside a word. Returns nil only when no frame is below the threshold.
    nonisolated private static func bestNeuralSilenceCutCandidate(
        in vadFrames: [NeuralVoiceActivityFrame],
        speechProbabilityThreshold: Double,
        minimumSilenceFrames: Int
    ) -> VoiceActivityCutCandidate? {
        struct QuietRun {
            var startFrame: Int
            var endFrame: Int
            var probabilitySum: Double
            var frameCount: Int
        }

        var runs: [QuietRun] = []
        var currentRun: QuietRun?
        for frame in vadFrames {
            if frame.speechProbability <= speechProbabilityThreshold {
                if currentRun == nil {
                    currentRun = QuietRun(startFrame: frame.startFrame, endFrame: frame.endFrame,
                                          probabilitySum: 0, frameCount: 0)
                }
                currentRun?.endFrame = frame.endFrame
                currentRun?.probabilitySum += frame.speechProbability
                currentRun?.frameCount += 1
            } else if let run = currentRun {
                runs.append(run)
                currentRun = nil
            }
        }
        if let currentRun { runs.append(currentRun) }

        // Depth dominates, length breaks near-ties.
        func confidence(of run: QuietRun) -> Double {
            let averageSpeechProbability = run.probabilitySum / Double(max(run.frameCount, 1))
            let silenceConfidence = max(
                0,
                min(1, (speechProbabilityThreshold - averageSpeechProbability) / max(speechProbabilityThreshold, 0.000_001))
            )
            let durationFrames = run.endFrame - run.startFrame
            let durationConfidence = min(1, Double(durationFrames) / Double(max(minimumSilenceFrames * 2, 1)))
            return min(1, 0.75 * silenceConfidence + 0.25 * durationConfidence)
        }

        let longPauses = runs.filter { $0.endFrame - $0.startFrame >= minimumSilenceFrames }
        let pool = longPauses.isEmpty ? runs : longPauses
        var bestCandidate: VoiceActivityCutCandidate?
        for run in pool {
            let candidate = VoiceActivityCutCandidate(
                localFrame: (run.startFrame + run.endFrame) / 2,
                confidence: confidence(of: run)
            )
            // Equal pauses: the later one wins so less audio carries over.
            if bestCandidate == nil || candidate.confidence >= bestCandidate!.confidence {
                bestCandidate = candidate
            }
        }
        return bestCandidate
    }

    /// The middle of the lowest-energy `windowSamples` stretch, scanned in
    /// 10 ms steps. Equal stretches: the later one wins, as with pauses.
    nonisolated private static func quietestStretchCandidate(
        in samples: [Float],
        windowSamples: Int
    ) -> VoiceActivityCutCandidate? {
        guard !samples.isEmpty else { return nil }
        guard samples.count > windowSamples else {
            return VoiceActivityCutCandidate(localFrame: samples.count / 2, confidence: 0)
        }

        var energyPrefix = [Double](repeating: 0, count: samples.count + 1)
        for (index, sample) in samples.enumerated() {
            energyPrefix[index + 1] = energyPrefix[index] + Double(sample) * Double(sample)
        }

        let hop = SileroNeuralVoiceActivityDetector.sampleRate / 100
        var bestStart = 0
        var bestEnergy = Double.infinity
        for start in stride(from: 0, through: samples.count - windowSamples, by: hop) {
            let energy = energyPrefix[start + windowSamples] - energyPrefix[start]
            if energy <= bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
        }
        return VoiceActivityCutCandidate(localFrame: bestStart + windowSamples / 2, confidence: 0)
    }

    /// A slice's text as it joins the transcript, or nil when it holds only
    /// whitespace or punctuation.
    nonisolated static func finalizedSegmentText(_ text: String?) -> String? {
        LocalTranscriptFinalizer.finalizedText(text)
    }

    // MARK: Final slice

    /// A last slice shorter than this is decoded together with the slice before
    /// it. Alone it lacks context: on 115 real cut points in five English
    /// recordings, decoding a 1 s tail with the slice before it made 18 fewer
    /// errors per 100 tail words, a 2 s tail 8 fewer, a 3 s tail 4 fewer; at
    /// 5 s the two were even and at 8 s identical.
    nonisolated static let shortTailSeconds = 4.0
    /// When a slice and its short tail together exceed one engine pass, the
    /// stretch is cut again within this distance of its middle.
    nonisolated static let rebalancedCutHalfWindowSeconds = 5.0

    nonisolated static func leavesShortTail(
        cutFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        sampleRate: Double
    ) -> Bool {
        Double(endFrame - cutFrame) / sampleRate < shortTailSeconds
    }

    nonisolated static func fitsOnePass(
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition,
        sampleRate: Double
    ) -> Bool {
        Double(endFrame - startFrame) / sampleRate <= Qwen3ASRDefaults.singlePassSecondsLimit
    }

    /// Cuts the last stretch of the audio, a slice plus its short tail, into
    /// two slices of similar length at the best pause near its middle, so
    /// neither is a short tail again and both stay within one engine pass.
    nonisolated static func rebalancedCutFrame(
        fileURL: URL,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        neuralVoiceActivityDetector: NeuralVoiceActivityDetecting? = nil
    ) -> AVAudioFramePosition {
        let sampleRate = Self.sampleRate(for: fileURL)
        let halfSeconds = Double(endFrame - startFrame) / sampleRate / 2
        // Neither side may exceed a slice or be a short tail itself.
        let halfWindow = min(rebalancedCutHalfWindowSeconds,
                             Qwen3ASRDefaults.chunkSeconds - halfSeconds,
                             halfSeconds - shortTailSeconds)
        var configuration = IncrementalVoiceActivityCutConfiguration.default
        configuration.minimumCutSeconds = halfSeconds - halfWindow
        let earliest = startFrame + AVAudioFramePosition((halfSeconds - halfWindow) * sampleRate)
        let latest = startFrame + AVAudioFramePosition((halfSeconds + halfWindow) * sampleRate)
        let cut = voiceActivityAwareCutFrame(
            fileURL: fileURL,
            startFrame: startFrame,
            targetFrame: endFrame,
            targetSegmentSeconds: halfSeconds + halfWindow,
            configuration: configuration,
            neuralVoiceActivityDetector: neuralVoiceActivityDetector
        )
        // A failed VAD returns the end of the audio; fall back to the middle.
        guard cut >= earliest, cut <= latest else { return startFrame + (endFrame - startFrame) / 2 }
        return cut
    }
}
