//
//  TappableTranscriptViewTests.swift
//  VoicelyTests
//

import Testing
import UIKit
@testable import Voicely

struct TappableTranscriptViewTests {

    /// A mid-transcript edit that keeps the unit count and the first/last
    /// timestamps (exactly what `WordToken.reanchored` produces for a one-word
    /// fix) must still rebuild the displayed text.
    @Test @MainActor func rebuildsWhenMiddleWordChangesWithSameCountAndEndpoints() {
        let coordinator = TappableTranscriptView.Coordinator(onWordTap: { _ in })
        let textView = UITextView()
        coordinator.textView = textView

        let original = [
            WordToken(word: "one ", start: 0, end: 1),
            WordToken(word: "two ", start: 1, end: 2),
            WordToken(word: "three", start: 2, end: 3)
        ]
        coordinator.apply(words: original, currentTime: 0)
        #expect(textView.attributedText.string == "one two three")

        let edited = [
            WordToken(word: "one ", start: 0, end: 1),
            WordToken(word: "2 ", start: 1, end: 2),
            WordToken(word: "three", start: 2, end: 3)
        ]
        coordinator.apply(words: edited, currentTime: 0)
        #expect(textView.attributedText.string == "one 2 three")
    }
}
