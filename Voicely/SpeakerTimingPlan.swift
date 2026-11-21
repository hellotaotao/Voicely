import Foundation

/// Splits a transcript into words with times the transcription model already
/// calculated (Parakeet) and whole spans without word times (Qwen3-ASR
/// slices), which go to one speaker each. All resulting token offsets are
/// relative to the original transcript, including the spans we skip.
struct SpeakerTimingPlan: Sendable {
    struct FallbackSpan: Sendable {
        let text: String
        let utf16Offset: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    let storedTokens: [SpeakerAlignedToken]
    let fallbackSpans: [FallbackSpan]

    var hasSpeech: Bool { !fallbackSpans.isEmpty || !storedTokens.isEmpty }

    init?(text: String, spans: [TranscriptSpan]) {
        guard !spans.isEmpty else { return nil }
        let transcript = text as NSString
        var offset = 0
        var previousEnd: TimeInterval = 0
        var storedTokens: [SpeakerAlignedToken] = []
        var fallbackSpans: [FallbackSpan] = []

        for span in spans {
            guard span.length > 0, span.length <= transcript.length - offset,
                  span.start.isFinite, span.end.isFinite, span.start >= 0, span.end >= span.start,
                  span.start + 0.001 >= previousEnd else { return nil }
            let spanOffset = offset
            offset += span.length
            previousEnd = span.end
            let piece = transcript.substring(with: NSRange(location: spanOffset, length: span.length))
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix(" transcription unavailable]") { continue }
            let significantCount = piece.unicodeScalars.filter(Self.isSpokenScalar).count
            guard significantCount > 0 else { continue }

            if let tokens = Self.validTokens(in: piece, span: span, offset: spanOffset, significantCount: significantCount) {
                storedTokens += tokens
            } else {
                fallbackSpans.append(.init(text: piece, utf16Offset: spanOffset, start: span.start, end: span.end))
            }
        }
        guard offset == transcript.length else { return nil }
        self.storedTokens = storedTokens
        self.fallbackSpans = fallbackSpans
    }

    private static func validTokens(in piece: String, span: TranscriptSpan, offset: Int,
                                    significantCount: Int) -> [SpeakerAlignedToken]? {
        guard let timings = span.wordTimings, !timings.isEmpty, span.end > span.start else { return nil }
        let source = piece as NSString
        var previousOffset = 0
        var previousStart: TimeInterval = 0
        var covered = 0
        var tokens: [SpeakerAlignedToken] = []

        for word in timings {
            guard word.offset >= previousOffset, word.offset < source.length,
                  word.length > 0, word.length <= source.length - word.offset,
                  word.start.isFinite, word.end.isFinite, word.start >= previousStart, word.end > word.start
            else { return nil }

            // Parakeet routes by the word's midpoint, so cuts near a word can
            // leave its first or last syllable outside the nominal slice.
            let middle = word.start + (word.end - word.start) / 2
            guard middle >= span.start - 0.25, middle <= span.end + 0.25,
                  word.start >= span.start - 2, word.end <= span.end + 2 else { return nil }
            let range = NSRange(location: word.offset, length: word.length)
            guard source.rangeOfComposedCharacterSequences(for: range) == range else { return nil }

            previousOffset = NSMaxRange(range)
            previousStart = word.start
            let rawWord = source.substring(with: range)
            var localOffset = 0
            var firstSpeechOffset: Int?
            var lastSpeechEnd = 0
            for character in rawWord {
                let count = character.unicodeScalars.filter(Self.isSpokenScalar).count
                let end = localOffset + String(character).utf16.count
                if count > 0 {
                    if firstSpeechOffset == nil { firstSpeechOffset = localOffset }
                    lastSpeechEnd = end
                    covered += count
                }
                localOffset = end
            }
            // Keep punctuation in the transcript rather than giving it a
            // speaker/time or letting it put a word across a sentence cut.
            if let firstSpeechOffset {
                tokens.append(.init(range: NSRange(location: offset + word.offset + firstSpeechOffset,
                                                   length: lastSpeechEnd - firstSpeechOffset),
                                    start: word.start, end: word.end))
            }
        }

        // Match the speaker assignment threshold: isolated missing words
        // stay unlabelled instead of discarding otherwise usable timing.
        return Double(covered) >= 0.8 * Double(significantCount) ? tokens : nil
    }

    static func isSpokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }
}
