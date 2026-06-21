//
//  VoiceNoteAutoTitle.swift
//  Voicely
//
//  Derives a human-readable note title from the start of a locally-produced
//  transcript. This is deliberately fully on-device: it never uploads audio or
//  text. It exists so recordings get a meaningful title instead of an
//  indistinguishable "Voice Note <time>".
//
//  The title is sized by *display width* (CJK / fullwidth characters count as
//  two columns, everything else as one) rather than by character count, so a
//  Chinese title and an English title fill roughly the same single row — a plain
//  character cap made English look half as long. It fills toward that width
//  budget across sentence boundaries instead of stopping at the first short
//  sentence, and steps back to a whole word when an English line is cut.
//

import Foundation

enum VoiceNoteAutoTitle {
    /// Target title length in display columns: CJK / fullwidth characters count
    /// as 2, everything else as 1. Sized a bit beyond a typical single row so
    /// the list's `lineLimit(1)` does the final, device-accurate truncation.
    static let widthBudget = 52

    /// Trailing punctuation stripped from a title (a title shouldn't end on a
    /// dangling sentence mark). Line breaks are included so a stray one at the
    /// end is cleaned too.
    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…",
        "。", "！", "？",   // CJK full-width terminators
        "\n", "\r"
    ]

    /// Returns a title derived from the transcript, or `nil` when the
    /// transcript has no usable speech to title from.
    static func derive(from transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // No real speech to title from (whole transcript is non-speech such as
        // "(music)" / "[Laughter]" / legacy "[BLANK_AUDIO]") — decided by meaning,
        // not by matching a placeholder string.
        guard !trimmed.isEmpty,
              TranscriptSanitizer.cleanedTranscript(trimmed) != nil else {
            return nil
        }

        var taken = ""
        var width = 0
        var truncatedByBudget = false

        for character in trimmed {
            // The title is a single line: stop at the first hard line break.
            if character == "\n" || character == "\r" { break }

            let columnWidth = displayWidth(of: character)
            if width + columnWidth > widthBudget {
                truncatedByBudget = true
                break
            }
            taken.append(character)
            width += columnWidth
        }

        if truncatedByBudget {
            taken = backtrackToWordBoundary(taken, original: trimmed)
        }

        let cleaned = trimTrailing(taken)
        guard !cleaned.isEmpty else { return nil }

        return truncatedByBudget ? cleaned + "…" : cleaned
    }

    // MARK: - Display width

    private static func displayWidth(of character: Character) -> Int {
        for scalar in character.unicodeScalars where isWide(scalar) {
            return 2
        }
        return 1
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,   // Hangul Jamo
             0x2E80...0x303E,   // CJK radicals, Kangxi, CJK symbols & punctuation
             0x3041...0x33FF,   // Hiragana, Katakana, CJK symbols
             0x3400...0x4DBF,   // CJK Unified Ext A
             0x4E00...0x9FFF,   // CJK Unified
             0xA000...0xA4CF,   // Yi
             0xAC00...0xD7A3,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFE30...0xFE4F,   // CJK compatibility forms
             0xFF00...0xFF60,   // Fullwidth forms
             0xFFE0...0xFFE6,   // Fullwidth signs
             0x1F300...0x1FAFF, // Emoji & pictographs
             0x20000...0x3FFFD: // CJK Unified Ext B and beyond
            return true
        default:
            return false
        }
    }

    // MARK: - Word boundary

    /// If the budget cut an ASCII word in half, step back to the last space so
    /// the title ends on a whole word. CJK has no inter-character spacing, so a
    /// hard cut there reads fine and is left alone.
    private static func backtrackToWordBoundary(_ taken: String, original: String) -> String {
        guard let lastTaken = taken.last, isNarrowWordCharacter(lastTaken) else { return taken }
        guard let nextIndex = original.index(original.startIndex, offsetBy: taken.count, limitedBy: original.endIndex),
              nextIndex < original.endIndex,
              isNarrowWordCharacter(original[nextIndex]),
              let spaceIndex = taken.lastIndex(of: " ") else {
            return taken
        }
        return String(taken[..<spaceIndex])
    }

    private static func isNarrowWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber else { return false }
        return displayWidth(of: character) == 1
    }

    // MARK: - Trailing cleanup

    private static func trimTrailing(_ text: String) -> String {
        var result = text
        while let last = result.last,
              last.isWhitespace || sentenceTerminators.contains(last) {
            result.removeLast()
        }
        return result
    }
}
