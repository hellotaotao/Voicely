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
    /// True while a recording is capturing only exact-zero samples (dead input) —
    /// shown to the user so a silent mic is visible immediately, not after the fact.
    @Published private(set) var inputAppearsSilent = false

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
        /// Frame position of the most recent buffer with real signal. A live mic
        /// always carries noise floor, so a growing gap of exact zeros means the
        /// input died (or never lived) — drives the user-facing warning banner.
        var lastSignalFrame: AVAudioFramePosition = 0
    }
    private let sharedState = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    /// The file and converter the real-time tap writes through. Guarded by a lock
    /// because the MainActor tears them down (stop, engine rebind) while a buffer
    /// may still be in flight on the audio thread: `removeTap` is not a documented
    /// barrier, so unsynchronized access was a data race. The tap copies both
    /// references out under the lock, which also keeps them alive for the duration
    /// of its write.
    private struct AudioWriteTargets: @unchecked Sendable {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
    }
    private let writeTargets = OSAllocatedUnfairLock<AudioWriteTargets>(
        initialState: AudioWriteTargets()
    )

    private var engine: AVAudioEngine?
    private var recordingTimer: Timer?
    private var pendingM4AURL: URL?
    private var prewarmTask: Task<Void, Never>?
    private var isRecordingSessionPrewarmed = false
    private var activeTargetFormat: AVAudioFormat?

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

        currentPCMFileURL = pcmURL
        activeTargetFormat = targetFormat
        inputAppearsSilent = false
        sharedState.withLock { state in
            state.framePosition = 0
            state.latestLevel = 0
            state.isWritingSuspended = false
            state.lastSignalFrame = 0
        }

        let newEngine = AVAudioEngine()
        engine = newEngine
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

#if DEBUG
        logInputRouteDiagnostics(inputFormat: inputFormat)
#endif

        // AVAudioConverter's implicit channel-count reduction (stereo USB mic →
        // mono) silently produces all-zero output on Mac Catalyst, while mono
        // inputs (iPhone mic, AirPods) work — the root cause of the "DJI
        // records silence on Mac" bug. Mix down to mono ourselves and let the
        // converter do pure sample-rate conversion.
        let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let newConverter = AVAudioConverter(from: monoInputFormat, to: targetFormat)
        writeTargets.withLock { $0.converter = newConverter }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let mono = Self.mixedDownToMono(buffer, format: monoInputFormat) else { return }
            self?.processTapBuffer(mono, inputFormat: monoInputFormat, outputFormat: targetFormat)
        }
        newEngine.prepare()

        do {
            try newEngine.start()
        } catch {
            debugLog("❌ [AudioRecordingService] Engine start failed: \(error)")
            inputNode.removeTap(onBus: 0)
            engine = nil
            writeTargets.withLock { $0.file = nil }
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
        guard isRecording else {
            return RecordingStopResult(filePath: nil, duration: 0)
        }

        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            engine = nil
        }
        // Drop both together so an in-flight buffer can never see a half-torn-down
        // pair; the tap's copy keeps the file alive until its write returns.
        writeTargets.withLock {
            $0.converter = nil
            $0.file = nil   // Close the write handle
        }

        stopUITimer()

        isRecording = false
        isPaused = false
        inputAppearsSilent = false

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
        let (audioFile, converter) = writeTargets.withLock { ($0.file, $0.converter) }
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
                state.lastSignalFrame = state.framePosition
            }
        }
    }

    /// Temporary PCM path for one recording. The nonce keeps a stop→restart
    /// inside the same wall-clock second from reusing the previous recording's
    /// path: `AVAudioFile(forWriting:)` would truncate it, and the finished
    /// recording's deferred cleanup would delete the new one's audio.
    nonisolated static func makePCMTemporaryURL(now: Date = Date()) -> URL {
        let nonce = UUID().uuidString.prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely_rec_\(Int(now.timeIntervalSince1970))_\(nonce).caf")
    }

    /// Averages all channels of a Float32 deinterleaved buffer into a new mono
    /// buffer at the same sample rate.
    private nonisolated static func mixedDownToMono(
        _ buffer: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
              buffer.frameLength > 0,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0]
        else { return nil }

        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            memcpy(dst, src[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        } else {
            var scale = Float(1) / Float(channels)
            vDSP_vsmul(src[0], 1, &scale, dst, 1, frames)
            for ch in 1..<channels {
                vDSP_vsma(src[ch], 1, &scale, dst, 1, dst, 1, frames)
            }
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

        // User-facing banner: 3 s of exact zeros means the input is dead (a live
        // mic always has noise floor), whether it never delivered or died mid-way.
        let silentNow = sharedState.withLock { state in
            state.framePosition - state.lastSignalFrame >= 48_000   // 3 s @ 16 kHz
        }
        let showWarning = isRecording && !isPaused && silentNow
        if inputAppearsSilent != showWarning {
            inputAppearsSilent = showWarning
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

    // MARK: PCM (CAF) → M4A conversion

    private func convertCAFToM4A(from cafURL: URL, to m4aURL: URL) async throws {
        let asset = AVURLAsset(url: cafURL)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // iOS 18 / Catalyst 18 replacement for the deprecated
        // outputURL + outputFileType + export() + .error dance. Throws on
        // failure directly. (Main app deploys to iOS 18 / macOS 15, so no
        // availability fallback is needed.)
        try await exportSession.export(to: m4aURL, as: .m4a)
    }
}
