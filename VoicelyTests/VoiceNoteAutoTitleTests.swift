//
//  VoiceNoteAutoTitleTests.swift
//  VoicelyTests
//

import Testing
@testable import Voicely

struct VoiceNoteAutoTitleTests {
    /// Display width used only by the assertions below: CJK / fullwidth
    /// characters count as 2 columns, everything else as 1. Mirrors the
    /// implementation's intent so we can assert a Chinese and an English title
    /// fill roughly the same single row.
    private func displayWidth(_ string: String) -> Int {
        string.reduce(0) { total, character in
            total + (isWide(character) ? 2 : 1)
        }
    }

    private func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
                 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6,
                 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Fill the row instead of stopping at the first short sentence

    @Test func englishTitleFillsPastFirstShortSentence() {
        let title = VoiceNoteAutoTitle.derive(from: "Hi there. Let us keep going with a few more words")
        #expect(title?.contains("keep going") == true)
    }

    @Test func chineseTitleFillsPastFirstShortSentence() {
        let title = VoiceNoteAutoTitle.derive(from: "你好。今天我们聊聊这个计划")
        #expect(title?.contains("今天") == true)
    }

    @Test func chineseAndEnglishTitlesHaveSimilarDisplayWidth() {
        let english = VoiceNoteAutoTitle.derive(from: String(repeating: "test data ", count: 20)) ?? ""
        let chinese = VoiceNoteAutoTitle.derive(from: String(repeating: "测试内容", count: 20)) ?? ""
        // Both should nearly fill one row, so their display widths are close —
        // not English looking half as long as Chinese.
        #expect(abs(displayWidth(english) - displayWidth(chinese)) <= 8)
    }

    // MARK: - Truncation

    @Test func truncatesLongTitleToAboutOneLineWithEllipsis() {
        let title = VoiceNoteAutoTitle.derive(from: String(repeating: "word ", count: 40))
        #expect(title?.hasSuffix("…") == true)
        #expect(displayWidth(title ?? "") <= 54)
    }

    @Test func truncationKeepsWholeEnglishWord() {
        let title = VoiceNoteAutoTitle.derive(
            from: "Internationalization localization globalization accessibility performance"
        )
        let core = (title ?? "")
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespaces)
        // The budget cut lands inside "accessibility"; we must step back to a
        // whole word rather than emit a half word.
        #expect(core.split(separator: " ").last.map(String.init) == "globalization")
    }

    // MARK: - Preserved behavior

    @Test func keepsShortContentWhole() {
        #expect(VoiceNoteAutoTitle.derive(from: "Just a quick note") == "Just a quick note")
    }

    @Test func dropsTrailingPunctuationAndWhitespace() {
        #expect(VoiceNoteAutoTitle.derive(from: "   Hello there.  ") == "Hello there")
    }

    @Test func usesFirstLineOnly() {
        #expect(VoiceNoteAutoTitle.derive(from: "First line\nSecond line") == "First line")
    }

    @Test func returnsNilForEmptyOrWhitespace() {
        #expect(VoiceNoteAutoTitle.derive(from: "") == nil)
        #expect(VoiceNoteAutoTitle.derive(from: "   \n  ") == nil)
    }

    @Test func returnsNilForNonSpeechOnlyTranscript() {
        // 整段非语音不该当标题:Whisper 原文(music/laughter)与历史 [BLANK_AUDIO] 都跳过。
        #expect(VoiceNoteAutoTitle.derive(from: "(music)") == nil)
        #expect(VoiceNoteAutoTitle.derive(from: "[Laughter]") == nil)
        #expect(VoiceNoteAutoTitle.derive(from: LocalTranscriptFinalizer.blankAudioTranscript) == nil)
    }
}
