//
//  AudioRecordingService.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

@preconcurrency import AVFoundation
import Combine
import Foundation

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
    /// Updated from the audio tap thread; may lag slightly.
    nonisolated(unsafe) private(set) var currentFramePosition: AVAudioFramePosition = 0

    // MARK: Private

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
        currentFramePosition = 0

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

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateDurationFromFrames()
            }
        }

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

        recordingTimer?.invalidate()
        recordingTimer = nil

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
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioLevel = 0.0
        debugLog("⏸ [AudioRecordingService] Paused")
    }

    func resumeRecording() {
        guard isRecording, isPaused, let eng = engine else { return }
        do {
            try eng.start()
            isPaused = false
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updateDurationFromFrames()
                }
            }
            debugLog("▶️ [AudioRecordingService] Resumed")
        } catch {
            debugLog("❌ [AudioRecordingService] Resume failed: \(error)")
        }
    }

    // MARK: Private helpers

    /// Called from the real-time audio tap thread. NOT @MainActor.
    private nonisolated func processTapBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        guard let converter else { return }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        do {
            try converter.convert(to: outputBuffer, from: inputBuffer)
        } catch {
            return
        }

        guard outputBuffer.frameLength > 0 else { return }

        do {
            try audioFile?.write(from: outputBuffer)
            currentFramePosition += AVAudioFramePosition(outputBuffer.frameLength)
        } catch {
            // Non-fatal: a dropped frame is preferable to a crash on the audio thread
        }

        updateAudioLevelFromBuffer(outputBuffer)
    }

    private nonisolated func updateAudioLevelFromBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = (sum / Float(count)).squareRoot()
        let normalised = min(1.0, rms * 10)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioLevel = self.audioLevel * 0.1 + normalised * 0.9
            if self.audioLevel < 0.04 { self.audioLevel = 0 }
        }
    }

    private func updateDurationFromFrames() {
        recordingDuration = Double(currentFramePosition) / 16000.0
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

