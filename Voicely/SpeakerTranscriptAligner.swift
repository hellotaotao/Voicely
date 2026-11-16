import AudioCommon
import Foundation
#if targetEnvironment(macCatalyst)
import AVFoundation
import CryptoKit
import MLX
import MLXCommon
import Qwen3ASR
#endif

/// Places the existing transcript on the audio clock without changing its text or
/// sending it anywhere. Use original word times whenever a span already has them.
enum SpeakerTranscriptAligner {
    enum AlignmentError: LocalizedError {
        case unsupportedPlatform
        case unsupportedTimeline
        case noAlignedSpeech
        case audioUnavailable
        case modelUnavailable
        case busy

        var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                String(localized: "Speaker identification can be run on a Mac.")
            case .unsupportedTimeline:
                String(localized: "This recording needs to be transcribed again before identifying speakers.")
            case .noAlignedSpeech:
                String(localized: "The transcript could not be matched to speech in this recording.")
            case .audioUnavailable:
                String(localized: "The recording could not be read to identify speakers.")
            case .modelUnavailable:
                String(localized: "The transcript alignment model could not be installed or loaded.")
            case .busy:
                String(localized: "Speaker identification is already running.")
            }
        }
    }

    static var isModelInstalled: Bool {
        #if targetEnvironment(macCatalyst)
        SpeakerAlignmentModel.directory.map(SpeakerAlignmentModel.hasExpectedFiles(in:)) ?? false
        #else
        false
        #endif
    }

    /// Prepares weights without allocating the model so the UI can distinguish
    /// a first-use download from the local inference work.
    static func prepareModel() async throws {
        #if targetEnvironment(macCatalyst)
        try await Worker.shared.prepareModel()
        #else
        throw AlignmentError.unsupportedPlatform
        #endif
    }

    static func align(
        audioURL: URL,
        text: String,
        spans: [TranscriptSpan],
        isEnglish: Bool
    ) async throws -> [SpeakerAlignedToken] {
        guard let plan = SpeakerTimingPlan(text: text, spans: spans) else { throw AlignmentError.unsupportedTimeline }
        return try await align(audioURL: audioURL, plan: plan, isEnglish: isEnglish)
    }

    static func align(
        audioURL: URL,
        plan: SpeakerTimingPlan,
        isEnglish: Bool,
        onProgress: @escaping @Sendable (SpeakerProcessingProgress) -> Void = { _ in }
    ) async throws -> [SpeakerAlignedToken] {
        try Task.checkCancellation()
        guard plan.requiresForcedAlignment else {
            guard !plan.storedTokens.isEmpty else { throw AlignmentError.noAlignedSpeech }
            return plan.storedTokens
        }
        #if targetEnvironment(macCatalyst)
        return try await Worker.shared.align(
            audioURL: audioURL, plan: plan, isEnglish: isEnglish, onProgress: onProgress)
        #else
        throw AlignmentError.unsupportedPlatform
        #endif
    }

    /// Match the aligner's surface words monotonically to the stored text. The
    /// aligner can glue punctuation from one sentence to a word in the next;
    /// only letters and numbers count as evidence for this word's range.
    /// Never scan past unmatched speech, or a repeated word could be mislabeled.
    static func mapTokens(
        _ words: [AlignedWord],
        in text: String,
        utf16Offset: Int,
        spanStart: Double,
        duration: Double
    ) -> [SpeakerAlignedToken] {
        guard utf16Offset >= 0, utf16Offset <= Int.max - text.utf16.count,
              spanStart.isFinite, spanStart >= 0, duration.isFinite, duration > 0 else { return [] }
        var source: [(scalar: Unicode.Scalar, start: Int, end: Int)] = []
        var offset = utf16Offset
        for character in text {
            let grapheme = String(character)
            let end = offset + grapheme.utf16.count
            for scalar in matchScalars(grapheme) {
                source.append((scalar, offset, end))
            }
            offset = end
        }

        var output: [SpeakerAlignedToken] = []
        var cursor = 0
        for word in words {
            let scalars = matchScalars(word.text)
            guard !scalars.isEmpty else { continue }
            guard scalars.count <= source.count - cursor else { break }
            let next = cursor + scalars.count
            guard zip(source[cursor..<next], scalars).allSatisfy({ $0.0.scalar == $0.1 }) else { break }
            let startOffset = source[cursor].start
            let endOffset = source[next - 1].end
            if next < source.count, source[next].start < endOffset {
                // An individual candidate must not split a rendered grapheme.
                break
            }
            cursor = next
            let start = Double(word.startTime), end = Double(word.endTime)
            // Timestamp classes are spaced 80 ms apart; allow one step of
            // rounding at the end of the audio, never a materially late token.
            guard start.isFinite, end.isFinite, start >= 0,
                  end <= duration + 0.081, start < min(end, duration) else { continue }
            output.append(SpeakerAlignedToken(range: NSRange(location: startOffset, length: endOffset - startOffset),
                                              start: spanStart + start, end: spanStart + min(end, duration)))
        }
        return output
    }

    private static func matchScalars(_ text: String) -> [Unicode.Scalar] {
        // Unlike CharacterSet.alphanumerics this excludes standalone marks
        // such as an emoji variation selector.
        text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter(SpeakerTimingPlan.isSpokenScalar)
    }
}

#if targetEnvironment(macCatalyst)
extension SpeakerTranscriptAligner {
    fileprivate actor Worker {
        static let shared = Worker()

        /// New notes already carry ~29 s spans. Bounded processing also avoids
        /// assigning words to guessed cuts on old, single-span long recordings.
        private static let longestSpan = 60.0
        private static let longestText = 1_200
        private var active = false
        private var preparedDirectory: URL?

        func prepareModel() async throws {
            guard !active else { throw AlignmentError.busy }
            active = true
            defer { active = false }
            preparedDirectory = nil
            preparedDirectory = try await installedModelDirectory(allowDownload: true)
        }

        func align(
            audioURL: URL,
            plan: SpeakerTimingPlan,
            isEnglish: Bool,
            modelDirectory: URL? = nil,
            onProgress: @Sendable (SpeakerProcessingProgress) -> Void
        ) async throws -> [SpeakerAlignedToken] {
            guard !active else { throw AlignmentError.busy }
            active = true
            defer { active = false }

            let audio: AVAudioFile
            do {
                audio = try AVAudioFile(forReading: audioURL)
            } catch {
                throw AlignmentError.audioUnavailable
            }
            let sampleRate = audio.processingFormat.sampleRate
            guard sampleRate.isFinite, sampleRate > 0, audio.length > 0 else {
                throw AlignmentError.audioUnavailable
            }
            let limit = audio.length
            let length = Double(limit) / sampleRate
            for span in plan.fallbackSpans {
                guard span.text.utf16.count <= Self.longestText, span.start < length,
                      span.end > span.start, span.end <= length + 0.25, span.end - span.start <= Self.longestSpan
                else { throw AlignmentError.unsupportedTimeline }
            }

            let directory: URL
            do {
                if let modelDirectory {
                    try SpeakerAlignmentModel.verifyFiles(in: modelDirectory)
                    directory = modelDirectory
                } else if let preparedDirectory, SpeakerAlignmentModel.hasExpectedFiles(in: preparedDirectory) {
                    directory = preparedDirectory
                    self.preparedDirectory = nil
                } else {
                    preparedDirectory = nil
                    directory = try await installedModelDirectory(allowDownload: false)
                }
            } catch {
                try Task.checkCancellation()
                throw AlignmentError.modelUnavailable
            }
            try Task.checkCancellation()

            let previousCacheLimit = Memory.cacheLimit
            var aligner: Qwen3ForcedAligner?
            Memory.cacheLimit = 0
            MetalBudget.unpinMemory()
            defer {
                aligner = nil
                Memory.clearCache()
                Memory.cacheLimit = previousCacheLimit
            }
            do {
                aligner = try await Qwen3ForcedAligner.fromPretrained(
                    modelId: SpeakerAlignmentModel.modelID, cacheDir: directory, offlineMode: true)
            } catch {
                try Task.checkCancellation()
                throw AlignmentError.modelUnavailable
            }

            let totalUnits = plan.fallbackSpans.count
            try Task.checkCancellation()
            onProgress(.init(completedUnits: 0, totalUnits: totalUnits))
            var result = plan.storedTokens
            for (index, span) in plan.fallbackSpans.enumerated() {
                try Task.checkCancellation()
                let piece = span.text
                let startFrame = min(limit, AVAudioFramePosition((span.start * sampleRate).rounded()))
                let endFrame = min(limit, AVAudioFramePosition((min(span.end, length) * sampleRate).rounded()))
                if startFrame < endFrame {
                    let samples = try Self.samples(audioURL: audioURL, from: startFrame, to: endFrame, index: index)
                    if !samples.isEmpty {
                        let words = aligner?.align(audio: samples, text: piece, sampleRate: 16_000,
                                                   language: Self.language(for: piece, isEnglish: isEnglish)) ?? []
                        result += mapTokens(words, in: piece, utf16Offset: span.utf16Offset,
                                            spanStart: Double(startFrame) / sampleRate,
                                            duration: Double(samples.count) / 16_000)
                    }
                }
                try Task.checkCancellation()
                onProgress(.init(completedUnits: index + 1, totalUnits: totalUnits))
            }
            try Task.checkCancellation()
            guard !result.isEmpty else { throw AlignmentError.noAlignedSpeech }
            return result.sorted { $0.range.location < $1.range.location }
        }

        private func installedModelDirectory(allowDownload: Bool) async throws -> URL {
            do {
                return try await SpeakerAlignmentModel.install(allowDownload: allowDownload)
            } catch {
                try Task.checkCancellation()
                throw AlignmentError.modelUnavailable
            }
        }

        private static func samples(
            audioURL: URL, from startFrame: AVAudioFramePosition, to endFrame: AVAudioFramePosition, index: Int
        ) throws -> [Float] {
            guard let url = IncrementalTranscriptionCoordinator.extractSegment(
                fileURL: audioURL, from: startFrame, to: endFrame, segmentIndex: index) else {
                throw AlignmentError.audioUnavailable
            }
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                return try Qwen3AudioPCM.loadPCM16kMono(url: url)
            } catch {
                throw AlignmentError.audioUnavailable
            }
        }

        private static func language(for text: String, isEnglish: Bool) -> String {
            guard !isEnglish else { return "English" }
            let textScalars = text.unicodeScalars
            if textScalars.contains(where: { (0x3041...0x30FA).contains($0.value) }) { return "Japanese" }
            if textScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return "Korean" }
            // The alignment tokenizer splits mixed English/Han by script.
            return "Chinese"
        }
    }

    #if DEBUG
    static func alignWithLocalModelForTesting(
        audioURL: URL,
        text: String,
        spans: [TranscriptSpan],
        isEnglish: Bool,
        modelDirectory: URL,
        onProgress: @escaping @Sendable (SpeakerProcessingProgress) -> Void = { _ in }
    ) async throws -> [SpeakerAlignedToken] {
        guard let plan = SpeakerTimingPlan(text: text, spans: spans) else { throw AlignmentError.unsupportedTimeline }
        guard plan.requiresForcedAlignment else {
            return try await align(audioURL: audioURL, plan: plan, isEnglish: isEnglish, onProgress: onProgress)
        }
        return try await Worker.shared.align(
            audioURL: audioURL, plan: plan, isEnglish: isEnglish, modelDirectory: modelDirectory,
            onProgress: onProgress)
    }
    #endif
}

private enum SpeakerAlignmentModel {
    static let modelID = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"
    // Apache-2.0 MLX conversion of Qwen's forced alignment model.
    private static let revision = "f0e9f12a0ddbcb5f1e1b7f0339090628f1cede1d"

    private struct Asset: Sendable {
        var file: String
        var bytes: Int
        var digest: String
    }

    private static let assets: [Asset] = [
        .init(file: "config.json", bytes: 5_982, digest: "d616c65d46c4b90bdc651b0a0963ea932732241140f337f9bb6b0335a9c8ef09"),
        .init(file: "merges.txt", bytes: 1_671_853, digest: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init(file: "quantize_config.json", bytes: 214, digest: "ca0ac4de959081ae1ec67cd57f441faa4bb5f6c4704e8700a83879807f11b490"),
        .init(file: "tokenizer_config.json", bytes: 12_666, digest: "3ab80063f8511deb9566e6ad438d17b7a6277fcffd52d92854112f19d36bd81c"),
        .init(file: "vocab.json", bytes: 2_776_833, digest: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        .init(file: "model.safetensors", bytes: 978_674_048, digest: "8187bcb2ab9046cbb274559523d21f60249410ccc561682bc5860b07101c5568")
    ]

    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Voicely/SpeakerAlignment/\(revision)", isDirectory: true)
    }

    static func hasExpectedFiles(in directory: URL) -> Bool {
        assets.allSatisfy { asset in
            let url = directory.appendingPathComponent(asset.file)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return values?.isRegularFile == true && values?.fileSize == asset.bytes
        }
    }

    static func verifyFiles(in directory: URL) throws {
        guard hasExpectedFiles(in: directory) else { throw SpeakerTranscriptAligner.AlignmentError.modelUnavailable }
        let weights = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".safetensors") }
        guard weights == ["model.safetensors"] else { throw SpeakerTranscriptAligner.AlignmentError.modelUnavailable }
        for asset in assets {
            try verifyDigest(of: directory.appendingPathComponent(asset.file), expected: asset.digest)
        }
    }

    static func install(allowDownload: Bool) async throws -> URL {
        let fm = FileManager.default
        guard let directory else { throw SpeakerTranscriptAligner.AlignmentError.modelUnavailable }
        if hasExpectedFiles(in: directory) {
            do {
                try verifyFiles(in: directory)
                return directory
            } catch {
                try Task.checkCancellation()
                try? fm.removeItem(at: directory)
                throw error
            }
        }
        // Only the explicit, consent-gated preparation path can use the network.
        // A cache may disappear after the UI decides it is already installed.
        guard allowDownload else { throw SpeakerTranscriptAligner.AlignmentError.modelUnavailable }

        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("Downloading-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let base = URL(string: "https://huggingface.co/\(modelID)/resolve/\(revision)/")!
        for asset in assets {
            try Task.checkCancellation()
            let (file, response) = try await session.download(from: base.appendingPathComponent(asset.file))
            defer { try? fm.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.bytes else {
                throw SpeakerTranscriptAligner.AlignmentError.modelUnavailable
            }
            try verifyDigest(of: file, expected: asset.digest)
            try fm.moveItem(at: file, to: staging.appendingPathComponent(asset.file))
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: directory.path) {
            if hasExpectedFiles(in: directory) {
                try verifyFiles(in: directory)
                return directory
            }
            try fm.removeItem(at: directory)
        }
        do {
            try fm.moveItem(at: staging, to: directory)
        } catch where hasExpectedFiles(in: directory) {
            // Another app instance finished installing the identical revision.
            try verifyFiles(in: directory)
        }
        return directory
    }

    private static func verifyDigest(of url: URL, expected: String) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw SpeakerTranscriptAligner.AlignmentError.modelUnavailable }
    }
}
#endif
