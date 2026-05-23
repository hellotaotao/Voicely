//
//  LocalTranscriptFinalizer.swift
//  Voicely
//

import Foundation

struct FinalizedTranscript: Equatable {
    var text: String
    var removedLineCount: Int
    var duplicateLineCount: Int
    var overlapMergeCount: Int

    var changed: Bool {
        removedLineCount > 0 || duplicateLineCount > 0 || overlapMergeCount > 0
    }
}

enum LocalTranscriptFinalizer {
    /// Local-only transcript finalization. This deliberately does not upload audio or text.
    /// It polishes live/local Whisper output by applying deterministic cleanup that is safe
    /// to run by default: non-speech filtering, adjacent duplicate removal, and whitespace normalization.
    static func finalizeTranscript(_ text: String?) -> FinalizedTranscript? {
        guard let text else { return nil }

        let rawLines = text.components(separatedBy: .newlines)
        var finalizedLines: [String] = []
        var removedLineCount = 0
        var duplicateLineCount = 0
        var overlapMergeCount = 0

        for rawLine in rawLines {
            guard let cleanedLine = TranscriptSanitizer.cleanedLine(rawLine) else {
                if !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    removedLineCount += 1
                }
                continue
            }

            if let previous = finalizedLines.last {
                if normalizedForDuplicateDetection(previous) == normalizedForDuplicateDetection(cleanedLine) {
                    duplicateLineCount += 1
                    continue
                }

                if let mergedLine = mergedBoundaryLine(previous: previous, current: cleanedLine) {
                    finalizedLines[finalizedLines.count - 1] = mergedLine
                    overlapMergeCount += 1
                    continue
                }
            }

            finalizedLines.append(cleanedLine)
        }

        let finalizedText = finalizedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalizedText.isEmpty else { return nil }
        return FinalizedTranscript(
            text: finalizedText,
            removedLineCount: removedLineCount,
            duplicateLineCount: duplicateLineCount,
            overlapMergeCount: overlapMergeCount
        )
    }

    static func finalizedText(_ text: String?) -> String? {
        finalizeTranscript(text)?.text
    }

    private static func normalizedForDuplicateDetection(_ text: String) -> String {
        normalizedTokens(in: text).joined(separator: " ")
    }

    private static func mergedBoundaryLine(previous: String, current: String) -> String? {
        let previousWords = words(in: previous)
        let currentWords = words(in: current)
        let previousTokens = previousWords.map(normalizedToken)
        let currentTokens = currentWords.map(normalizedToken)
        let maximumOverlap = min(previousTokens.count, currentTokens.count)

        guard maximumOverlap >= 2 else { return nil }

        for overlap in stride(from: maximumOverlap, through: 2, by: -1) {
            let previousSuffix = Array(previousTokens.suffix(overlap))
            let currentPrefix = Array(currentTokens.prefix(overlap))
            guard previousSuffix == currentPrefix else { continue }

            let overlappedTextLength = previousSuffix.joined(separator: " ").count
            guard overlappedTextLength >= 8 else { continue }

            let remainder = currentWords.dropFirst(overlap)
            guard !remainder.isEmpty else { return previous }
            return (previousWords + remainder).joined(separator: " ")
        }

        return nil
    }

    private static func normalizedTokens(in text: String) -> [String] {
        words(in: text).map(normalizedToken).filter { !$0.isEmpty }
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalizedToken(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
