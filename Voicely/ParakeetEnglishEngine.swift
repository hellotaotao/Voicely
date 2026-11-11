import AVFoundation
import FluidAudio
import Foundation
import os

/// Parakeet TDT v2 (FluidAudio, CoreML on CPU + Neural Engine): transcribes
/// the English stretches of a recording again after Qwen3-ASR has run, see
/// `EnglishStretchRouting`, and recordings and files with English chosen,
/// which skip Qwen3-ASR. It ships inside the app like Qwen3-ASR, is loaded
/// only while it works, or while a recording with English chosen goes on, and
/// unloaded afterwards, and runs on every platform the same way, so the phone
/// can use it while locked.
actor ParakeetEnglishEngine {
    static let shared = ParakeetEnglishEngine()

    nonisolated private static let log = Logger(subsystem: "com.hellotaotao.Voicely", category: "Parakeet")

    enum EngineError: LocalizedError {
        case modelMissing(URL?)
        case unreadableAudio

        var errorDescription: String? {
            switch self {
            case .modelMissing(let directory):
                return String(localized: "The English speech model is missing from this build")
                    + (directory.map { " (looked in \($0.path))" } ?? "") + "."
            case .unreadableAudio:
                return String(localized: "The audio could not be read for English transcription.")
            }
        }
    }

    // MARK: Files

    /// Name of the model folder in the app's resources, filled at build time
    /// by scripts/embed-speech-model.sh.
    nonisolated static let bundledDirectoryName = "EnglishSpeechModel"

    /// Where the model is read from. `VOICELY_PARAKEET_DIRECTORY` replaces the
    /// bundled folder for tests.
    nonisolated static func defaultModelDirectory(bundle: Bundle = .main) -> URL? {
        if let override = ProcessInfo.processInfo.environment["VOICELY_PARAKEET_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return bundle.resourceURL?.appendingPathComponent(bundledDirectoryName, isDirectory: true)
    }

    nonisolated static func isComplete(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        (["parakeet_vocab.json"] + ModelNames.ASR.requiredModels.sorted()).allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    nonisolated static var isAvailable: Bool {
        defaultModelDirectory().map { isComplete($0) } ?? false
    }

    // MARK: Transcription

    private var manager: AsrManager?
    /// Whether a call holds the engine, and the calls waiting for it.
    private var turns = ParakeetTurns<CheckedContinuation<Void, Never>>()
    /// Recordings that keep the model loaded between their calls.
    private var holds = 0

    /// Calls run one at a time, such as a recording that stops during an
    /// English import: this actor lets them interleave at every await, and
    /// `AsrManager` has one progress stream, which crashes when two tasks read it.
    /// A call `ahead` goes before every call still waiting.
    private func acquire(ahead: Bool = false) async {
        guard !turns.takeIfFree() else { return }
        await withCheckedContinuation { turns.wait($0, ahead: ahead) }
    }

    private func release() {
        turns.handOver()?.resume()
    }

    /// Keeps the model loaded between calls until `endHold`, for a recording
    /// that transcribes with Parakeet as it goes.
    func hold() {
        holds += 1
    }

    /// Lets the model go once no recording holds it.
    func endHold() async {
        holds = max(0, holds - 1)
        await unload()
    }

    /// Calls `beat` now and then every `interval` until cancelled. Detached,
    /// since converting the audio holds this actor.
    nonisolated static func preparationHeartbeat(
        every interval: Duration = .seconds(5),
        beat: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                beat()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Transcribes `[startFrame, endFrame)` of `fileURL` and returns its words,
    /// timed from the start of the file. `onProgress` is called as the model
    /// works through the audio (0...1), and with 0 every few seconds before
    /// that: loading the model and converting the audio report nothing of
    /// their own, and iOS ends a background task that goes quiet for long.
    /// A live slice of a recording goes `ahead` of calls already waiting.
    func transcribe(
        fileURL: URL,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        ahead: Bool = false,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [TimedWord] {
        // Beats while it waits its turn too: a call queued behind a warm-up
        // load must not go quiet long enough for iOS to end its background task.
        let preparing = Self.preparationHeartbeat { onProgress(0) }
        defer { preparing.cancel() }
        await acquire(ahead: ahead)
        defer { release() }
        let manager = try await loadedManager()
        let sampleRate = try Self.sampleRate(of: fileURL)
        let offset = Double(startFrame) / sampleRate
        let stretchURL = try Self.writeMono16k(from: fileURL, startFrame: startFrame, endFrame: endFrame)
        defer { try? FileManager.default.removeItem(at: stretchURL) }
        try Task.checkCancellation()
        preparing.cancel()

        let progressStream = await manager.transcriptionProgressStream
        let progressTask = Task {
            for try await fraction in progressStream { onProgress(fraction) }
        }
        defer { progressTask.cancel() }

        let started = ProcessInfo.processInfo.systemUptime
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(stretchURL, decoderState: &state)
        let seconds = Double(endFrame - startFrame) / sampleRate
        Self.log.notice("stretch audioSeconds=\(seconds) seconds=\(ProcessInfo.processInfo.systemUptime - started) tokens=\(result.tokenTimings?.count ?? 0) \(MemoryFootprint.summary, privacy: .public)")
        onProgress(1)
        return buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: $0.startTime + offset, end: $0.endTime + offset)
        }
    }

    /// Frees the model's memory unless a recording holds it. The next
    /// transcription loads it again.
    func unload() async {
        guard holds == 0 else { return }
        await acquire()
        defer { release() }
        guard holds == 0 else { return }
        await manager?.cleanup()
        manager = nil
    }

    /// Loads the model once, outside any transcription, so the Neural Engine
    /// compiles it while the app is open: the first load after an app or
    /// system update takes 14 s in the foreground on an iPhone 17 Pro and
    /// about 100 s locked. Waits its turn behind real work, and a call that
    /// comes after it uses the loaded model. Lets the model go afterwards
    /// unless a recording holds it.
    func warmUp() async {
        await acquire()
        do {
            _ = try await loadedManager()
        } catch {
            Self.log.error("warmUp failed: \(error.localizedDescription, privacy: .public)")
        }
        release()
        await unload()
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        guard let directory = Self.defaultModelDirectory(), Self.isComplete(directory) else {
            throw EngineError.modelMissing(Self.defaultModelDirectory())
        }
        let started = ProcessInfo.processInfo.systemUptime
        let models = try AsrModels.loadLocal(from: directory, version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        Self.log.notice("loaded seconds=\(ProcessInfo.processInfo.systemUptime - started) \(MemoryFootprint.summary, privacy: .public)")
        ModelWarmUp.markLoaded(.parakeet)
        self.manager = manager
        return manager
    }

    // MARK: Audio

    nonisolated private static func sampleRate(of url: URL) throws -> Double {
        try AVAudioFile(forReading: url).processingFormat.sampleRate
    }

    /// Length of each piece converted at a time, so a long stretch never sits
    /// in memory whole.
    nonisolated static let conversionPieceSeconds: Double = 300

    /// Writes `[startFrame, endFrame)` of `sourceURL` to a temporary 16 kHz mono
    /// Float32 file, the format Parakeet reads. Converting here, with the
    /// channel mixdown the rest of the app uses, keeps FluidAudio's own
    /// converter out of stereo files, which Mac Catalyst turns into silence.
    nonisolated static func writeMono16k(
        from sourceURL: URL,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition
    ) throws -> URL {
        let sampleRate = try sampleRate(of: sourceURL)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false) else {
            throw EngineError.unreadableAudio
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely_parakeet_\(UUID().uuidString).caf")
        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: format.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let pieceFrames = AVAudioFramePosition(conversionPieceSeconds * sampleRate)
            var pieceStart = startFrame
            var pieceIndex = 0
            while pieceStart < endFrame {
                let pieceEnd = min(endFrame, pieceStart + pieceFrames)
                pieceIndex += 1
                guard let pieceURL = IncrementalTranscriptionCoordinator.extractSegment(
                    fileURL: sourceURL, from: pieceStart, to: pieceEnd, segmentIndex: pieceIndex) else {
                    throw EngineError.unreadableAudio
                }
                defer { try? FileManager.default.removeItem(at: pieceURL) }
                let samples = try Qwen3AudioPCM.loadPCM16kMono(url: pieceURL)
                if !samples.isEmpty {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                        throw EngineError.unreadableAudio
                    }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { source in
                        buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
                    }
                    try output.write(from: buffer)
                }
                pieceStart = pieceEnd
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }
}

/// The order calls take Parakeet in: one at a time, first come first served,
/// except that calls marked `ahead` go before every call still waiting.
struct ParakeetTurns<Waiter> {
    private(set) var isBusy = false
    private var ahead: [Waiter] = []
    private var behind: [Waiter] = []

    /// Takes the engine when it is free; false when the caller has to wait.
    mutating func takeIfFree() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    mutating func wait(_ waiter: Waiter, ahead isAhead: Bool) {
        if isAhead {
            ahead.append(waiter)
        } else {
            behind.append(waiter)
        }
    }

    /// The waiter the engine goes to next, or nil, freeing it, when no one waits.
    mutating func handOver() -> Waiter? {
        if !ahead.isEmpty { return ahead.removeFirst() }
        if !behind.isEmpty { return behind.removeFirst() }
        isBusy = false
        return nil
    }
}
