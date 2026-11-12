import Foundation
import NaturalLanguage

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
///   A slice tagged with any other language, or whose text does not read as
///   English (`readsAsEnglish`), ends it and stays with Qwen3-ASR; English
///   after that starts a new one.
/// - Slices tagged "None" or without a tag (silence, gated slices, failures)
///   neither end a stretch nor start one. Between two English slices they go
///   to Parakeet with the stretch; before its first or after its last English
///   slice they stay with Qwen3-ASR.
/// - A stretch counts only when it runs at least `minimumStretchSeconds`
///   from its first English slice's start to its last one's end, so
///   recordings that switch back and forth keep Qwen3-ASR throughout.
/// - A recording with no other language needs no minimum: its English goes
///   to Parakeet however short it is.
///
/// The tag and the text both count because each catches what the other
/// misses: a slice that mixes another language into English is often tagged
/// English, and Qwen3-ASR sometimes writes foreign speech as English while
/// still naming the language.
enum EnglishStretchRouting {
    static let minimumStretchSeconds: TimeInterval = 180
    static let englishTag = "English"
    /// The language recognizer is unreliable on shorter sentences: it reads
    /// "Bye." as Danish.
    static let minimumCheckedSentenceWords = 5
    /// A sentence the recognizer gives to another language still counts as
    /// English when it rates English at least this high.
    static let englishConfidenceToKeepSentence = 0.5
    /// Spoken fillers, which the recognizer reads as words of other languages:
    /// "um" as Portuguese.
    private static let fillerPattern = #"\b(um+|uh+|er+m?|ah+|hm+|mm+)\b[,.]?\s*"#
    /// Added to a note's model identifier when Parakeet replaced part of its text.
    static let parakeetModelSuffix = "+parakeet"
    /// A note's model identifier when Parakeet wrote all of its text.
    static let parakeetOnlyModelIdentifier = "parakeet-tdt-0.6b-v2"

    /// The model identifier of a note whose text Parakeet replaced in part.
    /// Qwen3-ASR names no model when it hears no speech: `nil` means this device's.
    static func modelIdentifier(afterParakeet identifier: String?) -> String {
        let qwen = identifier == parakeetOnlyModelIdentifier ? nil : identifier
        let identifier = qwen ?? Qwen3Backend.current.modelIdentifier
        return identifier.hasSuffix(parakeetModelSuffix) ? identifier : identifier + parakeetModelSuffix
    }

    /// The model identifier of a note from who wrote the text it holds:
    /// Parakeet's own when Parakeet wrote all of it, Qwen3-ASR's marked when
    /// both did, else Qwen3-ASR's.
    static func modelIdentifier(parakeetWrote: Bool, qwenWrote: Bool, qwenIdentifier: String?) -> String? {
        guard parakeetWrote else { return qwenIdentifier }
        return qwenWrote ? modelIdentifier(afterParakeet: qwenIdentifier) : parakeetOnlyModelIdentifier
    }

    /// The model identifier of a note after Parakeet replaced the `replaced`
    /// slices. A replaced slice Parakeet heard nothing in is no one's text.
    static func modelIdentifier(
        afterParakeetReplaced replaced: [Int], in slices: [LanguageTaggedSlice], qwenIdentifier: String?
    ) -> String? {
        let replaced = Set(replaced)
        return modelIdentifier(
            parakeetWrote: replaced.contains { slices[$0].text != nil },
            qwenWrote: slices.indices.contains { !replaced.contains($0) && slices[$0].text != nil },
            qwenIdentifier: qwenIdentifier)
    }

    /// How the language for a recording was chosen.
    enum Mode: Equatable, Sendable {
        /// Auto-detect: Parakeet takes the long English stretches.
        case automatic
        /// The user chose English: Parakeet transcribes the whole recording.
        case english

        init(languageHint: String?) {
            self = languageHint == englishTag ? .english : .automatic
        }
    }

    /// The slice a file decoded in one pass makes: all of it, with what
    /// Qwen3-ASR wrote and named for it.
    static func onePassSlice(_ outcome: TranscriptionOutcome, duration: TimeInterval) -> LanguageTaggedSlice {
        var slice = LanguageTaggedSlice(start: 0, end: duration, text: nil, language: nil)
        if case .transcribed(let result) = outcome {
            slice.text = LocalTranscriptFinalizer.finalizedText(result.text)
            slice.language = slice.text == nil ? nil : result.language
        }
        return slice
    }

    /// Index ranges of the slices Parakeet transcribes again.
    static func stretches(
        in slices: [LanguageTaggedSlice],
        mode: Mode,
        minimumSeconds: TimeInterval = minimumStretchSeconds
    ) -> [ClosedRange<Int>] {
        switch mode {
        case .english:
            return slices.isEmpty ? [] : [0...(slices.count - 1)]
        case .automatic:
            break
        }
        let mayBeEnglish = slices.map(Self.mayBeEnglish)
        let minimumSeconds = mayBeEnglish.allSatisfy { $0 } ? 0 : minimumSeconds
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
            if !mayBeEnglish[index] {
                close()
            } else if slice.language == englishTag {
                if first == nil { first = index }
                last = index
            }
        }
        close()
        return result
    }

    /// `stretches(in:mode:)` off the main actor: the text check takes a few
    /// milliseconds a slice, which adds up on a long recording.
    static func stretchesInBackground(in slices: [LanguageTaggedSlice], mode: Mode) async -> [ClosedRange<Int>] {
        await Task.detached(priority: .utility) { stretches(in: slices, mode: mode) }.value
    }

    /// False when the slice's tag or its text points to another language.
    private static func mayBeEnglish(_ slice: LanguageTaggedSlice) -> Bool {
        switch slice.language {
        case englishTag?, nil, "None"?: return slice.text.map(readsAsEnglish) ?? true
        default: return false
        }
    }

    /// False when the text shows another language: a letter outside the Latin
    /// alphabet, or a sentence the system's language recognizer gives to
    /// another language. The recognizer has to be asked sentence by sentence:
    /// asked about a whole slice, it names the language most of it is in and
    /// answers English even for half English, half Chinese. It cannot see a
    /// few foreign words inside an English sentence.
    static func readsAsEnglish(_ text: String) -> Bool {
        guard !hasNonLatinLetters(text) else { return false }
        let text = text.replacingOccurrences(
            of: fillerPattern, with: "", options: [.regularExpression, .caseInsensitive])
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return !tokenizer.tokens(for: text.startIndex..<text.endIndex).contains {
            isInAnotherLanguage(text[$0].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// A whole transcript still reads as English with up to this share of its
    /// checked sentences, by characters, given to another language. Across
    /// the Latin-only notes on the Mac (2026-11-08) the recognizer misread
    /// one English sentence in a few long English notes (0.06–0.31%), while
    /// notes with real foreign passages ran 4% and up.
    static let foreignShareForEnglishTranscript = 0.01

    /// Whether a note's whole transcript reads as English, which picks the
    /// language a re-transcription uses. Any letter outside the Latin alphabet
    /// rules it out, as in `readsAsEnglish(_:)`; sentences of another language
    /// rule it out only above `foreignShareForEnglishTranscript`, because one
    /// misread sentence in an hour of English is not a second language.
    static func transcriptReadsAsEnglish(_ text: String) -> Bool {
        guard !hasNonLatinLetters(text) else { return false }
        let text = text.replacingOccurrences(
            of: fillerPattern, with: "", options: [.regularExpression, .caseInsensitive])
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var checked = 0
        var foreign = 0
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isChecked(sentence) else { continue }
            checked += sentence.count
            if isGivenToAnotherLanguage(sentence) { foreign += sentence.count }
        }
        return Double(foreign) <= Double(checked) * foreignShareForEnglishTranscript
    }

    private static func isChecked(_ sentence: String) -> Bool {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        return tokenizer.tokens(for: sentence.startIndex..<sentence.endIndex).count >= minimumCheckedSentenceWords
    }

    private static func hasNonLatinLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !scalar.isASCII && scalar.properties.isAlphabetic
                && !(scalar.properties.name?.hasPrefix("LATIN") ?? false)
        }
    }

    private static func isInAnotherLanguage(_ sentence: String) -> Bool {
        guard isChecked(sentence) else { return false }
        return isGivenToAnotherLanguage(sentence)
    }

    private static func isGivenToAnotherLanguage(_ sentence: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sentence)
        guard let language = recognizer.dominantLanguage, language != .english, language != .undetermined else {
            return false
        }
        return (recognizer.languageHypotheses(withMaximum: 30)[.english] ?? 0) < englishConfidenceToKeepSentence
    }

    /// Transcribes one stretch of a file with Parakeet: the file, its first
    /// and end frame. Returns the words timed from the start of the file.
    typealias Transcriber = (URL, Int64, Int64) async throws -> [TimedWord]

    /// Transcribes the stretches of `slices` with Parakeet and puts its words
    /// in their slices. Returns the slices and the indices it replaced; a
    /// stretch that fails keeps Qwen3-ASR's text.
    /// The recording frames a stretch of slices covers.
    static func frameRange(
        of stretch: ClosedRange<Int>,
        in slices: [LanguageTaggedSlice],
        sampleRate: Double
    ) -> (start: Int64, end: Int64) {
        (Int64((slices[stretch.lowerBound].start * sampleRate).rounded()),
         Int64((slices[stretch.upperBound].end * sampleRate).rounded()))
    }

    static func transcribeStretches(
        _ stretches: [ClosedRange<Int>],
        in slices: [LanguageTaggedSlice],
        fileURL: URL,
        sampleRate: Double,
        transcribe: Transcriber
    ) async -> (slices: [LanguageTaggedSlice], replaced: [Int]) {
        var result = slices
        var replaced: [Int] = []
        for stretch in stretches {
            if Task.isCancelled { break }
            let (start, end) = frameRange(of: stretch, in: slices, sampleRate: sampleRate)
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
