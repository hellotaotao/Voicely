//
//  AudioPlayerService.swift
//  Voicely
//
//  Created by Tao Wang on 16/6/2025.
//

import Foundation
import AVFoundation
import Combine

class AudioPlayerService: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    func loadAudio(from filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.enableRate = true
            duration = audioPlayer?.duration ?? 0
            currentTime = 0
        } catch {
            print("Failed to load audio: \(error)")
        }
    }
    
    func play() {
        guard let player = audioPlayer else { return }
        
        if !player.isPlaying {
            player.play()
            isPlaying = true
            startTimer()
        }
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seekBackward(seconds: TimeInterval = 5) {
        guard let player = audioPlayer else { return }
        let newTime = max(0, player.currentTime - seconds)
        seek(to: newTime)
    }
    
    func seekForward(seconds: TimeInterval = 5) {
        guard let player = audioPlayer else { return }
        let newTime = min(player.duration, player.currentTime + seconds)
        seek(to: newTime)
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        audioPlayer?.rate = rate
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateCurrentTime()
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateCurrentTime() {
        if let player = audioPlayer {
            currentTime = player.currentTime
        }
    }
    
    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        currentTime = 0
        stopTimer()
    }
    
    deinit {
        stop()
    }
}

extension AudioPlayerService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = 0
        stopTimer()
    }
}
