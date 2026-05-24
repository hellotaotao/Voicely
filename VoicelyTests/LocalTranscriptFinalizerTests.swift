//
//  LocalTranscriptFinalizerTests.swift
//  VoicelyTests
//

import Testing
@testable import Voicely

struct LocalTranscriptFinalizerTests {
    @Test func removesNonSpeechLinesAndAdjacentDuplicates() {
        let result = LocalTranscriptFinalizer.finalizeTranscript("""
        hello world
        [silence]
        Hello, world!
        next thought
        (music)
        """)

        #expect(result?.text == "hello world\nnext thought")
        #expect(result?.removedLineCount == 2)
        #expect(result?.duplicateLineCount == 1)
        #expect(result?.overlapMergeCount == 0)
    }

    @Test func returnsBlankAudioForOnlyNonSpeechText() {
        let result = LocalTranscriptFinalizer.finalizeTranscript("[BLANK_AUDIO]\n(music)")

        #expect(result?.text == "[BLANK_AUDIO]")
        #expect(result?.removedLineCount == 2)
        #expect(result?.duplicateLineCount == 0)
        #expect(result?.overlapMergeCount == 0)
    }

    @Test func mergesConservativeBoundaryOverlap() {
        let result = LocalTranscriptFinalizer.finalizeTranscript("""
        I need to call Alice tomorrow
        Alice tomorrow about the invoice
        """)

        #expect(result?.text == "I need to call Alice tomorrow about the invoice")
        #expect(result?.overlapMergeCount == 1)
    }

    @Test func preservesNonAdjacentRepeatedPhrases() {
        let result = LocalTranscriptFinalizer.finalizeTranscript("""
        agenda item one
        agenda item two
        agenda item one
        """)

        #expect(result?.text == "agenda item one\nagenda item two\nagenda item one")
        #expect(result?.duplicateLineCount == 0)
    }
}
