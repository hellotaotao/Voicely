//
//  AudioRecordingService.swift
//  Voicely
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import AVFoundation
import Combine

#if os(macOS)
import AVFoundation
#endif

@MainActor
class AudioRecordingService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var hasPermission = false
    @Published var audioLevel: Float = 0.0  // Audio level for waveform visualization
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    #if !os(macOS) || targetEnvironment(macCatalyst)
    private var audioSession = AVAudioSession.sharedInstance()
    #endif
    
    override init() {
        super.init()
        checkPermission()
    }
    
    func checkPermission() {
        #if targetEnvironment(macCatalyst)
        // For Mac Catalyst, we need to request microphone permission
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            hasPermission = true
        case .denied:
            hasPermission = false
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] allowed in
                DispatchQueue.main.async {
                    self?.hasPermission = allowed
                }
            }
        @unknown default:
            hasPermission = false
        }
        #elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermission = true
        case .denied, .restricted:
            hasPermission = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    self?.hasPermission = allowed
                }
            }
        @unknown default:
            hasPermission = false
        }
        #else
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                hasPermission = true
            case .denied:
                hasPermission = false
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async {
                        self?.hasPermission = allowed
                    }
                }
            @unknown default:
                hasPermission = false
            }
        } else {
            switch audioSession.recordPermission {
            case .granted:
                hasPermission = true
            case .denied:
                hasPermission = false
            case .undetermined:
                audioSession.requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async {
                        self?.hasPermission = allowed
                    }
                }
            @unknown default:
                hasPermission = false
            }
        }
        #endif
    }
    
    func startRecording() -> String? {
        guard hasPermission else {
            checkPermission()
            return nil
        }
        
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        print("🔍 [DEBUG] Setting up audio session for iOS...")
        do {
            print("🔍 [DEBUG] Setting category to .record, mode: .default")
            try audioSession.setCategory(.record, mode: .default)
            print("🔍 [DEBUG] Activating audio session...")
            try audioSession.setActive(true)
            print("✅ [DEBUG] Audio session activated successfully")
            print("🔍 [DEBUG] Audio session category: \(audioSession.category)")
            print("🔍 [DEBUG] Audio session mode: \(audioSession.mode)")
            print("🔍 [DEBUG] Audio session sample rate: \(audioSession.sampleRate) Hz")
            print("🔍 [DEBUG] Audio session input channels: \(audioSession.inputNumberOfChannels)")
        } catch {
            print("❌ [DEBUG] Failed to set up audio session: \(error)")
            print("❌ [DEBUG] Error code: \((error as NSError).code)")
            print("❌ [DEBUG] Error domain: \((error as NSError).domain)")
            return nil
        }
        #elseif targetEnvironment(macCatalyst)
        // For Mac Catalyst, we need to set up audio session differently
        print("🔍 [DEBUG] Setting up audio session for Mac Catalyst...")
        do {
            print("🔍 [DEBUG] Setting category to .playAndRecord with options")
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            print("🔍 [DEBUG] Activating audio session...")
            try audioSession.setActive(true)
            print("✅ [DEBUG] Audio session activated successfully for Mac Catalyst")
            print("🔍 [DEBUG] Audio session category: \(audioSession.category)")
            print("🔍 [DEBUG] Audio session mode: \(audioSession.mode)")
        } catch {
            print("❌ [DEBUG] Failed to set up audio session for Mac Catalyst: \(error)")
            print("❌ [DEBUG] This could be related to 'cannot add handler' warnings")
            return nil
        }
        #else
        print("🔍 [DEBUG] Running on macOS - audio session setup not required")
        #endif
        
        let audioFilename = CloudStorageManager.shared.generateAudioFilename()
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        
        print("🔍 [DEBUG] Creating AVAudioRecorder with settings:")
        print("🔍 [DEBUG]   - Format: MPEG4AAC")
        print("🔍 [DEBUG]   - Sample Rate: 16000 Hz")
        print("🔍 [DEBUG]   - Channels: 1 (mono)")
        print("🔍 [DEBUG]   - Quality: medium")
        print("🔍 [DEBUG]   - Output file: \(audioFilename.lastPathComponent)")
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true  // Enable audio level metering
            
            print("✅ [DEBUG] AVAudioRecorder created successfully")
            print("🔍 [DEBUG] Starting recording...")
            
            let success = audioRecorder?.record() ?? false
            if !success {
                print("❌ [DEBUG] Failed to start recording - record() returned false")
                return nil
            }
            
            print("✅ [DEBUG] Recording started successfully")
            
            isRecording = true
            isPaused = false
            recordingDuration = 0
            audioLevel = 0.0
            
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updateRecordingDuration()
                    self?.updateAudioLevel()
                }
            }
            
            print("Recording started successfully at: \(audioFilename.path)")
            // Return only the filename for cross-device compatibility
            return audioFilename.lastPathComponent
        } catch {
            print("Failed to start recording: \(error)")
            return nil
        }
    }
    
    func stopRecording() -> (String?, TimeInterval) {
        guard isRecording, let recorder = audioRecorder else {
            return (nil, 0)
        }
        
        recorder.stop()
        isRecording = false
        isPaused = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioLevel = 0.0
        
        // Store only filename for cross-device compatibility
        let filePath = recorder.url.lastPathComponent
        let duration = recordingDuration
        
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        do {
            try audioSession.setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        #elseif targetEnvironment(macCatalyst)
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session for Mac Catalyst: \(error)")
        }
        #endif
        
        print("Recording stopped. File saved at: \(filePath)")
        return (filePath, duration)
    }
    
    func pauseRecording() {
        guard isRecording, !isPaused, let recorder = audioRecorder else { return }
        
        recorder.pause()
        isPaused = true
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioLevel = 0.0
        
        print("Recording paused")
    }
    
    func resumeRecording() {
        guard isRecording, isPaused, let recorder = audioRecorder else { return }
        
        let success = recorder.record()
        if success {
            isPaused = false
            
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updateRecordingDuration()
                    self?.updateAudioLevel()
                }
            }
            
            print("Recording resumed")
        } else {
            print("Failed to resume recording")
        }
    }
    
    private func updateRecordingDuration() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recordingDuration = recorder.currentTime
    }
    
    private func updateAudioLevel() {
        guard let recorder = audioRecorder, recorder.isRecording, !isPaused else { 
            audioLevel = 0.0
            return 
        }
        
        recorder.updateMeters()
        let level = recorder.averagePower(forChannel: 0)
        
        // Convert dB to linear scale (0.0 to 1.0)
        // Use a more sensitive threshold for better responsiveness
        let minDb: Float = -50.0  // More sensitive threshold
        let maxDb: Float = 0.0
        
        let normalizedLevel = max(0.0, min(1.0, (level - minDb) / (maxDb - minDb)))
        
        // Apply different smoothing based on whether sound is increasing or decreasing
        if normalizedLevel > audioLevel {
            // Fast response when sound increases
            let fastSmoothingFactor: Float = 0.9
            audioLevel = audioLevel * (1.0 - fastSmoothingFactor) + normalizedLevel * fastSmoothingFactor
        } else {
            // Very fast decay when sound decreases
            let decaySmoothingFactor: Float = 0.9
            audioLevel = audioLevel * (1.0 - decaySmoothingFactor) + normalizedLevel * decaySmoothingFactor
        }
        
        // Quick cutoff for very quiet sounds
        if audioLevel < 0.04 {
            audioLevel = 0.0
        }
    }
}

extension AudioRecordingService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording encode error: \(error)")
        }
    }
}

