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

    @Test func keepsWhisperNonSpeechVerbatimWhenWholeClipIsNonSpeech() {
        // 整段都是非语音:如实保留 Whisper 原文(相邻去重),不再抹成 [BLANK_AUDIO]。
        #expect(LocalTranscriptFinalizer.finalizeTranscript("(music)\n(music)")?.text == "(music)")
        #expect(LocalTranscriptFinalizer.finalizeTranscript("[Laughter]")?.text == "[Laughter]")
    }

    @Test func returnsNilWhenNothingWasTranscribed() {
        // 纯空白 / 空输入仍返回 nil —— 这是「真没出文字」,交给上层当真出错处理。
        #expect(LocalTranscriptFinalizer.finalizeTranscript("") == nil)
        #expect(LocalTranscriptFinalizer.finalizeTranscript("   \n  ") == nil)
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
