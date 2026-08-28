//
//  TranscriptAssembler.swift
//  Voicely
//

import Foundation

/// One decoded slice/segment on its way into a note. `words` carry the tokens
/// whose concatenation renders the piece; a wordless piece (placeholder, test
/// override) synthesizes a single token spanning [start, end] so the assembled
/// transcript keeps the invariant `text == words.joined()`.
struct TranscriptPiece {
    var words: [WordToken]

    init(words: [WordToken]) {
        self.words = words
    }

    init(text: String, start: Double, end: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.words = trimmed.isEmpty ? [] : [WordToken(word: trimmed, start: start, end: end)]
    }

    /// Shifts slice-local word times to global recording time.
    func rebased(by offset: Double) -> TranscriptPiece {
        guard offset != 0 else { return self }
        return TranscriptPiece(words: words.map {
            WordToken(word: $0.word, start: $0.start + offset, end: $0.end + offset)
        })
    }

    /// One piece per non-blank line, so text-only inputs (test stubs, overrides,
    /// legacy sidecars) keep the finalizer's line-level filtering granularity.
    static func pieces(fromText text: String, start: Double, end: Double) -> [TranscriptPiece] {
        text.components(separatedBy: .newlines)
            .map { TranscriptPiece(text: $0, start: start, end: end) }
            .filter { !$0.words.isEmpty }
    }
}

struct AssembledTranscript: Equatable {
    var text: String
    var words: [WordToken]
    var droppedNonSpeechCount: Int
    var droppedDuplicateCount: Int
    var overlapMergeCount: Int
    /// True when nothing survived the non-speech filter and the result keeps
    /// whisper's non-speech cues verbatim instead (mirrors the finalizer's
    /// whole-clip-non-speech fallback).
    var isNonSpeechFallback: Bool
}

/// Sanitizes decoded pieces with text and word timings as one unit: dropping a
/// piece drops its words, merging a boundary drops the duplicated head tokens.
/// This is the single place transcript content decisions are made — the plain
/// text is always re-derived from the surviving tokens, never edited on its own.
enum TranscriptAssembler {

    static func assemble(_ pieces: [TranscriptPiece]) -> AssembledTranscript? {
        var kept: [[WordToken]] = []
        var nonSpeech: [[WordToken]] = []
        var droppedNonSpeech = 0
        var droppedDuplicates = 0
        var overlapMerges = 0

        for piece in pieces {
            guard let tokens = trimmedTokens(piece.words) else { continue }
            let pieceText = tokens.map(\.word).joined()

            // A piece with no real speech is filtered out; kept aside verbatim
            // for the all-non-speech fallback.
            if TranscriptSanitizer.cleanedTranscript(pieceText) == nil {
                droppedNonSpeech += 1
                if let previous = nonSpeech.last,
                   previous.count >= 2,
                   tokens.count >= 2,
                   normalizedKey(of: previous) == normalizedKey(of: tokens),
                   timeRangesOverlap(previous, tokens) {
                    continue
                } else {
                    nonSpeech.append(tokens)
                }
                continue
            }

            if let previous = kept.last {
                if previous.count >= 2,
                   tokens.count >= 2,
                   normalizedKey(of: previous) == normalizedKey(of: tokens),
                   timeRangesOverlap(previous, tokens) {
                    droppedDuplicates += 1
                    logDroppedDuplicate(kept: previous, dropped: tokens)
                    continue
                }
                if timeRangesOverlap(previous, tokens),
                   let merged = mergedBoundary(previous: previous, current: tokens) {
                    kept[kept.count - 1] = merged
                    overlapMerges += 1
                    continue
                }
            }
            kept.append(tokens)
        }

        let runs = kept.isEmpty ? nonSpeech : kept
        guard !runs.isEmpty else { return nil }
        let (text, words) = joined(runs)
        return AssembledTranscript(
            text: text,
            words: words,
            droppedNonSpeechCount: droppedNonSpeech,
            droppedDuplicateCount: droppedDuplicates,
            overlapMergeCount: overlapMerges,
            isNonSpeechFallback: kept.isEmpty
        )
    }

    // MARK: - Token helpers

    /// Trims edge whitespace so a piece renders flush after assembly: the first
    /// token loses its whisper-style leading space, edge tokens that were pure
    /// whitespace are dropped. Returns nil when nothing remains.
    private static func trimmedTokens(_ words: [WordToken]) -> [WordToken]? {
        var tokens = words

        while let first = tokens.first {
            let trimmed = String(first.word.drop(while: \.isWhitespace))
            if trimmed.isEmpty {
                tokens.removeFirst()
            } else {
                if trimmed != first.word {
                    tokens[0] = WordToken(word: trimmed, start: first.start, end: first.end)
                }
                break
            }
        }

        while let last = tokens.last {
            let trimmed = String(String(last.word.reversed()).drop(while: \.isWhitespace).reversed())
            if trimmed.isEmpty {
                tokens.removeLast()
            } else {
                if trimmed != last.word {
                    tokens[tokens.count - 1] = WordToken(word: trimmed, start: last.start, end: last.end)
                }
                break
            }
        }

        return tokens.isEmpty ? nil : tokens
    }

    /// Case/punctuation-insensitive identity of a token run, mirroring the
    /// line-duplicate detection the text-only finalizer used.
    private static func normalizedKey(of tokens: [WordToken]) -> String {
        tokens.map(\.word).joined()
            .split(whereSeparator: \.isWhitespace)
            .map(normalizedToken)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedToken(_ text: some StringProtocol) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func timeRange(_ tokens: [WordToken]) -> ClosedRange<Double>? {
        guard let first = tokens.first, let last = tokens.last else { return nil }
        return min(first.start, last.end)...max(first.start, last.end)
    }

    private static func timeRangesOverlap(_ lhs: [WordToken], _ rhs: [WordToken]) -> Bool {
        guard let lhsRange = timeRange(lhs), let rhsRange = timeRange(rhs) else { return false }
        if lhsRange.lowerBound == lhsRange.upperBound,
           rhsRange.lowerBound == rhsRange.upperBound {
            return abs(lhsRange.lowerBound - rhsRange.lowerBound) < 0.25
        }
        return max(lhsRange.lowerBound, rhsRange.lowerBound)
            < min(lhsRange.upperBound, rhsRange.upperBound)
    }

    /// Conservative boundary merge: when the current piece starts with the same
    /// ≥2 tokens (≥8 normalized chars) the previous piece ended with, the head
    /// duplicates are dropped — with their timings — and the remainder is
    /// appended to the previous piece.
    private static func mergedBoundary(previous: [WordToken], current: [WordToken]) -> [WordToken]? {
        let previousNormalized = previous.map { normalizedToken($0.word) }
        let currentNormalized = current.map { normalizedToken($0.word) }
        let maximumOverlap = min(previousNormalized.count, currentNormalized.count)
        guard maximumOverlap >= 2 else { return nil }

        for overlap in stride(from: maximumOverlap, through: 2, by: -1) {
            let previousSuffix = Array(previousNormalized.suffix(overlap))
            let currentPrefix = Array(currentNormalized.prefix(overlap))
            guard previousSuffix == currentPrefix else { continue }

            let overlappedTextLength = previousSuffix.joined(separator: " ").count
            guard overlappedTextLength >= 8 else { continue }

            let remainder = current.dropFirst(overlap)
            guard !remainder.isEmpty else { return previous }
            return previous + Array(remainder)
        }

        return nil
    }

    /// Joins kept runs into the final (text, words) pair, carrying the piece
    /// separator inside the preceding run's last token so the invariant
    /// `text == words.joined()` holds exactly.
    private static func joined(_ runs: [[WordToken]]) -> (String, [WordToken]) {
        var words: [WordToken] = []
        for (index, run) in runs.enumerated() {
            var run = run
            if index < runs.count - 1, let last = run.last {
                run[run.count - 1] = WordToken(word: last.word + "\n", start: last.start, end: last.end)
            }
            words.append(contentsOf: run)
        }
        return (words.map(\.word).joined(), words)
    }

    /// Phase-2 data collection: real-world timestamp shapes of dropped
    /// duplicates inform the future timestamp/VAD-verified dedup design.
    private static func logDroppedDuplicate(kept: [WordToken], dropped: [WordToken]) {
#if DEBUG
        guard let keptFirst = kept.first, let keptLast = kept.last,
              let droppedFirst = dropped.first, let droppedLast = dropped.last else { return }
        let droppedSpan = max(0.001, droppedLast.end - droppedFirst.start)
        let density = Double(dropped.count) / droppedSpan
        print("🔁 [Assembler] duplicate piece dropped: kept \(String(format: "%.2f–%.2f", keptFirst.start, keptLast.end))s, dropped \(String(format: "%.2f–%.2f", droppedFirst.start, droppedLast.end))s, \(dropped.count) tokens, \(String(format: "%.1f", density)) tok/s")
#endif
    }
}

enum TranscriptDegeneracyDetector {
    static func hasCatastrophicRepetition(_ text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: \.isWhitespace)
            .map(normalizedToken)
            .filter { !$0.isEmpty }
        guard tokens.count >= 24 else { return false }

        let maximumMotifLength = min(8, tokens.count / 12)
        guard maximumMotifLength > 0 else { return false }

        for motifLength in 1...maximumMotifLength {
            let motifStart = tokens.count - motifLength
            let motif = Array(tokens[motifStart..<tokens.count])
            var cursor = tokens.count
            var repetitions = 0

            while cursor >= motifLength {
                let candidate = Array(tokens[(cursor - motifLength)..<cursor])
                guard candidate == motif else { break }
                repetitions += 1
                cursor -= motifLength
            }

            if repetitions >= 12, repetitions * motifLength >= 24 {
                return true
            }
        }

        return false
    }

    private static func normalizedToken(_ text: some StringProtocol) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
