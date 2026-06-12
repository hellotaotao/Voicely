//
//  AudioPlayerService.swift
//  Voicely
//
//  Created by Tao Wang on 16/6/2025.
//

import Foundation
import AVFoundation
import Combine

struct PendingSeekState {
    private(set) var pendingTime: TimeInterval?

    mutating func storePendingSeek(_ requestedTime: TimeInterval, fallbackDuration: TimeInterval) -> TimeInterval {
        let normalizedTime = Self.normalize(requestedTime, duration: fallbackDuration)
        pendingTime = normalizedTime
        return normalizedTime
    }

    mutating func consumePendingSeek(preparedDuration: TimeInterval) -> TimeInterval? {
        guard let pendingTime else {
            return nil
        }

        self.pendingTime = nil
        return Self.normalize(pendingTime, duration: preparedDuration)
    }

    mutating func clear() {
        pendingTime = nil
    }

    static func normalize(_ requestedTime: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let lowerBoundedTime = max(0, requestedTime)
        guard duration > 0 else {
            return lowerBoundedTime
        }
        return min(lowerBoundedTime, duration)
    }
}

enum AudioWaveformExtractor {
    static let defaultBucketCount = 80

    static func normalizedLevels(from url: URL, bucketCount: Int = defaultBucketCount) async throws -> [Double] {
        let task = Task.detached(priority: .utility) {
            try extractNormalizedLevels(from: url, bucketCount: bucketCount)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func normalizedLevels(from rawLevels: [Double], minimumLevel: Double = 0.08) -> [Double] {
        guard !rawLevels.isEmpty else { return [] }

        let sanitized = rawLevels.map { level in
            level.isFinite ? max(0, level) : 0
        }

        guard let peak = sanitized.max(), peak > 0 else {
            return Array(repeating: minimumLevel, count: sanitized.count)
        }

        return sanitized.map { level in
            let unitLevel = min(max(level / peak, 0), 1)
            let shapedLevel = pow(unitLevel, 0.58)
            return min(max(minimumLevel, shapedLevel), 1)
        }
    }

    static func resampledLevels(_ levels: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return [] }
        guard levels.count != count else { return levels }
        guard count > 1, levels.count > 1 else {
            return Array(repeating: levels.first ?? 0, count: count)
        }

        let inputSpan = Double(levels.count - 1)
        let outputSpan = Double(count - 1)

        return (0..<count).map { index in
            let position = Double(index) * inputSpan / outputSpan
            let lowerIndex = Int(position.rounded(.down))
            let upperIndex = min(lowerIndex + 1, levels.count - 1)
            let fraction = position - Double(lowerIndex)
            return levels[lowerIndex] * (1 - fraction) + levels[upperIndex] * fraction
        }
    }

    private static func extractNormalizedLevels(from url: URL, bucketCount: Int) throws -> [Double] {
        guard bucketCount > 0 else { return [] }

        let file = try AVAudioFile(forReading: url)
        let totalFrames = file.length
        guard totalFrames > 0 else { return [] }

        var rawLevels: [Double] = []
        rawLevels.reserveCapacity(bucketCount)

        for bucketIndex in 0..<bucketCount {
            try Task.checkCancellation()

            let bucketStart = frameBoundary(forBucket: bucketIndex, bucketCount: bucketCount, totalFrames: totalFrames)
            let bucketEnd = frameBoundary(forBucket: bucketIndex + 1, bucketCount: bucketCount, totalFrames: totalFrames)
            let startFrame = min(max(0, bucketStart), max(0, totalFrames - 1))
            let endFrame = min(max(startFrame + 1, bucketEnd), totalFrames)
            let bucketFrames = max(1, endFrame - startFrame)

            if bucketFrames <= 4_096 {
                rawLevels.append(
                    try rmsLevel(in: file, startFrame: startFrame, frameCount: AVAudioFrameCount(bucketFrames))
                )
            } else {
                var sampledLevels: [Double] = []
                sampledLevels.reserveCapacity(3)

                for fraction in [0.2, 0.5, 0.8] {
                    try Task.checkCancellation()

                    let windowFrames = min(AVAudioFramePosition(1_024), bucketFrames)
                    let centeredOffset = AVAudioFramePosition((Double(bucketFrames) * fraction).rounded())
                    let proposedStart = startFrame + centeredOffset - (windowFrames / 2)
                    let windowStart = min(
                        max(startFrame, proposedStart),
                        max(startFrame, endFrame - windowFrames)
                    )

                    sampledLevels.append(
                        try rmsLevel(in: file, startFrame: windowStart, frameCount: AVAudioFrameCount(windowFrames))
                    )
                }

                rawLevels.append(sampledLevels.max() ?? 0)
            }
        }

        return normalizedLevels(from: smoothed(rawLevels))
    }

    private static func frameBoundary(
        forBucket bucketIndex: Int,
        bucketCount: Int,
        totalFrames: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        guard bucketCount > 0 else { return 0 }
        let clampedIndex = min(max(bucketIndex, 0), bucketCount)
        return AVAudioFramePosition(
            (Double(clampedIndex) / Double(bucketCount) * Double(totalFrames)).rounded(.down)
        )
    }

    private static func rmsLevel(
        in file: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) throws -> Double {
        let remainingFrames = max(0, file.length - startFrame)
        let resolvedFrameCount: AVAudioFrameCount
        if remainingFrames >= AVAudioFramePosition(frameCount) {
            resolvedFrameCount = frameCount
        } else {
            resolvedFrameCount = AVAudioFrameCount(remainingFrames)
        }
        guard resolvedFrameCount > 0 else { return 0 }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: resolvedFrameCount) else {
            return 0
        }

        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: resolvedFrameCount)
        return rmsLevel(in: buffer)
    }

    private static func rmsLevel(in buffer: AVAudioPCMBuffer) -> Double {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return 0 }

        if let floatChannelData = buffer.floatChannelData {
            return rmsLevel(
                frameLength: frameLength,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved
            ) { frameIndex, channelIndex in
                if buffer.format.isInterleaved {
                    return Double(floatChannelData[0][frameIndex * channelCount + channelIndex])
                }
                return Double(floatChannelData[channelIndex][frameIndex])
            }
        }

        if let int16ChannelData = buffer.int16ChannelData {
            return rmsLevel(
                frameLength: frameLength,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved
            ) { frameIndex, channelIndex in
                let sample: Int16
                if buffer.format.isInterleaved {
                    sample = int16ChannelData[0][frameIndex * channelCount + channelIndex]
                } else {
                    sample = int16ChannelData[channelIndex][frameIndex]
                }
                return Double(sample) / Double(Int16.max)
            }
        }

        if let int32ChannelData = buffer.int32ChannelData {
            return rmsLevel(
                frameLength: frameLength,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved
            ) { frameIndex, channelIndex in
                let sample: Int32
                if buffer.format.isInterleaved {
                    sample = int32ChannelData[0][frameIndex * channelCount + channelIndex]
                } else {
                    sample = int32ChannelData[channelIndex][frameIndex]
                }
                return Double(sample) / Double(Int32.max)
            }
        }

        return 0
    }

    private static func rmsLevel(
        frameLength: Int,
        channelCount: Int,
        isInterleaved: Bool,
        sampleAt: (Int, Int) -> Double
    ) -> Double {
        var squaredTotal = 0.0

        for frameIndex in 0..<frameLength {
            var framePeak = 0.0

            for channelIndex in 0..<channelCount {
                framePeak = max(framePeak, abs(sampleAt(frameIndex, channelIndex)))
            }

            squaredTotal += framePeak * framePeak
        }

        return sqrt(squaredTotal / Double(frameLength))
    }

    private static func smoothed(_ levels: [Double]) -> [Double] {
        guard levels.count > 2 else { return levels }

        return levels.enumerated().map { index, level in
            let previous = levels[max(0, index - 1)]
            let next = levels[min(levels.count - 1, index + 1)]
            return previous * 0.2 + level * 0.6 + next * 0.2
        }
    }
}

@MainActor
class AudioPlayerService: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    @Published private(set) var isPreparingAudio = false
    @Published private(set) var playbackStatusMessage: String?
    @Published private(set) var waveformLevels: [Double]?
    
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var pendingFilePath: String?
    private var preloadTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var pendingSeekState = PendingSeekState()
    private static var waveformCache: [String: [Double]] = [:]
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
        waveformTask?.cancel()
        discardLoadedPlayer()

        pendingFilePath = filePath.isEmpty ? nil : filePath
        duration = expectedDuration ?? 0
        playbackStatusMessage = nil
        isPreparingAudio = false
        waveformLevels = nil
        pendingSeekState.clear()

        guard let pendingFilePath else {
            return
        }

        if let cachedLevels = Self.waveformCache[pendingFilePath] {
            waveformLevels = cachedLevels
        } else {
            waveformTask = Task { @MainActor [weak self] in
                await self?.loadWaveformForCurrentSelection(filePath: pendingFilePath)
            }
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
        if let player = audioPlayer {
            pendingSeekState.clear()
            let resolvedTime = PendingSeekState.normalize(time, duration: player.duration)
            player.currentTime = resolvedTime
            currentTime = resolvedTime
            return
        }

        let stagedTime = pendingSeekState.storePendingSeek(time, fallbackDuration: duration)
        currentTime = stagedTime
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
        pendingSeekState.clear()
        stopTimer()
        deactivateAudioSessionIfNeeded()
    }
    
    deinit {
        preloadTask?.cancel()
        prepareTask?.cancel()
        waveformTask?.cancel()
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

        let storageManager = CloudStorageManager.shared

        guard let url = storageManager.getFileURL(for: filePath) else {
            debugLog("❌ [DEBUG] Failed to get file URL for: \(filePath)")
            if pendingFilePath == filePath {
                playbackStatusMessage = "Audio file unavailable."
            }
            return
        }

        debugLog("🔍 [DEBUG] Audio file URL: \(url.path)")

        if storageManager.isAudioFileMissing(at: url) {
            debugLog("❌ [DEBUG] Audio file NOT found at path")
            playbackStatusMessage = "Audio file unavailable."
            return
        }

        storageManager.startDownloadingFromCloud(url: url)

        guard pendingFilePath == filePath else { return }

        if storageManager.isFileReadyForPlayback(at: url) {
            playbackStatusMessage = nil
            return
        }

        playbackStatusMessage = "Audio is downloading from iCloud..."

        while !Task.isCancelled, pendingFilePath == filePath {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if storageManager.isFileReadyForPlayback(at: url) {
                playbackStatusMessage = nil
                return
            }
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
            if let candidateURL = CloudStorageManager.shared.getFileURL(for: filePath),
               CloudStorageManager.shared.isAudioFileMissing(at: candidateURL) {
                playbackStatusMessage = "Audio file unavailable."
            } else {
                playbackStatusMessage = "Audio is still downloading from iCloud."
            }
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
            if let pendingTime = pendingSeekState.consumePendingSeek(preparedDuration: player.duration) {
                player.currentTime = pendingTime
                currentTime = pendingTime
            } else {
                currentTime = 0
            }
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
    func loadWaveformForCurrentSelection(filePath: String) async {
        guard pendingFilePath == filePath else { return }

        if let cachedLevels = Self.waveformCache[filePath] {
            waveformLevels = cachedLevels
            return
        }

        guard let url = await CloudStorageManager.shared.prepareFileForReading(at: filePath) else {
            return
        }

        guard !Task.isCancelled, pendingFilePath == filePath else { return }

        do {
            let levels = try await AudioWaveformExtractor.normalizedLevels(from: url)

            guard !Task.isCancelled, pendingFilePath == filePath, !levels.isEmpty else { return }

            Self.waveformCache[filePath] = levels
            waveformLevels = levels
        } catch is CancellationError {
            return
        } catch {
            debugLog("⚠️ [DEBUG] Failed to extract playback waveform: \(error)")
        }
    }

    @MainActor
    func discardLoadedPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        pendingSeekState.clear()
        stopTimer()
        deactivateAudioSessionIfNeeded()
    }
}
