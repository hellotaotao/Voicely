//
//  LocalTranscriptFinalizer.swift
//  Voicely
//

import Foundation

struct FinalizedTranscript: Equatable {
    var text: String
}

enum LocalTranscriptFinalizer {
    /// Normalizes whitespace only: trims each line and drops blank lines.
    /// Everything the engine wrote stays, non-speech markers and repeated
    /// lines included: slices are contiguous in the audio, so a repeated
    /// line is something that was said twice. Returns nil when there is
    /// nothing but whitespace and punctuation.
    static func finalizeTranscript(_ text: String?) -> FinalizedTranscript? {
        guard let text else { return nil }
        let finalizedText = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard hasContent(finalizedText) else { return nil }
        return FinalizedTranscript(text: finalizedText)
    }

    static func finalizedText(_ text: String?) -> String? {
        finalizeTranscript(text)?.text
    }

    /// True when the text holds anything besides whitespace and punctuation.
    static func hasContent(_ text: String) -> Bool {
        let empty = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return text.unicodeScalars.contains { !empty.contains($0) }
    }
}
