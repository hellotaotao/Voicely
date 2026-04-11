//
//  AudioRecordingService.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import os

@MainActor
class AudioRecordingService: ObservableObject {

    // MARK: Published state (same public interface as before)

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var hasPermission = false
    @Published var audioLevel: Float = 0.0

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
    }
    private let sharedState = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    private var engine: AVAudioEngine?
    private nonisolated(unsafe) var audioFile: AVAudioFile?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private var recordingTimer: Timer?
    private var pendingM4AURL: URL?

    #if !os(macOS) || targetEnvironment(macCatalyst)
    private var audioSession = AVAudioSession.sharedInstance()
    #endif

    // MARK: Init

    init() {
        checkPermission()
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

    // MARK: Start Recording

    /// Starts recording. Returns the M4A filename (last path component) for cross-device compat.
    func startRecording() -> String? {
        guard hasPermission else {
            checkPermission()
            return nil
        }

        #if !os(macOS) && !targetEnvironment(macCatalyst)
        do {
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            debugLog("❌ [AudioRecordingService] Audio session setup failed: \(error)")
            return nil
        }
        #elseif targetEnvironment(macCatalyst)
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
        } catch {
            debugLog("❌ [AudioRecordingService] Audio session (Catalyst) setup failed: \(error)")
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

        let newEngine = AVAudioEngine()
        engine = newEngine
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        currentPCMFileURL = pcmURL
        sharedState.withLock { state in
            state.framePosition = 0
            state.latestLevel = 0
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer, inputFormat: inputFormat, outputFormat: targetFormat)
        }

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

        isRecording = true
        isPaused = false
        recordingDuration = 0
        audioLevel = 0.0

        startUITimer()

        debugLog("✅ [AudioRecordingService] Recording started → \(m4aURL.lastPathComponent)")
        return m4aURL.lastPathComponent
    }

    // MARK: Stop Recording

    /// Stops recording synchronously (engine stop + UI state update).
    /// Kicks off PCM→M4A conversion in the background.
    /// Returns the M4A filename and recorded duration immediately.
    func stopRecording() -> (String?, TimeInterval) {
        guard isRecording, let eng = engine else { return (nil, 0) }

        eng.inputNode.removeTap(onBus: 0)
        eng.stop()
        engine = nil

        audioFile = nil   // Close the write handle

        stopUITimer()

        isRecording = false
        isPaused = false
        audioLevel = 0.0

        let duration = recordingDuration
        let m4aFilename = pendingM4AURL?.lastPathComponent

        #if !os(macOS) && !targetEnvironment(macCatalyst)
        try? audioSession.setActive(false)
        #elseif targetEnvironment(macCatalyst)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // Kick off conversion in the background
        if let pcmURL = currentPCMFileURL, let m4aURL = pendingM4AURL {
            Task { [weak self] in
                do {
                    try await self?.convertCAFToM4A(from: pcmURL, to: m4aURL)
                    try? FileManager.default.removeItem(at: pcmURL)
                    debugLog("✅ [AudioRecordingService] M4A conversion complete → \(m4aURL.lastPathComponent)")
                } catch {
                    debugLog("❌ [AudioRecordingService] M4A conversion failed: \(error)")
                    // Keep the CAF file as backup — user's audio is not lost
                }
            }
        }

        currentPCMFileURL = nil
        pendingM4AURL = nil

        debugLog("✅ [AudioRecordingService] Recording stopped. Duration: \(duration)s")
        return (m4aFilename, duration)
    }

    // MARK: Pause / Resume

    func pauseRecording() {
        guard isRecording, !isPaused, let eng = engine else { return }
        eng.pause()
        isPaused = true
        stopUITimer()
        audioLevel = 0.0
        debugLog("⏸ [AudioRecordingService] Paused")
    }

    func resumeRecording() {
        guard isRecording, isPaused, let eng = engine else { return }
        do {
            try eng.start()
            isPaused = false
            startUITimer()
            debugLog("▶️ [AudioRecordingService] Resumed")
        } catch {
            debugLog("❌ [AudioRecordingService] Resume failed: \(error)")
        }
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

    /// Called from the real-time audio tap thread. NOT @MainActor.
    private nonisolated func processTapBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        guard let converter else { return }
        guard inputBuffer.frameLength > 0 else { return }

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
        }
    }

    private nonisolated func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return (sum / Float(count)).squareRoot()
    }

    /// Pull-model UI tick: runs on MainActor at 10 Hz.
    /// Reads shared state once under the lock, then updates @Published properties.
    private func tickUIFromSharedState() {
        let snapshot = sharedState.withLock { ($0.framePosition, $0.latestLevel) }
        recordingDuration = Double(snapshot.0) / 16000.0

        let normalised = min(Float(1.0), snapshot.1 * 10)
        let smoothed = audioLevel * 0.3 + normalised * 0.7
        audioLevel = smoothed < 0.04 ? 0 : smoothed
    }

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

