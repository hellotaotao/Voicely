//
//  AudioPlayerService.swift
//  Voicely
//
//  Created by Tao Wang on 16/6/2025.
//

import Foundation
import AVFoundation
import Combine

@MainActor
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
    #if !os(macOS) || targetEnvironment(macCatalyst)
    private let audioSession = AVAudioSession.sharedInstance()
    private var isAudioSessionActive = false
    #endif
    
    override init() {
        super.init()
    }
    
    private func activateAudioSessionIfNeeded() -> Bool {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        return true
        #else
        guard !isAudioSessionActive else {
            return true
        }

        debugLog("🔍 [DEBUG] AudioPlayerService: Setting up audio session for playback...")
        do {
            debugLog("🔍 [DEBUG] Setting category to .playback, mode: .default")
            try audioSession.setCategory(.playback, mode: .default)
            debugLog("🔍 [DEBUG] Activating audio session...")
            try audioSession.setActive(true)
            isAudioSessionActive = true
            debugLog("✅ [DEBUG] Audio playback session activated successfully")
            debugLog("🔍 [DEBUG] Audio session category: \(audioSession.category)")
            return true
        } catch {
            debugLog("❌ [DEBUG] Failed to setup audio session: \(error)")
            debugLog("❌ [DEBUG] This could cause 'cannot add handler' warnings")
            return false
        }
        #endif
    }

    private func deactivateAudioSessionIfNeeded() {
        #if !os(macOS) || targetEnvironment(macCatalyst)
        guard isAudioSessionActive else {
            return
        }

        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = false
        } catch {
            debugLog("❌ [DEBUG] Failed to deactivate audio session: \(error)")
        }
        #endif
    }
    
    @MainActor
    func loadAudio(from filePath: String, expectedDuration: TimeInterval? = nil) {
        debugLog("🔍 [DEBUG] AudioPlayerService: Loading audio from: \(filePath)")

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
                guard activateAudioSessionIfNeeded() else {
                    playbackStatusMessage = "Couldn't start audio playback."
                    return
                }

                if player.play() {
                    isPlaying = true
                    startTimer()
                } else {
                    playbackStatusMessage = "Couldn't start audio playback."
                    deactivateAudioSessionIfNeeded()
                }
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
        deactivateAudioSessionIfNeeded()
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
            MainActor.assumeIsolated {
                self?.updateCurrentTime()
            }
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
        deactivateAudioSessionIfNeeded()
    }
    
    deinit {
        preloadTask?.cancel()
        prepareTask?.cancel()
        audioPlayer?.stop()
        timer?.invalidate()
    }
}

extension AudioPlayerService: @preconcurrency AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = 0
        stopTimer()
        deactivateAudioSessionIfNeeded()
    }
}

private extension AudioPlayerService {
    @MainActor
    func prefetchAudioForCurrentSelection(filePath: String) async {
        guard pendingFilePath == filePath else { return }

        guard let url = CloudStorageManager.shared.getFileURL(for: filePath) else {
            debugLog("❌ [DEBUG] Failed to get file URL for: \(filePath)")
            if pendingFilePath == filePath {
                playbackStatusMessage = "Audio file unavailable."
            }
            return
        }

        debugLog("🔍 [DEBUG] Audio file URL: \(url.path)")

        if FileManager.default.fileExists(atPath: url.path) {
            debugLog("✅ [DEBUG] Audio file exists at path")
        } else {
            debugLog("⚠️ [DEBUG] Audio file NOT found at path - may need iCloud download")
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
        guard activateAudioSessionIfNeeded() else {
            playbackStatusMessage = "Couldn't start audio playback."
            return
        }

        do {
            debugLog("🔍 [DEBUG] Creating AVAudioPlayer...")
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.enableRate = true
            player.rate = playbackRate

            audioPlayer = player
            duration = player.duration
            currentTime = 0
            playbackStatusMessage = nil

            debugLog("✅ [DEBUG] AVAudioPlayer created successfully")
            debugLog("🔍 [DEBUG] Audio duration: \(duration) seconds")
            debugLog("🔍 [DEBUG] Audio format: \(player.format.description)")

            if player.play() {
                isPlaying = true
                startTimer()
            } else {
                playbackStatusMessage = "Couldn't start audio playback."
                deactivateAudioSessionIfNeeded()
            }
        } catch {
            debugLog("❌ [DEBUG] Failed to load audio: \(error)")
            debugLog("❌ [DEBUG] Error code: \((error as NSError).code)")
            deactivateAudioSessionIfNeeded()
            if (error as NSError).code == 257 {
                debugLog("❌ [DEBUG] Permission denied (Error 257) - iCloud file access issue")
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
        deactivateAudioSessionIfNeeded()
    }
}
