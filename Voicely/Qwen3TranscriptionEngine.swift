//
//  Qwen3TranscriptionEngine.swift
//  Voicely
//
//  Qwen3-ASR is the app's only speech engine. It runs on two backends that
//  share one model family: MLX on the Mac's GPU, CoreML on the Neural Engine
//  everywhere else. Built on the vendored speech-swift package.
//

import AudioCommon
import AVFoundation
import CoreML
import Foundation
import Metal
import Qwen3ASR

// MARK: - Backend

/// Which runtime decodes on this device.
///
/// MLX is several times faster but needs the GPU, which iOS takes away from an
/// app as soon as it leaves the foreground; a locked phone transcribing a
/// meeting can only use CoreML on the CPU and Neural Engine. The Mac has no
/// such limit, so it gets MLX whenever the GPU can run it.
enum Qwen3Backend: String, Sendable {
    case mlx
    case coreML

    nonisolated static let current: Qwen3Backend = resolve(
        isMacCatalyst: isMacCatalyst, gpuSupportsMLX: gpuSupportsMLX)

    nonisolated static func resolve(isMacCatalyst: Bool, gpuSupportsMLX: Bool) -> Qwen3Backend {
        isMacCatalyst && gpuSupportsMLX ? .mlx : .coreML
    }

    nonisolated private static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// MLX's attention kernels use `simdgroup_matrix`, which needs the Apple7
    /// GPU family (M1) or newer. On an Intel Mac pipeline creation fails and MLX
    /// aborts the process, so those fall back to CoreML.
    nonisolated private static let gpuSupportsMLX: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)
        #endif
    }()

    /// Stored on each note as the model that transcribed it.
    nonisolated var modelIdentifier: String {
        switch self {
        case .mlx: "qwen3-asr-0.6b-mlx"
        case .coreML: "qwen3-asr-0.6b-coreml"
        }
    }

    nonisolated var approximateDownloadSizeText: String {
        switch self {
        case .mlx: "about 0.7 GB"
        case .coreML: "about 0.95 GB"
        }
    }
}

// MARK: - Slice limits

/// How long a piece of audio one decode may take, and where the VAD may cut.
///
/// Measured on three real recordings (about 2.3 hours, docs/stable-roadmap.md
/// P-0i). CoreML handles slices up to its encoder's 30 s window: compared with
/// 14 s slices it was faster, left no empty slices and cut on longer pauses.
/// MLX does not: on slices over 15 s, 3 of 368 came back with most of their
/// text missing and single slices took minutes, so it stays under 15 s.
struct Qwen3SliceLimits: Equatable, Sendable {
    /// Longest audio decoded in one pass without slicing.
    let singlePassSeconds: TimeInterval
    /// Longest slice; a VAD cut may end it sooner.
    let chunkSeconds: TimeInterval
    /// Earliest point in a slice where the VAD may cut.
    let minimumCutSeconds: TimeInterval

    nonisolated static func limits(for backend: Qwen3Backend) -> Qwen3SliceLimits {
        switch backend {
        case .mlx: Qwen3SliceLimits(singlePassSeconds: 15, chunkSeconds: 14, minimumCutSeconds: 7)
        case .coreML: Qwen3SliceLimits(singlePassSeconds: 30, chunkSeconds: 29, minimumCutSeconds: 15)
        }
    }

    /// Unit tests always run on the 14 s cadence their fixtures are written
    /// for, whichever platform hosts them; `limits(for:)` is what ships.
    nonisolated static let current = limits(for: AppRuntime.isRunningTests ? .mlx : .current)
}

// MARK: - Defaults & knobs

enum Qwen3ASRDefaults {
    /// 0.6B 4-bit MLX weights. Pinned alongside the vendored speech-swift
    /// revision so weight layout and loader stay in sync. The CoreML backend
    /// takes its tokenizer files from this repository too.
    nonisolated static let mlxModelId = "mlx-community/Qwen3-ASR-0.6B-4bit"
    nonisolated static let coreMLModelId = "aufklarer/Qwen3-ASR-CoreML"
    nonisolated static let tokenizerFiles = ["vocab.json", "merges.txt", "tokenizer_config.json"]
    nonisolated static let coreMLBundles = [
        "encoder.mlmodelc", "embedding.mlmodelc", "decoder_part1.mlmodelc", "decoder_part2.mlmodelc"
    ]

    nonisolated static let modelDisplayName = "Qwen3 ASR 0.6B"

    /// Canonical defence against "percent percent percent…" repetition loops
    /// on silence or ambiguous audio, per the package's inference docs.
    nonisolated static let repetitionPenalty: Float = 1.15
    nonisolated static let maxTokens = 448

    nonisolated static let singlePassSecondsLimit = Qwen3SliceLimits.current.singlePassSeconds
    nonisolated static let chunkSeconds = Qwen3SliceLimits.current.chunkSeconds
    nonisolated static let minimumChunkCutSeconds = Qwen3SliceLimits.current.minimumCutSeconds

    /// Languages Qwen3-ASR was trained on, keyed the way Settings stores the
    /// choice. The value is the name the model's prompt expects.
    nonisolated static let languageNames: [String: String] = [
        "chinese": "Chinese", "english": "English", "cantonese": "Cantonese",
        "arabic": "Arabic", "german": "German", "french": "French",
        "spanish": "Spanish", "portuguese": "Portuguese", "indonesian": "Indonesian",
        "italian": "Italian", "korean": "Korean", "russian": "Russian",
        "thai": "Thai", "vietnamese": "Vietnamese", "japanese": "Japanese",
        "turkish": "Turkish", "hindi": "Hindi", "malay": "Malay",
        "dutch": "Dutch", "swedish": "Swedish", "danish": "Danish",
        "finnish": "Finnish", "polish": "Polish", "czech": "Czech",
        "filipino": "Filipino", "persian": "Persian", "greek": "Greek",
        "hungarian": "Hungarian", "macedonian": "Macedonian", "romanian": "Romanian"
    ]

    /// Maps the stored "selectedLanguage" key to the model's language hint.
    /// nil means auto-detect, which also covers a key left over from the
    /// longer Whisper language list.
    nonisolated static func languageHint(forSelectedLanguageKey key: String?) -> String? {
        guard let key, key != "auto" else { return nil }
        return languageNames[key]
    }
}

// MARK: - Model store (single load, single inference executor)

/// Owns the one loaded model for the process. Neither backend's model is
/// thread-safe and each inference saturates its compute unit anyway, so every
/// load and transcribe call is serialized on this actor.
actor Qwen3ASRModelStore {
    static let shared = Qwen3ASRModelStore()

    typealias ProgressHandler = @Sendable (Double, String) -> Void

    private let backend: Qwen3Backend
    /// Where the weights live; nil means Application Support. Tests point it
    /// at a directory that already holds them.
    private let baseOverride: URL?
    private var mlxModel: Qwen3ASRModel?
    private var coreMLModel: Qwen3CoreMLModel?
    private var loadTask: Task<Void, Error>?

    init(backend: Qwen3Backend = .current, baseDirectory: URL? = nil) {
        self.backend = backend
        baseOverride = baseDirectory
    }

    enum StoreError: LocalizedError {
        case modelNotDownloaded

        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded:
                return "The speech model isn't downloaded yet. Open Settings and tap Download to enable transcription."
            }
        }
    }

    // MARK: Files

    nonisolated static func baseDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Qwen3ASR", isDirectory: true)
    }

    /// Hub-layout repository directory (…/models/<org>/<name>). The layout is
    /// load-bearing: the package's downloader derives its download base by
    /// stripping the models/<org>/<name> suffix. With a flat directory it
    /// silently falls back to Caches/ and the weights land where the loader
    /// never looks.
    nonisolated static func repositoryDirectory(
        for modelId: String, base: URL, fileManager: FileManager = .default
    ) throws -> URL {
        var directory = base.appendingPathComponent("models", isDirectory: true)
        for component in modelId.split(separator: "/") {
            directory.appendPathComponent(String(component), isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Written once a download has loaded and warmed up. A snapshot that was
    /// interrupted leaves real-looking model folders behind, so file presence
    /// alone cannot tell a finished download from half of one.
    nonisolated static func readyMarkerURL(for backend: Qwen3Backend, base: URL) -> URL {
        base.appendingPathComponent(".ready-\(backend.rawValue)")
    }

    nonisolated static func isModelDownloaded(
        backend: Qwen3Backend = .current, base: URL? = nil, fileManager: FileManager = .default
    ) -> Bool {
        guard let base = base ?? (try? baseDirectory(fileManager: fileManager)),
              fileManager.fileExists(atPath: readyMarkerURL(for: backend, base: base).path),
              let tokenizerDirectory = try? repositoryDirectory(
                for: Qwen3ASRDefaults.mlxModelId, base: base, fileManager: fileManager),
              fileManager.fileExists(atPath: tokenizerDirectory.appendingPathComponent("vocab.json").path)
        else { return false }
        switch backend {
        case .mlx:
            let names = (try? fileManager.contentsOfDirectory(atPath: tokenizerDirectory.path)) ?? []
            return names.contains { $0.hasSuffix(".safetensors") }
        case .coreML:
            guard let directory = try? repositoryDirectory(
                for: Qwen3ASRDefaults.coreMLModelId, base: base, fileManager: fileManager) else { return false }
            return Qwen3ASRDefaults.coreMLBundles.allSatisfy {
                fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
    }

    // MARK: Loading

    var isModelLoaded: Bool { mlxModel != nil || coreMLModel != nil }

    /// Loads the already-downloaded model into memory (no network). Throws
    /// `StoreError.modelNotDownloaded` when the weights are missing.
    func prepareDownloadedModel(progressHandler: ProgressHandler? = nil) async throws {
        try await load(allowDownload: false, progressHandler: progressHandler)
    }

    /// Downloads the weights if needed, then loads and warms up.
    func downloadAndLoadModel(progressHandler: ProgressHandler? = nil) async throws {
        try await load(allowDownload: true, progressHandler: progressHandler)
    }

    /// Runs one inference on a slice of 16 kHz mono audio no longer than the
    /// backend's `Qwen3SliceLimits`. The model never leaves this actor.
    func transcribe(samples: [Float], languageHint: String?) async throws -> String {
        try await load(allowDownload: false, progressHandler: nil)
        if let mlxModel {
            return mlxModel.transcribe(
                audio: samples, sampleRate: 16_000,
                options: Qwen3DecodingOptions(
                    maxTokens: Qwen3ASRDefaults.maxTokens,
                    language: languageHint,
                    repetitionPenalty: Qwen3ASRDefaults.repetitionPenalty))
        }
        guard let coreMLModel else { throw StoreError.modelNotDownloaded }
        // Each slice creates an MLState and several IOSurface-backed arrays;
        // without a pool they pile up until CoreML cannot allocate another one,
        // about 200 slices into a recording.
        return try autoreleasepool {
            try coreMLModel.transcribe(samples, languageHint: languageHint)
        }
    }

    func unloadModel() {
        mlxModel?.unload()
        mlxModel = nil
        coreMLModel = nil
    }

    /// Deletes downloaded weights from disk (Settings action). Unloads first
    /// so a loaded model doesn't keep serving from removed files.
    func deleteDownloadedModel() throws {
        unloadModel()
        let base = try baseOverride ?? Self.baseDirectory()
        guard FileManager.default.fileExists(atPath: base.path) else { return }
        try FileManager.default.removeItem(at: base)
    }

    private func load(allowDownload: Bool, progressHandler: ProgressHandler?) async throws {
        if isModelLoaded { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let backend = self.backend
        let base = try baseOverride ?? Self.baseDirectory()
        if !allowDownload, !Self.isModelDownloaded(backend: backend, base: base) {
            throw StoreError.modelNotDownloaded
        }

        let task = Task {
            switch backend {
            case .mlx:
                self.mlxModel = try await Self.loadMLX(
                    base: base, allowDownload: allowDownload, progressHandler: progressHandler)
            case .coreML:
                self.coreMLModel = try await Self.loadCoreML(
                    base: base, allowDownload: allowDownload, progressHandler: progressHandler)
            }
            Self.excludeFromBackup(base)
            FileManager.default.createFile(
                atPath: Self.readyMarkerURL(for: backend, base: base).path, contents: nil)
            progressHandler?(1.0, "Ready")
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private static func loadMLX(
        base: URL, allowDownload: Bool, progressHandler: ProgressHandler?
    ) async throws -> Qwen3ASRModel {
        let directory = try repositoryDirectory(for: Qwen3ASRDefaults.mlxModelId, base: base)
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: Qwen3ASRDefaults.mlxModelId,
            cacheDir: directory,
            offlineMode: !allowDownload,
            progressHandler: { progress, status in progressHandler?(progress * 0.97, status) }
        )
        // One tiny decode compiles the Metal pipelines so the first real
        // slice doesn't pay the warm-up cost.
        progressHandler?(0.98, "Warming up…")
        _ = model.transcribe(
            audio: [Float](repeating: 0, count: 8_000),
            sampleRate: 16_000,
            options: Qwen3DecodingOptions(maxTokens: 4, repetitionPenalty: Qwen3ASRDefaults.repetitionPenalty)
        )
        return model
    }

    private static func loadCoreML(
        base: URL, allowDownload: Bool, progressHandler: ProgressHandler?
    ) async throws -> Qwen3CoreMLModel {
        let directory = try repositoryDirectory(for: Qwen3ASRDefaults.coreMLModelId, base: base)
        let tokenizerDirectory = try repositoryDirectory(for: Qwen3ASRDefaults.mlxModelId, base: base)
        // No GPU anywhere: the only configuration a locked iPhone may use. The
        // simulator has no Neural Engine to offer.
        #if targetEnvironment(simulator)
        let units = MLComputeUnits.cpuOnly
        #else
        let units = MLComputeUnits.cpuAndNeuralEngine
        #endif

        let encoder = try await CoreMLASREncoder.fromPretrained(
            modelId: Qwen3ASRDefaults.coreMLModelId, computeUnits: units,
            cacheDir: directory, offlineMode: !allowDownload,
            progressHandler: { progress, status in progressHandler?(progress * 0.3, status) })
        let decoder = try await CoreMLTextDecoder.fromPretrained(
            modelId: Qwen3ASRDefaults.coreMLModelId, computeUnits: units,
            cacheDir: directory, offlineMode: !allowDownload,
            progressHandler: { progress, status in progressHandler?(0.3 + progress * 0.6, status) })

        let vocabularyURL = tokenizerDirectory.appendingPathComponent("vocab.json")
        if !FileManager.default.fileExists(atPath: vocabularyURL.path) {
            guard allowDownload else { throw StoreError.modelNotDownloaded }
            progressHandler?(0.9, "Downloading tokenizer…")
            try await HuggingFaceDownloader.downloadFiles(
                modelId: Qwen3ASRDefaults.mlxModelId, to: tokenizerDirectory,
                files: Qwen3ASRDefaults.tokenizerFiles)
        }
        let tokenizer = Qwen3Tokenizer()
        try tokenizer.load(from: vocabularyURL)

        progressHandler?(0.95, "Warming up…")
        try encoder.warmUp()
        try decoder.warmUp()
        return Qwen3CoreMLModel(encoder: encoder, decoder: decoder, tokenizer: tokenizer)
    }

    /// The weights are re-downloadable, so they must not land in iCloud/device backups.
    nonisolated private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - CoreML decode

/// The package's CoreML pipeline with the MLX hop removed, so nothing here can
/// reach Metal. Its own `transcribeWithoutMLX` is not usable: it reads the
/// Neural Engine's Float16 output as Float32 and prefills one token per call.
final class Qwen3CoreMLModel {
    private let encoder: CoreMLASREncoder
    private let decoder: CoreMLTextDecoder
    private let tokenizer: Qwen3Tokenizer
    private let featureExtractor = WhisperFeatureExtractor()

    init(encoder: CoreMLASREncoder, decoder: CoreMLTextDecoder, tokenizer: Qwen3Tokenizer) {
        self.encoder = encoder
        self.decoder = decoder
        self.tokenizer = tokenizer
    }

    func transcribe(_ audio: [Float], languageHint: String?) throws -> String {
        let mel = featureExtractor.processRaw(audio, sampleRate: 16_000)
        let encoded = try encoder.encode(melFeatures: mel)
        let hidden = encoded.embeddings.shape[2].intValue
        let embeddings = Self.flatten(encoded.embeddings, rows: encoded.outputLength, hidden: hidden)

        decoder.resetCache()
        let endOfTurn = Int32(Qwen3ASRTokens.imEndTokenId)
        // <|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>
        let prefix: [Int32] = [151644, 8948, 198, endOfTurn, 198, 151644, 872, 198, 151669]
        // <|audio_end|><|im_end|>\n<|im_start|>assistant\n
        var suffix: [Int32] = [151670, endOfTurn, 198, 151644, 77091, 198]
        if let languageHint {
            suffix += tokenizer.encode("language \(languageHint)").map { Int32($0) }
        }
        suffix.append(151704)   // <|asr_text|>

        var logits = try decoder.decoderPrefillTokens(prefix)
        var consumed = 0
        while consumed < encoded.outputLength {
            let count = min(decoder.prefillBatchSize, encoded.outputLength - consumed)
            logits = try decoder.decoderPrefill(flatEmbeddings: embeddings, offset: consumed, realCount: count)
            consumed += count
        }
        logits = try decoder.decoderPrefillTokens(suffix)

        var tokens: [Int32] = []
        var seen = Set<Int32>()
        // An immediate end-of-turn would mean an empty transcript; the model
        // is asked for its next best guess instead, as the package does.
        var next = Self.pickToken(logits, seen: seen, excluding: endOfTurn)
        for _ in 0..<Qwen3ASRDefaults.maxTokens {
            tokens.append(next)
            seen.insert(next)
            if next == endOfTurn { break }
            logits = try decoder.decoderStep(embedding: try decoder.embed(tokenId: next))
            next = Self.pickToken(logits, seen: seen, excluding: nil)
        }

        let raw = tokenizer.decode(tokens: tokens.map { Int($0) })
        // Auto-detect prepends "language XX<asr_text>" to the transcript.
        if let marker = raw.range(of: "<asr_text>") {
            return String(raw[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    /// Greedy pick with the same repetition penalty the MLX backend applies.
    /// Without it a stretch of laughter repeats one syllable up to the token
    /// limit.
    static func pickToken(_ logits: MLMultiArray, seen: Set<Int32>, excluding excluded: Int32?) -> Int32 {
        let vocabulary = logits.shape.last?.intValue ?? logits.count
        let stride = logits.strides.last?.intValue ?? 1
        let read: (Int) -> Float
        if logits.dataType == .float16 {
            let pointer = logits.dataPointer.assumingMemoryBound(to: Float16.self)
            read = { Float(pointer[$0 * stride]) }
        } else {
            let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)
            read = { pointer[$0 * stride] }
        }
        return pickToken(count: vocabulary, seen: seen, excluding: excluded, logit: read)
    }

    static func pickToken(
        count: Int, seen: Set<Int32>, excluding excluded: Int32?,
        penalty: Float = Qwen3ASRDefaults.repetitionPenalty, logit: (Int) -> Float
    ) -> Int32 {
        var best: Int32 = 0
        var bestValue = -Float.infinity
        for index in 0..<count {
            let token = Int32(index)
            if token == excluded { continue }
            var value = logit(index)
            if value.isNaN { continue }
            // Positive logits divide and negative ones multiply, so the
            // penalty always lowers a repeated token's odds.
            if seen.contains(token) { value = value > 0 ? value / penalty : value * penalty }
            if value > bestValue {
                bestValue = value
                best = token
            }
        }
        return best
    }

    /// The Neural Engine hands back Float16 with its own strides, so the
    /// encoder output is read through its declared layout.
    static func flatten(_ array: MLMultiArray, rows: Int, hidden: Int) -> [Float] {
        var output = [Float](repeating: 0, count: rows * hidden)
        let strides = array.strides.map { $0.intValue }
        let rowStride = strides[1], columnStride = strides[2]
        if array.dataType == .float16 {
            let source = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for row in 0..<rows {
                for column in 0..<hidden {
                    output[row * hidden + column] = Float(source[row * rowStride + column * columnStride])
                }
            }
        } else {
            let source = array.dataPointer.assumingMemoryBound(to: Float.self)
            for row in 0..<rows {
                for column in 0..<hidden {
                    output[row * hidden + column] = source[row * rowStride + column * columnStride]
                }
            }
        }
        return output
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

    /// Decodes any AVFoundation-readable file (the recorder's segments,
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
        var readError: Error?
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
                    readError = error
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
            if let readError { throw readError }
            if let conversionError { throw conversionError }
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
