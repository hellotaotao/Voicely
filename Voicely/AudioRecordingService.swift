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

struct RecordingStopResult {
    let filePath: String?
    let duration: TimeInterval

    private let awaitConversion: (@Sendable () async -> Void)?

    init(
        filePath: String?,
        duration: TimeInterval,
        awaitConversion: (@Sendable () async -> Void)? = nil
    ) {
        self.filePath = filePath
        self.duration = duration
        self.awaitConversion = awaitConversion
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
        /// True once any tap buffer carried real signal (RMS above the noise
        /// floor). Stays false when the input is a dead/ghost device that
        /// delivers perfectly zeroed buffers — the silence watchdog keys off it.
        var hasSeenSignal = false
    }
    private let sharedState = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    private var engine: AVAudioEngine?
    #if targetEnvironment(macCatalyst)
    // Capture-stack recording (the path QuickTime uses). On Macs where the
    // session's default aggregate device wedges ("Abandoning I/O cycle because
    // reconfig pending"), AVAudioEngine taps deliver pure zeros no matter how
    // the engine is rebuilt; AVCaptureSession talks to the device directly.
    private var captureSession: AVCaptureSession?
    private var captureBridge: CaptureAudioBridge?
    private let captureQueue = DispatchQueue(label: "voicely.audio.capture")
    #endif
    private nonisolated(unsafe) var audioFile: AVAudioFile?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private var recordingTimer: Timer?
    private var pendingM4AURL: URL?
    private var prewarmTask: Task<Void, Never>?
    private var isRecordingSessionPrewarmed = false
    private var activeTargetFormat: AVAudioFormat?
    private var didAttemptSilenceRecovery = false

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
        #if targetEnvironment(macCatalyst)
        // The Mac records via AVCaptureSession (see startCaptureSessionRecording),
        // which needs no session/engine prewarm — recording simply starts cold.
        return
        #endif
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

        #if !targetEnvironment(macCatalyst)
        do {
            try prepareRecordingSessionForCapture()
            isRecordingSessionPrewarmed = false
        } catch {
            debugLog("❌ [AudioRecordingService] Audio session setup failed: \(error)")
            return nil
        }
        #endif

        let m4aURL = CloudStorageManager.shared.generateAudioFilename()
        let pcmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely_rec_\(Int(Date().timeIntervalSince1970)).caf")

        pendingM4AURL = m4aURL

        // Target format: 16 kHz Float32 mono (WhisperKit native)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        do {
            audioFile = try AVAudioFile(forWriting: pcmURL, settings: targetFormat.settings)
        } catch {
            debugLog("❌ [AudioRecordingService] Failed to create PCM file: \(error)")
            return nil
        }

        currentPCMFileURL = pcmURL
        activeTargetFormat = targetFormat
        didAttemptSilenceRecovery = false
        sharedState.withLock { state in
            state.framePosition = 0
            state.latestLevel = 0
            state.isWritingSuspended = false
            state.hasSeenSignal = false
        }

        #if targetEnvironment(macCatalyst)
        guard startCaptureSessionRecording(targetFormat: targetFormat) else {
            audioFile = nil
            currentPCMFileURL = nil
            return nil
        }
        #else
        let newEngine = AVAudioEngine()
        engine = newEngine
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

#if DEBUG
        logInputRouteDiagnostics(inputFormat: inputFormat)
#endif

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer, inputFormat: inputFormat, outputFormat: targetFormat)
        }
        newEngine.prepare()

        do {
            try newEngine.start()
        } catch {
            debugLog("❌ [AudioRecordingService] Engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            engine = nil
            audioFile = nil
            currentPCMFileURL = nil
            return nil
        }
        #endif

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
        guard isRecording else {
            return RecordingStopResult(filePath: nil, duration: 0)
        }

        #if targetEnvironment(macCatalyst)
        if let session = captureSession {
            // Sync on the delegate queue: after this no sample-buffer callback
            // can still be in flight, so closing the file below is safe.
            captureQueue.sync { session.stopRunning() }
            captureSession = nil
            captureBridge = nil
        }
        #endif
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            engine = nil
        }
        converter = nil

        audioFile = nil   // Close the write handle

        stopUITimer()

        isRecording = false
        isPaused = false

        let duration = recordingDuration
        let m4aFilename = pendingM4AURL?.lastPathComponent

        #if !os(macOS) && !targetEnvironment(macCatalyst)
        try? audioSession.setActive(false)
        #elseif targetEnvironment(macCatalyst)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRecordingSessionPrewarmed = false

        let conversionTask: Task<Void, Never>?
        if let pcmURL = currentPCMFileURL, let m4aURL = pendingM4AURL {
            conversionTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                do {
                    try await self.convertCAFToM4A(from: pcmURL, to: m4aURL)
                    try? FileManager.default.removeItem(at: pcmURL)
                    debugLog("✅ [AudioRecordingService] M4A conversion complete → \(m4aURL.lastPathComponent)")
                } catch {
                    debugLog("❌ [AudioRecordingService] M4A conversion failed: \(error)")
                    // Keep the CAF file as backup — user's audio is not lost
                }
            }
        } else {
            conversionTask = nil
        }

        currentPCMFileURL = nil
        pendingM4AURL = nil

        debugLog("✅ [AudioRecordingService] Recording stopped. Duration: \(duration)s")
        return RecordingStopResult(
            filePath: m4aFilename,
            duration: duration,
            awaitConversion: {
                await conversionTask?.value
            }
        )
    }

    // MARK: Pause / Resume

    func pauseRecording() {
        var hasLiveIO = engine != nil
        #if targetEnvironment(macCatalyst)
        hasLiveIO = hasLiveIO || captureSession != nil
        #endif
        guard isRecording, !isPaused, hasLiveIO else { return }
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
        guard isRecording, isPaused else { return false }
        #if targetEnvironment(macCatalyst)
        if captureSession != nil {
            // Capture session keeps running through pause (writes suspended only).
            sharedState.withLock { $0.isWritingSuspended = false }
            isPaused = false
            startUITimer()
            debugLog("▶️ [AudioRecordingService] Resumed")
            return true
        }
        #endif
        guard let eng = engine else { return false }
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
        // .record, not .playAndRecord: playAndRecord folds the default OUTPUT
        // device into the same CoreAudio aggregate as the input; a stuck
        // output-side reconfiguration then starves input IO ("Abandoning I/O
        // cycle because reconfig pending" → all-zero buffers). Input-only keeps
        // the aggregate clear of the output/virtual devices entirely.
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true)
        #endif
    }

    private func warmInputRoute() {
        let warmupEngine = AVAudioEngine()
        _ = warmupEngine.inputNode.outputFormat(forBus: 0)
        warmupEngine.prepare()
    }

#if DEBUG
    /// Dumps which input the audio session actually routed to — the Catalyst
    /// session can pick a different device than the system default (e.g. a
    /// silent virtual device like Teams/Immersed), which records pure silence.
    private func logInputRouteDiagnostics(inputFormat: AVAudioFormat) {
        #if !os(macOS) || targetEnvironment(macCatalyst)
        let inputs = audioSession.currentRoute.inputs
            .map { "\($0.portName) [\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        let available = (audioSession.availableInputs ?? [])
            .map { "\($0.portName) [\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        print("🎙️ route input: \(inputs.isEmpty ? "NONE" : inputs)")
        print("🎙️ available inputs: \(available.isEmpty ? "NONE" : available)")
        print("🎙️ preferred input: \(audioSession.preferredInput?.portName ?? "nil")")
        print("🎙️ session sampleRate=\(audioSession.sampleRate) permission=\(String(describing: AVAudioApplication.shared.recordPermission))")
        #endif
        print("🎙️ engine input format: \(inputFormat)")
    }
#endif

    /// Called from the real-time audio tap thread. NOT @MainActor.
    private nonisolated func processTapBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        guard let converter else { return }
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
            try audioFile?.write(from: outputBuffer)
            wroteFrames = AVAudioFramePosition(outputBuffer.frameLength)
        } catch {
            // Non-fatal: a dropped frame is preferable to a crash on the audio thread
            wroteFrames = 0
        }

        let rms = computeRMS(outputBuffer)

        sharedState.withLock { state in
            state.framePosition += wroteFrames
            state.latestLevel = rms
            if rms > 0.000001 {
                state.hasSeenSignal = true
            }
        }
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

        // Silence watchdog: buffers flowing but every sample zero for 2 s means
        // the engine is bound to a dead input (ghost CoreAudio device). Rebind
        // once — tear the engine down and rebuild against the current device.
        if isRecording, !isPaused, !didAttemptSilenceRecovery,
           recordingDuration >= 2.0,
           sharedState.withLock({ !$0.hasSeenSignal }) {
            didAttemptSilenceRecovery = true
            recoverFromSilentInput()
        }
#if DEBUG
        // Once per second: is the tap delivering real signal (level > 0) or
        // silence? level stuck at exactly 0 while speaking = dead input route.
        diagnosticTickCount += 1
        if diagnosticTickCount % 10 == 0 {
            let level = sharedState.withLock { $0.latestLevel }
            print("🎙️ t=\(String(format: "%.1f", recordingDuration))s level=\(String(format: "%.6f", level))")
        }
#endif
    }

#if DEBUG
    private var diagnosticTickCount = 0
#endif

    /// Rebinds capture after the watchdog saw 2 s of pure zeros: rebuild the
    /// engine against the *current* device (explicitly preferring the real USB
    /// input over any virtual one) and keep appending to the same PCM file.
    private func recoverFromSilentInput() {
        #if targetEnvironment(macCatalyst)
        if captureSession != nil {
            debugLog("⚠️ [AudioRecordingService] Capture path delivering silence — check the input device")
            return
        }
        #endif
        guard isRecording, let targetFormat = activeTargetFormat else { return }
        debugLog("🔄 [AudioRecordingService] 2 s of pure silence — rebinding audio engine to current input")

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        #if !os(macOS) || targetEnvironment(macCatalyst)
        try? audioSession.setActive(false)
        #endif
        do {
            try prepareRecordingSessionForCapture()
        } catch {
            debugLog("❌ [AudioRecordingService] Silence recovery: session setup failed: \(error)")
            return
        }
        #if !os(macOS) || targetEnvironment(macCatalyst)
        let realInput = audioSession.availableInputs?.first { $0.portType == .usbAudio }
            ?? audioSession.availableInputs?.first
        if let realInput {
            try? audioSession.setPreferredInput(realInput)
            debugLog("🔄 [AudioRecordingService] preferred input → \(realInput.portName)")
        }
        #endif

        let newEngine = AVAudioEngine()
        engine = newEngine
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
#if DEBUG
        logInputRouteDiagnostics(inputFormat: inputFormat)
#endif
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer, inputFormat: inputFormat, outputFormat: targetFormat)
        }
        newEngine.prepare()
        do {
            try newEngine.start()
            debugLog("🔄 [AudioRecordingService] Engine rebound and restarted")
        } catch {
            debugLog("❌ [AudioRecordingService] Silence recovery: engine restart failed: \(error)")
        }
    }

    #if targetEnvironment(macCatalyst)
    // MARK: AVCaptureSession recording (Mac)

    private func startCaptureSessionRecording(targetFormat: AVAudioFormat) -> Bool {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            debugLog("❌ [AudioRecordingService] No default audio capture device")
            return false
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                debugLog("❌ [AudioRecordingService] Cannot add capture input")
                return false
            }
            session.addInput(input)
        } catch {
            debugLog("❌ [AudioRecordingService] Capture input failed: \(error)")
            return false
        }

        let output = AVCaptureAudioDataOutput()
        let bridge = CaptureAudioBridge { [weak self] sampleBuffer in
            self?.handleCaptureSampleBuffer(sampleBuffer, outputFormat: targetFormat)
        }
        output.setSampleBufferDelegate(bridge, queue: captureQueue)
        guard session.canAddOutput(output) else {
            debugLog("❌ [AudioRecordingService] Cannot add capture output")
            return false
        }
        session.addOutput(output)
        session.commitConfiguration()

        captureBridge = bridge
        captureSession = session
        // startRunning blocks until IO is up — keep it off the main thread.
        captureQueue.async { session.startRunning() }
        debugLog("🎥 [AudioRecordingService] Capture recording from: \(device.localizedName)")
        return true
    }

    /// Runs on `captureQueue`. Converts each CMSampleBuffer to PCM and feeds the
    /// same convert-and-write pipeline the engine tap uses.
    private nonisolated func handleCaptureSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        outputFormat: AVAudioFormat
    ) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                         frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        pcm.frameLength = AVAudioFrameCount(numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(numSamples),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        // Lazily built from the first buffer's real format; captureQueue is
        // serial, and stopRecording drains it before clearing the converter.
        if converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        processTapBuffer(pcm, inputFormat: inputFormat, outputFormat: outputFormat)
    }
    #endif

    // MARK: PCM (CAF) → M4A conversion

    private func convertCAFToM4A(from cafURL: URL, to m4aURL: URL) async throws {
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

#if targetEnvironment(macCatalyst)
/// Forwards AVCaptureAudioDataOutput sample buffers to a closure. A separate
/// NSObject because the delegate protocol requires one and the service is a
/// MainActor ObservableObject.
private final class CaptureAudioBridge: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onSampleBuffer: (CMSampleBuffer) -> Void

    init(onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSampleBuffer(sampleBuffer)
    }
}
#endif
