//
//  TranscriptSanitizer.swift
//  Voicely
//

import Foundation

enum TranscriptSanitizer {
    private static let nonspeechMarkers: Set<String> = [
        "applause",
        "background noise",
        "blank audio",
        "blank_audio",
        "breathing",
        "hum",
        "humming",
        "inaudible",
        "laughing",
        "laughter",
        "music",
        "no audio",
        "noise",
        "silence",
        "silent"
    ]

    static func cleanedTranscript(_ text: String?) -> String? {
        guard let text else { return nil }

        let cleanedLines = text
            .components(separatedBy: .newlines)
            .compactMap(cleanedLine)

        let cleaned = cleanedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    static func cleanedLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalizedCue(trimmed)
        if nonspeechMarkers.contains(normalized) {
            return nil
        }

        if isShortBracketedCue(trimmed, normalized: normalized) {
            return nil
        }

        if isOnlyMusicNotation(trimmed) {
            return nil
        }

        return trimmed
    }

    private static func normalizedCue(_ text: String) -> String {
        let unwrapped = unwrapCueDelimiters(text)
        let separators = CharacterSet(charactersIn: "_-")
            .union(.whitespacesAndNewlines)
            .union(.punctuationCharacters)

        return unwrapped
            .lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func unwrapCueDelimiters(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var didUnwrap = true

        while didUnwrap {
            didUnwrap = false
            for pair in [("[", "]"), ("(", ")"), ("{", "}"), ("<", ">")] {
                if result.hasPrefix(pair.0), result.hasSuffix(pair.1), result.count >= 2 {
                    result = String(result.dropFirst().dropLast())
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    didUnwrap = true
                }
            }
        }

        return result
    }

    private static func isShortBracketedCue(_ text: String, normalized: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWrapped = [
            ("[", "]"),
            ("(", ")"),
            ("{", "}"),
            ("<", ">")
        ].contains { trimmed.hasPrefix($0.0) && trimmed.hasSuffix($0.1) }

        guard isWrapped else { return false }
        let wordCount = normalized.split(separator: " ").count
        return wordCount > 0 && wordCount <= 3
    }

    private static func isOnlyMusicNotation(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { scalar in
            scalar.value == 0x266A || scalar.value == 0x266B || scalar.value == 0x266C || scalar.value == 0x266D
        }
    }
}
