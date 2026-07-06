//
//  TranscriptAssemblerTests.swift
//  VoicelyTests
//

import Testing
@testable import Voicely

private func tok(_ word: String, _ start: Double, _ end: Double) -> WordToken {
    WordToken(word: word, start: start, end: end)
}

struct TranscriptAssemblerTests {

    // MARK: Invariant

    @Test func assembledTextEqualsJoinedWords() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [tok(" Hello", 0.0, 0.4), tok(" world", 0.4, 0.9)]),
            TranscriptPiece(words: [tok(" Next", 30.0, 30.5), tok(" thought", 30.5, 31.0)])
        ])

        #expect(result?.text == "Hello world\nNext thought")
        #expect(result?.text == result?.words.map(\.word).joined())
        #expect(result?.words.count == 4)
        // Timings survive assembly untouched.
        #expect(result?.words.first?.start == 0.0)
        #expect(result?.words.last?.end == 31.0)
    }

    // MARK: Non-speech filtering drops words too

    @Test func dropsNonSpeechPieceWithItsWords() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [tok(" real", 0, 1), tok(" speech", 1, 2)]),
            TranscriptPiece(words: [tok(" [Music]", 2, 10)]),
            TranscriptPiece(words: [tok(" more", 10, 11), tok(" speech", 11, 12)])
        ])

        #expect(result?.text == "real speech\nmore speech")
        #expect(result?.text == result?.words.map(\.word).joined())
        #expect(result?.words.contains { $0.word.contains("Music") } == false)
        #expect(result?.droppedNonSpeechCount == 1)
    }

    // MARK: Adjacent duplicates drop with their words

    @Test func dropsAdjacentDuplicatePieceWithItsWords() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [tok(" hello", 0, 1), tok(" world", 1, 2)]),
            TranscriptPiece(words: [tok(" Hello,", 2, 3), tok(" world!", 3, 4)])
        ])

        #expect(result?.text == "hello world")
        #expect(result?.words.count == 2)
        // The kept piece is the first one — its timings win.
        #expect(result?.words.last?.end == 2)
        #expect(result?.droppedDuplicateCount == 1)
    }

    @Test func preservesNonAdjacentRepeatedPieces() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [tok("agenda item one", 0, 1)]),
            TranscriptPiece(words: [tok("agenda item two", 1, 2)]),
            TranscriptPiece(words: [tok("agenda item one", 2, 3)])
        ])

        #expect(result?.text == "agenda item one\nagenda item two\nagenda item one")
        #expect(result?.droppedDuplicateCount == 0)
    }

    // MARK: Boundary overlap merge drops the overlapping head tokens

    @Test func mergesBoundaryOverlapDroppingOverlappingTokens() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [
                tok(" I", 0, 1), tok(" need", 1, 2), tok(" to", 2, 3),
                tok(" call", 3, 4), tok(" Alice", 4, 5), tok(" tomorrow", 5, 6)
            ]),
            TranscriptPiece(words: [
                tok(" Alice", 28, 29), tok(" tomorrow", 29, 30),
                tok(" about", 30, 31), tok(" the", 31, 32), tok(" invoice", 32, 33)
            ])
        ])

        #expect(result?.text == "I need to call Alice tomorrow about the invoice")
        #expect(result?.text == result?.words.map(\.word).joined())
        #expect(result?.overlapMergeCount == 1)
        // The kept remainder keeps its own timestamps.
        let aboutToken = result?.words.first { $0.word.contains("about") }
        #expect(aboutToken?.start == 30)
        // The duplicated head tokens are gone: "Alice" appears once, at 4s.
        let aliceTokens = result?.words.filter { $0.word.contains("Alice") } ?? []
        #expect(aliceTokens.count == 1)
        #expect(aliceTokens.first?.start == 4)
    }

    // MARK: All-non-speech fallback keeps whisper verbatim

    @Test func keepsNonSpeechVerbatimWhenEverythingIsNonSpeech() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(text: "(music)", start: 0, end: 10),
            TranscriptPiece(text: "(music)", start: 10, end: 20),
            TranscriptPiece(text: "[Laughter]", start: 20, end: 30)
        ])

        #expect(result?.text == "(music)\n[Laughter]")
        #expect(result?.text == result?.words.map(\.word).joined())
        #expect(result?.isNonSpeechFallback == true)
        // Synthesized tokens carry the piece time ranges (tap seeks to the region).
        #expect(result?.words.first?.start == 0)
        #expect(result?.words.last?.start == 20)
    }

    @Test func speechResultIsNotMarkedAsFallback() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [tok("hello", 0, 1)])
        ])
        #expect(result?.isNonSpeechFallback == false)
    }

    // MARK: Empty input

    @Test func returnsNilForEmptyOrBlankInput() {
        #expect(TranscriptAssembler.assemble([]) == nil)
        #expect(TranscriptAssembler.assemble([TranscriptPiece(text: "   ", start: 0, end: 1)]) == nil)
        #expect(TranscriptAssembler.assemble([TranscriptPiece(words: [])]) == nil)
    }

    // MARK: Wordless pieces synthesize a token

    @Test func synthesizesTokenForWordlessPiece() {
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [tok(" before", 0, 1)]),
            TranscriptPiece(text: "hello there", start: 3, end: 5),
            TranscriptPiece(words: [tok(" after", 6, 7)])
        ])

        #expect(result?.text == "before\nhello there\nafter")
        #expect(result?.text == result?.words.map(\.word).joined())
        let synthesized = result?.words.first { $0.word.contains("hello there") }
        #expect(synthesized?.start == 3)
        #expect(synthesized?.end == 5)
    }

    // MARK: Failed-range placeholders survive the filters

    @Test func keepsFailedRangePlaceholderPiece() {
        let placeholder = SegmentedAudioTranscriber.placeholder(
            forStart: 480_000, end: 960_000, sampleRate: 16_000)
        let result = TranscriptAssembler.assemble([
            TranscriptPiece(words: [tok(" speech", 0, 1)]),
            TranscriptPiece(text: placeholder, start: 30, end: 60),
            TranscriptPiece(words: [tok(" more", 60, 61)])
        ])

        #expect(result?.text == "speech\n\(placeholder)\nmore")
        #expect(result?.text == result?.words.map(\.word).joined())
        #expect(result?.isNonSpeechFallback == false)
    }
}
