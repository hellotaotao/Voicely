//
//  AudioRecordingService.swift
//  WhisperNotes
//
//  Created by Tao Wang on 1/6/2025.
//

import Foundation
import AVFoundation
import Combine

@MainActor
class AudioRecordingService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var hasPermission = false
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private var audioSession = AVAudioSession.sharedInstance()
    
    override init() {
        super.init()
        checkPermission()
    }
    
    func checkPermission() {
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
    
    func startRecording() -> String? {
        guard hasPermission else {
            checkPermission()
            return nil
        }
        
        do {
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
            return nil
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            isRecording = true
            recordingDuration = 0
            
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateRecordingDuration()
            }
            
            return audioFilename.path
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
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        let filePath = recorder.url.path
        let duration = recordingDuration
        
        do {
            try audioSession.setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        
        return (filePath, duration)
    }
    
    private func updateRecordingDuration() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recordingDuration = recorder.currentTime
    }
}

extension AudioRecordingService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("Recording encode error: \(error)")
        }
    }
}