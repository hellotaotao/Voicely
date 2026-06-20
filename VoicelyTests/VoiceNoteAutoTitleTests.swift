//
//  VoiceNoteAutoTitleTests.swift
//  VoicelyTests
//

import Testing
@testable import Voicely

struct VoiceNoteAutoTitleTests {
    @Test func derivesFirstEnglishSentence() {
        #expect(VoiceNoteAutoTitle.derive(from: "Hello world. Second sentence.") == "Hello world")
    }

    @Test func derivesFirstChineseSentence() {
        #expect(VoiceNoteAutoTitle.derive(from: "你好世界。第二句也写在这里。") == "你好世界")
    }

    @Test func usesFirstLineWhenNoSentencePunctuation() {
        #expect(VoiceNoteAutoTitle.derive(from: "First line\nSecond line") == "First line")
    }

    @Test func keepsShortSentenceWithoutPunctuation() {
        #expect(VoiceNoteAutoTitle.derive(from: "Just a quick note") == "Just a quick note")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(VoiceNoteAutoTitle.derive(from: "   Hello there.  ") == "Hello there")
    }

    @Test func returnsNilForEmptyOrWhitespace() {
        #expect(VoiceNoteAutoTitle.derive(from: "") == nil)
        #expect(VoiceNoteAutoTitle.derive(from: "   \n  ") == nil)
    }

    @Test func returnsNilForBlankAudioSentinel() {
        #expect(VoiceNoteAutoTitle.derive(from: LocalTranscriptFinalizer.blankAudioTranscript) == nil)
    }

    @Test func truncatesLongSentenceWithEllipsis() {
        let long = "This is a very long opening sentence that keeps going well beyond the limit without stopping"
        let title = VoiceNoteAutoTitle.derive(from: long)
        #expect(title?.hasSuffix("…") == true)
        // At most maxLength characters plus the single ellipsis character.
        #expect((title?.count ?? 0) <= VoiceNoteAutoTitle.maxLength + 1)
    }

    @Test func truncatesLongFirstSentenceBeforeLaterShortOne() {
        let text = String(repeating: "word ", count: 30) + ". short"
        let title = VoiceNoteAutoTitle.derive(from: text)
        #expect(title?.hasSuffix("…") == true)
    }
}
