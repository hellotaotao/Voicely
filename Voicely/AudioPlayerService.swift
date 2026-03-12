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
    @Published private(set) var isPreparingAudio = false
    @Published private(set) var playbackStatusMessage: String?
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var pendingFilePath: String?
    private var preloadTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        print("🔍 [DEBUG] AudioPlayerService: Setting up audio session for playback...")
        do {
            print("🔍 [DEBUG] Setting category to .playback, mode: .default")
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            print("🔍 [DEBUG] Activating audio session...")
            try AVAudioSession.sharedInstance().setActive(true)
            print("✅ [DEBUG] Audio playback session activated successfully")
            print("🔍 [DEBUG] Audio session category: \(AVAudioSession.sharedInstance().category)")
        } catch {
            print("❌ [DEBUG] Failed to setup audio session: \(error)")
            print("❌ [DEBUG] This could cause 'cannot add handler' warnings")
        }
    }
    
    @MainActor
    func loadAudio(from filePath: String, expectedDuration: TimeInterval? = nil) {
        print("🔍 [DEBUG] AudioPlayerService: Loading audio from: \(filePath)")

        preloadTask?.cancel()
        prepareTask?.cancel()
        discardLoadedPlayer()

        pendingFilePath = filePath.isEmpty ? nil : filePath
        duration = expectedDuration ?? 0
        playbackStatusMessage = nil
        isPreparingAudio = false

        guard let pendingFilePath else {
            return
        }

        preloadTask = Task { @MainActor [weak self] in
            await self?.prefetchAudioForCurrentSelection(filePath: pendingFilePath)
        }
    }
    
    func play() {
        if let player = audioPlayer {
            if !player.isPlaying {
                player.play()
                isPlaying = true
                startTimer()
            }
            return
        }

        guard !isPreparingAudio else { return }
        guard pendingFilePath != nil else { return }

        prepareTask?.cancel()
        prepareTask = Task { @MainActor [weak self] in
            await self?.prepareAndPlayCurrentSelection()
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
        preloadTask?.cancel()
        prepareTask?.cancel()
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

private extension AudioPlayerService {
    @MainActor
    func prefetchAudioForCurrentSelection(filePath: String) async {
        guard pendingFilePath == filePath else { return }

        guard let url = CloudStorageManager.shared.getFileURL(for: filePath) else {
            print("❌ [DEBUG] Failed to get file URL for: \(filePath)")
            if pendingFilePath == filePath {
                playbackStatusMessage = "Audio file unavailable."
            }
            return
        }

        print("🔍 [DEBUG] Audio file URL: \(url.path)")

        if FileManager.default.fileExists(atPath: url.path) {
            print("✅ [DEBUG] Audio file exists at path")
        } else {
            print("⚠️ [DEBUG] Audio file NOT found at path - may need iCloud download")
        }

        CloudStorageManager.shared.startDownloadingFromCloud(url: url)

        guard pendingFilePath == filePath else { return }

        if CloudStorageManager.shared.isFileReadyForPlayback(at: url) {
            playbackStatusMessage = nil
        } else {
            playbackStatusMessage = "Audio is downloading from iCloud. Playback will start after the file becomes available."
        }
    }

    @MainActor
    func prepareAndPlayCurrentSelection() async {
        guard let filePath = pendingFilePath else { return }

        isPreparingAudio = true
        playbackStatusMessage = "Preparing audio..."

        defer {
            if pendingFilePath == filePath {
                isPreparingAudio = false
            }
            prepareTask = nil
        }

        guard let url = await CloudStorageManager.shared.prepareFileForReading(at: filePath) else {
            guard pendingFilePath == filePath else { return }
            playbackStatusMessage = "Audio is still downloading from iCloud."
            return
        }

        guard !Task.isCancelled, pendingFilePath == filePath else { return }

        do {
            print("🔍 [DEBUG] Creating AVAudioPlayer...")
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.enableRate = true
            player.rate = playbackRate

            audioPlayer = player
            duration = player.duration
            currentTime = 0
            playbackStatusMessage = nil

            print("✅ [DEBUG] AVAudioPlayer created successfully")
            print("🔍 [DEBUG] Audio duration: \(duration) seconds")
            print("🔍 [DEBUG] Audio format: \(player.format.description)")

            player.play()
            isPlaying = true
            startTimer()
        } catch {
            print("❌ [DEBUG] Failed to load audio: \(error)")
            print("❌ [DEBUG] Error code: \((error as NSError).code)")
            if (error as NSError).code == 257 {
                print("❌ [DEBUG] Permission denied (Error 257) - iCloud file access issue")
                playbackStatusMessage = "Audio is still downloading from iCloud."
            } else {
                playbackStatusMessage = "Couldn't open this recording for playback."
            }
        }
    }

    @MainActor
    func discardLoadedPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        stopTimer()
    }
}
