//
//  AudioRecordingService.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Accelerate
@preconcurrency import AVFoundation
import Combine
import Foundation
import os

#if DEBUG
/// A callback duration comparison, not evidence of a hardware audio overload.
struct AudioTapTiming {
    let frameCount: UInt32
    let sampleRate: Double

    func exceedsBufferPeriod(elapsedNanoseconds: UInt64) -> Bool {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return false }
        let periodNanoseconds = Double(frameCount) / sampleRate * 1_000_000_000
        return Double(elapsedNanoseconds) > periodNanoseconds
    }
}
#endif

struct RecordingStopResult {
    let filePath: String?
    let duration: TimeInterval

    private let awaitConversion: (@Sendable () async -> Void)?
    private var resolvePath: (@Sendable () async -> String?)?
    private var cleanup: (@Sendable () async -> Void)?

    init(
        filePath: String?,
        duration: TimeInterval,
        awaitConversion: (@Sendable () async -> Void)? = nil
    ) {
        self.filePath = filePath
        self.duration = duration
        self.awaitConversion = awaitConversion
    }

    /// Starts conversion without transferring ownership of the PCM source.
    /// The caller releases that source only after incremental final-flush finishes.
    static func converting(
        sourceURL: URL,
        destinationURL: URL,
        duration: TimeInterval,
        convert: @escaping @Sendable (URL, URL) async throws -> Void
    ) -> RecordingStopResult {
        let task = Task.detached(priority: .utility) { () -> URL in
            do {
                try await convert(sourceURL, destinationURL)
                let size = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 else { throw CocoaError(.fileWriteUnknown) }
                return destinationURL
            } catch {
                // A failed export can leave an unusable partial destination.
                try? FileManager.default.removeItem(at: destinationURL)
                let fallbackURL = destinationURL.deletingPathExtension().appendingPathExtension("caf")
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: fallbackURL)
                    return fallbackURL
                } catch {
                    // Never discard the only recording, even if durable storage is unavailable.
                    return sourceURL
                }
            }
        }
        var result = RecordingStopResult(
            // Keep the persisted identity portable while export is pending.
            filePath: destinationURL.lastPathComponent,
            duration: duration,
            awaitConversion: { _ = await task.value }
        )
        result.resolvePath = {
            let resolved = await task.value
            return resolved == sourceURL ? resolved.path : resolved.lastPathComponent
        }
        result.cleanup = {
            let resolved = await task.value
            // Preserve the source if conversion and durable fallback both failed.
            guard resolved != sourceURL,
                  FileManager.default.fileExists(atPath: resolved.path) else { return }
            try? FileManager.default.removeItem(at: sourceURL)
        }
        return result
    }

    /// Returns the durable export path, or the retained source if export failed.
    func resolvedFilePath() async -> String? {
        if let resolvePath { return await resolvePath() }
        await awaitConversion?()
        return filePath
    }

    /// Call only after every PCM reader, including final-flush, has finished.
    func cleanupTemporaryAudio() async {
        await cleanup?()
    }

    func awaitConversionIfNeeded(forIncrementalTranscript transcript: String) async {
        guard transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        await awaitConversion?()
    }
}

@MainActor
class AudioRecordingService: ObservableObject {

    // MARK: Published state (same public interface as before)

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var hasPermission = false
    @Published private(set) var isPreparingRecordingSession = false

    // MARK: New: exposes PCM file URL and live frame position

    /// URL of the live CAF/PCM temp file being written. Nil when not recording.
    private(set) var currentPCMFileURL: URL?

    /// Approximate number of 16 kHz frames written so far.
    /// Read-safe from any thread; updated under lock from the audio tap thread.
    nonisolated var currentFramePosition: AVAudioFramePosition {
        sharedState.withLock { $0.framePosition }
    }

    /// Latest per-buffer RMS level (raw, unsmoothed). Safe to call from any thread.
    nonisolated func peekAudioLevel() -> Float {
        sharedState.withLock { $0.latestLevel }
    }

    // MARK: Private

    /// Shared state written by the audio tap thread and read by the MainActor UI tick.
    private struct SharedState {
        var framePosition: AVAudioFramePosition = 0
        var latestLevel: Float = 0
        var isWritingSuspended = false
    }
    private let sharedState = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    private var engine: AVAudioEngine?
    private struct AudioWriteTargets: @unchecked Sendable {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
    }
    private let writeTargets = OSAllocatedUnfairLock(initialState: AudioWriteTargets())
    private var recordingTimer: Timer?
    private var pendingM4AURL: URL?
    private var prewarmTask: Task<Void, Never>?
    private var isRecordingSessionPrewarmed = false

    #if !os(macOS) || targetEnvironment(macCatalyst)
    private var audioSession = AVAudioSession.sharedInstance()
    private var interruptionObserver: NSObjectProtocol?
    #endif

    // MARK: Init

    init() {
        checkPermission()
        registerForAudioSessionInterruptions()
    }

    deinit {
        prewarmTask?.cancel()
        #if !os(macOS) || targetEnvironment(macCatalyst)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        #endif
    }

    // MARK: Interruptions

    /// iOS forbids restarting input IO from the background, so a recording
    /// cannot reliably survive an interruption (incoming call, another app
    /// grabbing the audio session). Policy: end the recording cleanly and let
    /// the UI layer finalize it, rather than show a phantom "recording" state.
    private func registerForAudioSessionInterruptions() {
        #if !os(macOS) || targetEnvironment(macCatalyst)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            guard AudioInterruptionDecision.shouldEndRecording(userInfo: notification.userInfo) else {
                return
            }
            MainActor.assumeIsolated {
                self?.handleInterruptionThatEndsRecording()
            }
        }
        #endif
    }

    private func handleInterruptionThatEndsRecording() {
        guard isRecording else { return }
        debugLog("⚠️ [AudioRecordingService] Audio session interrupted — ending recording")
        NotificationCenter.default.post(name: .recordingInterruptedBySystem, object: nil)
    }

    // MARK: Permission

    func checkPermission() {
        #if targetEnvironment(macCatalyst)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: hasPermission = true
        case .denied:  hasPermission = false
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] allowed in
                DispatchQueue.main.async { self?.hasPermission = allowed }
            }
        @unknown default: hasPermission = false
        }
        #elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: hasPermission = true
        case .denied, .restricted: hasPermission = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async { self?.hasPermission = allowed }
            }
        @unknown default: hasPermission = false
        }
        #else
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: hasPermission = true
            case .denied:  hasPermission = false
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async { self?.hasPermission = allowed }
                }
            @unknown default: hasPermission = false
            }
        } else {
            switch audioSession.recordPermission {
            case .granted: hasPermission = true
            case .denied:  hasPermission = false
            case .undetermined:
                audioSession.requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async { self?.hasPermission = allowed }
                }
            @unknown default: hasPermission = false
            }
        }
        #endif
    }

    // MARK: Recording Session Prewarm

    func prewarmRecordingSessionIfPossible() {
        guard RecordingSessionPrewarmState.shouldStartPrewarm(
            hasPermission: hasPermission,
            isRecording: isRecording,
            isPrewarming: isPreparingRecordingSession,
            isPrewarmed: isRecordingSessionPrewarmed
        ) else {
            return
        }

        isPreparingRecordingSession = true
        prewarmTask?.cancel()
        prewarmTask = Task { @MainActor [weak self] in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, self.isPreparingRecordingSession else {
                return
            }

            defer {
                self.isPreparingRecordingSession = false
                self.prewarmTask = nil
            }

            do {
                try self.prepareRecordingSessionForCapture()
                self.warmInputRoute()
                self.isRecordingSessionPrewarmed = true
                debugLog("✅ [AudioRecordingService] Recording session prewarmed")
            } catch {
                self.isRecordingSessionPrewarmed = false
                debugLog("⚠️ [AudioRecordingService] Recording session prewarm failed: \(error)")
            }
        }
    }

    // MARK: Start Recording

    /// Starts recording. Returns the M4A filename (last path component) for cross-device compat.
    func startRecording() -> String? {
        guard hasPermission else {
            checkPermission()
            return nil
        }

        prewarmTask?.cancel()
        prewarmTask = nil
        isPreparingRecordingSession = false

        do {
            try prepareRecordingSessionForCapture()
            isRecordingSessionPrewarmed = false
        } catch {
            debugLog("❌ [AudioRecordingService] Audio session setup failed: \(error)")
            return nil
        }

        let m4aURL = CloudStorageManager.shared.generateAudioFilename()
        let pcmURL = Self.makePCMTemporaryURL()

        pendingM4AURL = m4aURL

        // Target format: 16 kHz Float32 mono (WhisperKit native)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        do {
            let file = try AVAudioFile(forWriting: pcmURL, settings: targetFormat.settings)
            writeTargets.withLock { $0.file = file }
        } catch {
            debugLog("❌ [AudioRecordingService] Failed to create PCM file: \(error)")
            return nil
        }

        let newEngine = AVAudioEngine()
        engine = newEngine
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Avoid Catalyst's implicit stereo-to-mono conversion for USB microphones.
        // Mix channels explicitly; the converter only changes the sample rate.
        guard let monoInputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoInputFormat, to: targetFormat) else {
            engine = nil
            writeTargets.withLock { $0 = AudioWriteTargets() }
            return nil
        }
        writeTargets.withLock { $0.converter = converter }

        currentPCMFileURL = pcmURL
        sharedState.withLock { state in
            state.framePosition = 0
            state.latestLevel = 0
            state.isWritingSuspended = false
        }

        #if DEBUG
        // Construct the log on the main actor, never lazily inside the audio tap.
        let tapPerformanceLog = OSLog(subsystem: "com.hellotaotao.Voicely", category: "AudioTapPerformance")
        #endif
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            #if DEBUG
            let measureTap = tapPerformanceLog.signpostsEnabled
            let signpostID = measureTap ? OSSignpostID(log: tapPerformanceLog) : .invalid
            let startedAt = measureTap ? DispatchTime.now().uptimeNanoseconds : 0
            if measureTap {
                os_signpost(.begin, log: tapPerformanceLog, name: "AudioTap", signpostID: signpostID)
            }
            defer {
                if measureTap {
                    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                    os_signpost(.end, log: tapPerformanceLog, name: "AudioTap", signpostID: signpostID)
                    let timing = AudioTapTiming(frameCount: buffer.frameLength, sampleRate: buffer.format.sampleRate)
                    if timing.exceedsBufferPeriod(elapsedNanoseconds: elapsed) {
                        os_signpost(.event, log: tapPerformanceLog, name: "AudioTapExceededBufferPeriod",
                                    signpostID: signpostID, "elapsed_ns=%llu frames=%u sample_rate=%f",
                                    elapsed, buffer.frameLength, buffer.format.sampleRate)
                    }
                }
            }
            #endif
            guard let mono = Self.mixedDownToMono(buffer) else { return }
            self?.processTapBuffer(mono, inputFormat: monoInputFormat, outputFormat: targetFormat)
        }
        newEngine.prepare()

        do {
            try newEngine.start()
        } catch {
            debugLog("❌ [AudioRecordingService] Engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            engine = nil
            writeTargets.withLock { $0 = AudioWriteTargets() }
            currentPCMFileURL = nil
            return nil
        }

        isRecording = true
        isPaused = false
        recordingDuration = 0

        startUITimer()

        debugLog("✅ [AudioRecordingService] Recording started → \(m4aURL.lastPathComponent)")
        return m4aURL.lastPathComponent
    }

    // MARK: Stop Recording

    /// Stops recording synchronously (engine stop + UI state update).
    /// Kicks off PCM→M4A conversion in the background.
    /// Returns the M4A filename and recorded duration immediately.
    func stopRecording() -> RecordingStopResult {
        guard isRecording, let eng = engine else {
            return RecordingStopResult(filePath: nil, duration: 0)
        }

        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        engine = nil

        // Wait for any in-flight write before closing the file and starting export.
        writeTargets.withLock { $0 = AudioWriteTargets() }

        stopUITimer()

        isRecording = false
        isPaused = false

        let duration = recordingDuration

        #if !os(macOS) && !targetEnvironment(macCatalyst)
        try? audioSession.setActive(false)
        #elseif targetEnvironment(macCatalyst)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRecordingSessionPrewarmed = false

        let result: RecordingStopResult
        if let pcmURL = currentPCMFileURL, let m4aURL = pendingM4AURL {
            result = .converting(
                sourceURL: pcmURL,
                destinationURL: m4aURL,
                duration: duration,
                convert: Self.convertCAFToM4A
            )
        } else {
            result = RecordingStopResult(filePath: currentPCMFileURL?.path, duration: duration)
        }

        currentPCMFileURL = nil
        pendingM4AURL = nil

        debugLog("✅ [AudioRecordingService] Recording stopped. Duration: \(duration)s")
        return result
    }

    // MARK: Pause / Resume

    func pauseRecording() {
        guard isRecording, !isPaused, engine != nil else { return }
        // Keep the engine (and mic IO) running and only suspend file writes:
        // iOS refuses to restart input IO from the background, so stopping IO
        // here would make resume impossible from the lock screen Live Activity.
        sharedState.withLock { $0.isWritingSuspended = true }
        isPaused = true
        stopUITimer()
        debugLog("⏸ [AudioRecordingService] Paused")
    }

    @discardableResult
    func resumeRecording() -> Bool {
        guard isRecording, isPaused, let eng = engine else { return false }
        if !eng.isRunning {
            // Engine actually stopped (e.g. after an interruption) — needs a
            // real IO restart, which only works in the foreground.
            do {
                try prepareRecordingSessionForCapture()
                try eng.start()
            } catch {
                debugLog("❌ [AudioRecordingService] Resume failed: \(error)")
                return false
            }
        }
        sharedState.withLock { $0.isWritingSuspended = false }
        isPaused = false
        startUITimer()
        debugLog("▶️ [AudioRecordingService] Resumed")
        return true
    }

    // MARK: UI timer (single 10 Hz tick)

    private func startUITimer() {
        stopUITimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickUIFromSharedState()
            }
        }
    }

    private func stopUITimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: Private helpers

    private func prepareRecordingSessionForCapture() throws {
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true)
        #elseif targetEnvironment(macCatalyst)
        try audioSession.setCategory(.playAndRecord, mode: .default,
                                     options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)
        #endif
    }

    private func warmInputRoute() {
        let warmupEngine = AVAudioEngine()
        _ = warmupEngine.inputNode.outputFormat(forBus: 0)
        warmupEngine.prepare()
    }

    /// Called from the real-time audio tap thread. NOT @MainActor.
    private nonisolated func processTapBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        writeTargets.withLock { targets in
            guard let file = targets.file, let converter = targets.converter else { return }
            processWritableBuffer(inputBuffer, inputFormat: inputFormat, outputFormat: outputFormat,
                                  file: file, converter: converter)
        }
    }

    private nonisolated func processWritableBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        file: AVAudioFile,
        converter: AVAudioConverter
    ) {
        guard inputBuffer.frameLength > 0 else { return }
        guard !sharedState.withLock({ $0.isWritingSuspended }) else { return }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(inputBuffer.frameLength) * ratio).rounded(.up) + 16
        )
        guard outputFrameCapacity > 0,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: outputFrameCapacity
              ) else { return }

        // Block-based convert is required for sample-rate conversion.
        // The simple convert(to:from:) form asserts outputCapacity >= inputLength,
        // which is impossible when downsampling (e.g. 48 kHz → 16 kHz).
        var nsError: NSError?
        var provided = false
        let status = converter.convert(to: outputBuffer, error: &nsError) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || nsError != nil {
            return
        }
        guard outputBuffer.frameLength > 0 else { return }

        let wroteFrames: AVAudioFramePosition
        do {
            try file.write(from: outputBuffer)
            wroteFrames = AVAudioFramePosition(outputBuffer.frameLength)
        } catch {
            // Non-fatal: a dropped frame is preferable to a crash on the audio thread
            wroteFrames = 0
        }

        let rms = computeRMS(outputBuffer)

        sharedState.withLock { state in
            state.framePosition += wroteFrames
            state.latestLevel = rms
        }
    }

    /// Average Float32 channels before sample-rate conversion. Supports both
    /// planar engine buffers and interleaved input without dropping a channel.
    nonisolated static func mixedDownToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.channelCount > 0,
              let source = buffer.floatChannelData else { return nil }
        if buffer.format.channelCount == 1, !buffer.format.isInterleaved { return buffer }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else { return nil }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = vDSP_Stride(buffer.format.isInterleaved ? channels : 1)
        var scale = 1 / Float(channels)
        vDSP_vsmul(source[0], stride, &scale, destination, 1, frames)
        for channel in 1..<channels {
            let input = buffer.format.isInterleaved ? source[0].advanced(by: channel) : source[channel]
            vDSP_vsma(input, stride, &scale, destination, 1, destination, 1, frames)
        }
        mono.frameLength = buffer.frameLength
        return mono
    }

    private nonisolated func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = vDSP_Length(buffer.frameLength)
        guard count > 0 else { return 0 }

        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, count)
        return rms
    }

    /// Pull-model UI tick: runs on MainActor at 10 Hz.
    /// Only publishes the duration; the waveform pulls the raw level itself
    /// via peekAudioLevel() at its own render cadence.
    private func tickUIFromSharedState() {
        let framePosition = sharedState.withLock { $0.framePosition }
        recordingDuration = Double(framePosition) / 16000.0
    }

    nonisolated static func makePCMTemporaryURL(now: Date = Date()) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voicely_rec_\(Int(now.timeIntervalSince1970))_\(UUID().uuidString).caf")
    }

    // MARK: PCM (CAF) → M4A conversion

    private nonisolated static func convertCAFToM4A(from cafURL: URL, to m4aURL: URL) async throws {
        let asset = AVURLAsset(url: cafURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        exportSession.outputURL = m4aURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        if let error = exportSession.error {
            throw error
        }
    }
}
