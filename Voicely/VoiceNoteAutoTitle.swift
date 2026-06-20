//
//  VoiceNoteAutoTitle.swift
//  Voicely
//
//  Derives a human-readable note title from the first sentence of a
//  locally-produced transcript. This is deliberately fully on-device:
//  it never uploads audio or text. It exists so recordings get a
//  meaningful title instead of an indistinguishable "Voice Note <time>".
//

import Foundation

enum VoiceNoteAutoTitle {
    /// Maximum number of characters (grapheme clusters) kept for a title
    /// before it is truncated with an ellipsis.
    static let maxLength = 40

    /// Characters that terminate the first "sentence" we use as the title.
    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…",
        "。", "！", "？",   // CJK full-width terminators
        "\n", "\r"
    ]

    /// Returns a title derived from the transcript, or `nil` when the
    /// transcript has no usable speech to title from.
    static func derive(from transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != LocalTranscriptFinalizer.blankAudioTranscript else {
            return nil
        }

        let firstSentence = firstSentence(in: trimmed)
        let candidate = firstSentence.isEmpty ? trimmed : firstSentence
        return truncated(candidate)
    }

    private static func firstSentence(in text: String) -> String {
        var result = ""
        for character in text {
            if sentenceTerminators.contains(character) {
                break
            }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncated(_ text: String) -> String? {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }

        let prefix = collapsed.prefix(maxLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "…"
    }
}
