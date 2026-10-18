//
//  LocalTranscriptFinalizerTests.swift
//  VoicelyTests
//

import Testing
@testable import Voicely

struct LocalTranscriptFinalizerTests {
    @Test func keepsNonSpeechMarkersAndRepeatedLines() {
        let result = LocalTranscriptFinalizer.finalizeTranscript("""
        hello world
        [silence]
        Hello, world!
        好的。
        好的。
        (music)
        (thank you)
        """)

        #expect(result?.text == "hello world\n[silence]\nHello, world!\n好的。\n好的。\n(music)\n(thank you)")
    }

    @Test func doesNotMergeWordsSharedAcrossLines() {
        let result = LocalTranscriptFinalizer.finalizeTranscript("""
        I need to call Alice tomorrow
        Alice tomorrow about the invoice
        """)

        #expect(result?.text == "I need to call Alice tomorrow\nAlice tomorrow about the invoice")
    }

    @Test func trimsLinesAndDropsBlankOnes() {
        #expect(LocalTranscriptFinalizer.finalizeTranscript("  first  \n\n   \nsecond ")?.text == "first\nsecond")
    }

    @Test func returnsNilWhenNothingWasTranscribed() {
        // Empty, whitespace-only and punctuation-only output means no text at all.
        #expect(LocalTranscriptFinalizer.finalizeTranscript("") == nil)
        #expect(LocalTranscriptFinalizer.finalizeTranscript("   \n  ") == nil)
        #expect(LocalTranscriptFinalizer.finalizeTranscript("。\n…") == nil)
    }

    @Test func nonSpeechMarkersCountAsContent() {
        #expect(LocalTranscriptFinalizer.hasContent("[BLANK_AUDIO]"))
        #expect(LocalTranscriptFinalizer.hasContent("♪"))
        #expect(!LocalTranscriptFinalizer.hasContent(" ., 。！ "))
    }
}
