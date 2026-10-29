import Foundation

/// One slice of a transcribed recording as Qwen3-ASR left it: where it sits,
/// its text, and the language the model named for it.
struct LanguageTaggedSlice: Codable, Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    /// Nil when the slice holds no text (silence, a slice the gate skipped).
    var text: String?
    /// The language Qwen3-ASR wrote for the slice ("English", "Chinese",
    /// "None", …). Nil when it decoded with a language hint, found no speech,
    /// or failed.
    var language: String?
}

/// A word Parakeet transcribed, timed in seconds from the start of the recording.
struct TimedWord: Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Which slices of a recording Parakeet transcribes again.
///
/// Parakeet TDT v2 is more accurate than Qwen3-ASR on English and only knows
/// English, so it takes over long English stretches and nothing else:
/// - Reading the slices in order, consecutive English slices form a stretch.
///   A slice tagged with any other language ends it; English after that
///   starts a new one.
/// - Slices tagged "None" or without a tag (silence, gated slices, failures)
///   neither end a stretch nor start one. Between two English slices they go
///   to Parakeet with the stretch; before its first or after its last English
///   slice they stay with Qwen3-ASR.
/// - A stretch counts only when it runs at least `minimumStretchSeconds`
///   from its first English slice's start to its last one's end, so
///   recordings that switch back and forth keep Qwen3-ASR throughout.
enum EnglishStretchRouting {
    static let minimumStretchSeconds: TimeInterval = 180
    static let englishTag = "English"

    /// How the language for a recording was chosen.
    enum Mode: Equatable, Sendable {
        /// Auto-detect: Parakeet takes the long English stretches.
        case automatic
        /// The user chose English: Parakeet transcribes the whole recording.
        case english
        /// The user chose another language: Parakeet is never used.
        case otherLanguage

        init(languageHint: String?) {
            switch languageHint {
            case nil: self = .automatic
            case englishTag?: self = .english
            default: self = .otherLanguage
            }
        }
    }

    /// Index ranges of the slices Parakeet transcribes again.
    static func stretches(
        in slices: [LanguageTaggedSlice],
        mode: Mode,
        minimumSeconds: TimeInterval = minimumStretchSeconds
    ) -> [ClosedRange<Int>] {
        switch mode {
        case .otherLanguage:
            return []
        case .english:
            return slices.isEmpty ? [] : [0...(slices.count - 1)]
        case .automatic:
            break
        }
        var result: [ClosedRange<Int>] = []
        var first: Int?
        var last: Int?
        func close() {
            if let first, let last, slices[last].end - slices[first].start >= minimumSeconds {
                result.append(first...last)
            }
            first = nil
            last = nil
        }
        for (index, slice) in slices.enumerated() {
            switch slice.language {
            case englishTag?:
                if first == nil { first = index }
                last = index
            case nil, "None"?:
                continue
            default:
                close()
            }
        }
        close()
        return result
    }

    /// Transcribes one stretch of a file with Parakeet: the file, its first
    /// and end frame. Returns the words timed from the start of the file.
    typealias Transcriber = (URL, Int64, Int64) async throws -> [TimedWord]

    /// Transcribes the stretches `stretches(in:mode:)` picks with Parakeet and
    /// puts its words in their slices. Returns the slices and the indices it
    /// replaced; a stretch that fails keeps Qwen3-ASR's text.
    static func transcribeStretches(
        in slices: [LanguageTaggedSlice],
        mode: Mode,
        fileURL: URL,
        sampleRate: Double,
        transcribe: Transcriber
    ) async -> (slices: [LanguageTaggedSlice], replaced: [Int]) {
        var result = slices
        var replaced: [Int] = []
        for stretch in stretches(in: slices, mode: mode) {
            if Task.isCancelled { break }
            let start = Int64((slices[stretch.lowerBound].start * sampleRate).rounded())
            let end = Int64((slices[stretch.upperBound].end * sampleRate).rounded())
            let words: [TimedWord]
            do {
                words = try await transcribe(fileURL, start, end)
            } catch {
                debugLog("⚠️ [EnglishStretchRouting] Parakeet failed on \(slices[stretch.lowerBound].start)–\(slices[stretch.upperBound].end) s: \(error)")
                continue
            }
            let texts = distribute(words, over: Array(slices[stretch]))
            for (index, text) in zip(stretch, texts) {
                result[index].text = LocalTranscriptFinalizer.finalizedText(text)
                replaced.append(index)
            }
        }
        return (result, replaced)
    }

    /// The transcript the slices make, one line per slice with text, and its spans.
    static func transcript(of slices: [LanguageTaggedSlice]) -> (text: String, spans: [TranscriptSpan]?) {
        var builder = TranscriptSpanBuilder()
        var lines: [String] = []
        for slice in slices {
            guard let text = slice.text else { continue }
            lines.append(text)
            builder.append(text, start: slice.start, end: slice.end)
        }
        return (lines.joined(separator: "\n"), builder.spans)
    }

    /// Hands each word to the slice its midpoint falls in, so the transcript
    /// keeps one line per slice and the slices' times stay its timeline.
    /// Slices are cut at pauses, so a word rarely straddles a boundary.
    /// Words outside every slice go to the nearest one. Returns one text per
    /// slice, nil where Parakeet heard nothing.
    static func distribute(_ words: [TimedWord], over slices: [LanguageTaggedSlice]) -> [String?] {
        guard !slices.isEmpty else { return [] }
        var buckets = [[String]](repeating: [], count: slices.count)
        var index = 0
        for word in words.sorted(by: { $0.start < $1.start }) {
            let middle = (word.start + word.end) / 2
            while index < slices.count - 1, middle >= slices[index].end { index += 1 }
            buckets[index].append(word.text)
        }
        return buckets.map { $0.isEmpty ? nil : $0.joined(separator: " ") }
    }
}

/// A recording's transcript in the version the app is not showing, kept so the
/// user can switch back. Stored on the note as JSON, together with a digest
/// of the text shown next to it: once that text changes (an edit, a new
/// transcription), the stored version no longer belongs to it.
struct AlternateTranscript: Codable, Equatable, Sendable {
    enum Engine: String, Codable, Sendable {
        case qwen3
        case parakeet

        var displayName: String {
            switch self {
            case .qwen3: return "Qwen3-ASR"
            case .parakeet: return "Parakeet"
            }
        }
    }

    /// Which version `text` is: `.qwen3` is Qwen3-ASR alone, `.parakeet` has
    /// Parakeet's text in the English stretches.
    var engine: Engine
    var text: String
    var spans: [TranscriptSpan]?
    var shownTextDigest: String = ""
}
