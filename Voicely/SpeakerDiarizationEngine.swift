import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Owns one non-thread-safe Core ML stream at a time. Model state is scoped to a recording.
actor SpeakerDiarizationEngine {
    static let shared = SpeakerDiarizationEngine()

    enum EngineError: LocalizedError, Equatable {
        case alreadyRunning
        case unreadableAudio
        case missingBundledModel
        case invalidModelOutput

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                String(localized: "Speaker identification is already running.")
            case .unreadableAudio:
                String(localized: "The audio could not be read for speaker identification.")
            case .missingBundledModel:
                String(localized: "The speaker model is missing from this app build.")
            case .invalidModelOutput:
                String(localized: "The speaker model could not analyze this recording.")
            }
        }
    }

    private var isRunning = false

    static func segments(
        for url: URL,
        onProgress: @escaping @Sendable (SpeakerProcessingProgress) -> Void = { _ in }
    ) async throws -> [SpeakerTimeRange] {
        try await shared.analyze(url, onProgress: onProgress)
    }

    private func analyze(
        _ url: URL, onProgress: @escaping @Sendable (SpeakerProcessingProgress) -> Void
    ) async throws -> [SpeakerTimeRange] {
        guard !isRunning else { throw EngineError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        guard let directory = Self.bundledModelDirectory() else { throw EngineError.missingBundledModel }
        return try await Self.segments(for: url, modelDirectory: directory, onProgress: onProgress)
    }

    /// The Nemotron model shipped inside the app, nil in a build without it.
    static func bundledModelDirectory() -> URL? {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("SpeakerDiarizationModel", isDirectory: true),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return directory
    }

    /// Loads the 8-bit streaming model on CPU and Neural Engine, which iOS
    /// also allows while the app is in the background.
    static func loadModels(from directory: URL) async throws -> (Nemotron3Config, Nemotron3Models) {
        guard let config = Nemotron3Config.preset(named: "c128-split-w8a8") else {
            throw EngineError.invalidModelOutput
        }
        let models = try await Nemotron3Models.load(
            config: config, directory: directory, computeUnits: .cpuAndNeuralEngine
        )
        return (config, models)
    }

    private static func segments(
        for url: URL, modelDirectory: URL, onProgress: @Sendable (SpeakerProcessingProgress) -> Void
    ) async throws -> [SpeakerTimeRange] {
        try Task.checkCancellation()
        let (config, models) = try await loadModels(from: modelDirectory)
        try Task.checkCancellation()

        let diarizer = Nemotron3Diarizer(config: config, models: models)
        var activity = SpeakerActivitySegments(speakerCount: config.numSpeakers)
        var totalFrames = 0
        var reportedFrames = 0
        func consume(_ chunks: [Nemotron3ChunkResult]) throws {
            for chunk in chunks {
                try Task.checkCancellation()
                try activity.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
                // Reserve completion until the stream and its output ranges are finalized.
                let completed = min(activity.processedFrameCount, totalFrames - 1)
                guard completed > reportedFrames else { continue }
                reportedFrames = completed
                onProgress(.init(completedUnits: completed, totalUnits: totalFrames))
            }
        }

        let duration = try readAudio(url, onDuration: { sourceDuration in
            // Nemotron returns one prediction per 10 ms frame, excluding tail padding.
            let frames = (sourceDuration * 100).rounded(.up)
            guard frames > 0, frames < Double(Int.max) else { throw EngineError.unreadableAudio }
            totalFrames = Int(frames)
            onProgress(.init(completedUnits: 0, totalUnits: totalFrames))
        }) { samples in
            diarizer.appendAudio(samples)
            try consume(diarizer.processBufferedAudio())
        }
        try Task.checkCancellation()
        try consume(diarizer.finishStream())
        let ranges = activity.finish(duration: duration)
        try Task.checkCancellation()
        onProgress(.init(completedUnits: totalFrames, totalUnits: totalFrames))
        return ranges
    }

    /// Only the few seconds needed by the streaming frontend are decoded at once.
    /// Mix stereo explicitly: on Catalyst a channel-count conversion can produce zeros.
    static func readAudio(
        _ url: URL, onDuration: (Double) throws -> Void = { _ in }, receive: ([Float]) throws -> Void
    ) throws -> Double {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceFormat = input.processingFormat
        let targetRate = 16_000.0
        guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0,
              let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate,
                channels: 1, interleaved: false
              ),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false
              ),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 32_768)
        else {
            throw EngineError.unreadableAudio
        }
        try Task.checkCancellation()
        try onDuration(Double(input.length) / sourceFormat.sampleRate)

        let inputCapacity: AVAudioFrameCount = 32_768
        var inputExhausted = false
        var inputError: Error?
        var emittedSamples = 0
        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool {
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, state in
                    guard !inputExhausted, input.framePosition < input.length else {
                        inputExhausted = true
                        state.pointee = .endOfStream
                        return nil
                    }

                    do {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputCapacity) else {
                            throw EngineError.unreadableAudio
                        }
                        try input.read(into: buffer, frameCount: inputCapacity)
                        guard buffer.frameLength > 0 else {
                            inputExhausted = true
                            state.pointee = .endOfStream
                            return nil
                        }
                        guard let mixed = AudioRecordingService.mixedDownToMono(buffer),
                              let mono = Self.matchMonoFormat(mixed, format: monoFormat) else {
                            throw EngineError.unreadableAudio
                        }
                        state.pointee = .haveData
                        return mono
                    } catch {
                        inputError = error
                        inputExhausted = true
                        state.pointee = .endOfStream
                        return nil
                    }
                }
                if let inputError { throw inputError }
                if status == .error { throw conversionError ?? EngineError.unreadableAudio }
                if output.frameLength > 0 {
                    guard let data = output.floatChannelData?[0] else { throw EngineError.unreadableAudio }
                    emittedSamples += Int(output.frameLength)
                    try receive(Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength))))
                }
                return status == .endOfStream || (status == .inputRanDry && inputExhausted)
            }
            if finished { break }
        }
        guard emittedSamples > 0 else { throw EngineError.unreadableAudio }
        return Double(emittedSamples) / targetRate
    }

    private static func matchMonoFormat(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let input = buffer.floatChannelData?[0],
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let output = copy.floatChannelData?[0] else { return nil }
        output.update(from: input, count: Int(buffer.frameLength))
        copy.frameLength = buffer.frameLength
        return copy
    }
}

/// Converts 10 ms probabilities to ranges without accumulating a recording's full frame matrix.
struct SpeakerActivitySegments {
    private let speakerCount: Int
    private var firstFrames: [Int?]
    private var position = 0
    private var completed: [SpeakerTimeRange] = []

    var processedFrameCount: Int { position }

    init(speakerCount: Int) {
        self.speakerCount = speakerCount
        self.firstFrames = Array(repeating: nil, count: speakerCount)
    }

    mutating func append(probabilities: [Float], frameCount: Int) throws {
        guard frameCount >= 0, speakerCount > 0,
              probabilities.count % speakerCount == 0, probabilities.count / speakerCount == frameCount else {
            throw SpeakerDiarizationEngine.EngineError.invalidModelOutput
        }
        for frame in 0..<frameCount {
            for speaker in 0..<speakerCount {
                if probabilities[frame * speakerCount + speaker] > 0.5 {
                    if firstFrames[speaker] == nil { firstFrames[speaker] = position }
                } else {
                    close(speaker)
                }
            }
            position += 1
        }
    }

    /// The ranges so far, with turns still running cut off at `duration`.
    func snapshot(duration: Double) -> [SpeakerTimeRange] {
        var copy = self
        return copy.finish(duration: duration)
    }

    mutating func finish(duration: Double) -> [SpeakerTimeRange] {
        for speaker in 0..<speakerCount { close(speaker) }
        return completed.compactMap { range in
            let end = min(range.end, duration)
            guard end > range.start else { return nil }
            return SpeakerTimeRange(speaker: range.speaker, start: range.start, end: end)
        }.sorted {
            ($0.start, $0.speaker, $0.end) < ($1.start, $1.speaker, $1.end)
        }
    }

    private mutating func close(_ speaker: Int) {
        guard let start = firstFrames[speaker] else { return }
        firstFrames[speaker] = nil
        guard position - start >= 20 else { return }
        completed.append(SpeakerTimeRange(speaker: speaker, start: Double(start) / 100, end: Double(position) / 100))
    }
}
