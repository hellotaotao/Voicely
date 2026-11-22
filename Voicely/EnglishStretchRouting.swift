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
    var wordTimings: [TranscriptWordTiming]? = nil
}

/// A word Parakeet transcribed, timed in seconds from the start of the recording.
struct TimedWord: Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Which slices of a recording Parakeet transcribes again.
///
/// Parakeet Ultra is more accurate than Qwen3-ASR on English and the
/// European languages it knows, and cannot write Chinese at all, so with
/// Qwen3-ASR chosen it takes over long stretches in its languages and nothing
/// else:
/// - Reading the slices in order, consecutive slices tagged with one of
///   Parakeet's languages (`parakeetLanguageTags`: English, French and German
///   alike) form a stretch. A slice tagged with any other language, or whose
///   text shows a language Parakeet lacks (`readsAsParakeetLanguage`), ends it
///   and stays with Qwen3-ASR; Parakeet's languages after that start a new one.
/// - Slices tagged "None" or without a tag (silence, gated slices, failures)
///   neither end a stretch nor start one. Between two of Parakeet's slices
///   they go to Parakeet with the stretch; before its first or after its last
///   such slice they stay with Qwen3-ASR.
/// - A stretch counts only when it runs at least `minimumStretchSeconds`
///   from its first tagged slice's start to its last one's end, so
///   recordings that switch back and forth keep Qwen3-ASR throughout.
/// - A recording with no other language needs no minimum: all of it goes to
///   Parakeet however short it is.
///
/// The tag and the text both count because each catches what the other
/// misses: a slice that mixes Chinese into English is often tagged English,
/// and Qwen3-ASR sometimes writes foreign speech as English while still
/// naming the right language.
enum EnglishStretchRouting {
    static let minimumStretchSeconds: TimeInterval = 180
    static let englishTag = "English"
    /// Qwen3-ASR's language tags for the languages Parakeet Ultra knows. The
    /// European languages Qwen3-ASR does not know (Ukrainian, Croatian,
    /// Bulgarian…) come tagged as a neighbour, often one of these.
    static let parakeetLanguageTags: Set<String> = [
        "English", "German", "French", "Spanish", "Portuguese", "Italian", "Russian", "Dutch",
        "Swedish", "Danish", "Finnish", "Polish", "Czech", "Greek", "Romanian", "Hungarian",
    ]
    /// The language recognizer is unreliable on shorter sentences: it reads
    /// "Bye." as Danish.
    static let minimumCheckedSentenceWords = 5
    /// Spoken fillers, which the recognizer reads as words of other languages:
    /// "um" as Portuguese.
    private static let fillerPattern = #"\b(um+|uh+|er+m?|ah+|hm+|mm+)\b[,.]?\s*"#
    /// Added to a note's model identifier when Parakeet replaced part of its text.
    static let parakeetModelSuffix = "+parakeet"
    /// A note's model identifier when Parakeet wrote all of its text.
    static let parakeetOnlyModelIdentifier = "parakeet-ultra"
    /// What notes Parakeet TDT 0.6B v2 wrote all of carry; the app shipped v2
    /// before Ultra.
    static let legacyParakeetOnlyModelIdentifier = "parakeet-tdt-0.6b-v2"

    /// True when the identifier says Parakeet, of any version, wrote all of a note.
    static func isParakeetOnly(_ identifier: String?) -> Bool {
        identifier == parakeetOnlyModelIdentifier || identifier == legacyParakeetOnlyModelIdentifier
    }

    /// The model identifier of a note whose text Parakeet replaced in part.
    /// Qwen3-ASR names no model when it hears no speech: `nil` means this device's.
    static func modelIdentifier(afterParakeet identifier: String?) -> String {
        let qwen = isParakeetOnly(identifier) ? nil : identifier
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
        /// Qwen3-ASR first: Parakeet takes the long stretches in its languages.
        case automatic
        /// The user chose English & European: Parakeet transcribes the whole recording.
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
            if let text = slice.text, text.utf16.elementsEqual(result.text.utf16) {
                slice.wordTimings = result.wordTimings
            }
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
        let mayGoToParakeet = slices.map(Self.mayGoToParakeet)
        let minimumSeconds = mayGoToParakeet.allSatisfy { $0 } ? 0 : minimumSeconds
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
            if !mayGoToParakeet[index] {
                close()
            } else if let tag = slice.language, parakeetLanguageTags.contains(tag) {
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

    /// False when the slice's tag or its text points to a language Parakeet lacks.
    private static func mayGoToParakeet(_ slice: LanguageTaggedSlice) -> Bool {
        if let tag = slice.language, tag != "None", !parakeetLanguageTags.contains(tag) { return false }
        return slice.text.map(readsAsParakeetLanguage) ?? true
    }

    /// False when the text shows a language Parakeet lacks: a letter outside
    /// the Latin, Cyrillic and Greek alphabets (Chinese, Japanese, Korean,
    /// Arabic…), or a sentence the system's language recognizer gives to a
    /// language outside `parakeetLanguageCodes` (Turkish, Vietnamese…). The
    /// recognizer has to be asked sentence by sentence: asked about a whole
    /// slice, it names the language most of it is in and answers English even
    /// for half English, half Chinese. It cannot see a few foreign words
    /// inside a sentence.
    static func readsAsParakeetLanguage(_ text: String) -> Bool {
        guard !hasLettersOutsideParakeetScripts(text) else { return false }
        let text = text.replacingOccurrences(
            of: fillerPattern, with: "", options: [.regularExpression, .caseInsensitive])
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return !tokenizer.tokens(for: text.startIndex..<text.endIndex).contains {
            let sentence = text[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            return isChecked(sentence) && isGivenToLanguageParakeetLacks(sentence)
        }
    }

    /// A whole transcript still suits Parakeet with up to this share of its
    /// checked sentences, by characters, given to a language Parakeet does
    /// not know. Across the Latin-only notes on the Mac (2026-11-08) the
    /// recognizer misread one English sentence in a few long English notes
    /// (0.06–0.31%), while notes with real foreign passages ran 4% and up.
    static let foreignShareForParakeetTranscript = 0.01

    /// The languages Parakeet Ultra transcribes, as `NLLanguage` codes:
    /// English and 24 European languages. The recognizer does not know
    /// Slovenian, Latvian, Lithuanian, Estonian or Maltese and reads them as
    /// neighbours in this set (Croatian, Czech, Polish, Finnish). It reads the
    /// garbled Russian Qwen3-ASR writes for Polish or Russian mixed with
    /// English as Kazakh, which Qwen3-ASR does not know either, so "kk" counts.
    static let parakeetLanguageCodes: Set<String> = [
        "en", "de", "fr", "es", "it", "pt", "ru", "uk", "hr", "sl", "lv", "lt", "et",
        "fi", "sv", "da", "nl", "pl", "cs", "sk", "hu", "ro", "bg", "el", "mt", "kk",
    ]
    /// A sentence the recognizer gives to another language still counts when
    /// it rates Parakeet's languages together at least this high.
    static let parakeetConfidenceToKeepSentence = 0.5

    /// Whether a note's whole transcript is in languages Parakeet Ultra knows,
    /// which picks the language a re-transcription offers first: English &
    /// European when it is, Auto Detect (Qwen3-ASR) when it is not. Any letter
    /// outside the Latin, Cyrillic and Greek alphabets (Chinese, Japanese,
    /// Arabic…) rules it out; sentences of another language rule it out only
    /// above `foreignShareForParakeetTranscript`, because one misread sentence
    /// in an hour of speech is not a second language.
    static func transcriptSuitsParakeet(_ text: String) -> Bool {
        guard !hasLettersOutsideParakeetScripts(text) else { return false }
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
            if isGivenToLanguageParakeetLacks(sentence) { foreign += sentence.count }
        }
        return Double(foreign) <= Double(checked) * foreignShareForParakeetTranscript
    }

    private static func hasLettersOutsideParakeetScripts(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard !scalar.isASCII, scalar.properties.isAlphabetic else { return false }
            let name = scalar.properties.name ?? ""
            return !(name.hasPrefix("LATIN") || name.hasPrefix("CYRILLIC") || name.hasPrefix("GREEK"))
        }
    }

    private static func isGivenToLanguageParakeetLacks(_ sentence: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sentence)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              !parakeetLanguageCodes.contains(language.rawValue) else {
            return false
        }
        let known = recognizer.languageHypotheses(withMaximum: 30)
            .filter { parakeetLanguageCodes.contains($0.key.rawValue) }
            .reduce(0) { $0 + $1.value }
        return known < parakeetConfidenceToKeepSentence
    }

    private static func isChecked(_ sentence: String) -> Bool {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        return tokenizer.tokens(for: sentence.startIndex..<sentence.endIndex).count >= minimumCheckedSentenceWords
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
            let buckets = distributeWords(words, over: Array(slices[stretch]))
            for (index, bucket) in zip(stretch, buckets) {
                let rendered = render(bucket)
                result[index].text = rendered?.text
                result[index].wordTimings = rendered?.wordTimings
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
            builder.append(text, start: slice.start, end: slice.end, wordTimings: slice.wordTimings)
        }
        return (lines.joined(separator: "\n"), builder.spans)
    }

    /// Hands each word to the slice its midpoint falls in, so the transcript
    /// keeps one line per slice and the slices' times stay its timeline.
    /// Slices are cut at pauses, so a word rarely straddles a boundary.
    /// Words outside every slice go to the nearest one. Returns one text per
    /// slice, nil where Parakeet heard nothing.
    static func distribute(_ words: [TimedWord], over slices: [LanguageTaggedSlice]) -> [String?] {
        distributeWords(words, over: slices).map { $0.isEmpty ? nil : $0.map(\.text).joined(separator: " ") }
    }

    private static func distributeWords(_ words: [TimedWord], over slices: [LanguageTaggedSlice]) -> [[TimedWord]] {
        guard !slices.isEmpty else { return [] }
        var buckets = [[TimedWord]](repeating: [], count: slices.count)
        var index = 0
        for word in words.sorted(by: { $0.start < $1.start }) {
            let middle = (word.start + word.end) / 2
            while index < slices.count - 1, middle >= slices[index].end { index += 1 }
            buckets[index].append(word)
        }
        return buckets
    }

    /// Keep the exact existing transcript formatting. A timing is attached
    /// only if its word matches literally at the next non-whitespace offset.
    static func render(_ words: some Collection<TimedWord>) -> (text: String, wordTimings: [TranscriptWordTiming]?)? {
        guard let text = LocalTranscriptFinalizer.finalizedText(words.map(\.text).joined(separator: " "))
        else { return nil }
        let source = text as NSString
        let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted
        var cursor = 0
        var timings: [TranscriptWordTiming] = []
        for word in words {
            let surface = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty else { continue }
            let remainder = NSRange(location: cursor, length: source.length - cursor)
            let first = source.rangeOfCharacter(from: nonWhitespace, range: remainder).location
            guard first != NSNotFound else { return (text, nil) }
            let range = source.range(of: surface, options: [.anchored, .literal],
                                     range: NSRange(location: first, length: source.length - first))
            guard range.location != NSNotFound else { return (text, nil) }
            cursor = NSMaxRange(range)
            if word.start.isFinite, word.end.isFinite, word.start >= 0, word.end > word.start {
                timings.append(TranscriptWordTiming(offset: range.location, length: range.length,
                                                    start: word.start, end: word.end))
            }
        }
        guard cursor == source.length else { return (text, nil) }
        return (text, timings.isEmpty ? nil : timings)
    }
}
