//
//  Qwen3TranscriptionEngine.swift
//  Voicely
//
//  Qwen3-ASR (MLX) engine: model store, download controller, and the
//  engine-mode switch that lets it run side by side with WhisperKit.
//  Ported from EverLog-iOS's integration of the vendored speech-swift package.
//

import AVFoundation
import Foundation
import Metal
import Qwen3ASR

// MARK: - Device gating

/// Hardware gate for the Qwen3 (MLX) engine.
///
/// MLX's matmul/attention kernels use `simdgroup_matrix`, which requires the
/// Apple7 GPU family (A14/M1) or newer. On older chips Metal pipeline creation
/// fails and MLX aborts the process, so the engine is never resolved or offered
/// there. The simulator has no Metal device for MLX at all, so it also resolves
/// to WhisperKit — which keeps simulator-driven UI tests on the legacy paths.
enum TranscriptionDeviceSupport {
    nonisolated static let deviceSupportsQwen3: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)
        #endif
    }()
}

// MARK: - Engine mode

/// Switch between the Qwen3-ASR (MLX) engine and the WhisperKit engine.
/// Stored in UserDefaults under `storageKey`. WhisperKit is the default:
/// Qwen3's decode path has unit coverage but has never been verified on a real
/// device, and it only reports chunk-level timings, so tap-to-seek playback
/// degrades on it. It stays available as an opt-in choice in Settings.
enum TranscriptionEngineMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case qwen3ASR
    case whisperKit

    nonisolated static let storageKey = "transcriptionEngineMode"
    nonisolated static let defaultMode: TranscriptionEngineMode = .whisperKit

    nonisolated var id: String { rawValue }

    /// Resolves the stored engine choice. Hardware that can't run MLX always
    /// resolves to Whisper, regardless of what's stored (the stored value may
    /// predate the gate or come from another synced device).
    nonisolated static func resolve(
        fromRawValue rawValue: String?,
        deviceSupportsQwen3: Bool = TranscriptionDeviceSupport.deviceSupportsQwen3
    ) -> TranscriptionEngineMode {
        guard deviceSupportsQwen3 else { return .whisperKit }
        guard let rawValue, let mode = TranscriptionEngineMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }

    /// The effective engine for this process. Tests used to be special-cased
    /// here so an unset default wouldn't route them at Qwen3; now that Whisper
    /// is the default for everyone, tests and shipping installs resolve
    /// identically and Qwen3 tests opt in by storing the mode (or injecting a
    /// provider).
    nonisolated static func currentResolved(userDefaults: UserDefaults = .standard) -> TranscriptionEngineMode {
        resolve(fromRawValue: userDefaults.string(forKey: storageKey))
    }

    nonisolated var displayName: String {
        switch self {
        case .qwen3ASR: "Qwen3 (Experimental)"
        case .whisperKit: "Whisper"
        }
    }

    nonisolated var subtitle: String {
        switch self {
        case .qwen3ASR: "Fast multilingual engine on the GPU. Unverified on device, and timings are per chunk, not per word."
        case .whisperKit: "The default engine. Word-level timings drive tap-to-seek playback."
        }
    }
}

// MARK: - Defaults & knobs

enum Qwen3ASRDefaults {
    /// 0.6B 4-bit MLX weights. Pinned alongside the vendored speech-swift
    /// revision so weight layout and loader stay in sync.
    nonisolated static let modelId = "mlx-community/Qwen3-ASR-0.6B-4bit"

    nonisolated static let modelDisplayName = "Qwen3 ASR 0.6B"

    nonisolated static let approximateDownloadSizeText = "about 0.5 GB"

    /// Canonical defence against "percent percent percent…" repetition loops
    /// on silence or ambiguous audio, per the package's inference docs.
    nonisolated static let repetitionPenalty: Float = 1.15

    /// Qwen3-ASR escalates to a slower decoding path above 15 s of audio, so
    /// segmented runs slice to stay under it (with room for the VAD cut).
    nonisolated static let singlePassSecondsLimit: TimeInterval = 15
    nonisolated static let chunkSeconds: TimeInterval = 14
    nonisolated static let minimumChunkCutSeconds: TimeInterval = 7

    /// Maps Voicely's stored "selectedLanguage" key ("auto", "chinese", …)
    /// to the ISO hint Qwen3 expects ("zh", …). nil = auto-detect.
    nonisolated static func languageHint(forSelectedLanguageKey key: String?) -> String? {
        guard let key, key != "auto" else { return nil }
        return LanguageConstants.languages[key]
    }

    nonisolated static func decodingOptions(languageHint: String?, context: String?) -> Qwen3DecodingOptions {
        Qwen3DecodingOptions(
            language: languageHint,
            context: context,
            repetitionPenalty: repetitionPenalty
        )
    }
}

// MARK: - Model store (single load, single inference executor)

/// Owns the one `Qwen3ASRModel` instance for the process. The model is not
/// thread-safe and each inference saturates the GPU anyway, so every load and
/// transcribe call is serialized on this actor.
actor Qwen3ASRModelStore {
    static let shared = Qwen3ASRModelStore()

    private var model: Qwen3ASRModel?
    private var loadTask: Task<Void, Error>?

    enum StoreError: LocalizedError {
        case modelNotDownloaded

        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded:
                return "The Qwen3 speech model isn't downloaded yet. Open Settings and tap Download to enable transcription."
            }
        }
    }

    nonisolated static func modelDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Qwen3ASR", isDirectory: true)
        // Hub-layout repo directory (…/models/<org>/<name>). The layout is
        // load-bearing: the package's downloader derives its download base by
        // stripping the models/<org>/<name> suffix. With a flat directory it
        // silently falls back to Caches/ and the weights land where the loader
        // never looks ("No safetensors files found").
        var directory = base.appendingPathComponent("models", isDirectory: true)
        for component in Qwen3ASRDefaults.modelId.split(separator: "/") {
            directory.appendPathComponent(String(component), isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func isModelDownloaded(at directory: URL, fileManager: FileManager = .default) -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasWeights = names.contains { $0.hasSuffix(".safetensors") }
        let hasVocab = names.contains("vocab.json")
        return hasWeights && hasVocab
    }

    nonisolated static func isModelDownloaded(fileManager: FileManager = .default) -> Bool {
        guard let directory = try? modelDirectory(fileManager: fileManager) else { return false }
        return isModelDownloaded(at: directory, fileManager: fileManager)
    }

    var isModelLoaded: Bool { model != nil }

    /// Loads the already-downloaded model into memory (no network). Throws
    /// `StoreError.modelNotDownloaded` when the weights are missing.
    func prepareDownloadedModel() async throws {
        try await load(allowDownload: false, progressHandler: nil)
    }

    /// Downloads the weights if needed, then loads + warms up.
    func downloadAndLoadModel(progressHandler: (@Sendable (Double, String) -> Void)? = nil) async throws {
        try await load(allowDownload: true, progressHandler: progressHandler)
    }

    /// Runs one inference. The model never leaves this actor.
    func transcribe(samples: [Float], options: Qwen3DecodingOptions) async throws -> String {
        try await load(allowDownload: false, progressHandler: nil)
        guard let model else { throw StoreError.modelNotDownloaded }
        return model.transcribe(audio: samples, sampleRate: 16_000, options: options)
    }

    func unloadModel() {
        model?.unload()
        model = nil
    }

    /// Deletes downloaded weights from disk (Settings action). Unloads first
    /// so a loaded model doesn't keep serving from removed files.
    func deleteDownloadedModel() {
        unloadModel()
        guard let directory = try? Self.modelDirectory(),
              Self.isModelDownloaded(at: directory) else { return }
        try? FileManager.default.removeItem(at: directory)
        print("🗑️ Qwen3 model weights deleted")
    }

    private func load(
        allowDownload: Bool,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws {
        if model != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let directory = try Self.modelDirectory()
        if !allowDownload, !Self.isModelDownloaded(at: directory) {
            throw StoreError.modelNotDownloaded
        }

        let task = Task {
            let loaded = try await Qwen3ASRModel.fromPretrained(
                modelId: Qwen3ASRDefaults.modelId,
                cacheDir: directory,
                offlineMode: !allowDownload,
                progressHandler: progressHandler
            )
            Self.excludeFromBackup(directory)
            // One tiny decode compiles the Metal pipelines so the first real
            // segment doesn't pay the warm-up cost.
            progressHandler?(0.98, "Warming up…")
            _ = loaded.transcribe(
                audio: [Float](repeating: 0, count: 8_000),
                sampleRate: 16_000,
                options: Qwen3DecodingOptions(maxTokens: 4, repetitionPenalty: Qwen3ASRDefaults.repetitionPenalty)
            )
            progressHandler?(1.0, "Ready")
            self.model = loaded
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    /// The weights are re-downloadable, so they must not land in iCloud/device backups.
    nonisolated private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - Audio decoding

enum Qwen3AudioPCM {
    enum AudioDecodeError: LocalizedError {
        case formatUnavailable

        var errorDescription: String? {
            "The audio could not be converted for transcription."
        }
    }

    /// Decodes any AVFoundation-readable file (the recorder's m4a segments,
    /// extracted slices) to the 16 kHz mono Float32 PCM the model wants.
    nonisolated static func loadPCM16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw AudioDecodeError.formatUnavailable
        }

        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            return try readAllSamples(from: file, format: sourceFormat)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioDecodeError.formatUnavailable
        }

        var output: [Float] = []
        let inputCapacity: AVAudioFrameCount = 32_768
        var fileExhausted = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 16_384) else {
                throw AudioDecodeError.formatUnavailable
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                // Position check, not read-and-catch: AVAudioFile.read throws at
                // EOF, and treating any thrown error as end-of-file would turn a
                // real I/O failure into a silently truncated transcript.
                if fileExhausted || file.framePosition >= file.length {
                    fileExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: inputCapacity)
                } catch {
                    fileExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    fileExhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError {
                throw conversionError
            }
            if outBuffer.frameLength > 0, let channelData = outBuffer.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error {
                break
            }
            if status == .inputRanDry && fileExhausted && outBuffer.frameLength == 0 {
                break
            }
        }
        return output
    }

    nonisolated private static func readAllSamples(from file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        var output: [Float] = []
        let capacity: AVAudioFrameCount = 32_768
        // AVAudioFile.read throws (a bare nilError) when called again at EOF
        // instead of returning an empty buffer, so the loop must stop on frame
        // position. The recorder's whole pipeline is 16 kHz mono Float32 — the
        // format this direct path serves — so every real recording hits this.
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioDecodeError.formatUnavailable
            }
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { break }
            output.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }
        return output
    }
}

// MARK: - Download controller (Settings UI + launch path)

/// Drives the Qwen3 weight download. Settings uses `startDownload()`; the
/// launch path awaits `downloadAndLoad()`. Both funnel into one shared task
/// so concurrent triggers share progress and result.
@MainActor
final class Qwen3ModelDownloadController: ObservableObject {
    static let shared = Qwen3ModelDownloadController()

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double, status: String)
        case ready
        case failed(message: String)
    }

    @Published private(set) var state: DownloadState = .notDownloaded

    private let store: Qwen3ASRModelStore
    private var downloadTask: Task<Bool, Never>?

    init(store: Qwen3ASRModelStore = .shared) {
        self.store = store
        refresh()
    }

    func refresh() {
        if case .downloading = state { return }
        state = Qwen3ASRModelStore.isModelDownloaded() ? .ready : .notDownloaded
    }

    func startDownload() {
        _ = downloadAndLoadTask()
    }

    /// Downloads (if needed) and loads the model; returns whether it is ready.
    func downloadAndLoad() async -> Bool {
        await downloadAndLoadTask().value
    }

    private func downloadAndLoadTask() -> Task<Bool, Never> {
        if let downloadTask { return downloadTask }
        state = .downloading(progress: 0, status: "Starting…")
        print("⬇️ Qwen3 model download/load started")
        let task = Task { [weak self, store] () -> Bool in
            do {
                try await store.downloadAndLoadModel { [weak self] progress, status in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(progress: progress, status: status)
                    }
                }
                print("✅ Qwen3 model ready")
                self?.state = .ready
                self?.downloadTask = nil
                // Reuse the model-loaded signal so queued notes start processing.
                NotificationCenter.default.post(name: .modelLoadedNotification, object: nil)
                return true
            } catch {
                print("❌ Qwen3 model download/load failed: \(error)")
                self?.state = .failed(message: error.localizedDescription)
                self?.downloadTask = nil
                return false
            }
        }
        downloadTask = task
        return task
    }
}
